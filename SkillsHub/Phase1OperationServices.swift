import Darwin
import Foundation

nonisolated private func sourceImportURL(source: SkillSource, fileManager: FileManager) throws -> URL {
    let path: String?
    let identity: TargetFileIdentity?
    switch source.kind {
    case .localDirectory:
        path = source.externalLocalPath
        identity = source.externalDirectoryIdentity
    case .githubRepository:
        path = source.localPath
        identity = source.directoryIdentity
    case .npmPackage, .manualFilesystem:
        path = nil
        identity = nil
    }
    guard let path, let identity else {
        throw Phase1OperationError.invalidPlan
    }
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory,
          (attributes[.systemNumber] as? NSNumber)?.uint64Value == identity.volumeNumber,
          (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == identity.fileNumber else {
        throw Phase1OperationError.sourceChanged
    }
    return url
}

nonisolated private func managedCopySourceURL(candidate: AvailableSkill, source: SkillSource, fileManager: FileManager) throws -> URL {
    guard source.kind == .localDirectory, let path = source.localPath,
          candidate.sourceID == source.id, candidate.manifestDigest != nil,
          candidate.validation.canInstall, candidate.checkStatus == .valid || candidate.checkStatus == .warning else {
        throw Phase1OperationError.candidateUnavailable
    }
    let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let attributes = try fileManager.attributesOfItem(atPath: root.path)
    guard let identity = source.directoryIdentity,
          attributes[.type] as? FileAttributeType == .typeDirectory,
          (attributes[.systemNumber] as? NSNumber)?.uint64Value == identity.volumeNumber,
          (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == identity.fileNumber else {
        throw Phase1OperationError.sourceChanged
    }
    if candidate.skillPath == "." { return root }
    let components = candidate.skillPath.components(separatedBy: "/")
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw Phase1OperationError.candidateUnavailable
    }
    var directory = root
    for component in components {
        directory.appendPathComponent(component, isDirectory: true)
        guard try fileManager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Phase1OperationError.sourceChanged
        }
    }
    return directory
}

nonisolated enum Phase1OperationKind: String, Codable, Hashable, Sendable {
    case initializeRoot
    case importLocalSource
    case importGitHubSource
    // Retained only so existing recovery records remain readable.
    case registerLocalSource
    case publishManagedCopy
}

nonisolated enum Phase1TaskKind: String, Codable, Hashable, Sendable {
    case initializeRoot
    case importLocalSource
    case importGitHubSource
    case registerLocalSource
    case publishManagedCopy
    case setAgentRelation
    case deleteBrokenLink
    case removeLocalSource
    case updateSource
}

extension Phase1OperationKind {
    nonisolated var taskKind: Phase1TaskKind {
        switch self {
        case .initializeRoot: .initializeRoot
        case .importLocalSource: .importLocalSource
        case .importGitHubSource: .importGitHubSource
        case .registerLocalSource: .registerLocalSource
        case .publishManagedCopy: .publishManagedCopy
        }
    }
}

nonisolated enum RootInitializationEntryKind: String, Codable, Hashable, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case other
}

nonisolated struct RootInitializationEntry: Codable, Hashable, Sendable {
    var name: String
    var kind: RootInitializationEntryKind
}

nonisolated struct RootInitializationFacts: Codable, Hashable, Sendable {
    var rootPath: String
    var volumeNumber: UInt64
    var fileNumber: UInt64
    var isReadable: Bool
    var isWritable: Bool
    var entries: [RootInitializationEntry]

    var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256Digest.hex((try? encoder.encode(self)) ?? Data())
    }

    static func observe(rootURL: URL, fileManager: FileManager) throws -> RootInitializationFacts {
        let normalized = rootURL.standardizedFileURL
        let rootValues = try normalized.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw Phase1OperationError.targetConflict(normalized.path)
        }
        let attributes = try fileManager.attributesOfItem(atPath: normalized.path)
        let volumeNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let children = try fileManager.contentsOfDirectory(
            at: normalized,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        )
        let entries = try children.map { child -> RootInitializationEntry in
            let values = try child.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            let kind: RootInitializationEntryKind
            if values.isSymbolicLink == true {
                kind = .symbolicLink
            } else if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .regularFile
            } else {
                kind = .other
            }
            return RootInitializationEntry(name: child.lastPathComponent, kind: kind)
        }.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return RootInitializationFacts(
            rootPath: normalized.path,
            volumeNumber: volumeNumber,
            fileNumber: fileNumber,
            isReadable: fileManager.isReadableFile(atPath: normalized.path),
            isWritable: fileManager.isWritableFile(atPath: normalized.path),
            entries: entries
        )
    }
}

/// Discovers content in `local/<folder>/` and `github/<owner>/<repo>/`.
/// Initialization and runtime scans share indexing and skip symbolic-link directories.
nonisolated struct RootContentDiscovery: Equatable {
    var installedSkills: [InstalledSkill]
    var availableSkills: [AvailableSkill]
    var localSourceNames: Set<String>

    static func observe(
        rootURL: URL,
        observedAt: Date,
        fileManager: FileManager,
        sources: [SkillSource] = [],
        localOnly: Bool = false
    ) throws -> RootContentDiscovery {
        let layout = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: rootURL)
        func directories(in container: URL) throws -> [URL] {
            let access = FileAccessService(fileManager: fileManager)
            guard !access.isSymlink(container) else {
                throw Phase1OperationError.targetConflict(container.path)
            }
            var node = stat()
            if Darwin.lstat(container.path, &node) != 0 {
                if errno == ENOENT { return [] }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return try fileManager.contentsOfDirectory(
                at: container, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ).filter { child in
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if sources.contains(where: { $0.localPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == child.standardizedFileURL.path }),
                   values.isDirectory != true || values.isSymbolicLink == true {
                    throw Phase1OperationError.targetConflict(child.path)
                }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
        }
        let localChildren = try directories(in: layout.localDirectory)
        var children = localChildren
        if !localOnly {
            for owner in try directories(in: layout.githubDirectory) {
                children.append(contentsOf: try directories(in: owner))
            }
        }
        children.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var installedSkills: [InstalledSkill] = []
        var availableSkills: [AvailableSkill] = []
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let sourceID = sources.first {
                $0.localPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == child.standardizedFileURL.path
            }?.id ?? StableIdentity.uuid(namespace: "root-local-source", value: child.standardizedFileURL.path)
            let index = LocalSourceIndexer(
                fileManager: fileManager,
                now: { observedAt }
            ).index(directory: child, sourceID: sourceID, generation: 0)
            guard index.source.isIndexIncomplete == false else {
                throw Phase1OperationError.candidateUnavailable
            }
            guard index.availableSkills.isEmpty == false else { continue }
            availableSkills.append(contentsOf: index.availableSkills)
            installedSkills.append(contentsOf: index.availableSkills.map { candidate in
                let installedURL = candidate.skillPath == "."
                    ? child
                    : child.appendingPathComponent(candidate.skillPath, isDirectory: true)
                return InstalledSkill(
                    id: SkillIDNormalizer().normalize(candidate.name),
                    sourceID: nil,
                    name: candidate.name,
                    description: candidate.description,
                    installedPath: installedURL.path,
                    sourceKind: .manualFilesystem,
                    validation: candidate.validation,
                    purpose: nil,
                    tagIDs: [],
                    installedAt: observedAt,
                    assetID: StableIdentity.uuid(namespace: "root-local-asset", value: installedURL.path),
                    canonicalPathComponent: candidate.skillPath,
                    currentRevision: candidate.manifestDigest,
                    manifestDigest: candidate.manifestDigest,
                    managedGeneration: 0
                )
            })
        }
        return RootContentDiscovery(
            installedSkills: installedSkills.sorted { $0.installedPath < $1.installedPath },
            availableSkills: availableSkills,
            localSourceNames: Set(localChildren.map(\.lastPathComponent))
        )
    }
}

nonisolated enum Phase1OperationPhase: String, Codable, Hashable, Sendable {
    case preparing
    case waitingConfirmation = "waiting-confirmation"
    case executing
    case observing
    case verifying
    case completed
    case needsAttention = "needs-attention"
}

nonisolated struct Phase1OperationPlan: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var kind: Phase1OperationKind
    var rootPath: String
    var expectedGeneration: UInt64
    var metadataDigest: String
    var factDigest: String
    var planDigest: String
    var createdAt: Date
    var source: SkillSource?
    var candidates: [AvailableSkill]
    var observations: [LocalCandidateObservation]
    var selectedCandidate: AvailableSkill?
    var sourceCandidatePath: String?
    var sourceManifest: ContentManifest?
    var assetID: UUID?
    var targetPath: String?
    var steps: [String]
    var expectedWrites: [String]
    var excludedActions: [String]
    var initializationFacts: RootInitializationFacts? = nil
    var initialMetadata: SkillsHubMetadata? = nil
    var initialLocalState: SkillsHubLocalState? = nil
    var compensationPaths: [String]? = nil
    var metadataFileIdentity: TargetFileIdentity? = nil
    var metadataParentIdentity: TargetFileIdentity? = nil

    func computedDigest() throws -> String {
        var canonical = self
        canonical.planDigest = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return SHA256Digest.hex(try encoder.encode(canonical))
    }
}

nonisolated struct Phase1ConfirmationToken: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var planID: UUID
    var planDigest: String
    var factDigest: String
    var confirmedAt: Date
}

nonisolated struct Phase1TaskEvent: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var phase: Phase1OperationPhase
    var message: LocalizedMessage
    var occurredAt: Date
}

nonisolated struct Phase1RelationTaskEvidence: Codable, Hashable, Sendable {
    var relation: AgentRelationIdentity
    var agentDisplayName: String
    var skillID: String
    var skillName: String
    var desiredEnabled: Bool
    var outcome: String
    var actualDelta: [String]
    var verification: VerificationConclusion
    var limitations: [String]
    var safeNextStep: String
}

nonisolated enum Phase1RecoveryState: String, Codable, Hashable, Sendable {
    init(_ state: RelationActionRecoveryState) {
        switch state {
        case .completed: self = .completed
        case .notCompleted: self = .notCompleted
        case .unknown: self = .unknown
        }
    }
    case completed
    case notCompleted = "not-completed"
    case unknown

    var presentationLabel: String {
        switch self {
        case .completed: "Completed"
        case .notCompleted: "Not completed"
        case .unknown: "Unknown"
        }
    }
}

nonisolated struct Phase1RecoveryComponent: Codable, Hashable, Sendable {
    var kind: String
    var state: Phase1RecoveryState
    var path: String
    var detail: String
}

nonisolated struct Phase1RecoveryEvidence: Codable, Hashable, Sendable {
    var components: [Phase1RecoveryComponent]
    var creationMaterials: CreationMaterialReview? = nil
    var agentID: String? = nil
    var sourceID: UUID? = nil
    var sourceKind: SkillSourceKind? = nil
}

nonisolated struct Phase1TaskRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var kind: Phase1TaskKind
    var title: LocalizedMessage
    var objectID: String
    var phase: Phase1OperationPhase
    var result: LocalizedMessage
    var planDigest: String
    var events: [Phase1TaskEvent]
    var updatedAt: Date
    var relationEvidence: Phase1RelationTaskEvidence? = nil
    var operationPlan: Phase1OperationPlan? = nil
    var recoveryEvidence: Phase1RecoveryEvidence? = nil

    var badgeEligible: Bool {
        phase == .preparing || phase == .waitingConfirmation || phase == .executing || phase == .observing
            || phase == .verifying || phase == .needsAttention
    }
}

nonisolated enum Phase1RelationTaskProjection {
    static func finalPhase(for outcome: ControllerRelationActionOutcome) -> Phase1OperationPhase {
        switch outcome {
        case .succeeded, .noChange:
            .completed
        case .blocked, .failed, .unknown, .stale, .replayed, .cancelled:
            .needsAttention
        }
    }

    static func outcomeLabel(_ outcome: ControllerRelationActionOutcome) -> String {
        switch outcome {
        case .succeeded: "Succeeded"
        case .noChange: "No change"
        case .blocked: "Blocked"
        case .failed: "Failed"
        case .unknown: "Unknown"
        case .stale: "Stale"
        case .replayed: "Duplicate rejected"
        case .cancelled: "Cancelled"
        }
    }
}

