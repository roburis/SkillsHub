import Darwin
import Foundation

nonisolated struct AgentConfigurationRecord: Codable, Hashable, Identifiable {
    var id: String
    var agent: AgentKind?
    var displayName: String
    var iconMonogram: String?
    var skillsDirectory: String?

    static func builtIn(_ agent: AgentKind) -> Self {
        Self(
            id: agent.rawValue,
            agent: agent,
            displayName: agent.displayName,
            iconMonogram: nil,
            skillsDirectory: nil
        )
    }

    static var phase1BuiltIns: [Self] {
        [.builtIn(.codex), .builtIn(.claudeCode)]
    }
}

nonisolated struct SkillsHubMetadata: Codable, Hashable {
    static let currentSchemaVersion = 4

    var schemaVersion: Int
    var logicalRevision: UUID
    var generation: UInt64
    var rootConfig: RootConfig
    var sources: [SkillSource]
    var availableSkills: [AvailableSkill]
    var installedSkills: [InstalledSkill]
    var agents: [AgentConfigurationRecord]
    var tags: [TagRecord]
    var purposeMetadata: [String: PurposeMetadata]
    var validationCache: [String: SkillValidationResult]
    var uiState: [String: String]
    var enablementIntents: [EnablementIntent]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        logicalRevision: UUID = UUID(),
        generation: UInt64 = 0,
        rootConfig: RootConfig,
        sources: [SkillSource] = [],
        availableSkills: [AvailableSkill] = [],
        installedSkills: [InstalledSkill] = [],
        agents: [AgentConfigurationRecord] = AgentConfigurationRecord.phase1BuiltIns,
        tags: [TagRecord] = [],
        purposeMetadata: [String: PurposeMetadata] = [:],
        validationCache: [String: SkillValidationResult] = [:],
        uiState: [String: String] = [:],
        enablementIntents: [EnablementIntent] = []) {
        self.schemaVersion = schemaVersion
        self.logicalRevision = logicalRevision
        self.generation = generation
        self.rootConfig = rootConfig
        self.sources = sources
        self.availableSkills = availableSkills
        self.installedSkills = installedSkills
        self.agents = agents
        self.tags = tags
        self.purposeMetadata = purposeMetadata
        self.validationCache = validationCache
        self.uiState = uiState
        self.enablementIntents = enablementIntents
    }

}

nonisolated struct RootLayout: Equatable {
    // Cross-process write-qualification lock lives in a dedicated file, independent of the
    // `.skillshub.json` node that commits replace, so replacing the metadata node never drops the lock.
    static let writeLockFileName = ".skillshub.lock"

    var localDirectory: URL
    var githubDirectory: URL
    var skillshubMetadataFile: URL
    var writeLockFile: URL
    var operationJournalFile: URL
    var operationRecoveryDirectory: URL
}

