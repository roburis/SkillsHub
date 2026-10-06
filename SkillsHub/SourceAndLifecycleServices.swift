import Darwin
import Foundation

nonisolated struct SourceTraversalAccess {
    private let contentsHandler: (URL) throws -> [URL]
    private let resourceValuesHandler: (URL, Set<URLResourceKey>) throws -> URLResourceValues
    private let symlinkDestinationHandler: (URL) throws -> String

    init(
        fileManager: FileManager = .default,
        contentsOfDirectory: ((URL) throws -> [URL])? = nil,
        resourceValues: ((URL, Set<URLResourceKey>) throws -> URLResourceValues)? = nil,
        symlinkDestination: ((URL) throws -> String)? = nil
    ) {
        contentsHandler = contentsOfDirectory ?? { directory in
            try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        }
        resourceValuesHandler = resourceValues ?? { url, keys in
            try url.resourceValues(forKeys: keys)
        }
        symlinkDestinationHandler = symlinkDestination ?? { url in
            try fileManager.destinationOfSymbolicLink(atPath: url.path)
        }
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try contentsHandler(url)
    }

    func resourceValues(at url: URL, forKeys keys: Set<URLResourceKey>) throws -> URLResourceValues {
        try resourceValuesHandler(url, keys)
    }

    func destinationOfSymbolicLink(at url: URL) throws -> String {
        try symlinkDestinationHandler(url)
    }
}

nonisolated struct LocalSourceIndexResult: Equatable {
    var source: SkillSource
    var availableSkills: [AvailableSkill]
    var observations: [LocalCandidateObservation]

    var isPlannable: Bool {
        !source.isIndexIncomplete && !availableSkills.isEmpty
    }
}