nonisolated enum Phase1JournalEventKind: String, Codable, Hashable, Sendable {
    case plan
    case confirmation
    case phase
    case stepStarted
    case stepResult
    case compensation
    case final
}

nonisolated struct Phase1JournalRecord: Codable, Hashable, Sendable {
    var operationID: UUID
    var kind: Phase1OperationKind
    var operationPlan: Phase1OperationPlan?
    var sequence: Int
    var planDigest: String
    var event: Phase1JournalEventKind
    var phase: Phase1OperationPhase
    var objectID: String
    var result: String
    var confirmationTokenID: UUID?
    var occurredAt: Date

    // In-memory progress uses the recorded phase, never guesses semantics from result text.
    var progressMessage: LocalizedMessage {
        switch phase {
        case .preparing: "Preparing the operation."
        case .waitingConfirmation: "Waiting for confirmation."
        case .executing: "Executing the confirmed operation."
        case .observing: "Observing the operation result."
        case .verifying: "Verifying the operation result."
        case .completed: "The operation completed."
        case .needsAttention: "The operation needs attention. Open its details before continuing."
        }
    }
}

nonisolated struct Phase1OperationResult: Sendable {
    var snapshot: RootSnapshot?
    var installedSkill: InstalledSkill?
    var task: Phase1TaskRecord
    var succeeded: Bool
}

nonisolated enum Phase1OperationError: Error, Equatable {
    case invalidPlan
    case staleFacts
    case confirmationMismatch
    case confirmationReplayed
    case candidateUnavailable
    case sourceChanged
    case targetConflict(String)
    case stagingVerificationFailed
    case metadataCommitFailed(String)
    case compensationFailed(String)
    case journalUnavailable
    case injectedFailure(String)
}

nonisolated enum Phase1OperationFaultInjection: Hashable, Sendable {
    case afterRootLayoutDirectory
    case afterRootMetadataCommit
    case afterStagingCopy
    case beforeTargetPublish
    case metadataCommitBeforeCAS
    case afterMetadataCommit
    case journal(Phase1JournalEventKind, String)
}

nonisolated struct Phase1OperationPlanner {
    private let fileManager: FileManager
    private let manifestBuilder: ContentManifestBuilder
    private let normalizer: SkillIDNormalizer

    init(
        fileManager: FileManager = .default,
        manifestBuilder: ContentManifestBuilder? = nil,
        normalizer: SkillIDNormalizer = SkillIDNormalizer()
    ) {
        self.fileManager = fileManager
        self.manifestBuilder = manifestBuilder ?? ContentManifestBuilder(fileManager: fileManager)
        self.normalizer = normalizer
    }

    func rootInitializationPlan(facts: RootInspectionFacts) throws -> Phase1OperationPlan {
        guard facts.snapshot == nil else {
            throw Phase1OperationError.targetConflict(facts.url.path)
        }
        let rootURL = facts.url.standardizedFileURL
        let observed = try RootInitializationFacts.observe(rootURL: rootURL, fileManager: fileManager)
        guard observed.isReadable, observed.isWritable else {
            throw Phase1OperationError.targetConflict(rootURL.path)
        }
        let plannedNames = Set([
            "local",
            "github",
            ".skillshub.json",
            ".skillshub.local.json",
            ".skillshub.operations.jsonl",
            ".skillshub-operations",
            ".skillshub-staging"
        ].map { $0.lowercased() })
        if let conflict = observed.entries.first(where: { entry in
            guard plannedNames.contains(entry.name.lowercased()) else { return false }
            return !(["local", "github"].contains(entry.name) && entry.kind == .directory)
        }) {
            throw Phase1OperationError.targetConflict(
                rootURL.appendingPathComponent(conflict.name).path
            )
        }
        let createdAt = Date(
            timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)
        )
        let discovery = try RootContentDiscovery.observe(
            rootURL: rootURL,
            observedAt: createdAt,
            fileManager: fileManager
        )
        let metadata = SkillsHubMetadata(
            rootConfig: RootConfig(
                rootPath: rootURL.path,
                createdAt: createdAt,
                updatedAt: createdAt
            ),
            installedSkills: discovery.installedSkills
        )
        let existingNames = Set(observed.entries.map(\.name))
        let missingDirectories = ["local", "github"]
            .filter { existingNames.contains($0) == false }
            .map { "\($0)/" }
        var plan = Phase1OperationPlan(
            id: UUID(),
            kind: .initializeRoot,
            rootPath: rootURL.path,
            expectedGeneration: 0,
            metadataDigest: "absent",
            factDigest: observed.digest,
            planDigest: "",
            createdAt: Date(),
            source: nil,
            candidates: [],
            observations: [],
            selectedCandidate: nil,
            sourceCandidatePath: nil,
            sourceManifest: nil,
            assetID: nil,
            targetPath: rootURL.path,
            steps: [
                "Recheck Root identity, node type, permissions, and directory contents",
                "Record the immutable plan and explicit establishment authorization",
                "Create only missing local and github directories",
                "Write initial metadata at schema \(SkillsHubMetadata.currentSchemaVersion), generation 0",
                "Write empty machine-local state",
                "Read back every planned object, journal event, schema, and generation"
            ],
            expectedWrites: missingDirectories + [
                ".skillshub.json",
                ".skillshub.lock",
                ".skillshub.local.json",
                ".skillshub.operations.jsonl"
            ],
            excludedActions: [
                "No existing Root content is modified, moved, or removed",
                "No external source is imported",
                "No GitHub content is materialized and no Agent target is changed",
                "No Skill, script, npm command, or build command is executed"
            ]
        )
        plan.initializationFacts = observed
        plan.initialMetadata = metadata
        plan.initialLocalState = SkillsHubLocalState()
        plan.compensationPaths = []
        plan.metadataParentIdentity = TargetFileIdentity(
            volumeNumber: observed.volumeNumber,
            fileNumber: observed.fileNumber
        )
        return try finalizedPlan(plan)
    }

    func sourceRegistrationPlan(
        directory: URL,
        snapshot: RootSnapshot,
        sourceID: UUID = UUID()
    ) throws -> Phase1OperationPlan {
        let root = URL(fileURLWithPath: snapshot.metadata.rootConfig.rootPath, isDirectory: true)
        guard !FileAccessService(fileManager: fileManager).isDescendant(directory, of: root) else {
            throw Phase1OperationError.candidateUnavailable
        }
        if let existing = snapshot.metadata.sources.first(where: { $0.id == sourceID }) {
            guard existing.kind == .localDirectory,
                  existing.localPath == directory.standardizedFileURL.path else {
                throw Phase1OperationError.sourceChanged
            }
            if let identity = existing.directoryIdentity {
                let attributes = try fileManager.attributesOfItem(atPath: directory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory,
                      (attributes[.systemNumber] as? NSNumber)?.uint64Value == identity.volumeNumber,
                      (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == identity.fileNumber else {
                    throw Phase1OperationError.sourceChanged
                }
            }
        }
        var index = LocalSourceIndexer(fileManager: fileManager).index(
            directory: directory,
            sourceID: sourceID,
            generation: snapshot.generation + 1
        )
        guard index.isPlannable else {
            throw Phase1OperationError.candidateUnavailable
        }
        for candidateIndex in index.availableSkills.indices {
            let key = StableIdentity.candidateID(
                sourceID: sourceID, relativePath: index.availableSkills[candidateIndex].skillPath
            )
            if let previous = snapshot.metadata.availableSkills.first(where: {
                StableIdentity.candidateID(sourceID: $0.sourceID, relativePath: $0.skillPath) == key
            }) {
                index.availableSkills[candidateIndex].candidateID = previous.candidateID
            }
        }
        let factDigest = SHA256Digest.hex(
            Data("\(snapshot.metadataDigest)|\(index.source.contentFingerprint ?? "none")".utf8)
        )
        return try finalizedPlan(
            Phase1OperationPlan(
                id: UUID(),
                kind: .registerLocalSource,
                rootPath: snapshot.metadata.rootConfig.rootPath,
                expectedGeneration: snapshot.generation,
                metadataDigest: snapshot.metadataDigest,
                factDigest: factDigest,
                planDigest: "",
                createdAt: Date(),
                source: index.source,
                candidates: index.availableSkills,
                observations: index.observations,
                selectedCandidate: nil,
                sourceCandidatePath: nil,
                sourceManifest: nil,
                assetID: nil,
                targetPath: nil,
                steps: ["Recheck the selected directory", "Register the source and candidate snapshot", "Read back metadata"],
                expectedWrites: [".skillshub.json", ".skillshub.operations.jsonl"],
                excludedActions: ["No Skill is copied or executed", "No directory outside the selected source is scanned"],
                compensationPaths: [],
                metadataFileIdentity: snapshot.metadataFileIdentity,
                metadataParentIdentity: snapshot.metadataParentIdentity
            )
        )
    }

    func localSourceImportPlan(
        directory: URL,
        rootURL: URL,
        snapshot: RootSnapshot,
        sourceID: UUID = UUID()
    ) throws -> Phase1OperationPlan {
        let sourceURL = directory.standardizedFileURL
        let rootURL = rootURL.standardizedFileURL
        guard snapshot.metadata.rootConfig.rootPath == rootURL.path else {
            throw Phase1OperationError.invalidPlan
        }
        let access = FileAccessService(fileManager: fileManager)
        guard !access.isDescendant(sourceURL, of: rootURL, resolvingSymlinks: false) else {
            throw Phase1OperationError.candidateUnavailable
        }

        let index = LocalSourceIndexer(fileManager: fileManager).index(
            directory: sourceURL,
            sourceID: sourceID,
            generation: snapshot.generation + 1
        )
        guard index.isPlannable, let externalIdentity = index.source.directoryIdentity else {
            throw Phase1OperationError.candidateUnavailable
        }
        try Task.checkCancellation()
        let manifest = try manifestBuilder.build(
            for: sourceURL,
            authorizedRoot: sourceURL,
            allowExternalSymbolicLinks: true
        )
        try Task.checkCancellation()
        let localDirectory = SkillsHubMetadataStore(fileManager: fileManager)
            .rootLayout(for: rootURL)
            .localDirectory
        guard !access.isSymlink(localDirectory), fileManager.fileExists(atPath: localDirectory.path) else {
            throw Phase1OperationError.targetConflict(localDirectory.path)
        }
        let component = sourceURL.lastPathComponent
        guard !component.isEmpty, component != ".", component != "..",
              !component.contains("/"), !component.contains("\\") else {
            throw Phase1OperationError.candidateUnavailable
        }
        let target = localDirectory.appendingPathComponent(component, isDirectory: true)
        guard !access.isSymlink(target), access.linkConflict(at: target, expectedDestination: target) == nil,
              !snapshot.metadata.sources.contains(where: {
                  $0.localPath?.precomposedStringWithCanonicalMapping.lowercased()
                      == target.path.precomposedStringWithCanonicalMapping.lowercased()
              }) else {
            throw Phase1OperationError.targetConflict(target.path)
        }

        var source = index.source
        source.localPath = target.path
        source.externalLocalPath = sourceURL.path
        source.externalDirectoryIdentity = externalIdentity
        source.directoryIdentity = nil
        source.baselineManifest = nil
        let operationID = UUID()
        let factDigest = SHA256Digest.hex(
            Data("\(snapshot.metadataDigest)|\(sourceID.uuidString)|\(manifest.digest)|\(target.path)".utf8)
        )
        return try finalizedPlan(
            Phase1OperationPlan(
                id: operationID,
                kind: .importLocalSource,
                rootPath: rootURL.path,
                expectedGeneration: snapshot.generation,
                metadataDigest: snapshot.metadataDigest,
                factDigest: factDigest,
                planDigest: "",
                createdAt: Date(),
                source: source,
                candidates: index.availableSkills,
                observations: index.observations,
                selectedCandidate: nil,
                sourceCandidatePath: sourceURL.path,
                sourceManifest: manifest,
                assetID: nil,
                targetPath: target.path,
                steps: [
                    "Recheck the complete selected source",
                    "Copy the complete source into operation-owned staging",
                    "Verify every staged node and discovered candidate",
                    "Publish one local source directory without merging",
                    "Commit source, candidate, managed-content, and baseline metadata",
                    "Read back the external source, managed copy, and metadata"
                ],
                expectedWrites: [
                    ".skillshub-operations/\(operationID.uuidString)",
                    target.path,
                    ".skillshub.json",
                    ".skillshub.operations.jsonl"
                ],
                excludedActions: [
                    "The selected external source is not modified or moved",
                    "No Agent relationship is enabled",
                    "No target content is merged or overwritten",
                    "No Skill, script, npm command, or build command is executed"
                ],
                compensationPaths: [
                    rootURL.appendingPathComponent(".skillshub-operations/\(operationID.uuidString)").path,
                    target.path
                ],
                metadataFileIdentity: snapshot.metadataFileIdentity,
                metadataParentIdentity: snapshot.metadataParentIdentity
            )
        )
    }

    func githubSourceImportPlan(
        result: GitHubIndexResult,
        rootURL: URL,
        snapshot: RootSnapshot
    ) throws -> Phase1OperationPlan {
        var source = result.source
        guard result.issue == nil,
              source.kind == .githubRepository,
              source.isIndexIncomplete == false,
              let staged = result.stagedRepository,
              result.availableSkills.isEmpty == false,
              result.availableSkills.allSatisfy({ $0.sourceID == source.id }),
              let identity = source.directoryIdentity,
              try directoryIdentity(staged.directory) == identity else {
            throw Phase1OperationError.candidateUnavailable
        }
        let normalizedRoot = rootURL.standardizedFileURL
        guard snapshot.metadata.rootConfig.rootPath == normalizedRoot.path else {
            throw Phase1OperationError.invalidPlan
        }
        let components = source.name.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components.allSatisfy({ Self.isSafeSourceComponent(String($0)) }) else {
            throw Phase1OperationError.candidateUnavailable
        }
        let layout = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: normalizedRoot)
        let ownerDirectory = layout.githubDirectory.appendingPathComponent(String(components[0]), isDirectory: true)
        let target = ownerDirectory.appendingPathComponent(String(components[1]), isDirectory: true)
        let access = FileAccessService(fileManager: fileManager)
        guard !access.isSymlink(layout.githubDirectory),
              fileManager.fileExists(atPath: layout.githubDirectory.path),
              !access.isSymlink(ownerDirectory),
              !access.isSymlink(target),
              access.linkConflict(at: target, expectedDestination: target) == nil,
              !snapshot.metadata.sources.contains(where: {
                  $0.kind == .githubRepository
                      && ($0.githubRepositoryID == source.githubRepositoryID
                          || $0.localPath?.precomposedStringWithCanonicalMapping.lowercased()
                              == target.path.precomposedStringWithCanonicalMapping.lowercased())
              }) else {
            throw Phase1OperationError.targetConflict(target.path)
        }
        source.localPath = staged.directory.path
        source.baselineManifest = nil
        let operationID = UUID()
        let factDigest = SHA256Digest.hex(
            Data("\(snapshot.metadataDigest)|\(source.id.uuidString)|\(staged.manifest.digest)|\(target.path)".utf8)
        )
        return try finalizedPlan(
            Phase1OperationPlan(
                id: operationID,
                kind: .importGitHubSource,
                rootPath: normalizedRoot.path,
                expectedGeneration: snapshot.generation,
                metadataDigest: snapshot.metadataDigest,
                factDigest: factDigest,
                planDigest: "",
                createdAt: Date(),
                source: source,
                candidates: result.availableSkills,
                observations: [],
                selectedCandidate: nil,
                sourceCandidatePath: staged.directory.path,
                sourceManifest: staged.manifest,
                assetID: nil,
                targetPath: target.path,
                steps: [
                    "Recheck the complete staged repository",
                    "Copy the complete repository into operation-owned staging",
                    "Verify every staged node and discovered candidate",
                    "Publish one GitHub repository directory without merging",
                    "Commit source, candidate, managed-content, commit, and baseline metadata",
                    "Read back the managed repository and metadata"
                ],
                expectedWrites: [
                    ".skillshub-operations/\(operationID.uuidString)",
                    target.path,
                    ".skillshub.json",
                    ".skillshub.operations.jsonl"
                ],
                excludedActions: [
                    "No Agent relationship is enabled",
                    "No target content is merged or overwritten",
                    "No Skill, script, Git command, npm command, or build command is executed"
                ],
                compensationPaths: [
                    normalizedRoot.appendingPathComponent(".skillshub-operations/\(operationID.uuidString)").path,
                    target.path
                ],
                metadataFileIdentity: snapshot.metadataFileIdentity,
                metadataParentIdentity: snapshot.metadataParentIdentity
            )
        )
    }

    private static func isSafeSourceComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private func directoryIdentity(_ url: URL) throws -> TargetFileIdentity {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let volume = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else {
            throw Phase1OperationError.targetConflict(url.path)
        }
        return TargetFileIdentity(volumeNumber: volume.uint64Value, fileNumber: file.uint64Value)
    }

    func managedCopyPlan(
        candidate: AvailableSkill,
        source: SkillSource,
        rootURL: URL,
        snapshot: RootSnapshot,
        assetID: UUID = UUID()
    ) throws -> Phase1OperationPlan {
        let candidateURL = try managedCopySourceURL(candidate: candidate, source: source, fileManager: fileManager)
        let manifest = try manifestBuilder.build(for: candidateURL, authorizedRoot: candidateURL)
        guard candidate.manifestDigest == manifest.digest else {
            throw Phase1OperationError.sourceChanged
        }
        let component = normalizer.normalize(candidate.name)
        guard !component.isEmpty else {
            throw Phase1OperationError.candidateUnavailable
        }
        let localDirectory = SkillsHubMetadataStore(fileManager: fileManager)
            .rootLayout(for: rootURL)
            .localDirectory
        let access = FileAccessService(fileManager: fileManager)
        guard !access.isSymlink(localDirectory),
              fileManager.fileExists(atPath: localDirectory.path) else {
            throw Phase1OperationError.targetConflict(localDirectory.path)
        }
        let target = localDirectory.appendingPathComponent(component, isDirectory: true)
        guard !access.isSymlink(target), access.linkConflict(at: target, expectedDestination: target) == nil else {
            throw Phase1OperationError.targetConflict(target.path)
        }
        let factDigest = SHA256Digest.hex(
            Data("\(snapshot.metadataDigest)|\(candidate.candidateID)|\(manifest.digest)|\(target.path)".utf8)
        )
        let operationID = UUID()
        let steps = [
            "Recheck source manifest and empty target",
            "Copy into operation-owned staging",
            "Verify staging manifest and publish by rename",
            "Commit metadata with expected generation",
            "Observe source and managed copy"
        ]
        let expectedWrites = [
            ".skillshub-staging/\(operationID.uuidString)",
            target.path,
            ".skillshub.json",
            ".skillshub.operations.jsonl"
        ]
        let excludedActions = [
            "The original source is not modified",
            "No Agent relationship is enabled",
            "No Skill, script, npm command, or build command is executed"
        ]
        return try finalizedPlan(
            Phase1OperationPlan(
                id: operationID,
                kind: .publishManagedCopy,
                rootPath: rootURL.path,
                expectedGeneration: snapshot.generation,
                metadataDigest: snapshot.metadataDigest,
                factDigest: factDigest,
                planDigest: "",
                createdAt: Date(),
                source: source,
                candidates: [],
                observations: [],
                selectedCandidate: candidate,
                sourceCandidatePath: candidateURL.path,
                sourceManifest: manifest,
                assetID: assetID,
                targetPath: target.path,
                steps: steps,
                expectedWrites: expectedWrites,
                excludedActions: excludedActions,
                compensationPaths: [
                    rootURL.appendingPathComponent(".skillshub-staging/\(operationID.uuidString)").path,
                    target.path
                ],
                metadataFileIdentity: snapshot.metadataFileIdentity,
                metadataParentIdentity: snapshot.metadataParentIdentity
            )
        )
    }

    func confirmation(for plan: Phase1OperationPlan) -> Phase1ConfirmationToken {
        Phase1ConfirmationToken(
            id: UUID(),
            planID: plan.id,
            planDigest: plan.planDigest,
            factDigest: plan.factDigest,
            confirmedAt: Date()
        )
    }

    private func finalizedPlan(_ plan: Phase1OperationPlan) throws -> Phase1OperationPlan {
        var result = plan
        result.planDigest = try result.computedDigest()
        return result
    }
}