nonisolated final class SkillsHubMetadataStore {
    // ponytail: one process-wide metadata lock; use per-Root locks if multiple active Roots are supported.
    private static let mutationLock = NSLock()
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let writeCheckpoint: (@Sendable (MetadataWritePhase, URL) throws -> Void)?

    init(
        fileManager: FileManager = .default,
        writeCheckpoint: (@Sendable (MetadataWritePhase, URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.writeCheckpoint = writeCheckpoint
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func rootLayout(for rootURL: URL) -> RootLayout {
        RootLayout(
            localDirectory: rootURL.appendingPathComponent("local", isDirectory: true),
            githubDirectory: rootURL.appendingPathComponent("github", isDirectory: true),
            skillshubMetadataFile: rootURL.appendingPathComponent(".skillshub.json"),
            writeLockFile: rootURL.appendingPathComponent(RootLayout.writeLockFileName),
            operationJournalFile: rootURL.appendingPathComponent(".skillshub.operations.jsonl"),
            operationRecoveryDirectory: rootURL.appendingPathComponent(".skillshub-operations", isDirectory: true)
        )
    }

    @concurrent func inspectRoot(at rootURL: URL) async -> RootInspectionResult {
        let normalizedURL = rootURL.standardizedFileURL
        let path = normalizedURL.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .invalid(.missing(path: path))
        }
        do {
            let values = try normalizedURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isReadableKey,
                .isSymbolicLinkKey
            ])
            if values.isSymbolicLink == true {
                return .invalid(.symbolicLink(path: path))
            }
            guard isDirectory.boolValue, values.isDirectory == true else {
                return .invalid(.notDirectory(path: path))
            }
            guard values.isReadable == true else {
                return .invalid(.unreadable(path: path))
            }
        } catch {
            return .invalid(.unreadable(path: path))
        }

        let metadataFile = rootLayout(for: normalizedURL).skillshubMetadataFile
        guard fileManager.fileExists(atPath: metadataFile.path) else {
            return .initializationRequired(RootInspectionFacts(url: normalizedURL))
        }
        do {
            let snapshot = try loadCurrentSnapshot(from: normalizedURL)
            return .existingRoot(RootInspectionFacts(url: normalizedURL, snapshot: snapshot))
        } catch is DecodingError {
            return .initializationRequired(RootInspectionFacts(url: normalizedURL))
        } catch MetadataCommitError.invalidSchema {
            return .initializationRequired(RootInspectionFacts(url: normalizedURL))
        } catch MetadataCommitError.writeVerificationFailed {
            return .initializationRequired(RootInspectionFacts(url: normalizedURL))
        } catch {
            return .invalid(.invalidMetadata(path: metadataFile.path, reason: String(describing: error)))
        }
    }

    func ensureRootLayout(at rootURL: URL) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let layout = rootLayout(for: rootURL)
        for directory in [layout.localDirectory, layout.githubDirectory] {
            if FileAccessService(fileManager: fileManager).isSymlink(directory) {
                throw Phase1OperationError.targetConflict(directory.path)
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func save(_ metadata: SkillsHubMetadata, to rootURL: URL) throws {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        guard metadata.schemaVersion == SkillsHubMetadata.currentSchemaVersion else {
            throw MetadataCommitError.invalidSchema(metadata.schemaVersion)
        }
        try validate(metadata)
        let file = rootLayout(for: rootURL).skillshubMetadataFile
        guard !fileManager.fileExists(atPath: file.path) else {
            throw MetadataCommitError.expectedSnapshotRequired
        }
        try ensureRootLayout(at: rootURL)
        let qualification = try acquireWriteQualification(at: rootURL)
        defer { qualification.release() }
        _ = try writeAndVerify(metadata, to: file, originalData: nil)
    }

    func writeInitialMetadata(
        _ metadata: SkillsHubMetadata,
        to rootURL: URL,
        expectedParentIdentity: TargetFileIdentity? = nil
    ) throws -> RootSnapshot {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let normalizedRoot = rootURL.standardizedFileURL
        guard metadata.schemaVersion == SkillsHubMetadata.currentSchemaVersion,
              metadata.generation == 0,
              metadata.rootConfig.rootPath == normalizedRoot.path else {
            throw MetadataCommitError.invalidSchema(metadata.schemaVersion)
        }
        try validate(metadata)
        let layout = rootLayout(for: normalizedRoot)
        let access = FileAccessService(fileManager: fileManager)
        for directory in [layout.localDirectory, layout.githubDirectory] {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !access.isSymlink(directory) else {
                throw Phase1OperationError.targetConflict(directory.path)
            }
        }
        guard !fileManager.fileExists(atPath: layout.skillshubMetadataFile.path) else {
            throw Phase1OperationError.targetConflict(layout.skillshubMetadataFile.path)
        }
        let qualification = try acquireWriteQualification(at: normalizedRoot)
        defer { qualification.release() }
        return try writeAndVerify(
            metadata,
            to: layout.skillshubMetadataFile,
            originalData: nil,
            expectedParentIdentity: expectedParentIdentity
        )
    }

    func load(from rootURL: URL) throws -> SkillsHubMetadata {
        try loadCurrentSnapshot(from: rootURL).metadata
    }

    func loadCurrentSnapshot(from rootURL: URL) throws -> RootSnapshot {
        let observed = try readStableFile(at: rootLayout(for: rootURL).skillshubMetadataFile)
        let metadata = try decodeMetadata(observed.data, at: rootURL)
        return RootSnapshot(
            metadata: metadata, generation: metadata.generation,
            metadataDigest: SHA256Digest.hex(observed.data),
            metadataFileIdentity: observed.fileIdentity,
            metadataParentIdentity: observed.parentIdentity
        )
    }

    /// Connects an authorized Root using the current format. File access errors remain errors.
    func loadOrCreateSnapshot(from rootURL: URL) throws -> RootSnapshot {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let parentIdentity = try directoryIdentity(of: rootURL)
        let qualification = try acquireWriteQualification(at: rootURL)
        defer { qualification.release() }
        let file = rootLayout(for: rootURL).skillshubMetadataFile
        if try optionalFileIdentity(of: file) != nil {
            let observed = try readStableFile(at: file)
            do {
                let metadata = try decodeMetadata(observed.data, at: rootURL)
                return RootSnapshot(
                    metadata: metadata, generation: metadata.generation,
                    metadataDigest: SHA256Digest.hex(observed.data),
                    metadataFileIdentity: observed.fileIdentity,
                    metadataParentIdentity: observed.parentIdentity
                )
            } catch is DecodingError {
                // A complete readable file with invalid fields is rebuilt below.
            } catch MetadataCommitError.invalidSchema {
            } catch MetadataCommitError.writeVerificationFailed {
            }
            try ensureRootLayout(at: rootURL)
            return try writeAndVerify(
                SkillsHubMetadata(rootConfig: RootConfig(rootPath: rootURL.standardizedFileURL.path)),
                to: file, originalData: observed.data,
                expectedFileIdentity: observed.fileIdentity,
                expectedParentIdentity: observed.parentIdentity
            )
        }
        try ensureRootLayout(at: rootURL)
        return try writeAndVerify(
            SkillsHubMetadata(rootConfig: RootConfig(rootPath: rootURL.standardizedFileURL.path)),
            to: file, originalData: nil, expectedParentIdentity: parentIdentity
        )
    }

    private func decodeMetadata(_ data: Data, at rootURL: URL) throws -> SkillsHubMetadata {
        let metadata = try decoder.decode(SkillsHubMetadata.self, from: data)
        try validate(metadata)
        guard metadata.rootConfig.rootPath == rootURL.standardizedFileURL.path else {
            throw MetadataCommitError.writeVerificationFailed
        }
        return metadata
    }

    func commit(
        at rootURL: URL,
        expected snapshot: RootSnapshot,
        applying mutation: (inout SkillsHubMetadata) throws -> Void
    ) throws -> RootSnapshot {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let qualification = try acquireWriteQualification(at: rootURL)
        defer { qualification.release() }
        let file = rootLayout(for: rootURL).skillshubMetadataFile
        let current = try loadCurrentSnapshot(from: rootURL)
        guard current.generation == snapshot.generation else {
            throw MetadataCommitError.staleGeneration(expected: snapshot.generation, actual: current.generation)
        }
        guard current.metadataDigest == snapshot.metadataDigest else {
            throw MetadataCommitError.staleDigest
        }
        guard let expectedFileIdentity = snapshot.metadataFileIdentity,
              current.metadataFileIdentity == expectedFileIdentity else {
            throw MetadataCommitError.metadataIdentityChanged
        }
        guard let expectedParentIdentity = snapshot.metadataParentIdentity,
              current.metadataParentIdentity == expectedParentIdentity else {
            throw MetadataCommitError.metadataParentIdentityChanged
        }

        var next = current.metadata
        try mutation(&next)
        guard current.generation < UInt64.max else {
            throw MetadataCommitError.generationExhausted
        }
        next.schemaVersion = SkillsHubMetadata.currentSchemaVersion
        next.generation = current.generation + 1
        next.logicalRevision = UUID()
        try validate(next)
        let original = try readStableFile(at: file)
        guard original.fileIdentity == expectedFileIdentity else {
            throw MetadataCommitError.metadataIdentityChanged
        }
        guard original.parentIdentity == expectedParentIdentity else {
            throw MetadataCommitError.metadataParentIdentityChanged
        }
        guard SHA256Digest.hex(original.data) == snapshot.metadataDigest else {
            throw MetadataCommitError.staleDigest
        }
        return try writeAndVerify(
            next,
            to: file,
            originalData: original.data,
            expectedFileIdentity: expectedFileIdentity,
            expectedParentIdentity: expectedParentIdentity
        )
    }

    private func acquireWriteQualification(at rootURL: URL) throws -> RootProcessWriteLock {
        switch RootProcessWriteLock.acquire(at: rootLayout(for: rootURL).writeLockFile) {
        case .success(let qualification):
            return qualification
        case .failure(let reason):
            throw reason
        }
    }

    private func validate(_ metadata: SkillsHubMetadata) throws {
        guard metadata.schemaVersion == SkillsHubMetadata.currentSchemaVersion else {
            throw MetadataCommitError.invalidSchema(metadata.schemaVersion)
        }
        guard Set(metadata.sources.map(\.id)).count == metadata.sources.count,
              Set(metadata.availableSkills.map(\.candidateID)).count == metadata.availableSkills.count,
              Set(metadata.installedSkills.map(\.assetID)).count == metadata.installedSkills.count,
              Set(metadata.agents.map(\.id)).count == metadata.agents.count,
              metadata.agents.allSatisfy({ configuration in
                  let name = configuration.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                  guard name.isEmpty == false else { return false }
                  if let agent = configuration.agent {
                      return configuration.id == agent.rawValue && configuration.iconMonogram == nil
                  }
                  guard let monogram = configuration.iconMonogram,
                        let directory = configuration.skillsDirectory else { return false }
                  return Self.isValidAgentMonogram(monogram)
                      && URL(fileURLWithPath: directory).path == directory
                      && directory.hasPrefix("/")
              })
        else {
            throw MetadataCommitError.writeVerificationFailed
        }
        let sourceIDs = Set(metadata.sources.map(\.id))
        let assetIDs = Set(metadata.installedSkills.map(\.assetID))
        let canonicalPaths = metadata.installedSkills.map { $0.installedPath.precomposedStringWithCanonicalMapping.lowercased() }
        let localSourcePaths = metadata.sources.compactMap { source in
            source.kind == .localDirectory ? source.localPath?.precomposedStringWithCanonicalMapping.lowercased() : nil
        }
        let candidateKeys = metadata.availableSkills.map {
            StableIdentity.candidateID(sourceID: $0.sourceID, relativePath: $0.skillPath)
        }
        let candidates = Dictionary(uniqueKeysWithValues: metadata.availableSkills.map { ($0.candidateID, $0) })
        guard metadata.availableSkills.allSatisfy({ sourceIDs.contains($0.sourceID) && !$0.candidateID.isEmpty }),
              metadata.installedSkills.allSatisfy({ $0.sourceID.map(sourceIDs.contains) ?? true }),
              metadata.installedSkills.allSatisfy({ asset in
                  guard let candidateID = asset.candidateID else { return true }
                  guard let candidate = candidates[candidateID] else { return false }
                  return candidate.sourceID == asset.sourceID
              }),
              metadata.enablementIntents.allSatisfy({ assetIDs.contains($0.assetID) && !$0.agentID.isEmpty && $0.scope == .global }),
              Set(candidateKeys).count == candidateKeys.count,
              Set(metadata.enablementIntents.map(\.id)).count == metadata.enablementIntents.count,
              Set(canonicalPaths).count == canonicalPaths.count,
              Set(localSourcePaths).count == localSourcePaths.count
        else {
            throw MetadataCommitError.writeVerificationFailed
        }
        // a persisted stable link name must be a single safe path component.
        guard metadata.installedSkills.allSatisfy({ asset in
            asset.stableLinkName.map(Self.isSafePathComponent) ?? true
        }) else {
            throw MetadataCommitError.writeVerificationFailed
        }
        // baseline manifest paths must stay in-bounds (no absolute or `..` traversal).
        guard metadata.sources.allSatisfy({ source in
            source.baselineManifest?.entries.allSatisfy { Self.isInBoundsRelativePath($0.relativePath) } ?? true
        }) else {
            throw MetadataCommitError.writeVerificationFailed
        }
    }

    private static func isValidAgentMonogram(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...4).contains(trimmed.count)
            && trimmed.allSatisfy { character in
                character.isWhitespace == false
                    && character.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) == false }
            }
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }

    private static func isInBoundsRelativePath(_ value: String) -> Bool {
        guard value != "." else { return true }
        guard !value.hasPrefix("/") else { return false }
        return !value.split(separator: "/").contains("..")
    }

    private func writeAndVerify(
        _ metadata: SkillsHubMetadata,
        to file: URL,
        originalData: Data?,
        expectedFileIdentity: TargetFileIdentity? = nil,
        expectedParentIdentity: TargetFileIdentity? = nil
    ) throws -> RootSnapshot {
        try writeCheckpoint?(.encoding, file)
        let encoded = try encoder.encode(metadata)
        let candidate = try decoder.decode(SkillsHubMetadata.self, from: encoded)
        try validate(candidate)
        guard try encoder.encode(candidate) == encoded else {
            throw MetadataCommitError.writeVerificationFailed
        }
        let staging = file.deletingLastPathComponent().appendingPathComponent(".skillshub-\(UUID().uuidString).staging")
        let parent = file.deletingLastPathComponent()
        let initialParentIdentity = try directoryIdentity(of: parent)
        if let expectedParentIdentity, initialParentIdentity != expectedParentIdentity {
            throw MetadataCommitError.metadataParentIdentityChanged
        }
        let initialFileIdentity = try optionalFileIdentity(of: file)
        if let expectedFileIdentity, initialFileIdentity != expectedFileIdentity {
            throw MetadataCommitError.metadataIdentityChanged
        }
        if originalData == nil, initialFileIdentity != nil {
            throw Phase1OperationError.targetConflict(file.path)
        }
        var stagingIdentity: TargetFileIdentity?
        var replacementStarted = false
        do {
            try encoded.write(to: staging, options: [.withoutOverwriting])
            stagingIdentity = try fileIdentity(of: staging)
            try writeCheckpoint?(.staging, staging)
            guard try Data(contentsOf: staging) == encoded else {
                throw MetadataCommitError.writeVerificationFailed
            }
            try writeCheckpoint?(.stagingFileSync, staging)
            try synchronizeFile(at: staging, phase: .stagingFileSync)
            try writeCheckpoint?(.stagingDirectorySync, parent)
            try synchronizeDirectory(at: parent, phase: .stagingDirectorySync)
            try writeCheckpoint?(.replacement, staging)
            guard try directoryIdentity(of: parent) == initialParentIdentity else {
                throw MetadataCommitError.metadataParentIdentityChanged
            }
            guard try optionalFileIdentity(of: staging) == stagingIdentity else {
                throw MetadataCommitError.metadataIdentityChanged
            }
            if let originalData {
                guard try optionalFileIdentity(of: file) == initialFileIdentity else {
                    throw MetadataCommitError.metadataIdentityChanged
                }
                guard try Data(contentsOf: file) == originalData else {
                    throw MetadataCommitError.staleDigest
                }
                try exchange(
                    staging,
                    with: file,
                    expectedParentIdentity: initialParentIdentity,
                    phase: .replacement
                )
            } else {
                try publishExclusively(
                    staging,
                    to: file,
                    expectedParentIdentity: initialParentIdentity,
                    phase: .replacement
                )
            }
            replacementStarted = true
            try writeCheckpoint?(.displacedOriginal, originalData == nil ? file : staging)
            guard try directoryIdentity(of: parent) == initialParentIdentity else {
                throw MetadataCommitError.metadataParentIdentityChanged
            }
            guard try optionalFileIdentity(of: file) == stagingIdentity else {
                throw MetadataCommitError.metadataIdentityChanged
            }
            if let originalData {
                guard try optionalFileIdentity(of: staging) == initialFileIdentity,
                      try Data(contentsOf: staging) == originalData else {
                    throw MetadataCommitError.metadataIdentityChanged
                }
            }
            try writeCheckpoint?(.publishedFileSync, file)
            try synchronizeFile(at: file, phase: .publishedFileSync)
            try writeCheckpoint?(.publishedDirectorySync, parent)
            try synchronizeDirectory(at: parent, phase: .publishedDirectorySync)
            try writeCheckpoint?(.readback, file)
            let observed = try readStableFile(at: file)
            let reread = observed.data
            let decoded = try decoder.decode(SkillsHubMetadata.self, from: reread)
            try validate(decoded)
            guard observed.fileIdentity == stagingIdentity,
                  observed.parentIdentity == initialParentIdentity,
                  reread == encoded,
                  try encoder.encode(decoded) == encoded else {
                throw MetadataCommitError.writeVerificationFailed
            }
            if originalData != nil {
                try fileManager.removeItem(at: staging)
            }
            return RootSnapshot(
                metadata: decoded,
                generation: decoded.generation,
                metadataDigest: SHA256Digest.hex(reread),
                metadataFileIdentity: observed.fileIdentity,
                metadataParentIdentity: observed.parentIdentity
            )
        } catch {
            if replacementStarted {
                // Keep the actual files; an external edit must never be overwritten by a blind rollback.
                throw MetadataCommitError.recoveryRequired(
                    metadataPath: file.path, backupPath: originalData == nil ? nil : staging.path,
                    stagingPath: staging.path, reason: String(describing: error)
                )
            }
            if let stagingIdentity,
               (try? optionalFileIdentity(of: staging)) == stagingIdentity {
                try? fileManager.removeItem(at: staging)
            }
            throw error
        }
    }

    private func readStableFile(at file: URL) throws -> (
        data: Data,
        fileIdentity: TargetFileIdentity,
        parentIdentity: TargetFileIdentity
    ) {
        let parent = file.deletingLastPathComponent()
        let parentBefore = try directoryIdentity(of: parent)
        let fileBefore = try fileIdentity(of: file)
        let data = try Data(contentsOf: file)
        guard try directoryIdentity(of: parent) == parentBefore else {
            throw MetadataCommitError.metadataParentIdentityChanged
        }
        guard try fileIdentity(of: file) == fileBefore else {
            throw MetadataCommitError.metadataIdentityChanged
        }
        return (data, fileBefore, parentBefore)
    }

    private func optionalFileIdentity(of url: URL) throws -> TargetFileIdentity? {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &status) } ?? -1
        }
        if result == 0 {
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw MetadataCommitError.metadataIdentityChanged
            }
            return TargetFileIdentity(
                volumeNumber: UInt64(status.st_dev),
                fileNumber: UInt64(status.st_ino)
            )
        }
        if errno == ENOENT { return nil }
        throw MetadataCommitError.filesystemFailure(
            phase: .readback,
            path: url.path,
            errno: errno
        )
    }

    private func fileIdentity(of url: URL) throws -> TargetFileIdentity {
        guard let identity = try optionalFileIdentity(of: url) else {
            throw MetadataCommitError.metadataIdentityChanged
        }
        return identity
    }

    private func directoryIdentity(of url: URL) throws -> TargetFileIdentity {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &status) } ?? -1
        }
        guard result == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw MetadataCommitError.metadataParentIdentityChanged
        }
        return TargetFileIdentity(
            volumeNumber: UInt64(status.st_dev),
            fileNumber: UInt64(status.st_ino)
        )
    }

    private func synchronizeFile(at url: URL, phase: MetadataWritePhase) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else {
            throw MetadataCommitError.filesystemFailure(phase: phase, path: url.path, errno: errno)
        }
        defer { Darwin.close(descriptor) }
        if Darwin.fcntl(descriptor, F_FULLFSYNC) != 0, Darwin.fsync(descriptor) != 0 {
            throw MetadataCommitError.filesystemFailure(phase: phase, path: url.path, errno: errno)
        }
    }

    private func synchronizeDirectory(at url: URL, phase: MetadataWritePhase) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else {
            throw MetadataCommitError.filesystemFailure(phase: phase, path: url.path, errno: errno)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw MetadataCommitError.filesystemFailure(phase: phase, path: url.path, errno: errno)
        }
    }

    private func exchange(
        _ first: URL,
        with second: URL,
        expectedParentIdentity: TargetFileIdentity,
        phase: MetadataWritePhase
    ) throws {
        let outcome = try renameWithinVerifiedParent(
            source: first,
            destination: second,
            expectedParentIdentity: expectedParentIdentity,
            flags: UInt32(RENAME_SWAP) | UInt32(RENAME_NOFOLLOW_ANY) | UInt32(RENAME_RESOLVE_BENEATH)
        )
        guard outcome.result == 0 else {
            throw MetadataCommitError.filesystemFailure(phase: phase, path: second.path, errno: outcome.errorNumber)
        }
    }

    private func publishExclusively(
        _ source: URL,
        to destination: URL,
        expectedParentIdentity: TargetFileIdentity,
        phase: MetadataWritePhase
    ) throws {
        let outcome = try renameWithinVerifiedParent(
            source: source,
            destination: destination,
            expectedParentIdentity: expectedParentIdentity,
            flags: UInt32(RENAME_EXCL) | UInt32(RENAME_NOFOLLOW_ANY) | UInt32(RENAME_RESOLVE_BENEATH)
        )
        guard outcome.result == 0 else {
            if outcome.errorNumber == EEXIST {
                throw Phase1OperationError.targetConflict(destination.path)
            }
            throw MetadataCommitError.filesystemFailure(
                phase: phase,
                path: destination.path,
                errno: outcome.errorNumber
            )
        }
    }

    private func renameWithinVerifiedParent(
        source: URL,
        destination: URL,
        expectedParentIdentity: TargetFileIdentity,
        flags: UInt32
    ) throws -> (result: Int32, errorNumber: Int32) {
        let parent = source.deletingLastPathComponent()
        guard parent == destination.deletingLastPathComponent() else {
            throw MetadataCommitError.metadataParentIdentityChanged
        }
        let descriptor = parent.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else {
            throw MetadataCommitError.metadataParentIdentityChanged
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              TargetFileIdentity(
                volumeNumber: UInt64(status.st_dev),
                fileNumber: UInt64(status.st_ino)
              ) == expectedParentIdentity else {
            throw MetadataCommitError.metadataParentIdentityChanged
        }
        let result = source.lastPathComponent.withCString { sourceName in
            destination.lastPathComponent.withCString { destinationName in
                Darwin.renameatx_np(
                    descriptor,
                    sourceName,
                    descriptor,
                    destinationName,
                    flags
                )
            }
        }
        return (result, result == 0 ? 0 : errno)
    }

}