nonisolated final class LocalSourceIndexer {
    private let fileManager: FileManager
    private let parser: SkillFrontmatterParser
    private let validator: SkillValidator
    private let normalizer: SkillIDNormalizer
    private let manifestBuilder: ContentManifestBuilder
    private let readAccess: ManifestReadAccess
    private let traversal: SourceTraversalAccess
    private let maximumVisitedNodeCount: Int
    private let isCancelled: () -> Bool
    private let now: () -> Date

    init(
        fileManager: FileManager = .default,
        parser: SkillFrontmatterParser = SkillFrontmatterParser(),
        validator: SkillValidator? = nil,
        normalizer: SkillIDNormalizer = SkillIDNormalizer(),
        manifestBuilder: ContentManifestBuilder? = nil,
        traversal: SourceTraversalAccess? = nil,
        readAccess: ManifestReadAccess? = nil,
        maximumVisitedNodeCount: Int = 100_000,
        isCancelled: @escaping () -> Bool = { withUnsafeCurrentTask { $0?.isCancelled ?? false } },
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.parser = parser
        let readAccess = readAccess ?? ManifestReadAccess(fileManager: fileManager)
        self.readAccess = readAccess
        self.validator = validator ?? SkillValidator(fileManager: fileManager, readAccess: readAccess)
        self.normalizer = normalizer
        self.manifestBuilder = manifestBuilder ?? ContentManifestBuilder(fileManager: fileManager, readAccess: readAccess)
        self.traversal = traversal ?? SourceTraversalAccess(fileManager: fileManager)
        self.maximumVisitedNodeCount = maximumVisitedNodeCount
        self.isCancelled = isCancelled
        self.now = now
    }

    func index(directory: URL, sourceID: UUID = UUID(), generation: UInt64 = 0) -> LocalSourceIndexResult {
        let sourceDirectory = directory.standardizedFileURL
        let observedAt = now()
        var source = SkillSource(
            id: sourceID,
            kind: .localDirectory,
            name: sourceDirectory.lastPathComponent,
            localPath: sourceDirectory.path,
            lastCheckedAt: observedAt
        )
        var skills: [AvailableSkill] = []
        var observations: [LocalCandidateObservation] = []

        let rootValues: URLResourceValues
        do {
            rootValues = try traversal.resourceValues(
                at: sourceDirectory,
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            let missing = isMissingFileError(error)
            observations.append(
                observation(
                    sourceID: sourceID,
                    relativePath: ".",
                    name: sourceDirectory.lastPathComponent,
                    detail: missing ? "Selected source does not exist." : String(describing: error),
                    status: missing ? .blocked : .unreadable,
                    reason: missing ? .sourceMissing : .attributesUnreadable,
                    observedAt: observedAt
                )
            )
            return finalize(source: source, skills: skills, observations: observations)
        }
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            observations.append(
                observation(
                    sourceID: sourceID,
                    relativePath: ".",
                    name: sourceDirectory.lastPathComponent,
                    detail: "Selected source is not a directly authorized directory.",
                    status: .blocked,
                    reason: .sourceNotDirectory,
                    observedAt: observedAt
                )
            )
            return finalize(source: source, skills: skills, observations: observations)
        }

        let sourceIdentity: TargetFileIdentity
        let parentIdentity: TargetFileIdentity
        do {
            sourceIdentity = try directoryIdentity(sourceDirectory)
            parentIdentity = try directoryIdentity(sourceDirectory.deletingLastPathComponent())
            source.directoryIdentity = sourceIdentity
        } catch {
            observations.append(observation(
                sourceID: sourceID, relativePath: ".", name: source.name,
                detail: String(describing: error), status: .unreadable,
                reason: .attributesUnreadable, observedAt: observedAt
            ))
            return finalize(source: source, skills: skills, observations: observations)
        }

        scanDirectories(
            sourceDirectory: sourceDirectory,
            sourceID: sourceID,
            generation: generation,
            observedAt: observedAt,
            skills: &skills,
            observations: &observations
        )
        if (try? directoryIdentity(sourceDirectory)) != sourceIdentity
            || (try? directoryIdentity(sourceDirectory.deletingLastPathComponent())) != parentIdentity {
            observations.append(observation(
                sourceID: sourceID, relativePath: ".", name: source.name,
                detail: "Selected source or its parent changed during discovery.", status: .unreadable,
                reason: .sourceChanged, observedAt: observedAt
            ))
        }
        return finalize(source: source, skills: skills, observations: observations)
    }

    private func scanDirectories(
        sourceDirectory: URL,
        sourceID: UUID,
        generation: UInt64,
        observedAt: Date,
        skills: inout [AvailableSkill],
        observations: inout [LocalCandidateObservation]
    ) {
        var pending = [sourceDirectory]
        var visitedNodeCount = 1
        while let directory = pending.popLast() {
            if isCancelled() {
                observations.append(observation(
                    sourceID: sourceID, relativePath: relativeSkillPath(for: directory, sourceDirectory: sourceDirectory),
                    name: directory.lastPathComponent, detail: "Source discovery was cancelled.",
                    status: .unreadable, reason: .scanCancelled, observedAt: observedAt
                ))
                return
            }
            guard visitedNodeCount <= maximumVisitedNodeCount else {
                observations.append(observation(
                    sourceID: sourceID, relativePath: relativeSkillPath(for: directory, sourceDirectory: sourceDirectory),
                    name: directory.lastPathComponent, detail: "Source discovery exceeded its node budget.",
                    status: .unreadable, reason: .traversalBudgetExceeded, observedAt: observedAt
                ))
                return
            }

            let children: [URL]
            do {
                children = try traversal.contentsOfDirectory(at: directory)
            } catch {
                observations.append(observation(
                    sourceID: sourceID, relativePath: relativeSkillPath(for: directory, sourceDirectory: sourceDirectory),
                    name: directory.lastPathComponent, detail: String(describing: error),
                    status: .unreadable, reason: .enumerationFailed, observedAt: observedAt
                ))
                continue
            }
            let nodeCount = visitedNodeCount.addingReportingOverflow(children.count)
            guard !nodeCount.overflow, nodeCount.partialValue <= maximumVisitedNodeCount else {
                observations.append(observation(
                    sourceID: sourceID, relativePath: relativeSkillPath(for: directory, sourceDirectory: sourceDirectory),
                    name: directory.lastPathComponent, detail: "Source discovery exceeded its node budget.",
                    status: .unreadable, reason: .traversalBudgetExceeded, observedAt: observedAt
                ))
                return
            }
            visitedNodeCount = nodeCount.partialValue
            if isCancelled() {
                observations.append(observation(
                    sourceID: sourceID, relativePath: relativeSkillPath(for: directory, sourceDirectory: sourceDirectory),
                    name: directory.lastPathComponent, detail: "Source discovery was cancelled.",
                    status: .unreadable, reason: .scanCancelled, observedAt: observedAt
                ))
                return
            }

            if let entry = children.first(where: { $0.lastPathComponent == "SKILL.md" }) {
                observeCandidateAttempt(
                    at: directory, entry: entry, sourceDirectory: sourceDirectory, sourceID: sourceID,
                    generation: generation, observedAt: observedAt, skills: &skills, observations: &observations
                )
            }
            for child in children.sorted(by: stableURLOrder).reversed() {
                let relativePath = relativeSkillPath(for: child, sourceDirectory: sourceDirectory)
                do {
                    let values = try traversal.resourceValues(at: child, forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true {
                        if child.lastPathComponent == "SKILL.md" { continue }
                        let destination = try traversal.destinationOfSymbolicLink(at: child)
                        let target = destination.hasPrefix("/")
                            ? URL(fileURLWithPath: destination)
                            : child.deletingLastPathComponent().appendingPathComponent(destination)
                        observations.append(observation(
                            sourceID: sourceID, relativePath: relativePath, name: child.lastPathComponent,
                            detail: isInside(target, sourceDirectory: sourceDirectory)
                                ? "Symbolic link was recorded and not traversed."
                                : "Symbolic link leaves the selected source and was not traversed.",
                            status: .warning,
                            reason: isInside(target, sourceDirectory: sourceDirectory) ? .symbolicLinkSkipped : .symlinkEscapesSource,
                            observedAt: observedAt
                        ))
                    } else if values.isDirectory == true {
                        pending.append(child)
                    }
                } catch {
                    observations.append(observation(
                        sourceID: sourceID, relativePath: relativePath, name: child.lastPathComponent,
                        detail: String(describing: error), status: .unreadable,
                        reason: .attributesUnreadable, observedAt: observedAt
                    ))
                }
            }
        }
    }

    private func observeCandidateAttempt(
        at skillDirectory: URL,
        entry: URL,
        sourceDirectory: URL,
        sourceID: UUID,
        generation: UInt64,
        observedAt: Date,
        skills: inout [AvailableSkill],
        observations: inout [LocalCandidateObservation]
    ) {
        let relativePath = relativeSkillPath(for: skillDirectory, sourceDirectory: sourceDirectory)
        let entryIsSymbolicLink: Bool
        var entryContentURL = entry
        do {
            let values = try traversal.resourceValues(at: entry, forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            entryIsSymbolicLink = values.isSymbolicLink == true
            if entryIsSymbolicLink {
                let target = try FileAccessService(fileManager: fileManager).resolvePath(
                    entry.lastPathComponent, relativeTo: skillDirectory, within: sourceDirectory
                ) { url, requiresDirectory in
                    let node = try self.traversal.resourceValues(at: url, forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if node.isSymbolicLink == true { return try self.traversal.destinationOfSymbolicLink(at: url) }
                    guard !requiresDirectory || node.isDirectory == true else {
                        throw FileAccessFailure.unreadable(path: url.path)
                    }
                    return nil
                }
                guard try traversal.resourceValues(at: target, forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw FileAccessFailure.unreadable(path: target.path)
                }
                entryContentURL = target
            } else if values.isRegularFile != true {
                appendUnavailableCandidate(
                    sourceID: sourceID, relativePath: relativePath, name: skillDirectory.lastPathComponent,
                    detail: "SKILL.md is not a regular file.", status: .blocked, reason: .candidateBlocked,
                    generation: generation, observedAt: observedAt, skills: &skills, observations: &observations
                )
                return
            }
        } catch FileAccessFailure.symlinkEscapesRoot {
            appendUnavailableCandidate(
                sourceID: sourceID, relativePath: relativePath, name: skillDirectory.lastPathComponent,
                detail: "SKILL.md symbolic link leaves the selected source.", status: .blocked,
                reason: .symlinkEscapesSource, generation: generation, observedAt: observedAt,
                skills: &skills, observations: &observations
            )
            return
        } catch FileAccessFailure.symlinkCycle {
            appendUnavailableCandidate(
                sourceID: sourceID, relativePath: relativePath, name: skillDirectory.lastPathComponent,
                detail: "SKILL.md symbolic link contains a cycle.", status: .blocked,
                reason: .candidateBlocked, generation: generation, observedAt: observedAt,
                skills: &skills, observations: &observations
            )
            return
        } catch {
            let missing = isMissingFileError(error)
            appendUnavailableCandidate(
                sourceID: sourceID, relativePath: relativePath, name: skillDirectory.lastPathComponent,
                detail: missing ? "SKILL.md symbolic link target is missing." : String(describing: error),
                status: missing ? .blocked : .unreadable,
                reason: missing ? .candidateBlocked : .symlinkUnreadable,
                generation: generation, observedAt: observedAt, skills: &skills, observations: &observations
            )
            return
        }

        do {
            let manifest = try manifestBuilder.build(for: skillDirectory, authorizedRoot: sourceDirectory)
            let bytes: Data
            do {
                bytes = try readAccess.data(at: entryContentURL)
            } catch {
                throw ContentManifestFailure.readFailed(path: entry.path, stage: .content)
            }
            guard let skillText = String(data: bytes, encoding: .utf8) else {
                throw FileAccessFailure.unreadable(path: entry.path)
            }
            let frontmatter: SkillFrontmatter
            do {
                frontmatter = try parser.parse(skillText)
            } catch let error as SkillFrontmatterError {
                let validation = SkillValidationResult.invalidFrontmatter(error)
                let candidateID = StableIdentity.candidateID(sourceID: sourceID, relativePath: relativePath)
                observations.append(
                    observation(
                        sourceID: sourceID,
                        relativePath: relativePath,
                        name: skillDirectory.lastPathComponent,
                        detail: validation.messages.map(\.message).joined(separator: " "),
                        status: .blocked,
                        reason: .candidateBlocked,
                        observedAt: observedAt,
                        manifest: manifest
                    )
                )
                skills.append(
                    AvailableSkill(
                        id: candidateID,
                        sourceID: sourceID,
                        skillPath: relativePath,
                        name: skillDirectory.lastPathComponent,
                        description: "",
                        validation: validation,
                        candidateID: candidateID,
                        manifestDigest: manifest.digest,
                        checkStatus: .blocked,
                        generatedAtGeneration: generation
                    )
                )
                return
            }
            let skillID = normalizer.normalize(frontmatter.name)
            let validation = validator.validate(
                contents: skillText,
                manifest: entryIsSymbolicLink ? manifestReplacingLinkedEntry(manifest, bytes: bytes) : manifest,
                skillDirectory: skillDirectory,
                sourceMetadataPresent: true,
                frontmatter: frontmatter
            )
            var resolvedValidation = validation
            if entryIsSymbolicLink {
                resolvedValidation.risks.append(RiskMarker(
                    id: "linked-skill-entry", kind: .symlink, path: "SKILL.md",
                    detail: "SKILL.md resolves within the selected source."
                ))
                if resolvedValidation.status == .valid { resolvedValidation.status = .warning }
            }
            let status = checkStatus(for: resolvedValidation)
            let reason: LocalSourceObservationReason = status == .valid ? .candidateValid : (status == .warning ? .candidateWarning : .candidateBlocked)
            observations.append(
                observation(
                    sourceID: sourceID,
                    relativePath: relativePath,
                    name: frontmatter.name,
                    detail: resolvedValidation.messages.map(\.message).joined(separator: " "),
                    status: status,
                    reason: reason,
                    observedAt: observedAt,
                    manifest: manifest
                )
            )
            skills.append(
                AvailableSkill(
                    id: skillID,
                    sourceID: sourceID,
                    skillPath: relativePath,
                    name: frontmatter.name,
                    description: frontmatter.description,
                    validation: resolvedValidation,
                    manifestDigest: manifest.digest,
                    checkStatus: status,
                    generatedAtGeneration: generation
                )
            )
        } catch FileAccessFailure.unreadable {
            appendUnavailableCandidate(
                sourceID: sourceID, relativePath: relativePath, name: skillDirectory.lastPathComponent,
                detail: "Candidate could not be read.", status: .unreadable, reason: .candidateUnreadable,
                generation: generation, observedAt: observedAt, skills: &skills, observations: &observations
            )
        } catch ContentManifestFailure.readFailed {
            appendUnavailableCandidate(
                sourceID: sourceID, relativePath: relativePath, name: skillDirectory.lastPathComponent,
                detail: "Candidate manifest could not be read completely.", status: .unreadable,
                reason: .candidateUnreadable, generation: generation, observedAt: observedAt,
                skills: &skills, observations: &observations
            )
        } catch FileAccessFailure.symlinkEscapesRoot {
            appendUnavailableCandidate(
                sourceID: sourceID, relativePath: relativePath, name: skillDirectory.lastPathComponent,
                detail: "Candidate contains a symbolic link outside the selected source.", status: .blocked,
                reason: .symlinkEscapesSource, generation: generation, observedAt: observedAt,
                skills: &skills, observations: &observations
            )
        } catch {
            appendUnavailableCandidate(
                sourceID: sourceID, relativePath: relativePath, name: skillDirectory.lastPathComponent,
                detail: String(describing: error), status: .blocked, reason: .candidateBlocked,
                generation: generation, observedAt: observedAt, skills: &skills, observations: &observations
            )
        }
    }

    private func appendUnavailableCandidate(
        sourceID: UUID,
        relativePath: String,
        name: String,
        detail: String,
        status: CandidateCheckStatus,
        reason: LocalSourceObservationReason,
        generation: UInt64,
        observedAt: Date,
        skills: inout [AvailableSkill],
        observations: inout [LocalCandidateObservation]
    ) {
        let candidateID = StableIdentity.candidateID(sourceID: sourceID, relativePath: relativePath)
        let validation = SkillValidationResult(
            status: .invalid,
            messages: [ValidationMessage(id: reason.rawValue, severity: .error, message: detail)],
            risks: []
        )
        observations.append(observation(
            sourceID: sourceID, relativePath: relativePath, name: name, detail: detail,
            status: status, reason: reason, observedAt: observedAt
        ))
        skills.append(AvailableSkill(
            id: candidateID, sourceID: sourceID, skillPath: relativePath, name: name,
            description: "", validation: validation, candidateID: candidateID,
            checkStatus: status, generatedAtGeneration: generation
        ))
    }

    private func manifestReplacingLinkedEntry(_ manifest: ContentManifest, bytes: Data) -> ContentManifest {
        var resolved = manifest
        guard let index = resolved.entries.firstIndex(where: { $0.relativePath == "SKILL.md" }) else { return manifest }
        resolved.entries[index] = ContentManifestEntry(
            relativePath: "SKILL.md", kind: .file, byteDigest: SHA256Digest.hex(bytes),
            symbolicLinkTarget: nil, isExecutable: false, byteCount: Int64(bytes.count)
        )
        return resolved
    }

    private func directoryIdentity(_ directory: URL) throws -> TargetFileIdentity {
        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let volume = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else {
            throw FileAccessFailure.unreadable(path: directory.path)
        }
        return TargetFileIdentity(volumeNumber: volume.uint64Value, fileNumber: file.uint64Value)
    }

    private func stableURLOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.precomposedStringWithCanonicalMapping
            < rhs.lastPathComponent.precomposedStringWithCanonicalMapping
    }

    private func relativeSkillPath(for skillDirectory: URL, sourceDirectory: URL) -> String {
        let sourcePath = sourceDirectory.standardizedFileURL.path
        let skillPath = skillDirectory.standardizedFileURL.path
        guard skillPath != sourcePath, skillPath.hasPrefix(sourcePath + "/") else {
            return "."
        }
        return String(skillPath.dropFirst(sourcePath.count + 1))
    }

    private func isMissingFileError(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain else {
            return false
        }
        return error.code == CocoaError.Code.fileNoSuchFile.rawValue
            || error.code == CocoaError.Code.fileReadNoSuchFile.rawValue
    }

    private func isInside(_ candidate: URL, sourceDirectory: URL) -> Bool {
        let sourcePath = sourceDirectory.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == sourcePath || candidatePath.hasPrefix(sourcePath + "/")
    }

    private func observation(
        sourceID: UUID,
        relativePath: String,
        name: String,
        detail: String,
        status: CandidateCheckStatus,
        reason: LocalSourceObservationReason,
        observedAt: Date,
        manifest: ContentManifest? = nil
    ) -> LocalCandidateObservation {
        let candidateID = StableIdentity.candidateID(sourceID: sourceID, relativePath: relativePath)
        let fingerprint = manifest?.digest ?? SHA256Digest.hex(
            Data("\(candidateID)|\(status.rawValue)|\(reason.rawValue)|\(detail)".utf8)
        )
        return LocalCandidateObservation(
            candidateID: candidateID,
            sourceID: sourceID,
            relativePath: relativePath,
            name: name,
            detail: detail,
            status: status,
            reason: reason,
            fingerprint: fingerprint,
            observedAt: observedAt,
            manifest: manifest
        )
    }

    private func finalize(
        source: SkillSource,
        skills: [AvailableSkill],
        observations: [LocalCandidateObservation]
    ) -> LocalSourceIndexResult {
        var resolvedSource = source
        let orderedObservations = observations.sorted {
            if $0.relativePath == $1.relativePath {
                return $0.candidateID < $1.candidateID
            }
            if $0.relativePath == "." { return true }
            if $1.relativePath == "." { return false }
            return $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
        }
        let sourceFingerprint = orderedObservations
            .map { "\($0.candidateID)|\($0.status.rawValue)|\($0.reason.rawValue)|\($0.fingerprint)" }
            .joined(separator: "\n")
        resolvedSource.contentFingerprint = SHA256Digest.hex(
            Data("\(source.directoryIdentity?.fingerprint ?? "unavailable")|\(sourceFingerprint)".utf8)
        )
        resolvedSource.isIndexIncomplete = orderedObservations.contains { observation in
            switch observation.reason {
            case .candidateUnreadable, .sourceMissing, .sourceNotDirectory, .enumerationFailed,
                 .attributesUnreadable, .symlinkUnreadable, .traversalBudgetExceeded,
                 .scanCancelled, .sourceChanged:
                true
            default:
                false
            }
        }
        resolvedSource.indexStatusReason = resolvedSource.isIndexIncomplete
            ? orderedObservations.first(where: {
                switch $0.reason {
                case .candidateUnreadable, .sourceMissing, .sourceNotDirectory, .enumerationFailed,
                     .attributesUnreadable, .symlinkUnreadable, .traversalBudgetExceeded,
                     .scanCancelled, .sourceChanged:
                    true
                default:
                    false
                }
            })?.reason.rawValue
            : (skills.isEmpty ? "noSkillFound" : nil)
        resolvedSource.registrationState = resolvedSource.isIndexIncomplete ? .needsAttention : .registered
        return LocalSourceIndexResult(
            source: resolvedSource,
            availableSkills: skills.sorted { $0.skillPath.localizedCaseInsensitiveCompare($1.skillPath) == .orderedAscending },
            observations: orderedObservations
        )
    }

    private func checkStatus(for validation: SkillValidationResult) -> CandidateCheckStatus {
        switch validation.status {
        case .valid: .valid
        case .warning: .warning
        case .invalid: .blocked
        }
    }
}

nonisolated enum SourceDirectoryExchangeError: Error, Equatable {
    case invalidScope
    case factsChanged
    case materialsChanged
    case filesystem(path: String, errno: Int32)
}

nonisolated enum SourceDirectoryExchangeCheckpoint: CaseIterable, Sendable {
    case beforeRecord, afterRecord, beforeExchange, beforePrimitive, afterExchange, beforeReadback, afterReadback, afterObservationRecord
}

/// Confirmation facts and recovery materials, never a successful source revision/baseline.
nonisolated struct SourceDirectoryExchangeRecord: Codable, Equatable, Sendable {
    struct Tree: Codable, Equatable, Sendable {
        let path: String
        let identity: LinkNodeIdentity
        let manifest: ContentManifest
    }

    let schemaVersion: Int
    let operationID: UUID
    let rootPath: String
    let directories: [String: LinkNodeIdentity]
    let originalMetadata: Data
    let metadataIdentity: LinkNodeIdentity
    let current: Tree
    let prepared: Tree

    var operationDirectory: URL { URL(fileURLWithPath: prepared.path).deletingLastPathComponent() }
    var recordURL: URL { operationDirectory.appendingPathComponent("source-exchange.json") }
}

nonisolated struct SourceDirectoryExchangeObservation: Codable, Equatable, Sendable {
    enum TreeState: String, Codable, Sendable { case original, prepared, unknown }
    let current: TreeState
    let retained: TreeState
    let metadataUnchanged: Bool
    let materialsVerified: Bool
}

/// The caller prepares the complete tree in this operation's recovery directory, then explicitly
/// confirms the returned facts. No business metadata commit, cleanup or automatic retry lives here.
nonisolated struct SourceDirectoryExchange {
    var checkpoint: (@Sendable (SourceDirectoryExchangeCheckpoint) throws -> Void)?

    func prepare(rootURL: URL, sourceURL: URL, operationID: UUID) throws -> SourceDirectoryExchangeRecord {
        let root = rootURL.standardizedFileURL
        let source = sourceURL.standardizedFileURL
        let prepared = root.appendingPathComponent(".skillshub-operations/\(operationID.uuidString)/prepared")
        try validateScope(root: root, source: source, prepared: prepared, operationID: operationID)
        let directories = try directoryFacts(root: root, source: source, prepared: prepared)
        let snapshot = try SkillsHubMetadataStore().loadCurrentSnapshot(from: root)
        let metadataURL = root.appendingPathComponent(".skillshub.json")
        let metadataIdentity = try LinkNodeIdentity.read(at: metadataURL)
        let bytes = try Data(contentsOf: metadataURL)
        guard metadataIdentity.kind == S_IFREG,
              metadataIdentity.file == snapshot.metadataFileIdentity,
              SHA256Digest.hex(bytes) == snapshot.metadataDigest else {
            throw SourceDirectoryExchangeError.factsChanged
        }
        let record = SourceDirectoryExchangeRecord(
            schemaVersion: 1, operationID: operationID, rootPath: root.path, directories: directories,
            originalMetadata: bytes, metadataIdentity: metadataIdentity,
            current: try tree(at: source), prepared: try tree(at: prepared)
        )
        try verifyInputs(record, rootURL: root)
        return record
    }

    func execute(
        confirmed record: SourceDirectoryExchangeRecord, rootURL: URL
    ) async throws -> RootWriteQualification<SourceDirectoryExchangeObservation> {
        // Validate before the coordinator can create/open its lock in a supplied Root.
        try verifyDirectories(record, rootURL: rootURL)
        return try await RootMutationOwner.shared.withWriteQualification(at: rootURL) {
            try perform(record, rootURL: rootURL)
        }
    }

    /// Each component is observed independently. A missing/corrupt record cannot authorize replay.
    func observe(_ record: SourceDirectoryExchangeRecord, rootURL: URL) -> SourceDirectoryExchangeObservation {
        func state(at path: String) -> SourceDirectoryExchangeObservation.TreeState {
            guard parentsMatch(record, path: path, rootURL: rootURL),
                  let observed = try? tree(at: URL(fileURLWithPath: path)),
                  parentsMatch(record, path: path, rootURL: rootURL) else { return .unknown }
            if matches(observed, record.current) { return .original }
            if matches(observed, record.prepared) { return .prepared }
            return .unknown
        }
        return SourceDirectoryExchangeObservation(
            current: state(at: record.current.path), retained: state(at: record.prepared.path),
            metadataUnchanged: parentsMatch(record, path: record.rootPath + "/.skillshub.json", rootURL: rootURL)
                && ((try? verifyMetadata(record)) != nil),
            materialsVerified: parentsMatch(record, path: record.recordURL.path, rootURL: rootURL)
                && ((try? verifyMaterials(record)) != nil)
        )
    }

    func loadRecord(operationID: UUID, rootURL: URL) throws -> SourceDirectoryExchangeRecord {
        let root = rootURL.standardizedFileURL
        let directory = root.appendingPathComponent(".skillshub-operations/\(operationID.uuidString)")
        // Refuse links in the recovery path before opening a record.
        for url in [root, directory.deletingLastPathComponent(), directory] {
            guard try LinkNodeIdentity.read(at: url).kind == S_IFDIR else {
                throw SourceDirectoryExchangeError.invalidScope
            }
        }
        let file = directory.appendingPathComponent("source-exchange.json")
        guard try LinkNodeIdentity.read(at: file).kind == S_IFREG else {
            throw SourceDirectoryExchangeError.materialsChanged
        }
        let record = try JSONDecoder().decode(SourceDirectoryExchangeRecord.self, from: Data(contentsOf: file))
        guard record.operationID == operationID else { throw SourceDirectoryExchangeError.materialsChanged }
        guard parentsMatch(record, path: file.path, rootURL: root) else { throw SourceDirectoryExchangeError.materialsChanged }
        try verifyMaterials(record)
        return record
    }

    private func perform(
        _ record: SourceDirectoryExchangeRecord, rootURL: URL
    ) throws -> SourceDirectoryExchangeObservation {
        try Task.checkCancellation()
        try checkpoint?(.beforeRecord)
        try verifyInputs(record, rootURL: rootURL)
        let bytes = try JSONEncoder().encode(record)
        try checkSpace(at: record.operationDirectory, required: UInt64(bytes.count))
        try writeEvidence(bytes, to: record.recordURL, record: record, rootURL: rootURL)
        for path in record.directories.keys.sorted(by: { $0.count > $1.count }) {
            try synchronize(URL(fileURLWithPath: path), directory: true, rootURL: rootURL)
        }
        try verifyMaterials(record)
        try checkpoint?(.afterRecord)
        // Sync both complete trees before changing their names. Never follow source links.
        for input in [record.current, record.prepared] {
            for entry in input.manifest.entries.sorted(by: { $0.relativePath.count > $1.relativePath.count })
                where entry.kind != .symbolicLink {
                try Task.checkCancellation()
                try synchronize(URL(fileURLWithPath: input.path).appendingPathComponent(entry.relativePath),
                                directory: entry.kind == .directory, rootURL: rootURL)
            }
        }
        let source = URL(fileURLWithPath: record.current.path)
        let prepared = URL(fileURLWithPath: record.prepared.path)
        let sourceParent = source.deletingLastPathComponent()
        try withDescriptor(sourceParent, directory: true, rootURL: rootURL) { sourceFD in
            try withDescriptor(record.operationDirectory, directory: true, rootURL: rootURL) { preparedFD in
                try checkpoint?(.beforeExchange)
                try Task.checkCancellation()
                try verifyInputs(record, rootURL: rootURL)
                try verifyMaterials(record)
                try verifyDescriptor(sourceFD, expected: record.directories[sourceParent.path])
                try verifyDescriptor(preparedFD, expected: record.directories[record.operationDirectory.path])
                for fd in [sourceFD, preparedFD] {
                    guard Darwin.faccessat(fd, ".", W_OK | X_OK, 0) == 0 else {
                        throw SourceDirectoryExchangeError.filesystem(path: sourceParent.path, errno: errno)
                    }
                }
                // Content is already present; leave room for evidence, but still propagate ENOSPC.
                try checkSpace(at: record.operationDirectory, required: UInt64(bytes.count))
                let flags = UInt32(RENAME_SWAP) | UInt32(RENAME_NOFOLLOW_ANY) | UInt32(RENAME_RESOLVE_BENEATH)
                try checkpoint?(.beforePrimitive)
                guard Darwin.renameatx_np(sourceFD, source.lastPathComponent, preparedFD, prepared.lastPathComponent, flags) == 0 else {
                    throw SourceDirectoryExchangeError.filesystem(path: source.path, errno: errno)
                }
                // From this point every failure preserves both actual trees; no compensating swap.
                try checkpoint?(.afterExchange)
                for fd in [sourceFD, preparedFD] {
                    guard Darwin.fsync(fd) == 0 else {
                        throw SourceDirectoryExchangeError.filesystem(path: sourceParent.path, errno: errno)
                    }
                }
            }
        }
        try checkpoint?(.beforeReadback)
        try Task.checkCancellation()
        let observed = observe(record, rootURL: rootURL)
        guard observed.current == .prepared, observed.retained == .original,
              observed.metadataUnchanged, observed.materialsVerified else {
            throw SourceDirectoryExchangeError.factsChanged
        }
        try checkpoint?(.afterReadback)
        try verifyDirectories(record, rootURL: rootURL)
        guard observe(record, rootURL: rootURL) == observed else { throw SourceDirectoryExchangeError.factsChanged }
        let observationURL = record.operationDirectory.appendingPathComponent("source-exchange-observation.json")
        let observationBytes = try JSONEncoder().encode(observed)
        try writeEvidence(observationBytes, to: observationURL, record: record, rootURL: rootURL)
        guard try Data(contentsOf: observationURL) == observationBytes else {
            throw SourceDirectoryExchangeError.materialsChanged
        }
        try checkpoint?(.afterObservationRecord)
        // Recheck after the final checkpoint too: observations are not a lock on external writers.
        guard observe(record, rootURL: rootURL) == observed else { throw SourceDirectoryExchangeError.factsChanged }
        return observed
    }

    private func validateScope(root: URL, source: URL, prepared: URL, operationID: UUID) throws {
        let prefix = root.path + "/"
        guard source.path.hasPrefix(prefix), source.path == source.standardizedFileURL.path,
              prepared.path == prepared.standardizedFileURL.path else { throw SourceDirectoryExchangeError.invalidScope }
        let parts = source.path.dropFirst(prefix.count).split(separator: "/")
        guard (parts.count == 2 && parts[0] == "local") || (parts.count == 3 && parts[0] == "github"),
              prepared.path == root.appendingPathComponent(".skillshub-operations/\(operationID.uuidString)/prepared").path else {
            throw SourceDirectoryExchangeError.invalidScope
        }
    }

    private func directoryFacts(root: URL, source: URL, prepared: URL) throws -> [String: LinkNodeIdentity] {
        var result: [String: LinkNodeIdentity] = [:]
        for leaf in [source.deletingLastPathComponent(), prepared.deletingLastPathComponent()] {
            var current = root
            for part in [""] + leaf.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init) {
                if !part.isEmpty { current.appendPathComponent(part) }
                let identity = try LinkNodeIdentity.read(at: current)
                guard identity.kind == S_IFDIR else { throw SourceDirectoryExchangeError.invalidScope }
                result[current.path] = identity
            }
        }
        return result
    }

    private func verifyDirectories(_ record: SourceDirectoryExchangeRecord, rootURL: URL) throws {
        let root = rootURL.standardizedFileURL
        let source = URL(fileURLWithPath: record.current.path).standardizedFileURL
        let prepared = URL(fileURLWithPath: record.prepared.path).standardizedFileURL
        guard record.schemaVersion == 1, record.rootPath == root.path,
              source.path == record.current.path, prepared.path == record.prepared.path else {
            throw SourceDirectoryExchangeError.invalidScope
        }
        try validateScope(root: root, source: source, prepared: prepared, operationID: record.operationID)
        guard try directoryFacts(root: root, source: source, prepared: prepared) == record.directories else {
            throw SourceDirectoryExchangeError.factsChanged
        }
    }

    private func parentsMatch(_ record: SourceDirectoryExchangeRecord, path: String, rootURL: URL) -> Bool {
        let root = rootURL.standardizedFileURL
        guard record.schemaVersion == 1, record.rootPath == root.path,
              path.hasPrefix(root.path + "/"),
              (try? validateScope(root: root, source: URL(fileURLWithPath: record.current.path),
                                  prepared: URL(fileURLWithPath: record.prepared.path), operationID: record.operationID)) != nil else {
            return false
        }
        var directory = root
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        for part in [""] + parent.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init) {
            if !part.isEmpty { directory.appendPathComponent(part) }
            guard let expected = record.directories[directory.path], expected.kind == S_IFDIR,
                  (try? LinkNodeIdentity.read(at: directory)) == expected else { return false }
        }
        return true
    }

    private func verifyInputs(_ record: SourceDirectoryExchangeRecord, rootURL: URL) throws {
        try verifyDirectories(record, rootURL: rootURL)
        try verifyMetadata(record)
        guard matches(try tree(at: URL(fileURLWithPath: record.current.path)), record.current),
              matches(try tree(at: URL(fileURLWithPath: record.prepared.path)), record.prepared) else {
            throw SourceDirectoryExchangeError.factsChanged
        }
        let volume = record.current.identity.file.volumeNumber
        guard record.prepared.identity.file.volumeNumber == volume,
              record.directories.values.allSatisfy({ $0.file.volumeNumber == volume }) else {
            throw SourceDirectoryExchangeError.filesystem(path: record.prepared.path, errno: EXDEV)
        }
        try verifyDirectories(record, rootURL: rootURL)
    }

    private func verifyMetadata(_ record: SourceDirectoryExchangeRecord) throws {
        let file = URL(fileURLWithPath: record.rootPath).appendingPathComponent(".skillshub.json")
        guard try LinkNodeIdentity.read(at: file) == record.metadataIdentity,
              try Data(contentsOf: file) == record.originalMetadata,
              try LinkNodeIdentity.read(at: file) == record.metadataIdentity else {
            throw SourceDirectoryExchangeError.factsChanged
        }
    }

    private func verifyMaterials(_ record: SourceDirectoryExchangeRecord) throws {
        guard try LinkNodeIdentity.read(at: record.recordURL).kind == S_IFREG,
              try JSONDecoder().decode(SourceDirectoryExchangeRecord.self, from: Data(contentsOf: record.recordURL)) == record else {
            throw SourceDirectoryExchangeError.materialsChanged
        }
    }

    private func tree(at url: URL) throws -> SourceDirectoryExchangeRecord.Tree {
        let identity = try LinkNodeIdentity.read(at: url)
        guard identity.kind == S_IFDIR else { throw SourceDirectoryExchangeError.factsChanged }
        let manifest = try ContentManifestBuilder().build(for: url, authorizedRoot: url)
        guard try LinkNodeIdentity.read(at: url) == identity else { throw SourceDirectoryExchangeError.factsChanged }
        return .init(path: url.path, identity: identity, manifest: manifest)
    }

    private func matches(_ lhs: SourceDirectoryExchangeRecord.Tree, _ rhs: SourceDirectoryExchangeRecord.Tree) -> Bool {
        lhs.identity == rhs.identity && lhs.manifest.entries == rhs.manifest.entries && lhs.manifest.digest == rhs.manifest.digest
    }

    private func checkSpace(at url: URL, required: UInt64) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let available = attributes[.systemFreeSize] as? NSNumber, available.uint64Value > required else {
            throw SourceDirectoryExchangeError.filesystem(path: url.path, errno: ENOSPC)
        }
    }

    private func withDescriptor<T>(_ url: URL, directory: Bool, rootURL: URL, body: (Int32) throws -> T) throws -> T {
        let root = rootURL.standardizedFileURL
        let path = url.standardizedFileURL.path
        guard path == root.path || path.hasPrefix(root.path + "/") else { throw SourceDirectoryExchangeError.invalidScope }
        // System aliases above the user-authorized Root (e.g. /var) are allowed; links inside it are not.
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw SourceDirectoryExchangeError.filesystem(path: root.path, errno: errno) }
        defer { Darwin.close(rootFD) }
        let relative = path == root.path ? "." : String(path.dropFirst(root.path.count + 1))
        let fd = Darwin.openat(rootFD, relative, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw SourceDirectoryExchangeError.filesystem(path: url.path, errno: errno) }
        defer { Darwin.close(fd) }
        return try body(fd)
    }

    private func verifyDescriptor(_ fd: Int32, expected: LinkNodeIdentity?) throws {
        var status = stat()
        guard Darwin.fstat(fd, &status) == 0, LinkNodeIdentity(status) == expected else {
            throw SourceDirectoryExchangeError.factsChanged
        }
    }

    private func synchronize(_ url: URL, directory: Bool, rootURL: URL) throws {
        try withDescriptor(url, directory: directory, rootURL: rootURL) { fd in
            var status = stat()
            guard Darwin.fstat(fd, &status) == 0, status.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
                throw SourceDirectoryExchangeError.factsChanged
            }
            if !directory, Darwin.fcntl(fd, F_FULLFSYNC) == 0 { return }
            guard Darwin.fsync(fd) == 0 else { throw SourceDirectoryExchangeError.filesystem(path: url.path, errno: errno) }
        }
    }

    private func writeEvidence(_ data: Data, to file: URL, record: SourceDirectoryExchangeRecord, rootURL: URL) throws {
        guard parentsMatch(record, path: file.path, rootURL: rootURL) else { throw SourceDirectoryExchangeError.materialsChanged }
        try withDescriptor(record.operationDirectory, directory: true, rootURL: rootURL) { directory in
            try verifyDescriptor(directory, expected: record.directories[record.operationDirectory.path])
            let fd = Darwin.openat(directory, file.lastPathComponent, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw SourceDirectoryExchangeError.filesystem(path: file.path, errno: errno) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            if Darwin.fcntl(fd, F_FULLFSYNC) != 0, Darwin.fsync(fd) != 0 {
                throw SourceDirectoryExchangeError.filesystem(path: file.path, errno: errno)
            }
            guard Darwin.fsync(directory) == 0 else { throw SourceDirectoryExchangeError.filesystem(path: file.path, errno: errno) }
            try handle.seek(toOffset: 0)
            guard try handle.readToEnd() == data, parentsMatch(record, path: file.path, rootURL: rootURL) else {
                throw SourceDirectoryExchangeError.materialsChanged
            }
        }
    }
}