actor Phase1OperationCoordinator {
    private let metadataStore: SkillsHubMetadataStore
    private let fileManager: FileManager
    private let manifestBuilder: ContentManifestBuilder
    private let faultInjection: Phase1OperationFaultInjection?
    private let rootMutationOwner: RootMutationOwner
    private var consumedConfirmationIDs: Set<UUID> = []
    private var cancelledPlanIDs: Set<UUID> = []

    init(
        metadataStore: SkillsHubMetadataStore,
        fileManager: FileManager = .default,
        manifestBuilder: ContentManifestBuilder? = nil,
        faultInjection: Phase1OperationFaultInjection? = nil,
        rootMutationOwner: RootMutationOwner = .shared
    ) {
        self.metadataStore = metadataStore
        self.fileManager = fileManager
        self.manifestBuilder = manifestBuilder ?? ContentManifestBuilder(fileManager: fileManager)
        self.faultInjection = faultInjection
        self.rootMutationOwner = rootMutationOwner
    }

    func commit(
        plan: Phase1OperationPlan,
        confirmation: Phase1ConfirmationToken,
        progress: AsyncStream<Phase1JournalRecord>.Continuation? = nil
    ) async -> Phase1OperationResult {
        defer { progress?.finish() }
        return await rootMutationOwner.perform(at: URL(fileURLWithPath: plan.rootPath, isDirectory: true)) {
            self.commitWithinRootMutation(plan: plan, confirmation: confirmation, progress: progress)
        }
    }

    private func commitWithinRootMutation(
        plan: Phase1OperationPlan,
        confirmation: Phase1ConfirmationToken,
        progress: AsyncStream<Phase1JournalRecord>.Continuation?
    ) -> Phase1OperationResult {
        var events: [Phase1TaskEvent] = []
        let objectID = operationObjectID(for: plan)
        do {
            let journal = Phase1OperationJournal(rootURL: URL(fileURLWithPath: plan.rootPath), fileManager: fileManager, progress: progress)
            try validate(plan: plan, confirmation: confirmation, journal: journal)
            try preflight(plan: plan)
            var sequence = 0
            try append(
                journal: journal,
                plan: plan,
                objectID: objectID,
                sequence: &sequence,
                event: .plan,
                phase: .waitingConfirmation,
                result: "immutable-plan"
            )
            try append(
                journal: journal,
                plan: plan,
                objectID: objectID,
                sequence: &sequence,
                event: .confirmation,
                phase: .waitingConfirmation,
                result: plan.kind == .initializeRoot
                    ? "establishment-authorized"
                    : (plan.kind == .importLocalSource || plan.kind == .importGitHubSource ? "source-import-authorized" : "confirmed"),
                confirmationTokenID: confirmation.id
            )
            consumedConfirmationIDs.insert(confirmation.id)
            events.append(event(
                .waitingConfirmation,
                plan.kind == .initializeRoot
                    ? "Root establishment authorized."
                    : (plan.kind == .importLocalSource || plan.kind == .importGitHubSource ? "Source import authorized." : "Plan confirmed.")
            ))

            switch plan.kind {
            case .initializeRoot:
                return try commitRootInitialization(
                    plan: plan,
                    journal: journal,
                    objectID: objectID,
                    sequence: &sequence,
                    events: &events
                )
            case .importLocalSource, .importGitHubSource:
                return try commitLocalSourceImport(
                    plan: plan,
                    journal: journal,
                    objectID: objectID,
                    sequence: &sequence,
                    events: &events
                )
            case .registerLocalSource:
                return try commitSourceRegistration(
                    plan: plan,
                    journal: journal,
                    objectID: objectID,
                    sequence: &sequence,
                    events: &events
                )
            case .publishManagedCopy:
                return try commitManagedCopy(
                    plan: plan,
                    journal: journal,
                    objectID: objectID,
                    sequence: &sequence,
                    events: &events
                )
            }
        } catch {
            events.append(event(.needsAttention, SkillsHubLocalization.errorPresentation(for: error)))
            return Phase1OperationResult(
                snapshot: plan.kind == .initializeRoot ? nil : try? metadataStore.loadCurrentSnapshot(from: URL(fileURLWithPath: plan.rootPath)),
                installedSkill: nil,
                task: task(
                    plan: plan,
                    objectID: objectID,
                    phase: .needsAttention,
                    result: SkillsHubLocalization.errorPresentation(for: error),
                    events: events
                ),
                succeeded: false
            )
        }
    }

    func recoveredTasks(rootURL: URL) -> [Phase1TaskRecord] {
        (try? Phase1OperationJournal(rootURL: rootURL, fileManager: fileManager).recoverTasks()) ?? []
    }

    func cancel(plan: Phase1OperationPlan) -> Phase1TaskRecord {
        cancelledPlanIDs.insert(plan.id)
        let objectID = operationObjectID(for: plan)
        let message: LocalizedMessage = "Cancelled before confirmation; no authorized write occurred."
        return task(
            plan: plan,
            objectID: objectID,
            phase: .completed,
            result: message,
            events: [event(.completed, message)]
        )
    }

    private func commitRootInitialization(
        plan: Phase1OperationPlan,
        journal: Phase1OperationJournal,
        objectID: String,
        sequence: inout Int,
        events: inout [Phase1TaskEvent]
    ) throws -> Phase1OperationResult {
        guard let plannedFacts = plan.initializationFacts,
              let initialMetadata = plan.initialMetadata,
              let initialLocalState = plan.initialLocalState,
              initialMetadata.schemaVersion == SkillsHubMetadata.currentSchemaVersion,
              initialMetadata.generation == 0,
              initialMetadata.rootConfig.rootPath == plan.rootPath,
              plannedFacts.rootPath == plan.rootPath
        else {
            throw Phase1OperationError.invalidPlan
        }
        let rootURL = URL(fileURLWithPath: plan.rootPath, isDirectory: true).standardizedFileURL
        let layout = metadataStore.rootLayout(for: rootURL)
        try append(
            journal: journal,
            plan: plan,
            objectID: objectID,
            sequence: &sequence,
            event: .stepStarted,
            phase: .executing,
            result: "root-layout"
        )
        events.append(event(.executing, "Creating only missing Root directories."))
        try ensureRootDirectory(layout.localDirectory)
        if faultInjection == .afterRootLayoutDirectory {
            throw Phase1OperationError.injectedFailure("after-root-layout-directory")
        }
        try ensureRootDirectory(layout.githubDirectory)
        try append(
            journal: journal,
            plan: plan,
            objectID: objectID,
            sequence: &sequence,
            event: .stepResult,
            phase: .executing,
            result: "root-layout-created"
        )

        try append(
            journal: journal,
            plan: plan,
            objectID: objectID,
            sequence: &sequence,
            event: .stepStarted,
            phase: .executing,
            result: "initial-metadata"
        )
        let snapshot = try metadataStore.writeInitialMetadata(
            initialMetadata,
            to: rootURL,
            expectedParentIdentity: plan.metadataParentIdentity
        )
        try append(
            journal: journal,
            plan: plan,
            objectID: objectID,
            sequence: &sequence,
            event: .stepResult,
            phase: .executing,
            result: "initial-metadata-committed"
        )
        if faultInjection == .afterRootMetadataCommit {
            throw Phase1OperationError.injectedFailure("after-root-metadata-commit")
        }

        try append(
            journal: journal,
            plan: plan,
            objectID: objectID,
            sequence: &sequence,
            event: .stepStarted,
            phase: .executing,
            result: "initial-local-state"
        )
        try SkillsHubLocalStateStore(fileManager: fileManager).save(initialLocalState, to: rootURL)
        try append(
            journal: journal,
            plan: plan,
            objectID: objectID,
            sequence: &sequence,
            event: .stepResult,
            phase: .executing,
            result: "initial-local-state-committed"
        )

        try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .phase, phase: .observing, result: "root-readback")
        let verifiedSnapshot = try metadataStore.loadCurrentSnapshot(from: rootURL)
        let verifiedLocalState = try SkillsHubLocalStateStore(fileManager: fileManager).load(from: rootURL)
        guard verifiedSnapshot == snapshot else {
            throw Phase1OperationError.metadataCommitFailed("Initial Root snapshot changed during verification.")
        }
        guard verifiedSnapshot.metadata == initialMetadata else {
            throw Phase1OperationError.metadataCommitFailed("Initial Root metadata does not match the authorized plan.")
        }
        guard verifiedLocalState == initialLocalState else {
            throw Phase1OperationError.stagingVerificationFailed
        }
        let verifiedDiscovery = try RootContentDiscovery.observe(
            rootURL: rootURL,
            observedAt: initialMetadata.rootConfig.createdAt,
            fileManager: fileManager
        )
        guard verifiedDiscovery.installedSkills == initialMetadata.installedSkills else {
            throw Phase1OperationError.sourceChanged
        }
        guard try rootMatchesPlannedInitialization(
            rootURL: rootURL,
            plannedFacts: plannedFacts
        ) else {
            throw Phase1OperationError.stagingVerificationFailed
        }
        events.append(event(.observing, "Every planned Root object was read back."))
        try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .phase, phase: .verifying, result: "root-verified")
        try append(
            journal: journal,
            plan: plan,
            objectID: objectID,
            sequence: &sequence,
            event: .final,
            phase: .completed,
            result: "root-initialized"
        )
        try journal.verifyCompletedPlan(plan)
        events.append(event(.verifying, "Schema, generation, local state, and journal were verified."))
        events.append(event(.completed, "Root established from the authorized plan."))
        return Phase1OperationResult(
            snapshot: verifiedSnapshot,
            installedSkill: nil,
            task: task(
                plan: plan,
                objectID: objectID,
                phase: .completed,
                result: "Root established.",
                events: events
            ),
            succeeded: true
        )
    }

    private func ensureRootDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw Phase1OperationError.targetConflict(directory.path)
            }
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    private func commitLocalSourceImport(
        plan: Phase1OperationPlan,
        journal: Phase1OperationJournal,
        objectID: String,
        sequence: inout Int,
        events: inout [Phase1TaskEvent]
    ) throws -> Phase1OperationResult {
        guard var source = plan.source,
              let sourcePath = plan.sourceCandidatePath,
              let plannedManifest = plan.sourceManifest,
              let targetPath = plan.targetPath else {
            throw Phase1OperationError.invalidPlan
        }
        let rootURL = URL(fileURLWithPath: plan.rootPath, isDirectory: true)
        let sourceURL = try sourceImportURL(source: source, fileManager: fileManager)
        guard sourceURL.path == sourcePath else { throw Phase1OperationError.invalidPlan }
        let allowsExternalLinks = source.kind == .localDirectory
        let targetURL = URL(fileURLWithPath: targetPath, isDirectory: true)
        let manifest = try manifestBuilder.build(
            for: sourceURL,
            authorizedRoot: sourceURL,
            allowExternalSymbolicLinks: allowsExternalLinks
        )
        guard manifest.digest == plannedManifest.digest else {
            throw Phase1OperationError.sourceChanged
        }

        let access = FileAccessService(fileManager: fileManager)
        guard !access.isSymlink(targetURL.deletingLastPathComponent()),
              !access.isSymlink(targetURL),
              access.linkConflict(at: targetURL, expectedDestination: targetURL) == nil else {
            throw Phase1OperationError.targetConflict(targetPath)
        }

        let stagingRoot = metadataStore.rootLayout(for: rootURL)
            .operationRecoveryDirectory
            .appendingPathComponent(plan.id.uuidString, isDirectory: true)
        let stagingSource = stagingRoot.appendingPathComponent("source", isDirectory: true)
        var createdTargetParentIdentity: TargetFileIdentity?
        try Task.checkCancellation()
        try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .stepStarted, phase: .executing, result: "staging-copy")
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let stagingIdentity = try directoryIdentity(stagingRoot)
        var stagingManifest: ContentManifest?
        var stagingNeedsCleanup = true
        defer {
            if stagingNeedsCleanup {
                do {
                    try removeOwnedStaging(stagingRoot, identity: stagingIdentity, manifest: stagingManifest, plan: plan)
                    try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .compensation, phase: .needsAttention, result: "staging-removed")
                } catch {
                    events.append(event(.needsAttention, "Operation staging was preserved because cleanup could not be verified: \(error)"))
                }
            }
            if let createdTargetParentIdentity,
               (try? directoryIdentity(targetURL.deletingLastPathComponent())) == createdTargetParentIdentity,
               (try? fileManager.contentsOfDirectory(atPath: targetURL.deletingLastPathComponent().path).isEmpty) == true {
                try? fileManager.removeItem(at: targetURL.deletingLastPathComponent())
            }
        }

        events.append(event(.executing, "Copying the complete selected source into operation staging."))
        try fileManager.copyItem(at: sourceURL, to: stagingSource)
        stagingManifest = try manifestBuilder.build(
            for: stagingSource,
            authorizedRoot: stagingSource,
            allowExternalSymbolicLinks: allowsExternalLinks
        )
        if faultInjection == .afterStagingCopy {
            throw Phase1OperationError.injectedFailure("after-staging-copy")
        }
        let stagedIndex = LocalSourceIndexer(fileManager: fileManager).index(
            directory: stagingSource,
            sourceID: source.id,
            generation: plan.expectedGeneration + 1
        )
        guard stagingManifest?.digest == plannedManifest.digest,
              stagedIndex.isPlannable,
              Set(stagedIndex.availableSkills.map(\.skillPath)) == Set(plan.candidates.map(\.skillPath)) else {
            throw Phase1OperationError.stagingVerificationFailed
        }
        let sourceAfterCopy = try sourceImportURL(source: source, fileManager: fileManager)
        guard try manifestBuilder.build(
            for: sourceAfterCopy,
            authorizedRoot: sourceAfterCopy,
            allowExternalSymbolicLinks: allowsExternalLinks
        ).digest == plannedManifest.digest else {
            throw Phase1OperationError.sourceChanged
        }
        try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .stepResult, phase: .executing, result: "staging-verified")
        try Task.checkCancellation()
        try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .stepStarted, phase: .executing, result: "target-publish")
        guard !access.isSymlink(targetURL.deletingLastPathComponent()),
              !access.isSymlink(targetURL),
              access.linkConflict(at: targetURL, expectedDestination: targetURL) == nil else {
            throw Phase1OperationError.targetConflict(targetPath)
        }
        if faultInjection == .beforeTargetPublish {
            throw Phase1OperationError.injectedFailure("before-target-publish")
        }
        let targetParent = targetURL.deletingLastPathComponent()
        if source.kind == .githubRepository,
           !fileManager.fileExists(atPath: targetParent.path) {
            try fileManager.createDirectory(at: targetParent, withIntermediateDirectories: false)
            createdTargetParentIdentity = try directoryIdentity(targetParent)
        }
        guard !access.isSymlink(targetParent) else {
            throw Phase1OperationError.targetConflict(targetParent.path)
        }
        let publishedIdentity = try directoryIdentity(stagingSource)
        guard publishedIdentity.volumeNumber == (try directoryIdentity(targetURL.deletingLastPathComponent())).volumeNumber else {
            throw Phase1OperationError.targetConflict(targetPath)
        }
        try fileManager.moveItem(at: stagingSource, to: targetURL)
        try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .stepResult, phase: .executing, result: "target-published")

        let managedIndex = LocalSourceIndexer(fileManager: fileManager).index(
            directory: targetURL,
            sourceID: source.id,
            generation: plan.expectedGeneration + 1
        )
        guard managedIndex.isPlannable,
              Set(managedIndex.availableSkills.map(\.skillPath)) == Set(plan.candidates.map(\.skillPath)) else {
            throw Phase1OperationError.stagingVerificationFailed
        }
        source.localPath = targetURL.path
        source.contentFingerprint = managedIndex.source.contentFingerprint
        source.directoryIdentity = managedIndex.source.directoryIdentity
        source.lastCheckedAt = managedIndex.source.lastCheckedAt
        source.baselineManifest = plannedManifest
        let installed = managedIndex.availableSkills.map { candidate in
            let skillURL = candidate.skillPath == "."
                ? targetURL
                : targetURL.appendingPathComponent(candidate.skillPath, isDirectory: true)
            return InstalledSkill(
                id: candidate.candidateID,
                sourceID: source.id,
                name: candidate.name,
                description: candidate.description,
                installedPath: skillURL.path,
                sourceKind: source.kind,
                validation: candidate.validation,
                purpose: nil,
                tagIDs: [],
                installedAt: Date(),
                assetID: StableIdentity.assetID(
                    candidateID: candidate.candidateID,
                    canonicalPathComponent: skillURL.lastPathComponent
                ),
                candidateID: candidate.candidateID,
                canonicalPathComponent: skillURL.lastPathComponent,
                currentRevision: candidate.manifestDigest,
                manifestDigest: candidate.manifestDigest,
                managedGeneration: plan.expectedGeneration + 1
            )
        }

        let snapshot: RootSnapshot
        do {
            try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .stepStarted, phase: .executing, result: "metadata-cas")
            if faultInjection == .metadataCommitBeforeCAS {
                throw Phase1OperationError.injectedFailure("metadata-commit-before-cas")
            }
            snapshot = try metadataStore.commit(
                at: rootURL,
                expected: try currentSnapshot(matching: plan)
            ) { metadata in
                guard !metadata.sources.contains(where: {
                    $0.id == source.id || $0.localPath?.precomposedStringWithCanonicalMapping.lowercased()
                        == targetPath.precomposedStringWithCanonicalMapping.lowercased()
                        || (source.kind == .localDirectory
                            && $0.externalLocalPath?.precomposedStringWithCanonicalMapping.lowercased()
                                == sourceURL.path.precomposedStringWithCanonicalMapping.lowercased())
                        || (source.kind == .githubRepository
                            && $0.githubRepositoryID == source.githubRepositoryID)
                }), !metadata.installedSkills.contains(where: { existing in
                    installed.contains { $0.assetID == existing.assetID || $0.installedPath == existing.installedPath }
                }) else {
                    throw Phase1OperationError.targetConflict(targetPath)
                }
                metadata.sources.append(source)
                metadata.availableSkills.append(contentsOf: managedIndex.availableSkills)
                metadata.installedSkills.append(contentsOf: installed)
            }
        } catch {
            let publishedManifest = try? manifestBuilder.build(
                for: targetURL,
                authorizedRoot: targetURL,
                allowExternalSymbolicLinks: allowsExternalLinks
            )
            let current = try? metadataStore.loadCurrentSnapshot(from: rootURL)
            guard plan.compensationPaths?.contains(targetPath) == true,
                  (try? directoryIdentity(targetURL)) == publishedIdentity,
                  publishedManifest?.digest == plannedManifest.digest,
                  let current,
                  !current.metadata.sources.contains(where: { $0.id == source.id || $0.localPath == targetPath }) else {
                stagingNeedsCleanup = false
                throw Phase1OperationError.compensationFailed(targetPath)
            }
            do {
                try fileManager.removeItem(at: targetURL)
                if let createdTargetParentIdentity,
                   (try? directoryIdentity(targetParent)) == createdTargetParentIdentity,
                   (try? fileManager.contentsOfDirectory(atPath: targetParent.path).isEmpty) == true {
                    try fileManager.removeItem(at: targetParent)
                }
                try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .compensation, phase: .needsAttention, result: "published-target-removed")
            } catch {
                stagingNeedsCleanup = false
                throw Phase1OperationError.compensationFailed(targetPath)
            }
            throw Phase1OperationError.metadataCommitFailed(String(describing: error))
        }

        do {
            try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .stepResult, phase: .executing, result: "metadata-committed")
            if faultInjection == .afterMetadataCommit {
                throw Phase1OperationError.injectedFailure("after-metadata-commit")
            }
            try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .phase, phase: .observing, result: "source-readback")
            let targetManifest = try manifestBuilder.build(
                for: targetURL,
                authorizedRoot: targetURL,
                allowExternalSymbolicLinks: allowsExternalLinks
            )
            let sourceIsUnchanged: Bool
            if source.kind == .localDirectory {
                sourceIsUnchanged = try manifestBuilder.build(
                    for: sourceURL,
                    authorizedRoot: sourceURL,
                    allowExternalSymbolicLinks: true
                ).digest == plannedManifest.digest
            } else {
                sourceIsUnchanged = true
            }
            guard targetManifest.digest == plannedManifest.digest,
                  sourceIsUnchanged,
                  try metadataStore.loadCurrentSnapshot(from: rootURL) == snapshot else {
                throw Phase1OperationError.stagingVerificationFailed
            }
            try removeOwnedStaging(stagingRoot, identity: stagingIdentity, manifest: nil, plan: plan)
            stagingNeedsCleanup = false
            try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .phase, phase: .verifying, result: "source-verified")
            try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .final, phase: .completed, result: "local-source-imported")
            try journal.verifyCompletedPlan(plan)
            events.append(event(.verifying, "Complete managed tree, candidates, baseline, and metadata were verified."))
            events.append(event(.completed, "Source imported; no Agent relationship was enabled."))
        } catch {
            events.append(event(.needsAttention, "Source metadata committed, but final observation evidence is incomplete: \(error)"))
            return Phase1OperationResult(
                snapshot: snapshot,
                installedSkill: installed.first,
                task: task(
                    plan: plan,
                    objectID: objectID,
                    phase: .needsAttention,
                    result: "Source committed; final observation requires attention.",
                    events: events
                ),
                succeeded: false
            )
        }
        return Phase1OperationResult(
            snapshot: snapshot,
            installedSkill: installed.first,
            task: task(plan: plan, objectID: objectID, phase: .completed, result: "Source imported.", events: events),
            succeeded: true
        )
    }

    private func commitSourceRegistration(
        plan: Phase1OperationPlan,
        journal: Phase1OperationJournal,
        objectID: String,
        sequence: inout Int,
        events: inout [Phase1TaskEvent]
    ) throws -> Phase1OperationResult {
        guard let source = plan.source else {
            throw Phase1OperationError.invalidPlan
        }
        let currentIndex = try observeSource(source, generation: plan.expectedGeneration)
        guard currentIndex.source.contentFingerprint == source.contentFingerprint else {
            throw Phase1OperationError.sourceChanged
        }
        try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .stepStarted, phase: .executing, result: "metadata-cas")
        events.append(event(.executing, "Registering source metadata."))
        let rootURL = URL(fileURLWithPath: plan.rootPath, isDirectory: true)
        if faultInjection == .metadataCommitBeforeCAS {
            throw Phase1OperationError.injectedFailure("metadata-commit-before-cas")
        }
        let expectedSnapshot = try currentSnapshot(matching: plan)
        let snapshot = try metadataStore.commit(
            at: rootURL,
            expected: expectedSnapshot
        ) { metadata in
            guard !metadata.sources.contains(where: { existing in
                existing.kind == .localDirectory && existing.localPath == source.localPath && existing.id != source.id
            }) else {
                throw Phase1OperationError.targetConflict(source.localPath ?? source.name)
            }
            metadata.sources.removeAll { $0.id == source.id }
            metadata.sources.append(source)
            metadata.availableSkills.removeAll { $0.sourceID == source.id }
            metadata.availableSkills.append(contentsOf: plan.candidates)
        }
        do {
            try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .stepResult, phase: .executing, result: "metadata-committed")
            try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .phase, phase: .observing, result: "source-readback")
            guard try metadataStore.loadCurrentSnapshot(from: rootURL) == snapshot else {
                throw Phase1OperationError.staleFacts
            }
            let observed = try observeSource(source, generation: snapshot.generation)
            guard observed.source.contentFingerprint == source.contentFingerprint else {
                throw Phase1OperationError.sourceChanged
            }
            events.append(event(.observing, "Metadata read back at generation \(snapshot.generation)."))
            try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .phase, phase: .verifying, result: "source-verified")
            try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .final, phase: .completed, result: "source-registered")
            try journal.verifyCompletedPlan(plan)
            events.append(event(.verifying, "Source and candidate snapshot verified."))
            events.append(event(.completed, "Source registered; no Skill was copied."))
        } catch {
            events.append(event(.needsAttention, "Source metadata committed, but final observation evidence is incomplete: \(error)"))
            return Phase1OperationResult(
                snapshot: snapshot,
                installedSkill: nil,
                task: task(
                    plan: plan,
                    objectID: objectID,
                    phase: .needsAttention,
                    result: "Source metadata committed; final journal evidence requires attention.",
                    events: events
                ),
                succeeded: false
            )
        }
        return Phase1OperationResult(
            snapshot: snapshot,
            installedSkill: nil,
            task: task(plan: plan, objectID: objectID, phase: .completed, result: "Source registered.", events: events),
            succeeded: true
        )
    }

    private func commitManagedCopy(
        plan: Phase1OperationPlan,
        journal: Phase1OperationJournal,
        objectID: String,
        sequence: inout Int,
        events: inout [Phase1TaskEvent]
    ) throws -> Phase1OperationResult {
        guard let candidate = plan.selectedCandidate,
              let source = plan.source,
              let sourcePath = plan.sourceCandidatePath,
              let plannedManifest = plan.sourceManifest,
              let targetPath = plan.targetPath,
              let assetID = plan.assetID
        else {
            throw Phase1OperationError.invalidPlan
        }
        let rootURL = URL(fileURLWithPath: plan.rootPath, isDirectory: true)
        let sourceURL = try managedCopySourceURL(candidate: candidate, source: source, fileManager: fileManager)
        guard sourceURL.path == sourcePath else { throw Phase1OperationError.invalidPlan }
        let targetURL = URL(fileURLWithPath: targetPath, isDirectory: true)
        let currentManifest = try manifestBuilder.build(for: sourceURL, authorizedRoot: sourceURL)
        guard currentManifest.digest == plannedManifest.digest else {
            throw Phase1OperationError.sourceChanged
        }
        let access = FileAccessService(fileManager: fileManager)
        if access.isSymlink(targetURL) || access.linkConflict(at: targetURL, expectedDestination: targetURL) != nil {
            throw Phase1OperationError.targetConflict(targetPath)
        }

        let layout = metadataStore.rootLayout(for: rootURL)
        let stagingRoot = layout.operationStagingDirectory.appendingPathComponent(plan.id.uuidString, isDirectory: true)
        let stagingAsset = stagingRoot.appendingPathComponent("asset", isDirectory: true)
        try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .stepStarted, phase: .executing, result: "staging-copy")
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let stagingIdentity = try directoryIdentity(stagingRoot)
        var stagingManifest: ContentManifest?
        var stagingNeedsCleanup = true
        defer {
            if stagingNeedsCleanup {
                do {
                    try removeOwnedStaging(stagingRoot, identity: stagingIdentity, manifest: stagingManifest, plan: plan)
                    try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .compensation, phase: .needsAttention, result: "staging-removed")
                } catch {
                    events.append(event(.needsAttention, "Operation staging was preserved because cleanup could not be verified: \(error)"))
                }
            }
        }

        events.append(event(.executing, "Copying the candidate into operation staging."))
        try fileManager.copyItem(at: sourceURL, to: stagingAsset)
        stagingManifest = try manifestBuilder.build(for: stagingAsset, authorizedRoot: stagingAsset)
        if faultInjection == .afterStagingCopy {
            throw Phase1OperationError.injectedFailure("after-staging-copy")
        }
        guard stagingManifest?.digest == plannedManifest.digest else {
            throw Phase1OperationError.stagingVerificationFailed
        }
        let sourceAfterCopy = try managedCopySourceURL(candidate: candidate, source: source, fileManager: fileManager)
        guard try manifestBuilder.build(for: sourceAfterCopy, authorizedRoot: sourceAfterCopy).digest == plannedManifest.digest else {
            throw Phase1OperationError.sourceChanged
        }
        try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .stepResult, phase: .executing, result: "staging-verified")
        try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .stepStarted, phase: .executing, result: "target-publish")
        guard !access.isSymlink(targetURL.deletingLastPathComponent()),
              !access.isSymlink(targetURL), access.linkConflict(at: targetURL, expectedDestination: targetURL) == nil else {
            throw Phase1OperationError.targetConflict(targetPath)
        }
        if faultInjection == .beforeTargetPublish {
            throw Phase1OperationError.injectedFailure("before-target-publish")
        }
        let publishedIdentity = try directoryIdentity(stagingAsset)
        guard publishedIdentity.volumeNumber == (try directoryIdentity(targetURL.deletingLastPathComponent())).volumeNumber else {
            throw Phase1OperationError.targetConflict(targetPath)
        }
        try fileManager.moveItem(at: stagingAsset, to: targetURL)
        try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .stepResult, phase: .executing, result: "target-published")

        let installed = InstalledSkill(
            id: normalizerID(candidate.name),
            sourceID: candidate.sourceID,
            name: candidate.name,
            description: candidate.description,
            installedPath: targetURL.path,
            sourceKind: .localDirectory,
            validation: candidate.validation,
            purpose: nil,
            tagIDs: [],
            installedAt: Date(),
            assetID: assetID,
            candidateID: candidate.candidateID,
            canonicalPathComponent: targetURL.lastPathComponent,
            currentRevision: plannedManifest.digest,
            manifestDigest: plannedManifest.digest,
            managedGeneration: plan.expectedGeneration + 1
        )

        let snapshot: RootSnapshot
        do {
            try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .stepStarted, phase: .executing, result: "metadata-cas")
            if faultInjection == .metadataCommitBeforeCAS {
                throw Phase1OperationError.injectedFailure("metadata-commit-before-cas")
            }
            snapshot = try metadataStore.commit(
                at: rootURL,
                expected: try currentSnapshot(matching: plan)
            ) { metadata in
                guard !metadata.installedSkills.contains(where: { $0.assetID == assetID || $0.installedPath == targetPath }) else {
                    throw Phase1OperationError.targetConflict(targetPath)
                }
                metadata.installedSkills.append(installed)
            }
        } catch {
            let publishedManifest = try? manifestBuilder.build(for: targetURL, authorizedRoot: targetURL)
            let current = try? metadataStore.loadCurrentSnapshot(from: rootURL)
            guard plan.compensationPaths?.contains(targetPath) == true,
                  (try? directoryIdentity(targetURL)) == publishedIdentity,
                  publishedManifest?.digest == plannedManifest.digest,
                  let current,
                  !current.metadata.installedSkills.contains(where: { $0.assetID == assetID || $0.installedPath == targetPath }) else {
                stagingNeedsCleanup = false
                throw Phase1OperationError.compensationFailed(targetPath)
            }
            do {
                try fileManager.removeItem(at: targetURL)
                try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .compensation, phase: .needsAttention, result: "published-target-removed")
            } catch {
                stagingNeedsCleanup = false
                throw Phase1OperationError.compensationFailed(targetPath)
            }
            throw Phase1OperationError.metadataCommitFailed(String(describing: error))
        }

        do {
            try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .stepResult, phase: .executing, result: "metadata-committed")
            if faultInjection == .afterMetadataCommit {
                throw Phase1OperationError.injectedFailure("after-metadata-commit")
            }
            try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .phase, phase: .observing, result: "managed-readback")
            events.append(event(.observing, "Managed target and original source were read back."))
            let targetManifest = try manifestBuilder.build(for: targetURL, authorizedRoot: targetURL)
            let observedSource = try managedCopySourceURL(candidate: candidate, source: source, fileManager: fileManager)
            let sourceAfter = try manifestBuilder.build(for: observedSource, authorizedRoot: observedSource)
            guard targetManifest.digest == plannedManifest.digest, sourceAfter.digest == plannedManifest.digest,
                  try metadataStore.loadCurrentSnapshot(from: rootURL) == snapshot else {
                throw Phase1OperationError.stagingVerificationFailed
            }
            try removeOwnedStaging(stagingRoot, identity: stagingIdentity, manifest: nil, plan: plan)
            stagingNeedsCleanup = false
            try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .phase, phase: .verifying, result: "managed-verified")
            try append(journal: journal, plan: plan, objectID: objectID, sequence: &sequence, event: .final, phase: .completed, result: "managed-copy-verified")
            try journal.verifyCompletedPlan(plan)
            events.append(event(.verifying, "Manifest, metadata, and source preservation verified."))
            events.append(event(.completed, "One canonical managed copy was published."))
        } catch {
            events.append(event(.needsAttention, "Managed metadata committed, but final observation evidence is incomplete: \(error)"))
            return Phase1OperationResult(
                snapshot: snapshot,
                installedSkill: installed,
                task: task(
                    plan: plan,
                    objectID: objectID,
                    phase: .needsAttention,
                    result: "Managed asset committed; final observation requires attention.",
                    events: events
                ),
                succeeded: false
            )
        }
        return Phase1OperationResult(
            snapshot: snapshot,
            installedSkill: installed,
            task: task(plan: plan, objectID: objectID, phase: .completed, result: "Managed copy published.", events: events),
            succeeded: true
        )
    }

    private func validate(plan: Phase1OperationPlan, confirmation: Phase1ConfirmationToken) throws {
        guard plan.planDigest.isEmpty == false,
              (try? plan.computedDigest()) == plan.planDigest,
              confirmation.planID == plan.id,
              confirmation.planDigest == plan.planDigest,
              confirmation.factDigest == plan.factDigest else {
            throw Phase1OperationError.confirmationMismatch
        }
        guard !consumedConfirmationIDs.contains(confirmation.id),
              !cancelledPlanIDs.contains(plan.id) else {
            throw Phase1OperationError.confirmationReplayed
        }
    }

    private func observeSource(_ source: SkillSource, generation: UInt64) throws -> LocalSourceIndexResult {
        guard let path = source.localPath else { throw Phase1OperationError.invalidPlan }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard let identity = source.directoryIdentity,
              (try? directoryIdentity(directory)) == identity else {
            throw Phase1OperationError.sourceChanged
        }
        return LocalSourceIndexer(fileManager: fileManager).index(
            directory: directory, sourceID: source.id, generation: generation
        )
    }

    private func directoryIdentity(_ url: URL) throws -> TargetFileIdentity {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let volume = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else {
            throw Phase1OperationError.targetConflict(url.path)
        }
        return TargetFileIdentity(volumeNumber: volume.uint64Value, fileNumber: file.uint64Value)
    }

    private func removeOwnedStaging(_ root: URL, identity: TargetFileIdentity, manifest: ContentManifest?, plan: Phase1OperationPlan) throws {
        guard plan.compensationPaths?.contains(root.path) == true,
              try directoryIdentity(root) == identity else {
            throw Phase1OperationError.compensationFailed(root.path)
        }
        let children = try fileManager.contentsOfDirectory(atPath: root.path)
        if !children.isEmpty {
            let childName = plan.kind == .importLocalSource || plan.kind == .importGitHubSource ? "source" : "asset"
            let asset = root.appendingPathComponent(childName)
            guard children == [childName], let manifest,
                  try manifestBuilder.build(
                    for: asset,
                    authorizedRoot: asset,
                    allowExternalSymbolicLinks: plan.kind == .importLocalSource
                  ).digest == manifest.digest else {
                throw Phase1OperationError.compensationFailed(root.path)
            }
        }
        try fileManager.removeItem(at: root)
    }

    private func validate(
        plan: Phase1OperationPlan,
        confirmation: Phase1ConfirmationToken,
        journal: Phase1OperationJournal
    ) throws {
        try validate(plan: plan, confirmation: confirmation)
        guard try !journal.containsSubmission(planID: plan.id, confirmationID: confirmation.id) else {
            throw Phase1OperationError.confirmationReplayed
        }
    }

    private func preflight(plan: Phase1OperationPlan) throws {
        let rootURL = URL(fileURLWithPath: plan.rootPath, isDirectory: true)
        let layout = metadataStore.rootLayout(for: rootURL)
        let expectedCompensation: [String]
        switch plan.kind {
        case .importLocalSource, .importGitHubSource:
            expectedCompensation = [
                layout.operationRecoveryDirectory.appendingPathComponent(plan.id.uuidString).path,
                plan.targetPath ?? ""
            ]
        case .publishManagedCopy:
            expectedCompensation = [
                layout.operationStagingDirectory.appendingPathComponent(plan.id.uuidString).path,
                plan.targetPath ?? ""
            ]
        case .initializeRoot, .registerLocalSource:
            expectedCompensation = []
        }
        guard plan.compensationPaths == expectedCompensation else {
            throw Phase1OperationError.invalidPlan
        }
        if plan.kind == .initializeRoot {
            guard let plannedFacts = plan.initializationFacts else {
                throw Phase1OperationError.invalidPlan
            }
            let existingNames = Set(plannedFacts.entries.map(\.name))
            let expectedWrites = Set(
                ["local", "github"]
                    .filter { existingNames.contains($0) == false }
                    .map { "\($0)/" }
                    + [
                        ".skillshub.json",
                        ".skillshub.lock",
                        ".skillshub.local.json",
                        ".skillshub.operations.jsonl"
                    ]
            )
            guard let initialMetadata = plan.initialMetadata,
                  plan.initialLocalState != nil,
                  plan.expectedGeneration == 0,
                  plan.metadataDigest == "absent",
                  plan.factDigest == plannedFacts.digest,
                  plannedFacts.rootPath == rootURL.standardizedFileURL.path,
                  initialMetadata.schemaVersion == SkillsHubMetadata.currentSchemaVersion,
                  initialMetadata.generation == 0,
                  initialMetadata.rootConfig.rootPath == rootURL.standardizedFileURL.path,
                  Set(plan.expectedWrites) == expectedWrites else {
                throw Phase1OperationError.invalidPlan
            }
            let currentFacts = try RootInitializationFacts.observe(
                rootURL: rootURL,
                fileManager: fileManager
            )
            guard currentFacts == plannedFacts else {
                throw Phase1OperationError.staleFacts
            }
            let currentDiscovery = try RootContentDiscovery.observe(
                rootURL: rootURL,
                observedAt: initialMetadata.rootConfig.createdAt,
                fileManager: fileManager
            )
            guard currentDiscovery.installedSkills == initialMetadata.installedSkills else {
                throw Phase1OperationError.sourceChanged
            }
            return
        }
        _ = try currentSnapshot(matching: plan)

        switch plan.kind {
        case .initializeRoot:
            throw Phase1OperationError.invalidPlan
        case .importLocalSource, .importGitHubSource:
            guard let source = plan.source,
                  let sourcePath = plan.sourceCandidatePath,
                  let plannedManifest = plan.sourceManifest,
                  let targetPath = plan.targetPath else {
                throw Phase1OperationError.invalidPlan
            }
            let sourceURL = try sourceImportURL(source: source, fileManager: fileManager)
            guard sourceURL.path == sourcePath,
                  try manifestBuilder.build(
                    for: sourceURL,
                    authorizedRoot: sourceURL,
                    allowExternalSymbolicLinks: source.kind == .localDirectory
                  ).digest == plannedManifest.digest else {
                throw Phase1OperationError.sourceChanged
            }
            let targetURL = URL(fileURLWithPath: targetPath, isDirectory: true)
            let access = FileAccessService(fileManager: fileManager)
            let staging = metadataStore.rootLayout(for: rootURL).operationRecoveryDirectory
            if fileManager.fileExists(atPath: staging.path) || access.isSymlink(staging) {
                _ = try directoryIdentity(staging)
            }
            let operationStaging = staging.appendingPathComponent(plan.id.uuidString)
            guard !fileManager.fileExists(atPath: operationStaging.path), !access.isSymlink(operationStaging),
                  !access.isSymlink(targetURL.deletingLastPathComponent()),
                  !access.isSymlink(targetURL),
                  access.linkConflict(at: targetURL, expectedDestination: targetURL) == nil else {
                throw Phase1OperationError.targetConflict(targetPath)
            }
        case .registerLocalSource:
            guard let source = plan.source else {
                throw Phase1OperationError.invalidPlan
            }
            let current = try observeSource(source, generation: plan.expectedGeneration)
            guard current.source.contentFingerprint == source.contentFingerprint else {
                throw Phase1OperationError.sourceChanged
            }
        case .publishManagedCopy:
            guard let candidate = plan.selectedCandidate,
                  let source = plan.source,
                  let sourcePath = plan.sourceCandidatePath,
                  let plannedManifest = plan.sourceManifest,
                  let targetPath = plan.targetPath else {
                throw Phase1OperationError.invalidPlan
            }
            let sourceURL = try managedCopySourceURL(candidate: candidate, source: source, fileManager: fileManager)
            guard sourceURL.path == sourcePath else { throw Phase1OperationError.invalidPlan }
            let currentManifest = try manifestBuilder.build(for: sourceURL, authorizedRoot: sourceURL)
            guard currentManifest.digest == plannedManifest.digest else {
                throw Phase1OperationError.sourceChanged
            }
            let targetURL = URL(fileURLWithPath: targetPath, isDirectory: true)
            let access = FileAccessService(fileManager: fileManager)
            let staging = metadataStore.rootLayout(for: rootURL).operationStagingDirectory
            if fileManager.fileExists(atPath: staging.path) || access.isSymlink(staging) {
                _ = try directoryIdentity(staging)
            }
            let operationStaging = staging.appendingPathComponent(plan.id.uuidString)
            guard !fileManager.fileExists(atPath: operationStaging.path), !access.isSymlink(operationStaging) else {
                throw Phase1OperationError.targetConflict(operationStaging.path)
            }
            guard !access.isSymlink(targetURL.deletingLastPathComponent()),
                  !access.isSymlink(targetURL),
                  access.linkConflict(
                at: targetURL,
                expectedDestination: targetURL
            ) == nil else {
                throw Phase1OperationError.targetConflict(targetPath)
            }
        }
    }

    private func currentSnapshot(matching plan: Phase1OperationPlan) throws -> RootSnapshot {
        let rootURL = URL(fileURLWithPath: plan.rootPath, isDirectory: true)
        let snapshot = try metadataStore.loadCurrentSnapshot(from: rootURL)
        guard snapshot.generation == plan.expectedGeneration,
              snapshot.metadataDigest == plan.metadataDigest,
              snapshot.metadataFileIdentity == plan.metadataFileIdentity,
              snapshot.metadataParentIdentity == plan.metadataParentIdentity else {
            throw Phase1OperationError.staleFacts
        }
        return snapshot
    }

    private func append(
        journal: Phase1OperationJournal,
        plan: Phase1OperationPlan,
        objectID: String,
        sequence: inout Int,
        event: Phase1JournalEventKind,
        phase: Phase1OperationPhase,
        result: String,
        confirmationTokenID: UUID? = nil
    ) throws {
        if faultInjection == .journal(event, result) {
            throw Phase1OperationError.injectedFailure("journal-\(event.rawValue)-\(result)")
        }
        sequence += 1
        try journal.append(
            Phase1JournalRecord(
                operationID: plan.id,
                kind: plan.kind,
                operationPlan: event == .plan ? plan : nil,
                sequence: sequence,
                planDigest: plan.planDigest,
                event: event,
                phase: phase,
                objectID: objectID,
                result: result,
                confirmationTokenID: confirmationTokenID,
                occurredAt: Date()
            )
        )
    }

    private func rootMatchesPlannedInitialization(
        rootURL: URL,
        plannedFacts: RootInitializationFacts
    ) throws -> Bool {
        let observed = try RootInitializationFacts.observe(rootURL: rootURL, fileManager: fileManager)
        var expectedEntries = Dictionary(uniqueKeysWithValues: plannedFacts.entries.map { ($0.name, $0) })
        for entry in [
            RootInitializationEntry(name: "local", kind: .directory),
            RootInitializationEntry(name: "github", kind: .directory),
            RootInitializationEntry(name: ".skillshub.json", kind: .regularFile),
            RootInitializationEntry(name: ".skillshub.local.json", kind: .regularFile),
            RootInitializationEntry(name: ".skillshub.operations.jsonl", kind: .regularFile),
            RootInitializationEntry(name: RootLayout.writeLockFileName, kind: .regularFile)
        ] {
            expectedEntries[entry.name] = entry
        }
        let sortedExpectedEntries = expectedEntries.values.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return observed.rootPath == plannedFacts.rootPath
            && observed.volumeNumber == plannedFacts.volumeNumber
            && observed.fileNumber == plannedFacts.fileNumber
            && observed.isReadable
            && observed.isWritable
            && observed.entries == sortedExpectedEntries
    }

    private func operationObjectID(for plan: Phase1OperationPlan) -> String {
        switch plan.kind {
        case .initializeRoot:
            return plan.rootPath
        case .importLocalSource, .importGitHubSource:
            return plan.source?.id.uuidString ?? plan.rootPath
        case .registerLocalSource:
            return plan.source?.id.uuidString ?? plan.rootPath
        case .publishManagedCopy:
            return plan.selectedCandidate?.candidateID ?? plan.rootPath
        }
    }

    private func event(_ phase: Phase1OperationPhase, _ message: LocalizedMessage) -> Phase1TaskEvent {
        Phase1TaskEvent(id: UUID(), phase: phase, message: message, occurredAt: Date())
    }

    private func task(
        plan: Phase1OperationPlan,
        objectID: String,
        phase: Phase1OperationPhase,
        result: LocalizedMessage,
        events: [Phase1TaskEvent]
    ) -> Phase1TaskRecord {
        Phase1TaskRecord(
            id: plan.id,
            kind: plan.kind.taskKind,
            title: LocalizedMessage(operationTitle(for: plan.kind)),
            objectID: objectID,
            phase: phase,
            result: result,
            planDigest: plan.planDigest,
            events: events,
            updatedAt: Date(),
            operationPlan: plan
        )
    }

    private func operationTitle(for kind: Phase1OperationKind) -> String {
        switch kind {
        case .initializeRoot: return "Establish Management Directory"
        case .importLocalSource: return "Import local source"
        case .importGitHubSource: return "Import GitHub source"
        case .registerLocalSource: return "Register local source"
        case .publishManagedCopy: return "Publish managed Skill"
        }
    }

    private func normalizerID(_ name: String) -> String {
        SkillIDNormalizer().normalize(name)
    }
}