nonisolated struct SourceRemovalSkill: Codable, Equatable, Sendable {
    var assetID: UUID
    var skillID: String
    var name: String
    var installedPath: String
}

nonisolated struct SourceRemovalPlan: Equatable, Identifiable, Sendable {
    var id: UUID
    var rootPath: String
    var source: SkillSource
    var sourceIdentity: TargetFileIdentity
    var contentDigest: String
    var metadataGeneration: UInt64
    var metadataDigest: String
    var skills: [SourceRemovalSkill]
    var relationPlans: [ManagedRelationClearPlan]
    var planDigest: String

    var affectedAgents: [String] {
        Array(Set(relationPlans.flatMap { $0.items.map(\.agentDisplayName) })).sorted()
    }
}

nonisolated enum SourceRemovalStage: String, Codable, Equatable, Sendable {
    case confirmed
    case relationshipsCleared = "relationships-cleared"
    case contentTrashed = "content-trashed"
    case completed
    case needsAttention = "needs-attention"
}

nonisolated struct SourceRemovalOperationRecord: Codable, Equatable, Sendable {
    var operationID: UUID
    var planDigest: String
    var rootPath: String
    var sourceID: UUID
    var sourceKind: SkillSourceKind?
    var sourcePath: String
    var sourceIdentity: TargetFileIdentity
    var skillAssetIDs: [UUID]
    var relationIDs: [String]
    var stage: SourceRemovalStage
    var relationResults: [String: String]
    var trashPath: String?
    var metadataGeneration: UInt64?
    var detail: String
    var updatedAt: Date
}

nonisolated struct SourceRemovalResult: Equatable, Sendable {
    var sourceID: UUID
    var sourceName: String
    var relationResults: [ManagedRelationClearResultItem]
    var contentMovedToTrash: Bool
    var trashPath: String?
    var metadataRemoved: Bool
    var operationRecordCompleted: Bool
    var detail: LocalizedMessage

    var succeeded: Bool { contentMovedToTrash && metadataRemoved && operationRecordCompleted }
}

nonisolated enum SourceRemovalError: Error, Equatable, Sendable {
    case invalidScope
    case planChanged
    case relationshipsRemain
    case recordUnavailable
    case trashFailed(String)
    case trashResultUnverified
    case metadataCommitFailed(String)
}

private nonisolated struct SourceRemovalRecordedError: Error {
    var underlying: Error
    var record: SourceRemovalOperationRecord
}

nonisolated final class SourceRemovalService: @unchecked Sendable {
    private let fileManager: FileManager
    private let trashItem: (URL) throws -> URL

    init(
        fileManager: FileManager = .default,
        trashItem: ((URL) throws -> URL)? = nil
    ) {
        self.fileManager = fileManager
        self.trashItem = trashItem ?? { url in
            var resultingURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
            guard let resultingURL else { throw SourceRemovalError.trashResultUnverified }
            return resultingURL as URL
        }
    }

    static func isValidScope(source: SkillSource, rootURL: URL) -> Bool {
        guard let path = source.localPath else { return false }
        let root = rootURL.standardizedFileURL
        let sourceURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard path == sourceURL.path else { return false }
        switch source.kind {
        case .localDirectory, .manualFilesystem:
            return sourceURL.deletingLastPathComponent() == root.appendingPathComponent("local", isDirectory: true)
        case .githubRepository:
            return sourceURL.deletingLastPathComponent().deletingLastPathComponent()
                == root.appendingPathComponent("github", isDirectory: true)
        case .npmPackage:
            return false
        }
    }

    func recoveryOperationIDs(rootURL: URL) throws -> [UUID] {
        let operations = rootURL.standardizedFileURL.appendingPathComponent(".skillshub-operations", isDirectory: true)
        guard fileManager.fileExists(atPath: operations.path) else { return [] }
        guard (try? LinkNodeIdentity.read(at: operations).kind) == S_IFDIR else {
            throw SourceRemovalError.recordUnavailable
        }
        return try fileManager.contentsOfDirectory(at: operations, includingPropertiesForKeys: nil).compactMap { entry in
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  let entryKind = try? LinkNodeIdentity.read(at: entry).kind else { return nil }
            guard entryKind == S_IFDIR else { return id }
            guard (try? LinkNodeIdentity.read(at: entry.appendingPathComponent("source-removal.json"))) != nil else { return nil }
            return id
        }.sorted { $0.uuidString < $1.uuidString }
    }

    func startRecord(for plan: SourceRemovalPlan, rootURL: URL) throws -> SourceRemovalOperationRecord {
        try validate(plan: plan, rootURL: rootURL)
        let record = SourceRemovalOperationRecord(
            operationID: plan.id,
            planDigest: plan.planDigest,
            rootPath: plan.rootPath,
            sourceID: plan.source.id,
            sourceKind: plan.source.kind,
            sourcePath: plan.source.localPath ?? "",
            sourceIdentity: plan.sourceIdentity,
            skillAssetIDs: plan.skills.map(\.assetID).sorted { $0.uuidString < $1.uuidString },
            relationIDs: plan.relationPlans.flatMap { $0.items.map(\.relation.id) }.sorted(),
            stage: .confirmed,
            relationResults: [:],
            trashPath: nil,
            metadataGeneration: nil,
            detail: "Source removal confirmed; no content has moved yet.",
            updatedAt: Date()
        )
        try save(record, rootURL: rootURL, requireExisting: false)
        return record
    }

    func saveRelationResults(
        _ results: [ManagedRelationClearResultItem],
        record: inout SourceRemovalOperationRecord,
        rootURL: URL,
        allCleared: Bool
    ) throws {
        for result in results {
            let originalDetail = SkillsHubLocalization().localized(result.detail, language: .english)
            record.relationResults[result.relation.id] = "\(result.outcome.rawValue): \(originalDetail)"
        }
        record.stage = allCleared ? .relationshipsCleared : .needsAttention
        record.detail = allCleared
            ? "All required managed relationships were cleared."
            : "Required relationship cleanup is incomplete; source content was retained."
        record.updatedAt = Date()
        try save(record, rootURL: rootURL, requireExisting: true)
    }

    func removeContentAndRegistration(
        plan: SourceRemovalPlan,
        record: inout SourceRemovalOperationRecord,
        rootURL: URL,
        metadataStore: SkillsHubMetadataStore
    ) async throws -> RootSnapshot {
        try validate(plan: plan, rootURL: rootURL)
        guard record.stage == .relationshipsCleared,
              record.operationID == plan.id,
              record.planDigest == plan.planDigest else {
            throw SourceRemovalError.recordUnavailable
        }
        let initialRecord = record
        let result: (RootSnapshot, SourceRemovalOperationRecord)
        do {
            result = try await RootMutationOwner.shared.perform(at: rootURL) {
            var nextRecord = initialRecord
            let current = try metadataStore.loadCurrentSnapshot(from: rootURL)
            let assetIDs = Set(plan.skills.map(\.assetID))
            guard self.currentScopeMatches(plan: plan, snapshot: current),
                  current.metadata.enablementIntents.contains(where: { assetIDs.contains($0.assetID) }) == false else {
                throw SourceRemovalError.planChanged
            }

            let sourceURL = URL(fileURLWithPath: plan.source.localPath ?? "", isDirectory: true).standardizedFileURL
            let trashURL: URL
            do {
                trashURL = try self.trashItem(sourceURL).standardizedFileURL
            } catch let error as SourceRemovalError {
                throw error
            } catch {
                throw SourceRemovalError.trashFailed(String(describing: error))
            }
            nextRecord.trashPath = trashURL.path
            guard self.fileManager.fileExists(atPath: sourceURL.path) == false,
                  (try? self.directoryIdentity(trashURL)) == plan.sourceIdentity else {
                nextRecord.stage = .needsAttention
                nextRecord.detail = "Trash returned a destination, but the moved source identity could not be verified."
                nextRecord.updatedAt = Date()
                throw SourceRemovalRecordedError(
                    underlying: SourceRemovalError.trashResultUnverified,
                    record: nextRecord
                )
            }
            nextRecord.stage = .contentTrashed
            nextRecord.detail = "Source content moved to the system Trash; metadata removal is pending."
            nextRecord.updatedAt = Date()
            do {
                try self.save(nextRecord, rootURL: rootURL, requireExisting: true)
            } catch {
                throw SourceRemovalRecordedError(underlying: error, record: nextRecord)
            }

            let snapshot: RootSnapshot
            do {
                snapshot = try metadataStore.commit(at: rootURL, expected: current) { metadata in
                    guard metadata.enablementIntents.contains(where: { assetIDs.contains($0.assetID) }) == false else {
                        throw SourceRemovalError.relationshipsRemain
                    }
                    let skillIDs = Set(plan.skills.map(\.skillID))
                    metadata.sources.removeAll { $0.id == plan.source.id }
                    metadata.availableSkills.removeAll { $0.sourceID == plan.source.id }
                    metadata.installedSkills.removeAll { assetIDs.contains($0.assetID) }
                    let remainingSkillIDs = Set(metadata.installedSkills.map(\.id))
                    let orphanedSkillIDs = skillIDs.subtracting(remainingSkillIDs)
                    for skillID in orphanedSkillIDs {
                        metadata.purposeMetadata[skillID] = nil
                        metadata.validationCache[skillID] = nil
                    }
                }
            } catch {
                throw SourceRemovalError.metadataCommitFailed(String(describing: error))
            }
            nextRecord.stage = .completed
            nextRecord.metadataGeneration = snapshot.generation
            nextRecord.detail = "Source content and active metadata were removed and verified."
            nextRecord.updatedAt = Date()
            try self.save(nextRecord, rootURL: rootURL, requireExisting: true)
                return (snapshot, nextRecord)
            }
        } catch let error as SourceRemovalRecordedError {
            record = error.record
            throw error.underlying
        } catch {
            if let observed = try? loadRecord(operationID: plan.id, rootURL: rootURL) {
                record = observed
            }
            throw error
        }
        record = result.1
        return result.0
    }

    private func validate(plan: SourceRemovalPlan, rootURL: URL) throws {
        let root = rootURL.standardizedFileURL
        guard plan.rootPath == root.path,
              Self.isValidScope(source: plan.source, rootURL: root),
              plan.skills.isEmpty == false else {
            throw SourceRemovalError.invalidScope
        }
    }

    private func currentScopeMatches(plan: SourceRemovalPlan, snapshot: RootSnapshot) -> Bool {
        guard let path = plan.source.localPath,
              (try? directoryIdentity(URL(fileURLWithPath: path, isDirectory: true))) == plan.sourceIdentity,
              (try? ContentManifestBuilder(fileManager: fileManager).build(
                for: URL(fileURLWithPath: path, isDirectory: true),
                authorizedRoot: URL(fileURLWithPath: path, isDirectory: true),
                allowExternalSymbolicLinks: true
              ).digest) == plan.contentDigest else {
            return false
        }
        let expectedAssets = plan.skills.sorted { $0.assetID.uuidString < $1.assetID.uuidString }
        let currentAssets = snapshot.metadata.installedSkills.compactMap { skill -> SourceRemovalSkill? in
            let belongsToSource: Bool
            if plan.source.kind == .manualFilesystem {
                let installed = URL(fileURLWithPath: skill.installedPath, isDirectory: true).standardizedFileURL.path
                belongsToSource = skill.sourceID == nil && skill.sourceKind == .manualFilesystem
                    && (installed == path || installed.hasPrefix(path + "/"))
            } else {
                belongsToSource = skill.sourceID == plan.source.id
            }
            guard belongsToSource else { return nil }
            return SourceRemovalSkill(assetID: skill.assetID, skillID: skill.id, name: skill.name, installedPath: skill.installedPath)
        }.sorted { $0.assetID.uuidString < $1.assetID.uuidString }
        guard currentAssets == expectedAssets else { return false }
        if plan.source.kind == .manualFilesystem {
            return snapshot.metadata.sources.contains { $0.localPath == path } == false
        }
        return snapshot.metadata.sources.first { $0.id == plan.source.id } == plan.source
    }

    private func save(
        _ record: SourceRemovalOperationRecord,
        rootURL: URL,
        requireExisting: Bool
    ) throws {
        let directory = rootURL.standardizedFileURL
            .appendingPathComponent(".skillshub-operations/\(record.operationID.uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("source-removal.json")
        let operations = directory.deletingLastPathComponent()
        guard (try? LinkNodeIdentity.read(at: rootURL.standardizedFileURL).kind) == S_IFDIR else {
            throw SourceRemovalError.recordUnavailable
        }
        if fileManager.fileExists(atPath: operations.path) {
            guard (try? LinkNodeIdentity.read(at: operations).kind) == S_IFDIR else {
                throw SourceRemovalError.recordUnavailable
            }
        } else {
            try fileManager.createDirectory(at: operations, withIntermediateDirectories: false)
            guard (try? LinkNodeIdentity.read(at: operations).kind) == S_IFDIR else {
                throw SourceRemovalError.recordUnavailable
            }
            try synchronize(rootURL.standardizedFileURL, directory: true)
        }
        if requireExisting, (try? LinkNodeIdentity.read(at: file).kind) != S_IFREG {
            throw SourceRemovalError.recordUnavailable
        }
        if requireExisting {
            guard (try? LinkNodeIdentity.read(at: directory).kind) == S_IFDIR else {
                throw SourceRemovalError.recordUnavailable
            }
        } else {
            guard (try? LinkNodeIdentity.read(at: directory)) == nil else {
                throw SourceRemovalError.recordUnavailable
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        guard (try? LinkNodeIdentity.read(at: directory).kind) == S_IFDIR else {
            throw SourceRemovalError.recordUnavailable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: file, options: .atomic)
        guard try Data(contentsOf: file) == data else { throw SourceRemovalError.recordUnavailable }
        try synchronize(file, directory: false)
        try synchronize(directory, directory: true)
    }

    func loadRecord(operationID: UUID, rootURL: URL) throws -> SourceRemovalOperationRecord {
        let operations = rootURL.standardizedFileURL.appendingPathComponent(".skillshub-operations", isDirectory: true)
        let directory = operations.appendingPathComponent(operationID.uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("source-removal.json")
        guard (try? LinkNodeIdentity.read(at: operations).kind) == S_IFDIR,
              (try? LinkNodeIdentity.read(at: directory).kind) == S_IFDIR,
              (try? LinkNodeIdentity.read(at: file).kind) == S_IFREG else {
            throw SourceRemovalError.recordUnavailable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(SourceRemovalOperationRecord.self, from: Data(contentsOf: file))
        guard record.operationID == operationID,
              record.rootPath == rootURL.standardizedFileURL.path else {
            throw SourceRemovalError.recordUnavailable
        }
        return record
    }

    private func directoryIdentity(_ url: URL) throws -> TargetFileIdentity {
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            path.map { Darwin.lstat($0, &value) } ?? -1
        }) == 0, value.st_mode & S_IFMT == S_IFDIR else {
            throw SourceRemovalError.trashResultUnverified
        }
        return TargetFileIdentity(volumeNumber: UInt64(value.st_dev), fileNumber: UInt64(value.st_ino))
    }

    private func synchronize(_ url: URL, directory: Bool) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | (directory ? O_DIRECTORY : 0)) } ?? -1
        }
        guard descriptor >= 0 else { throw SourceRemovalError.recordUnavailable }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw SourceRemovalError.recordUnavailable }
    }
}