nonisolated final class Phase1OperationJournal {
    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let progress: AsyncStream<Phase1JournalRecord>.Continuation?

    init(rootURL: URL, fileManager: FileManager = .default, progress: AsyncStream<Phase1JournalRecord>.Continuation? = nil) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.progress = progress
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func append(_ record: Phase1JournalRecord) throws {
        let file = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: rootURL).operationJournalFile
        guard !FileAccessService(fileManager: fileManager).isSymlink(file) else {
            throw Phase1OperationError.journalUnavailable
        }
        let data = try encoder.encode(record) + Data([0x0A])
        if !fileManager.fileExists(atPath: file.path) {
            guard fileManager.createFile(atPath: file.path, contents: nil) else {
                throw Phase1OperationError.journalUnavailable
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        progress?.yield(record)
    }

    func containsSubmission(planID: UUID, confirmationID: UUID) throws -> Bool {
        try validatedRecords().contains {
            $0.operationID == planID || $0.confirmationTokenID == confirmationID
        }
    }

    func verifyCompletedPlan(_ plan: Phase1OperationPlan) throws {
        let records = try validatedRecords().filter { $0.operationID == plan.id }
        guard records.first?.event == .plan,
              try records.first?.operationPlan?.computedDigest() == plan.planDigest,
              records.contains(where: { $0.event == .confirmation && $0.confirmationTokenID != nil }),
              records.last?.event == .final,
              records.last?.phase == .completed,
              records.enumerated().allSatisfy({ index, record in
                  record.sequence == index + 1 && record.kind == plan.kind && record.planDigest == plan.planDigest
              }) else {
            throw Phase1OperationError.journalUnavailable
        }
    }

    func recoverTasks() throws -> [Phase1TaskRecord] {
        let file = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: rootURL).operationJournalFile
        let records: [Phase1JournalRecord]
        let foundCorruptedRecord: Bool
        do {
            (records, foundCorruptedRecord) = try readRecords()
        } catch {
            records = []
            foundCorruptedRecord = true
        }
        var tasks: [Phase1TaskRecord] = Dictionary(grouping: records, by: \.operationID).compactMap { entry -> Phase1TaskRecord? in
            let operationID = entry.key
            let ordered = entry.value
            guard let last = ordered.last else { return nil }
            let operationPlan = ordered.compactMap(\.operationPlan).first
            let valid = validPrefix(ordered)
            let currentPlan = operationPlan?.compensationPaths != nil
            let phase: Phase1OperationPhase = valid && currentPlan && last.event == .final ? last.phase : .needsAttention
            let result: LocalizedMessage = if !valid {
                "Journal contains a corrupted sequence or plan; operation state is unknown."
            } else if currentPlan && last.event == .final {
                finalResult(for: last.kind)
            } else {
                LocalizedMessage(recoveryResult(last: last, plan: operationPlan))
            }
            var task = Phase1TaskRecord(
                id: operationID,
                kind: last.kind.taskKind,
                title: LocalizedMessage(operationTitle(for: last.kind)),
                objectID: last.objectID,
                phase: phase,
                result: result,
                planDigest: last.planDigest,
                events: ordered.map {
                    Phase1TaskEvent(
                        id: UUID(),
                        phase: $0.phase,
                        message: LocalizedMessage("Historical record (original): %@", arguments: [$0.result]),
                        occurredAt: $0.occurredAt
                    )
                },
                updatedAt: last.occurredAt,
                operationPlan: operationPlan
            )
            if let operationPlan,
               operationPlan.kind == .importLocalSource || operationPlan.kind == .importGitHubSource {
                task.recoveryEvidence = sourceImportRecoveryEvidence(
                    plan: operationPlan,
                    snapshot: try? SkillsHubMetadataStore(fileManager: fileManager).loadCurrentSnapshot(from: rootURL),
                    recordReadable: valid && !foundCorruptedRecord
                )
            }
            return task
        }.sorted { $0.updatedAt > $1.updatedAt }
        if foundCorruptedRecord {
            if !tasks.isEmpty {
                for index in tasks.indices {
                    tasks[index].phase = .needsAttention
                    tasks[index].result = "Journal contains a corrupted record; operation state is unknown."
                    tasks[index].events.append(
                        Phase1TaskEvent(
                            id: UUID(),
                            phase: .needsAttention,
                            message: "Corrupted journal record detected during recovery.",
                            occurredAt: Date()
                        )
                    )
                }
            } else {
                tasks.append(
                    Phase1TaskRecord(
                        id: StableIdentity.assetID(candidateID: "journal", canonicalPathComponent: file.path),
                        kind: .initializeRoot,
                        title: "Recover operation journal",
                        objectID: file.path,
                        phase: .needsAttention,
                        result: "Journal contains a corrupted record; operation state is unknown.",
                        planDigest: "unknown",
                        events: [
                            Phase1TaskEvent(
                                id: UUID(),
                                phase: .needsAttention,
                                message: "Corrupted journal record detected during recovery.",
                                occurredAt: Date()
                            )
                        ],
                        updatedAt: Date()
                    )
                )
            }
        }
        return tasks
    }

    private func finalResult(for kind: Phase1OperationKind) -> LocalizedMessage {
        switch kind {
        case .initializeRoot: "Root established."
        case .importLocalSource, .importGitHubSource: "Source imported."
        case .registerLocalSource: "Source registered."
        case .publishManagedCopy: "Managed copy published."
        }
    }

    private func sourceImportRecoveryEvidence(
        plan: Phase1OperationPlan,
        snapshot: RootSnapshot?,
        recordReadable: Bool
    ) -> Phase1RecoveryEvidence {
        let targetPath = plan.targetPath ?? plan.rootPath
        let target = URL(fileURLWithPath: targetPath, isDirectory: true)
        let source = plan.source.flatMap { planned in
            snapshot?.metadata.sources.first { $0.id == planned.id }
        }
        let observedManifest = try? ContentManifestBuilder(fileManager: fileManager).build(
            for: target,
            authorizedRoot: target,
            allowExternalSymbolicLinks: plan.kind == .importLocalSource
        )
        let contentState: Phase1RecoveryState
        if !fileManager.fileExists(atPath: target.path) {
            contentState = .notCompleted
        } else if let expectedIdentity = source?.directoryIdentity,
                  let currentIdentity = try? LinkNodeIdentity.read(at: target).file,
                  observedManifest?.digest == plan.sourceManifest?.digest,
                  expectedIdentity == currentIdentity {
            contentState = .completed
        } else {
            contentState = .unknown
        }
        let metadataState: Phase1RecoveryState
        let baselineState: Phase1RecoveryState
        if let source {
            metadataState = source.localPath == targetPath ? .completed : .unknown
            baselineState = source.baselineManifest?.digest == plan.sourceManifest?.digest ? .completed : .unknown
        } else if snapshot != nil {
            metadataState = .notCompleted
            baselineState = .notCompleted
        } else {
            metadataState = .unknown
            baselineState = .unknown
        }
        let relationState: Phase1RecoveryState
        let relationCount: Int
        if let snapshot, let sourceID = plan.source?.id {
            let assetIDs = Set(snapshot.metadata.installedSkills.filter { $0.sourceID == sourceID }.map(\.assetID))
            relationCount = snapshot.metadata.enablementIntents.filter { assetIDs.contains($0.assetID) }.count
            relationState = .completed
        } else {
            relationCount = 0
            relationState = .unknown
        }
        let metadataPath = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: rootURL).skillshubMetadataFile.path
        let operationPath = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: rootURL)
            .operationJournalFile.path
        return Phase1RecoveryEvidence(
            components: [
                Phase1RecoveryComponent(kind: "content", state: contentState, path: targetPath, detail: "observed-current-source-content"),
                Phase1RecoveryComponent(kind: "relationships", state: relationState, path: targetPath, detail: "observed-current-managed-relations:\(relationCount)"),
                Phase1RecoveryComponent(kind: "metadata", state: metadataState, path: metadataPath, detail: "observed-current-metadata"),
                Phase1RecoveryComponent(kind: "success-baseline", state: baselineState, path: metadataPath, detail: "observed-current-success-baseline"),
                Phase1RecoveryComponent(
                    kind: "operation-materials",
                    state: recordReadable ? .completed : .unknown,
                    path: operationPath,
                    detail: recordReadable ? "source-import-record-readable" : "source-import-record-unverifiable"
                )
            ],
            sourceID: plan.source?.id,
            sourceKind: plan.source?.kind
        )
    }

    private func readRecords() throws -> ([Phase1JournalRecord], Bool) {
        let file = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: rootURL).operationJournalFile
        guard !FileAccessService(fileManager: fileManager).isSymlink(file) else {
            throw Phase1OperationError.journalUnavailable
        }
        guard fileManager.fileExists(atPath: file.path) else { return ([], false) }
        let data = try Data(contentsOf: file)
        var records: [Phase1JournalRecord] = []
        var corrupted = !data.isEmpty && data.last != 0x0A
        for line in data.split(separator: 0x0A) {
            do {
                records.append(try decoder.decode(Phase1JournalRecord.self, from: Data(line)))
            } catch {
                corrupted = true
            }
        }
        return (records, corrupted)
    }

    private func validatedRecords() throws -> [Phase1JournalRecord] {
        let (records, corrupted) = try readRecords()
        guard !corrupted, Dictionary(grouping: records, by: \.operationID).values.allSatisfy(validPrefix) else {
            throw Phase1OperationError.journalUnavailable
        }
        return records
    }

    private func validPrefix(_ records: [Phase1JournalRecord]) -> Bool {
        guard let first = records.first, first.event == .plan,
              let plan = first.operationPlan, plan.id == first.operationID,
              plan.rootPath == rootURL.standardizedFileURL.path,
              plan.kind == first.kind, plan.planDigest == first.planDigest else { return false }
        if plan.kind == .publishManagedCopy || plan.kind == .importLocalSource || plan.kind == .importGitHubSource {
            guard let targetPath = plan.targetPath,
                  {
                      let target = URL(fileURLWithPath: targetPath).standardizedFileURL
                      if plan.kind == .importGitHubSource {
                          return target.deletingLastPathComponent().deletingLastPathComponent()
                              == rootURL.standardizedFileURL.appendingPathComponent("github")
                      }
                      return target.deletingLastPathComponent()
                          == rootURL.standardizedFileURL.appendingPathComponent("local")
                  }() else { return false }
        }
        if plan.compensationPaths != nil, (try? plan.computedDigest()) != first.planDigest { return false }
        guard records.enumerated().allSatisfy({ index, record in
            record.sequence == index + 1 && record.kind == first.kind && record.planDigest == first.planDigest
                && (index == 0 || record.event != .plan)
                && (record.event != .final || index == records.count - 1)
        }) else { return false }
        if records.count > 1, records[1].event != .confirmation || records[1].confirmationTokenID == nil { return false }
        if plan.compensationPaths != nil, records.last?.phase == .completed {
            let steps: [String]
            switch plan.kind {
            case .initializeRoot:
                steps = ["root-layout", "root-layout-created", "initial-metadata", "initial-metadata-committed", "initial-local-state", "initial-local-state-committed"]
            case .importLocalSource, .importGitHubSource:
                steps = ["staging-copy", "staging-verified", "target-publish", "target-published", "metadata-cas", "metadata-committed"]
            case .registerLocalSource:
                steps = ["metadata-cas", "metadata-committed"]
            case .publishManagedCopy:
                steps = ["staging-copy", "staging-verified", "target-publish", "target-published", "metadata-cas", "metadata-committed"]
            }
            let execution = Array(records.dropFirst(2).dropLast(3))
            return records.count == steps.count + 5
                && execution.map(\.result) == steps
                && execution.enumerated().allSatisfy { index, record in
                    record.event == (index.isMultiple(of: 2) ? .stepStarted : .stepResult) && record.phase == .executing
                }
                && records.suffix(3).map(\.event) == [.phase, .phase, .final]
                && records.suffix(3).map(\.phase) == [.observing, .verifying, .completed]
        }
        return true
    }

    private func recoveryResult(
        last: Phase1JournalRecord,
        plan: Phase1OperationPlan?
    ) -> String {
        guard let plan else {
            return "Interrupted operation has no readable plan snapshot; state is unknown."
        }
        let store = SkillsHubMetadataStore(fileManager: fileManager)
        let snapshot = try? store.loadCurrentSnapshot(from: rootURL)
        switch plan.kind {
        case .initializeRoot:
            let layout = store.rootLayout(for: rootURL)
            let localStateFile = SkillsHubLocalStateStore(fileManager: fileManager)
                .localStateFile(for: rootURL)
            let plannedDirectories = [
                layout.localDirectory,
                layout.githubDirectory,
            ]
            let directoryCount = plannedDirectories.filter {
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }.count
            let metadataMatches = snapshot?.metadata == plan.initialMetadata
            let localStateMatches = (try? SkillsHubLocalStateStore(fileManager: fileManager).load(from: rootURL))
                == plan.initialLocalState
                && fileManager.fileExists(atPath: localStateFile.path)
            if metadataMatches && localStateMatches && directoryCount == plannedDirectories.count {
                return "Root objects match the plan, but final journal evidence is missing; re-observe without replaying automatically."
            }
            if metadataMatches {
                return "Root metadata is present, but initialization is incomplete; it will not be replayed automatically."
            }
            if directoryCount > 0 {
                return "A partial plan-owned Root layout is present; initialization will not be replayed automatically."
            }
            return "No verified Root establishment delta is present; the interrupted operation will not be replayed automatically."
        case .importLocalSource, .importGitHubSource:
            guard let targetPath = plan.targetPath,
                  let manifest = plan.sourceManifest,
                  let sourceID = plan.source?.id else {
                return "Source import plan is incomplete; state is unknown."
            }
            let targetURL = URL(fileURLWithPath: targetPath, isDirectory: true)
            guard FileAccessService(fileManager: fileManager).isDescendant(targetURL, of: rootURL) else {
                return "Managed source is outside the current Root; restore current authorization before observing."
            }
            let observedManifest = try? ContentManifestBuilder(fileManager: fileManager).build(
                for: targetURL,
                authorizedRoot: targetURL,
                allowExternalSymbolicLinks: plan.kind == .importLocalSource
            )
            let targetMatches = observedManifest?.digest == manifest.digest
            let metadataMatches = snapshot?.metadata.sources.contains { source in
                source.id == sourceID
                    && source.localPath == targetPath
                    && source.baselineManifest?.digest == manifest.digest
            } == true
            if targetMatches && metadataMatches {
                return "Managed source and metadata are consistent, but final journal evidence is missing; re-observe before completing."
            }
            if targetMatches {
                return "A complete managed source is present without matching metadata; bounded recovery requires attention."
            }
            if metadataMatches {
                return "Metadata claims a managed source whose content cannot be verified; state is inconsistent."
            }
            return "No verified local-source import delta is present; the interrupted operation will not be replayed automatically."
        case .registerLocalSource:
            guard let plannedSource = plan.source else {
                return "Source-registration plan is incomplete; state is unknown."
            }
            let isRegistered = snapshot?.metadata.sources.contains { source in
                source.id == plannedSource.id
                    && source.contentFingerprint == plannedSource.contentFingerprint
            } == true
            return isRegistered
                ? "Source metadata is present, but final journal evidence is missing; re-observe before continuing."
                : "Source metadata is absent; the interrupted operation will not be replayed automatically."
        case .publishManagedCopy:
            guard let targetPath = plan.targetPath,
                  let manifest = plan.sourceManifest else {
                return "Managed-copy plan is incomplete; state is unknown."
            }
            let targetURL = URL(fileURLWithPath: targetPath, isDirectory: true)
            guard FileAccessService(fileManager: fileManager).isDescendant(targetURL, of: rootURL) else {
                return "Managed target is outside the current Root; restore current authorization before observing."
            }
            let observedManifest = try? ContentManifestBuilder(fileManager: fileManager).build(
                for: targetURL,
                authorizedRoot: targetURL
            )
            let targetMatches = observedManifest?.digest == manifest.digest
            let metadataMatches = snapshot?.metadata.installedSkills.contains { installed in
                installed.assetID == plan.assetID
                    && installed.manifestDigest == manifest.digest
                    && installed.installedPath == targetPath
            } == true
            if targetMatches && metadataMatches {
                return "Managed target and metadata are consistent, but final journal evidence is missing; re-observe before completing."
            }
            if targetMatches {
                return "A plan-owned target is present without matching metadata; bounded recovery requires attention."
            }
            if metadataMatches {
                return "Metadata claims a managed asset whose target cannot be verified; state is inconsistent."
            }
            return "No verified managed delta is present; the interrupted operation will not be replayed automatically."
        }
    }

    private func operationTitle(for kind: Phase1OperationKind) -> String {
        switch kind {
        case .initializeRoot: return "Establish Management Directory"
        case .importLocalSource: return "Import local source"
        case .importGitHubSource: return "Import GitHub source"
        case .registerLocalSource: return "Register local source"
        case .publishManagedCopy: return "Publish managed Skill"
        }
    }
}