nonisolated struct ContentManifestBuilder {
    private let fileManager: FileManager
    private let readAccess: ManifestReadAccess

    init(fileManager: FileManager = .default, readAccess: ManifestReadAccess? = nil) {
        self.fileManager = fileManager
        self.readAccess = readAccess ?? ManifestReadAccess(fileManager: fileManager)
    }

    func build(
        for candidate: URL,
        authorizedRoot: URL,
        allowExternalSymbolicLinks: Bool = false
    ) throws -> ContentManifest {
        let access = FileAccessService(fileManager: fileManager)
        let candidateRoot = candidate.standardizedFileURL
        let authorizedRoot = authorizedRoot.standardizedFileURL
        guard access.isDescendant(candidateRoot, of: authorizedRoot, resolvingSymlinks: false) else {
            throw FileAccessFailure.outsideAuthorizedDirectory(path: candidateRoot.path)
        }

        var entries: [ContentManifestEntry] = []
        try appendNode(
            candidateRoot,
            candidateRoot: candidateRoot,
            authorizedRoot: authorizedRoot,
            allowExternalSymbolicLinks: allowExternalSymbolicLinks,
            entries: &entries
        )

        entries.sort { $0.relativePath < $1.relativePath }
        // Deterministic, unambiguous encoding: Codable escapes every field, so paths containing the
        // former `|`/newline delimiters cannot collide with each other's digests.
        let digestEncoder = JSONEncoder()
        digestEncoder.outputFormatting = [.sortedKeys]
        let digestPayload = try digestEncoder.encode(entries)
        return ContentManifest(
            entries: entries,
            fileCount: entries.filter { $0.kind == .file }.count,
            totalByteCount: entries.reduce(0) { $0 + $1.byteCount },
            digest: SHA256Digest.hex(digestPayload),
            observedAt: Date()
        )
    }

    private func appendNode(
        _ url: URL,
        candidateRoot: URL,
        authorizedRoot: URL,
        allowExternalSymbolicLinks: Bool,
        entries: inout [ContentManifestEntry]
    ) throws {
        let access = FileAccessService(fileManager: fileManager)
        guard access.isDescendant(url, of: candidateRoot, resolvingSymlinks: false) else {
            throw FileAccessFailure.outsideAuthorizedDirectory(path: url.path)
        }
        let relativePath = relativePath(for: url, root: candidateRoot)
        let values: URLResourceValues
        do {
            values = try readAccess.resourceValues(
                at: url,
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .isExecutableKey,
                    .fileSizeKey
                ]
            )
        } catch {
            throw ContentManifestFailure.readFailed(path: url.path, stage: .attributes)
        }

        if values.isSymbolicLink == true {
            let rawTarget: String
            do {
                rawTarget = try readAccess.destinationOfSymbolicLink(at: url)
            } catch {
                throw ContentManifestFailure.readFailed(path: url.path, stage: .symbolicLinkTarget)
            }
            if !allowExternalSymbolicLinks {
                let resolved = try resolvedSymlinkTarget(
                    rawTarget,
                    linkURL: url,
                    authorizedRoot: authorizedRoot,
                    access: access
                )
                guard access.isDescendant(resolved, of: authorizedRoot, resolvingSymlinks: false) else {
                    throw FileAccessFailure.symlinkEscapesRoot(path: url.path)
                }
            }
            entries.append(
                ContentManifestEntry(
                    relativePath: relativePath,
                    kind: .symbolicLink,
                    byteDigest: nil,
                    symbolicLinkTarget: rawTarget,
                    isExecutable: false,
                    byteCount: 0
                )
            )
            return
        }

        if values.isDirectory == true {
            entries.append(
                ContentManifestEntry(
                    relativePath: relativePath,
                    kind: .directory,
                    byteDigest: nil,
                    symbolicLinkTarget: nil,
                    isExecutable: false,
                    byteCount: 0
                )
            )
            let children: [URL]
            do {
                children = try readAccess.contentsOfDirectory(at: url)
            } catch {
                throw ContentManifestFailure.readFailed(path: url.path, stage: .enumeration)
            }
            try assertNoCaseInsensitiveConflicts(children, directory: url)
            for child in children.sorted(by: stableURLOrder) {
                try appendNode(
                    child,
                    candidateRoot: candidateRoot,
                    authorizedRoot: authorizedRoot,
                    allowExternalSymbolicLinks: allowExternalSymbolicLinks,
                    entries: &entries
                )
            }
            return
        }
        guard values.isRegularFile == true else {
            throw ContentManifestFailure.unsupportedNode(path: url.path)
        }
        let data: Data
        do {
            data = try readAccess.data(at: url)
        } catch {
            throw ContentManifestFailure.readFailed(path: url.path, stage: .content)
        }
        entries.append(
            ContentManifestEntry(
                relativePath: relativePath,
                kind: .file,
                byteDigest: SHA256Digest.hex(data),
                symbolicLinkTarget: nil,
                isExecutable: values.isExecutable == true,
                byteCount: Int64(data.count)
            )
        )
    }

    private func assertNoCaseInsensitiveConflicts(_ urls: [URL], directory: URL) throws {
        let grouped = Dictionary(grouping: urls) { url in
            url.lastPathComponent.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
        guard let conflict = grouped.values
            .map({ $0.map(\.lastPathComponent).sorted() })
            .filter({ Set($0).count > 1 })
            .sorted(by: { $0.joined(separator: "\u{0}") < $1.joined(separator: "\u{0}") })
            .first
        else {
            return
        }
        throw ContentManifestFailure.caseInsensitiveConflict(
            directoryPath: directory.path,
            names: conflict
        )
    }

    private func resolvedSymlinkTarget(
        _ initialTarget: String,
        linkURL: URL,
        authorizedRoot: URL,
        access: FileAccessService
    ) throws -> URL {
        var initialLinkPending = true
        do {
            return try access.resolvePath(linkURL.lastPathComponent, relativeTo: linkURL.deletingLastPathComponent(), within: authorizedRoot) { url, requiresDirectory in
                if initialLinkPending && !requiresDirectory {
                    initialLinkPending = false
                    return initialTarget
                }
                do {
                    let values = try readAccess.resourceValues(at: url, forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                    if values.isSymbolicLink == true {
                        return try readAccess.destinationOfSymbolicLink(at: url)
                    }
                    guard !requiresDirectory || values.isDirectory == true else {
                        throw FileAccessFailure.unreadable(path: url.path)
                    }
                    return nil
                } catch {
                    throw ContentManifestFailure.readFailed(path: url.path, stage: .symbolicLinkTarget)
                }
            }
        } catch FileAccessFailure.symlinkEscapesRoot {
            throw FileAccessFailure.symlinkEscapesRoot(path: linkURL.path)
        } catch FileAccessFailure.symlinkCycle {
            throw FileAccessFailure.symlinkCycle(path: linkURL.path)
        }
    }

    private func stableURLOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent < rhs.lastPathComponent
    }

    private func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != rootPath else { return "." }
        return String(path.dropFirst(rootPath.count + 1)).precomposedStringWithCanonicalMapping
    }
}
