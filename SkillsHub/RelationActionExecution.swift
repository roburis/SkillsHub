import Darwin
import Foundation

nonisolated enum RelationActionExecutionStatus: String, Equatable, Sendable {
    case succeeded
    case noChange = "no-change"
    case blocked
    case failed
    case unknown
}

nonisolated enum RelationActionExecutionBlockReason: String, Equatable, Sendable {
    case currentFactsChanged = "current-facts-changed"
    case nodeConflict = "node-conflict"
    case ownershipEvidenceInvalid = "ownership-evidence-invalid"
    case identityBoundRemovalUnavailable = "identity-bound-removal-unavailable"
}

nonisolated enum RelationActionFileEvent: Equatable, Sendable {
    case created(String)
    case isolated(String)
    case removed(String)
    case restored(String)
    case creationCompensated(String)
    case compensationFailed(String)
    case retainedForRecovery(String)
}

nonisolated enum RelationActionMetadataDelta: String, Equatable, Sendable {
    case none
    case committed
    case restored
    case unknown
}

nonisolated struct RelationActionExecutionResult: Sendable {
    let relation: AgentRelationIdentity
    let status: RelationActionExecutionStatus
    let blockReason: RelationActionExecutionBlockReason?
    let fileEvents: [RelationActionFileEvent]
    let metadataDelta: RelationActionMetadataDelta
    let observation: TargetObservation?
    let verification: VerificationRecord?
    let limitations: [String]
    let safeNextStep: String
    var creationMaterials: CreationMaterialSettlement? = nil
}

nonisolated struct CreationMaterialReview: Codable, Hashable, Sendable {
    let path: String
    let canSettle: Bool
    let detail: String
}

nonisolated struct BrokenLinkDeletionExecutionResult: Equatable, Sendable {
    let status: RelationActionExecutionStatus
    let fileEvents: [RelationActionFileEvent]
    let retainedPath: String?
    let safeNextStep: String
    var failureMessage: LocalizedMessage? = nil
}

nonisolated struct RelationActionRecoveryResult: Sendable {
    let relation: AgentRelationIdentity?
    let observation: TargetObservation?
    let verification: VerificationRecord?
    let components: [RelationActionRecoveryComponent]
    let limitations: [String]
    let safeNextStep: String
    let creationMaterials: CreationMaterialReview?

    init(
        relation: AgentRelationIdentity?,
        observation: TargetObservation?,
        verification: VerificationRecord?,
        components: [RelationActionRecoveryComponent] = [],
        limitations: [String],
        safeNextStep: String,
        creationMaterials: CreationMaterialReview? = nil
    ) {
        self.relation = relation
        self.observation = observation
        self.verification = verification
        self.components = components
        self.limitations = limitations
        self.safeNextStep = safeNextStep
        self.creationMaterials = creationMaterials
    }
}

nonisolated enum RelationActionRecoveryState: String, Codable, Equatable, Sendable {
    case completed
    case notCompleted = "not-completed"
    case unknown
}

nonisolated struct RelationActionRecoveryComponent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case metadata
        case linkNode = "link-node"
        case targetDirectory = "target-directory"
        case operationMaterials = "operation-materials"
        case preparationNode = "preparation-node"
        case isolationNode = "isolation-node"
        case creationDirectory = "creation-directory"
    }

    let kind: Kind
    let state: RelationActionRecoveryState
    let path: String
    let detail: String
}

nonisolated enum RelationActionOperationCheckpoint: String, Codable, Equatable, Sendable {
    case afterFilePrimitive = "after-file-primitive"
    case afterMetadataCommit = "after-metadata-commit"
    case finalObservation = "final-observation"
    case recoveryObservation = "recovery-observation"
}

nonisolated struct RelationActionOperationObservation: Codable, Equatable, Sendable {
    let checkpoint: RelationActionOperationCheckpoint
    let metadataGeneration: UInt64?
    let metadataDigest: String?
    let metadataFileIdentity: TargetFileIdentity?
    let metadataParentIdentity: TargetFileIdentity?
    let linkObservation: TargetObservation?
    let targetDirectoryIdentity: TargetFileIdentity?
    let limitation: String?
    let observedAt: Date
}

nonisolated struct RelationActionOperationRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let operationID: UUID
    let rootPath: String
    let relation: AgentRelationIdentity
    let desiredEnabled: Bool
    let facts: RelationActionFacts
    let factsDigest: String
    let originalMetadataDigest: String
    let originalMetadataFileIdentity: TargetFileIdentity?
    let metadataParentIdentity: TargetFileIdentity?
    let targetDirectoryIdentity: TargetFileIdentity
    let operationDirectoryIdentity: TargetFileIdentity
    let linkPath: String
    let canonicalTargetPath: String
    var preparationPaths: [String]
    var isolationPaths: [String]
    var retainedPaths: [String]
    var observations: [RelationActionOperationObservation]
    var completedAt: Date?
    var targetNodeIdentity: LinkNodeIdentity? = nil
    var creation: LinkCreationEvidence? = nil
    var removal: LinkRemovalEvidence? = nil
    var creationMaterials: CreationMaterialSettlement? = nil
}

nonisolated struct BrokenLinkDeletionOperationRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let operationKind: BrokenLinkDeletionAuthorization.Kind
    let operationID: UUID
    let facts: BrokenLinkDeletionFacts
    let factsDigest: String
    let operationDirectoryIdentity: TargetFileIdentity
    var removal: LinkRemovalEvidence?
    var completedAt: Date?
}

nonisolated enum RelationRecoveryOperationRecord: Sendable {
    case relation(RelationActionOperationRecord)
    case brokenLink(BrokenLinkDeletionOperationRecord)
}

nonisolated struct UnfinishedAgentOperation: Hashable, Sendable {
    let id: UUID
    let title: String
}

nonisolated enum RelationActionOperationRecordError: Error, Equatable {
    case invalidRoot
    case invalidRecord
    case recordAlreadyExists
    case recordUnavailable
    case readbackFailed
    case synchronizationFailed(path: String, errno: Int32)
}

nonisolated final class RelationActionOperationRecordStore: @unchecked Sendable {
    static let recordFileName = "record.json"
    static let originalMetadataFileName = "original-metadata.json"

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func recoveryOperationIDs(rootURL: URL) throws -> [UUID] {
        let directory = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: rootURL.standardizedFileURL)
            .operationRecoveryDirectory
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        guard (try? LinkNodeIdentity.read(at: directory).kind) == S_IFDIR else {
            throw RelationActionOperationRecordError.recordUnavailable
        }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { entry in
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  let entryKind = try? LinkNodeIdentity.read(at: entry).kind else { return nil }
            guard entryKind == S_IFDIR else { return id }
            guard (try? LinkNodeIdentity.read(at: entry.appendingPathComponent(Self.recordFileName))) != nil else { return nil }
            return id
        }.sorted { $0.uuidString < $1.uuidString }
    }

    func loadRecoveryRecord(operationID: UUID, rootURL: URL) throws -> RelationRecoveryOperationRecord {
        let directory = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: rootURL.standardizedFileURL)
            .operationRecoveryDirectory.appendingPathComponent(operationID.uuidString, isDirectory: true)
        guard (try? LinkNodeIdentity.read(at: directory).kind) == S_IFDIR,
              (try? LinkNodeIdentity.read(at: directory.appendingPathComponent(Self.recordFileName)).kind) == S_IFREG else {
            throw RelationActionOperationRecordError.recordUnavailable
        }
        if let record = try? load(operationID: operationID, rootURL: rootURL) {
            return .relation(record)
        }
        return .brokenLink(try loadBrokenLinkDeletion(operationID: operationID, rootURL: rootURL))
    }

    func unfinishedOperationBlockers(
        agentID: String,
        rootURL: URL
    ) throws -> [UnfinishedAgentOperation] {
        let directory = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: rootURL.standardizedFileURL)
            .operationRecoveryDirectory
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).compactMap { operationDirectory in
            let recordFile = operationDirectory.appendingPathComponent(Self.recordFileName)
            guard fileManager.fileExists(atPath: recordFile.path) else { return nil }
            let data = try Data(contentsOf: recordFile)
            if let record = try? decoder.decode(RelationActionOperationRecord.self, from: data) {
                guard record.relation.agentID == agentID, record.completedAt == nil else { return nil }
                return UnfinishedAgentOperation(
                    id: record.operationID,
                    title: "Unfinished relationship operation"
                )
            }
            if let record = try? decoder.decode(BrokenLinkDeletionOperationRecord.self, from: data) {
                guard record.facts.agentID == agentID, record.completedAt == nil else { return nil }
                return UnfinishedAgentOperation(
                    id: record.operationID,
                    title: "Unfinished broken-link operation"
                )
            }
            return UnfinishedAgentOperation(
                id: UUID(uuidString: operationDirectory.lastPathComponent)
                    ?? StableIdentity.assetID(candidateID: "operation", canonicalPathComponent: operationDirectory.path),
                title: "Unverifiable operation record"
            )
        }
    }

    func prepare(
        authorization: RelationActionAuthorization,
        snapshot: RootSnapshot,
        rootURL: URL
    ) throws -> RelationActionOperationRecord {
        let normalizedRoot = rootURL.standardizedFileURL
        guard normalizedRoot.path == authorization.facts.rootPath,
              snapshot.generation == authorization.facts.metadataGeneration,
              snapshot.metadataDigest == authorization.facts.metadataDigest,
              snapshot.metadataFileIdentity == authorization.facts.metadataFileIdentity,
              snapshot.metadataParentIdentity == authorization.facts.metadataParentIdentity else {
            throw RelationActionOperationRecordError.invalidRoot
        }

        let layout = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: normalizedRoot)
        let metadata = try Data(contentsOf: layout.skillshubMetadataFile)
        guard SHA256Digest.hex(metadata) == snapshot.metadataDigest,
              try identity(of: layout.skillshubMetadataFile, kind: S_IFREG) == snapshot.metadataFileIdentity,
              try identity(of: normalizedRoot, kind: S_IFDIR) == snapshot.metadataParentIdentity else {
            throw RelationActionOperationRecordError.invalidRecord
        }

        try ensureDirectory(layout.operationRecoveryDirectory)
        let operationDirectory = layout.operationRecoveryDirectory.appendingPathComponent(
            authorization.actionID.uuidString,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: operationDirectory.path) else {
            throw RelationActionOperationRecordError.recordAlreadyExists
        }
        try fileManager.createDirectory(at: operationDirectory, withIntermediateDirectories: false)
        let operationDirectoryIdentity = try requiredIdentity(of: operationDirectory, kind: S_IFDIR)
        let targetDirectoryIdentity = try requiredIdentity(
            of: URL(fileURLWithPath: authorization.facts.targetPath, isDirectory: true),
            kind: S_IFDIR
        )
        var record = RelationActionOperationRecord(
            schemaVersion: RelationActionOperationRecord.schemaVersion,
            operationID: authorization.actionID,
            rootPath: normalizedRoot.path,
            relation: authorization.relation,
            desiredEnabled: authorization.desiredEnabled,
            facts: authorization.facts,
            factsDigest: authorization.factsDigest,
            originalMetadataDigest: snapshot.metadataDigest,
            originalMetadataFileIdentity: snapshot.metadataFileIdentity,
            metadataParentIdentity: snapshot.metadataParentIdentity,
            targetDirectoryIdentity: targetDirectoryIdentity,
            operationDirectoryIdentity: operationDirectoryIdentity,
            linkPath: authorization.facts.linkPath,
            canonicalTargetPath: authorization.facts.canonicalPath,
            preparationPaths: [authorization.facts.linkPath, authorization.facts.canonicalPath],
            isolationPaths: [],
            retainedPaths: [],
            observations: [],
            completedAt: nil
        )
        record.targetNodeIdentity = try LinkNodeIdentity.read(at: URL(fileURLWithPath: authorization.facts.targetPath))
        let inspection = try RelationOwnershipInspector().inspect(
            linkURL: URL(fileURLWithPath: authorization.facts.linkPath), relation: authorization.relation,
            canonicalTargetPath: authorization.facts.canonicalPath, evidence: nil
        )
        guard RelationActionTokenBuilder().observationDigest(of: inspection.observation) == authorization.facts.observationDigest,
              inspection.observation.parentIdentity == record.targetNodeIdentity else {
            throw RelationActionOperationRecordError.invalidRecord
        }
        try writeNew(metadata, to: operationDirectory.appendingPathComponent(Self.originalMetadataFileName))
        try writeNew(try encoder.encode(record), to: operationDirectory.appendingPathComponent(Self.recordFileName))
        try synchronizeDirectory(operationDirectory)
        try synchronizeDirectory(layout.operationRecoveryDirectory)
        guard try load(operationID: authorization.actionID, rootURL: normalizedRoot) == record else {
            throw RelationActionOperationRecordError.readbackFailed
        }
        return record
    }

    func save(_ record: RelationActionOperationRecord, rootURL: URL) throws {
        try validate(record, operationID: record.operationID, rootURL: rootURL)
        let operationDirectory = try verifiedOperationDirectory(for: record, rootURL: rootURL)
        let file = operationDirectory.appendingPathComponent(Self.recordFileName)
        let data = try encoder.encode(record)
        try data.write(to: file, options: [.atomic])
        try synchronizeFile(file)
        try synchronizeDirectory(operationDirectory)
        guard try Data(contentsOf: file) == data,
              try verifiedOperationDirectory(for: record, rootURL: rootURL) == operationDirectory else {
            throw RelationActionOperationRecordError.readbackFailed
        }
    }

    func load(operationID: UUID, rootURL: URL) throws -> RelationActionOperationRecord {
        let normalizedRoot = rootURL.standardizedFileURL
        let layout = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: normalizedRoot)
        let operationDirectory = layout.operationRecoveryDirectory.appendingPathComponent(
            operationID.uuidString,
            isDirectory: true
        )
        let recordFile = operationDirectory.appendingPathComponent(Self.recordFileName)
        let record = try decoder.decode(RelationActionOperationRecord.self, from: Data(contentsOf: recordFile))
        try validate(record, operationID: operationID, rootURL: normalizedRoot)
        _ = try verifiedOperationDirectory(for: record, rootURL: normalizedRoot)
        let original = try Data(contentsOf: operationDirectory.appendingPathComponent(Self.originalMetadataFileName))
        guard SHA256Digest.hex(original) == record.originalMetadataDigest else {
            throw RelationActionOperationRecordError.invalidRecord
        }
        return record
    }

    func prepare(
        authorization: BrokenLinkDeletionAuthorization,
        rootURL: URL
    ) throws -> BrokenLinkDeletionOperationRecord {
        let normalizedRoot = rootURL.standardizedFileURL
        guard authorization.kind == .confirmedBrokenLink,
              normalizedRoot.path == authorization.facts.rootPath,
              try LinkNodeIdentity.read(at: normalizedRoot) == authorization.facts.rootIdentity,
              BrokenLinkDeletionTokenBuilder().digest(of: authorization.facts) == authorization.factsDigest else {
            throw RelationActionOperationRecordError.invalidRoot
        }
        let layout = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: normalizedRoot)
        try ensureDirectory(layout.operationRecoveryDirectory)
        let operationDirectory = layout.operationRecoveryDirectory.appendingPathComponent(
            authorization.actionID.uuidString,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: operationDirectory.path) else {
            throw RelationActionOperationRecordError.recordAlreadyExists
        }
        try fileManager.createDirectory(at: operationDirectory, withIntermediateDirectories: false)
        let record = BrokenLinkDeletionOperationRecord(
            schemaVersion: BrokenLinkDeletionOperationRecord.schemaVersion,
            operationKind: authorization.kind,
            operationID: authorization.actionID,
            facts: authorization.facts,
            factsDigest: authorization.factsDigest,
            operationDirectoryIdentity: try requiredIdentity(of: operationDirectory, kind: S_IFDIR),
            removal: nil,
            completedAt: nil
        )
        try writeNew(try encoder.encode(record), to: operationDirectory.appendingPathComponent(Self.recordFileName))
        try synchronizeDirectory(operationDirectory)
        try synchronizeDirectory(layout.operationRecoveryDirectory)
        guard try loadBrokenLinkDeletion(operationID: authorization.actionID, rootURL: normalizedRoot) == record else {
            throw RelationActionOperationRecordError.readbackFailed
        }
        return record
    }

    func save(_ record: BrokenLinkDeletionOperationRecord, rootURL: URL) throws {
        try validate(record, operationID: record.operationID, rootURL: rootURL)
        let directory = try verifiedOperationDirectory(for: record, rootURL: rootURL)
        let file = directory.appendingPathComponent(Self.recordFileName)
        let data = try encoder.encode(record)
        try data.write(to: file, options: [.atomic])
        try synchronizeFile(file)
        try synchronizeDirectory(directory)
        guard try Data(contentsOf: file) == data else {
            throw RelationActionOperationRecordError.readbackFailed
        }
    }

    func loadBrokenLinkDeletion(
        operationID: UUID,
        rootURL: URL
    ) throws -> BrokenLinkDeletionOperationRecord {
        let directory = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: rootURL.standardizedFileURL)
            .operationRecoveryDirectory.appendingPathComponent(operationID.uuidString, isDirectory: true)
        let record = try decoder.decode(
            BrokenLinkDeletionOperationRecord.self,
            from: Data(contentsOf: directory.appendingPathComponent(Self.recordFileName))
        )
        try validate(record, operationID: operationID, rootURL: rootURL)
        _ = try verifiedOperationDirectory(for: record, rootURL: rootURL)
        return record
    }

    private func validate(
        _ record: RelationActionOperationRecord,
        operationID: UUID,
        rootURL: URL
    ) throws {
        let normalizedRoot = rootURL.standardizedFileURL
        guard record.schemaVersion == RelationActionOperationRecord.schemaVersion,
              record.operationID == operationID,
              record.rootPath == normalizedRoot.path,
              record.facts.rootPath == normalizedRoot.path,
              record.relation == record.facts.relation,
              record.linkPath == record.facts.linkPath,
              record.canonicalTargetPath == record.facts.canonicalPath,
              record.originalMetadataDigest == record.facts.metadataDigest,
              record.originalMetadataFileIdentity == record.facts.metadataFileIdentity,
              record.metadataParentIdentity == record.facts.metadataParentIdentity,
              record.factsDigest == RelationActionTokenBuilder().digest(of: record.facts) else {
            throw RelationActionOperationRecordError.invalidRecord
        }
        if let creation = record.creation {
            let parent = URL(fileURLWithPath: record.linkPath).deletingLastPathComponent()
            guard creation.operationID == record.operationID,
                  creation.linkText == record.canonicalTargetPath,
                  creation.parentIdentity == record.targetNodeIdentity,
                  creation.nodeIdentity.kind == S_IFLNK,
                  creation.stagingDirectoryIdentity.kind == S_IFDIR,
                  creation.stagingPath == parent.appendingPathComponent(
                    ".skillshub-create-\(record.operationID.uuidString)/link"
                  ).path,
                  record.preparationPaths.contains(creation.stagingPath) else {
                throw RelationActionOperationRecordError.invalidRecord
            }
        }
        if let removal = record.removal {
            let directory = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: normalizedRoot)
                .operationRecoveryDirectory.appendingPathComponent(operationID.uuidString, isDirectory: true)
            guard !record.desiredEnabled,
                  removal.isolationPath == directory.appendingPathComponent("isolation/link").path,
                  record.isolationPaths == [removal.isolationPath],
                  removal.creation.parentIdentity == record.targetNodeIdentity,
                  removal.creation.nodeIdentity.kind == S_IFLNK,
                  removal.creation.linkText == record.canonicalTargetPath,
                  removal.operationDirectoryIdentity.file == record.operationDirectoryIdentity,
                  removal.isolationDirectoryIdentity.kind == S_IFDIR else {
                throw RelationActionOperationRecordError.invalidRecord
            }
        }
        if let materials = record.creationMaterials {
            guard record.desiredEnabled, record.creation != nil, record.completedAt != nil else {
                throw RelationActionOperationRecordError.invalidRecord
            }
            if let path = materials.isolationPath {
                let directory = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: normalizedRoot)
                    .operationRecoveryDirectory.appendingPathComponent(operationID.uuidString, isDirectory: true)
                guard path == directory.appendingPathComponent("creation-settlement/directory").path,
                      materials.operationDirectoryIdentity?.file == record.operationDirectoryIdentity,
                      materials.isolationDirectoryIdentity?.kind == S_IFDIR,
                      materials.operationDirectoryIdentity?.kind == S_IFDIR,
                      materials.isolationDirectoryIdentity?.file.volumeNumber == record.creation?.parentIdentity.file.volumeNumber,
                      materials.status != .settled || materials.observedIdentity == record.creation?.stagingDirectoryIdentity else {
                    throw RelationActionOperationRecordError.invalidRecord
                }
            } else if materials.status != .retained || materials.operationDirectoryIdentity != nil
                || materials.isolationDirectoryIdentity != nil || materials.observedIdentity != nil {
                throw RelationActionOperationRecordError.invalidRecord
            }
        }
    }

    private func validate(
        _ record: BrokenLinkDeletionOperationRecord,
        operationID: UUID,
        rootURL: URL
    ) throws {
        let normalizedRoot = rootURL.standardizedFileURL
        guard record.schemaVersion == BrokenLinkDeletionOperationRecord.schemaVersion,
              record.operationKind == .confirmedBrokenLink,
              record.operationID == operationID,
              record.facts.rootPath == normalizedRoot.path,
              record.factsDigest == BrokenLinkDeletionTokenBuilder().digest(of: record.facts) else {
            throw RelationActionOperationRecordError.invalidRecord
        }
        if let removal = record.removal {
            let directory = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: normalizedRoot)
                .operationRecoveryDirectory.appendingPathComponent(operationID.uuidString, isDirectory: true)
            guard removal.isolationPath == directory.appendingPathComponent("isolation/link").path,
                  removal.creation.operationID == operationID,
                  removal.creation.parentIdentity == record.facts.parentIdentity,
                  removal.creation.nodeIdentity == record.facts.nodeIdentity,
                  removal.creation.linkText == record.facts.rawTarget,
                  removal.operationDirectoryIdentity.file == record.operationDirectoryIdentity,
                  removal.isolationDirectoryIdentity.kind == S_IFDIR else {
                throw RelationActionOperationRecordError.invalidRecord
            }
        }
    }

    private func verifiedOperationDirectory(for record: RelationActionOperationRecord, rootURL: URL) throws -> URL {
        let normalizedRoot = rootURL.standardizedFileURL
        guard record.rootPath == normalizedRoot.path else {
            throw RelationActionOperationRecordError.invalidRoot
        }
        let operations = SkillsHubMetadataStore(fileManager: fileManager)
            .rootLayout(for: normalizedRoot).operationRecoveryDirectory
        _ = try requiredIdentity(of: operations, kind: S_IFDIR)
        let directory = operations.appendingPathComponent(record.operationID.uuidString, isDirectory: true)
        guard try requiredIdentity(of: directory, kind: S_IFDIR) == record.operationDirectoryIdentity else {
            throw RelationActionOperationRecordError.invalidRecord
        }
        return directory
    }

    private func verifiedOperationDirectory(
        for record: BrokenLinkDeletionOperationRecord,
        rootURL: URL
    ) throws -> URL {
        let operations = SkillsHubMetadataStore(fileManager: fileManager)
            .rootLayout(for: rootURL.standardizedFileURL).operationRecoveryDirectory
        _ = try requiredIdentity(of: operations, kind: S_IFDIR)
        let directory = operations.appendingPathComponent(record.operationID.uuidString, isDirectory: true)
        guard try requiredIdentity(of: directory, kind: S_IFDIR) == record.operationDirectoryIdentity else {
            throw RelationActionOperationRecordError.invalidRecord
        }
        return directory
    }

    private func ensureDirectory(_ directory: URL) throws {
        if fileManager.fileExists(atPath: directory.path) {
            _ = try requiredIdentity(of: directory, kind: S_IFDIR)
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            _ = try requiredIdentity(of: directory, kind: S_IFDIR)
            try synchronizeDirectory(directory.deletingLastPathComponent())
        }
    }

    private func writeNew(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: [.withoutOverwriting])
        try synchronizeFile(file)
        guard try Data(contentsOf: file) == data else {
            throw RelationActionOperationRecordError.readbackFailed
        }
    }

    private func identity(of url: URL, kind: mode_t) throws -> TargetFileIdentity? {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &status) } ?? -1
        }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw RelationActionOperationRecordError.recordUnavailable
        }
        guard status.st_mode & S_IFMT == kind else {
            throw RelationActionOperationRecordError.invalidRecord
        }
        return TargetFileIdentity(volumeNumber: UInt64(status.st_dev), fileNumber: UInt64(status.st_ino))
    }

    private func requiredIdentity(of url: URL, kind: mode_t) throws -> TargetFileIdentity {
        guard let identity = try identity(of: url, kind: kind) else {
            throw RelationActionOperationRecordError.recordUnavailable
        }
        return identity
    }

    private func synchronizeFile(_ file: URL) throws {
        let descriptor = file.withUnsafeFileSystemRepresentation {
            $0.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else {
            throw RelationActionOperationRecordError.synchronizationFailed(path: file.path, errno: errno)
        }
        defer { Darwin.close(descriptor) }
        if Darwin.fcntl(descriptor, F_FULLFSYNC) != 0, Darwin.fsync(descriptor) != 0 {
            throw RelationActionOperationRecordError.synchronizationFailed(path: file.path, errno: errno)
        }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.withUnsafeFileSystemRepresentation {
            $0.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else {
            throw RelationActionOperationRecordError.synchronizationFailed(path: directory.path, errno: errno)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw RelationActionOperationRecordError.synchronizationFailed(path: directory.path, errno: errno)
        }
    }
}

nonisolated enum RelationActionExecutionFaultPoint: Equatable, Sendable {
    case beforeOperationRecord
    case afterOperationRecord
    case beforeIsolationRecord
    case afterIsolationRecord
    case beforeFilePrimitive
    case afterFilePrimitive
    case beforeLocalStateCommit
    case afterLocalStateCommit
    case beforeMetadataCAS
    case afterMetadataCAS
    case beforeFinalObservation
    case beforeCompensation
    case beforeMaterialResultRecord
    case beforeMaterialSettlement
}

nonisolated struct BrokenLinkDeletionInspector: @unchecked Sendable {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func facts(
        rootURL: URL,
        rootSessionOwner: SecurityScopedAccessOwner,
        agentID: String,
        agentDisplayName: String,
        qualification: AgentTargetQualification,
        linkURL: URL
    ) throws -> BrokenLinkDeletionFacts {
        guard case .rootSession = rootSessionOwner else {
            throw BrokenLinkDeletionError.invalidRootSession
        }
        guard qualification.agentID == agentID,
              qualification.scope == .global,
              qualification.authorizationStatus == .current,
              qualification.allowsManagedWrite,
              let authorizedDirectory = qualification.target?.standardizedFileURL else {
            throw BrokenLinkDeletionError.invalidAgentTarget
        }
        let link = linkURL.standardizedFileURL
        guard link.lastPathComponent.isEmpty == false else {
            throw BrokenLinkDeletionError.invalidLinkPath
        }
        let parentIdentity = try LinkNodeIdentity.read(at: link.deletingLastPathComponent())
        guard parentIdentity == (try LinkNodeIdentity.read(at: authorizedDirectory)) else {
            throw BrokenLinkDeletionError.invalidLinkPath
        }
        let nodeIdentity = try LinkNodeIdentity.read(at: link)
        guard parentIdentity.kind == S_IFDIR, nodeIdentity.kind == S_IFLNK else {
            throw BrokenLinkDeletionError.notSymbolicLink
        }
        let rawTarget = try fileManager.destinationOfSymbolicLink(atPath: link.path)
        let resolvedTarget = try resolvedTarget(
            rawTarget: rawTarget,
            relativeTo: link.deletingLastPathComponent()
        )
        try verifyMissingTarget(at: resolvedTarget)
        guard try LinkNodeIdentity.read(at: authorizedDirectory) == parentIdentity,
              try LinkNodeIdentity.read(at: link) == nodeIdentity,
              try fileManager.destinationOfSymbolicLink(atPath: link.path) == rawTarget else {
            throw BrokenLinkDeletionError.confirmedFactsChanged
        }
        return BrokenLinkDeletionFacts(
            rootPath: rootURL.standardizedFileURL.path,
            rootSessionOwnerIdentity: rootSessionOwner.identity,
            rootIdentity: try LinkNodeIdentity.read(at: rootURL.standardizedFileURL),
            agentID: agentID,
            agentDisplayName: agentDisplayName,
            authorizedDirectoryPath: authorizedDirectory.path,
            parentIdentity: parentIdentity,
            linkPath: link.path,
            nodeIdentity: nodeIdentity,
            rawTarget: rawTarget,
            resolvedTargetPath: resolvedTarget.path
        )
    }

    func verifyMissingTarget(at url: URL) throws {
        var status = stat()
        guard Darwin.fstatat(AT_FDCWD, url.path, &status, 0) != 0 else {
            throw BrokenLinkDeletionError.targetExists
        }
        let failure = errno
        guard failure == ENOENT || failure == ENOTDIR else {
            throw BrokenLinkDeletionError.targetStatusUnknown(failure)
        }
    }

    func resolvedTarget(rawTarget: String, relativeTo parent: URL) throws -> URL {
        let firstTarget = rawTarget.hasPrefix("/")
            ? URL(fileURLWithPath: rawTarget)
            : parent.appendingPathComponent(rawTarget)
        return try FileAccessService(fileManager: fileManager).resolvedSymlinkTarget(firstTarget)
    }

}

nonisolated final class RelationActionExecutor: @unchecked Sendable {
    private let metadataStore: SkillsHubMetadataStore
    private let localStateStore: SkillsHubLocalStateStore
    private let linkService: AgentLinkService
    private let inspector: RelationOwnershipInspector
    private let fileManager: FileManager
    private let operationRecordStore: RelationActionOperationRecordStore
    private let now: @Sendable () -> Date
    private let faultHook: (@Sendable (RelationActionExecutionFaultPoint) throws -> Void)?

    init(
        metadataStore: SkillsHubMetadataStore,
        localStateStore: SkillsHubLocalStateStore = SkillsHubLocalStateStore(),
        linkService: AgentLinkService = AgentLinkService(),
        inspector: RelationOwnershipInspector = RelationOwnershipInspector(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        faultHook: (@Sendable (RelationActionExecutionFaultPoint) throws -> Void)? = nil
    ) {
        self.metadataStore = metadataStore
        self.localStateStore = localStateStore
        self.linkService = linkService
        self.inspector = inspector
        self.fileManager = fileManager
        self.operationRecordStore = RelationActionOperationRecordStore(fileManager: fileManager)
        self.now = now
        self.faultHook = faultHook
    }

    // Shared by normal execution and isolated platform qualification; never replayed by recover.
    func removeManagedNode(
        authorization: RelationActionAuthorization,
        record: inout RelationActionOperationRecord,
        rootURL: URL,
        onEvent: (RelationActionFileEvent) -> Void
    ) throws {
        let snapshot = try metadataStore.loadCurrentSnapshot(from: rootURL)
        guard !authorization.desiredEnabled, record.operationID == authorization.actionID,
              record.removal == nil, snapshotMatchesAuthorization(snapshot, authorization: authorization),
              let evidence = snapshot.metadata.managedRelationEvidence.first(where: { $0.relation == authorization.relation }),
              evidenceMatchesAuthorization(evidence, authorization: authorization),
              let creation = evidence.creation else {
            throw RelationLinkPrimitiveError.identityChanged
        }
        let inspection = try inspector.inspect(linkURL: URL(fileURLWithPath: authorization.facts.linkPath),
            relation: authorization.relation, canonicalTargetPath: authorization.facts.canonicalPath, evidence: evidence)
        guard inspectionMatchesAuthorization(inspection, evidence: evidence, authorization: authorization) else {
            throw RelationLinkPrimitiveError.identityChanged
        }
        let directory = metadataStore.rootLayout(for: rootURL).operationRecoveryDirectory
            .appendingPathComponent(authorization.actionID.uuidString, isDirectory: true)
        try linkService.removeManagedLink(at: URL(fileURLWithPath: authorization.facts.linkPath),
            creation: creation, operationDirectory: directory,
            expectedOperationIdentity: record.operationDirectoryIdentity,
            recordIsolation: { removal in
                try faultHook?(.beforeIsolationRecord)
                record.removal = removal
                record.isolationPaths = [removal.isolationPath]
                record.retainedPaths = [record.linkPath, removal.isolationPath]
                try operationRecordStore.save(record, rootURL: rootURL)
                try faultHook?(.afterIsolationRecord)
            }, verifyRecord: {
                guard try operationRecordStore.load(operationID: authorization.actionID, rootURL: rootURL) == record,
                      try LinkNodeIdentity.read(at: rootURL).file == record.metadataParentIdentity,
                      try snapshotMatchesAuthorization(metadataStore.loadCurrentSnapshot(from: rootURL), authorization: authorization) else {
                    throw RelationActionOperationRecordError.readbackFailed
                }
            }, onEvent: onEvent)
    }

    func executeBrokenLinkDeletion(
        authorization: BrokenLinkDeletionAuthorization,
        rootURL: URL
    ) -> BrokenLinkDeletionExecutionResult {
        var events: [RelationActionFileEvent] = []
        var record: BrokenLinkDeletionOperationRecord?
        do {
            guard authorization.kind == .confirmedBrokenLink else {
                throw BrokenLinkDeletionError.confirmedFactsChanged
            }
            try verifyBrokenLinkDeletionFacts(authorization.facts, rootURL: rootURL, requireLink: true)
            record = try operationRecordStore.prepare(authorization: authorization, rootURL: rootURL)
            let operationDirectory = metadataStore.rootLayout(for: rootURL).operationRecoveryDirectory
                .appendingPathComponent(authorization.actionID.uuidString, isDirectory: true)
            let creation = LinkCreationEvidence(
                operationID: authorization.actionID,
                stagingPath: authorization.facts.linkPath,
                parentIdentity: authorization.facts.parentIdentity,
                stagingDirectoryIdentity: authorization.facts.parentIdentity,
                nodeIdentity: authorization.facts.nodeIdentity,
                linkText: authorization.facts.rawTarget
            )
            try linkService.removeManagedLink(
                at: URL(fileURLWithPath: authorization.facts.linkPath),
                creation: creation,
                operationDirectory: operationDirectory,
                expectedOperationIdentity: record!.operationDirectoryIdentity,
                recordIsolation: { removal in
                    record!.removal = removal
                    try operationRecordStore.save(record!, rootURL: rootURL)
                },
                verifyRecord: {
                    guard try operationRecordStore.loadBrokenLinkDeletion(
                        operationID: authorization.actionID,
                        rootURL: rootURL
                    ) == record else {
                        throw RelationActionOperationRecordError.readbackFailed
                    }
                    try self.verifyBrokenLinkDeletionFacts(
                        authorization.facts,
                        rootURL: rootURL,
                        requireLink: false
                    )
                },
                onEvent: { events.append($0) }
            )
            record!.completedAt = now()
            try operationRecordStore.save(record!, rootURL: rootURL)
            return BrokenLinkDeletionExecutionResult(
                status: .succeeded,
                fileEvents: events,
                retainedPath: nil,
                safeNextStep: "recheck-agent-directory"
            )
        } catch {
            let retainedPath = retainedBrokenLinkPath(record: record, facts: authorization.facts)
            let blocked = error is BrokenLinkDeletionError || error is RelationLinkPrimitiveError
            return BrokenLinkDeletionExecutionResult(
                status: blocked ? .blocked : .unknown,
                fileEvents: events + (retainedPath.map { [.retainedForRecovery($0)] } ?? []),
                retainedPath: retainedPath,
                safeNextStep: retainedPath == nil ? "recheck-agent-directory" : "review-retained-link-node",
                failureMessage: SkillsHubLocalization.errorPresentation(for: error)
            )
        }
    }

    func execute(
        authorization: RelationActionAuthorization,
        rootURL: URL,
        currentInstallation: @Sendable () -> AgentInstallationEvidence?
    ) -> RelationActionExecutionResult {
        let relation = authorization.relation
        var fileEvents: [RelationActionFileEvent] = []
        var createdNode: ManagedLinkNode?
        var createdLocation: String?
        var localBackup: RelationLocalStateBackup?
        var localStateWriteAttempted = false
        var metadataDelta: RelationActionMetadataDelta = .none
        var metadataWasCommitted = false
        var operationRecord: RelationActionOperationRecord?

        do {
            let snapshot = try metadataStore.loadCurrentSnapshot(from: rootURL)
            let originalLocal = try localStateStore.load(from: rootURL)
            localBackup = try backupLocalState(at: rootURL)
            guard snapshotMatchesAuthorization(snapshot, authorization: authorization),
                  snapshot.metadata.installedSkills.contains(where: {
                      $0.assetID == relation.assetID
                  }) else {
                return blocked(
                    relation: relation,
                    reason: .currentFactsChanged,
                    events: fileEvents
                )
            }

            let linkURL = URL(fileURLWithPath: authorization.facts.linkPath)
            let currentEvidence = snapshot.metadata.managedRelationEvidence.first {
                $0.relation == relation
            }
            let inspection = try inspector.inspect(
                linkURL: linkURL,
                relation: relation,
                canonicalTargetPath: authorization.facts.canonicalPath,
                evidence: currentEvidence
            )
            guard inspectionMatchesAuthorization(
                inspection,
                evidence: currentEvidence,
                authorization: authorization
            ) else {
                return blocked(
                    relation: relation,
                    reason: .currentFactsChanged,
                    events: fileEvents,
                    observation: inspection.observation
                )
            }
            guard ownershipAllowsAction(
                inspection.classification,
                desiredEnabled: authorization.desiredEnabled
            ) else {
                return blocked(
                    relation: relation,
                    reason: .nodeConflict,
                    events: fileEvents,
                    observation: inspection.observation
                )
            }
            if inspection.classification == .exactManagedLink,
               evidenceMatchesAuthorization(currentEvidence, authorization: authorization) == false {
                return blocked(
                    relation: relation,
                    reason: .ownershipEvidenceInvalid,
                    events: fileEvents,
                    observation: inspection.observation
                )
            }

            try faultHook?(.beforeOperationRecord)
            operationRecord = try operationRecordStore.prepare(
                authorization: authorization,
                snapshot: snapshot,
                rootURL: rootURL
            )
            try faultHook?(.afterOperationRecord)
            try faultHook?(.beforeFilePrimitive)
            if authorization.desiredEnabled, inspection.classification == .vacant {
                guard let parentIdentity = operationRecord?.targetNodeIdentity else {
                    throw RelationLinkPrimitiveError.identityChanged
                }
                let node = try linkService.createManagedLink(
                    at: linkURL,
                    linkText: authorization.facts.canonicalPath,
                    operationID: authorization.actionID,
                    expectedParentIdentity: parentIdentity,
                    recordPreparation: { url in
                        guard var record = operationRecord else {
                            throw RelationActionOperationRecordError.recordUnavailable
                        }
                        record.preparationPaths.append(url.path)
                        record.retainedPaths.append(url.deletingLastPathComponent().path)
                        try operationRecordStore.save(record, rootURL: rootURL)
                        operationRecord = record
                    },
                    recordCreation: { creation in
                        guard var record = operationRecord else {
                            throw RelationActionOperationRecordError.recordUnavailable
                        }
                        guard try operationRecordStore.load(operationID: authorization.actionID, rootURL: rootURL) == record else {
                            throw RelationActionOperationRecordError.readbackFailed
                        }
                        if record.creation == creation { return }
                        record.creation = creation
                        try operationRecordStore.save(record, rootURL: rootURL)
                        operationRecord = record
                    },
                    onCreated: { createdLocation = $0.path }
                )
                createdNode = node
                fileEvents.append(.created(node.linkURL.path))
            } else if authorization.desiredEnabled == false,
                      inspection.classification == .exactManagedLink {
                guard var record = operationRecord else { throw RelationActionOperationRecordError.recordUnavailable }
                defer { operationRecord = record }
                try removeManagedNode(authorization: authorization, record: &record, rootURL: rootURL,
                    onEvent: { fileEvents.append($0) })
            }
            try faultHook?(.afterFilePrimitive)
            try appendOperationObservation(
                to: &operationRecord,
                checkpoint: .afterFilePrimitive,
                rootURL: rootURL,
                fileEvents: fileEvents,
                completed: false
            )

            let stagedObservation = try inspector.inspect(
                linkURL: linkURL,
                relation: relation,
                canonicalTargetPath: authorization.facts.canonicalPath,
                evidence: nil
            ).observation
            if !authorization.desiredEnabled, stagedObservation.nodeKind != .vacant {
                throw RelationLinkPrimitiveError.identityChanged
            }
            let existingIntent = currentIntent(in: snapshot, relation: relation)
            let stableLinkName = URL(fileURLWithPath: authorization.facts.linkPath).lastPathComponent
            let needsStableLinkName = authorization.desiredEnabled
                && snapshot.metadata.installedSkills.first(where: { $0.assetID == relation.assetID })?.stableLinkName == nil
            let metadataNeedsCommit = existingIntent?.isEnabled != authorization.desiredEnabled
                || existingIntent == nil
                || createdNode != nil
                || (authorization.desiredEnabled == false && currentEvidence != nil)
                || needsStableLinkName
            let targetGeneration = metadataNeedsCommit ? snapshot.generation + 1 : snapshot.generation
            let targetIntent = EnablementIntent(
                assetID: relation.assetID,
                agentID: relation.agentID,
                scope: relation.scope,
                isEnabled: authorization.desiredEnabled,
                generation: metadataNeedsCommit ? targetGeneration : (existingIntent?.generation ?? targetGeneration)
            )
            let stagedEvidence = try evidenceForDesiredState(
                authorization: authorization,
                observation: stagedObservation,
                existingEvidence: currentEvidence,
                targetGeneration: targetIntent.generation,
                createdNode: createdNode
            )
            let stagedVerification = RelationVerifier.verify(
                actionFacts: revalidatedFacts(authorization.facts, currentInstallation: currentInstallation),
                rootGeneration: targetGeneration,
                intent: targetIntent,
                observation: stagedObservation,
                evidence: stagedEvidence,
                limitations: []
            )
            let stagedLocal = originalLocal.replacingRelationState(
                relation,
                observation: stagedObservation,
                evidence: stagedEvidence,
                verification: stagedVerification
            )

            try faultHook?(.beforeLocalStateCommit)
            localStateWriteAttempted = true
            try localStateStore.save(stagedLocal, to: rootURL)
            try faultHook?(.afterLocalStateCommit)

            var committedSnapshot = snapshot
            if metadataNeedsCommit {
                try faultHook?(.beforeMetadataCAS)
                if let stagedEvidence {
                    let current = try inspector.inspect(
                        linkURL: linkURL, relation: relation,
                        canonicalTargetPath: authorization.facts.canonicalPath, evidence: stagedEvidence
                    )
                    guard current.classification == .exactManagedLink else {
                        throw RelationLinkPrimitiveError.createdNodeChanged
                    }
                }
                committedSnapshot = try metadataStore.commit(
                    at: rootURL,
                    expected: snapshot
                ) { metadata in
                    if needsStableLinkName,
                       let index = metadata.installedSkills.firstIndex(where: { $0.assetID == relation.assetID }) {
                        metadata.installedSkills[index].stableLinkName = stableLinkName
                    }
                    metadata.enablementIntents.removeAll { intent in
                        relationForIntent(intent) == relation
                    }
                    metadata.enablementIntents.append(targetIntent)
                    metadata.enablementIntents.sort { $0.id < $1.id }
                    metadata.managedRelationEvidence.removeAll { $0.relation == relation }
                    if let stagedEvidence {
                        metadata.managedRelationEvidence.append(stagedEvidence)
                        metadata.managedRelationEvidence.sort { $0.id < $1.id }
                    }
                }
                metadataWasCommitted = true
                metadataDelta = .committed
                try faultHook?(.afterMetadataCAS)
                try appendOperationObservation(
                    to: &operationRecord,
                    checkpoint: .afterMetadataCommit,
                    rootURL: rootURL,
                    fileEvents: fileEvents,
                    completed: false
                )
            }

            try faultHook?(.beforeFinalObservation)

            let final = try observeAndPersist(
                authorization: authorization,
                rootURL: rootURL,
                snapshot: committedSnapshot,
                fallbackIntent: targetIntent,
                existingEvidence: stagedEvidence,
                currentInstallation: currentInstallation
            )
            try appendOperationObservation(
                to: &operationRecord,
                checkpoint: .finalObservation,
                rootURL: rootURL,
                fileEvents: fileEvents,
                completed: final.verification.conclusion == .verifiedConsistent
            )
            let changed = fileEvents.isEmpty == false || metadataNeedsCommit
            var result = RelationActionExecutionResult(
                relation: relation,
                status: final.verification.conclusion == .verifiedConsistent
                    ? (changed ? .succeeded : .noChange) : .unknown,
                blockReason: nil,
                fileEvents: fileEvents,
                metadataDelta: metadataDelta,
                observation: final.observation,
                verification: final.verification,
                limitations: final.limitations,
                safeNextStep: final.verification.conclusion == .verifiedConsistent
                    ? "none"
                    : "observe-current-relation"
            )
            if createdNode != nil, final.verification.conclusion == .verifiedConsistent,
               let record = operationRecord {
                result.creationMaterials = settleCreationMaterials(operationID: record.operationID, rootURL: rootURL)
                let current = recoverCurrentFacts(authorization: authorization, rootURL: rootURL,
                    currentInstallation: currentInstallation)
                if current.verification?.conclusion != .verifiedConsistent {
                    return RelationActionExecutionResult(relation: relation, status: .unknown, blockReason: nil,
                        fileEvents: fileEvents, metadataDelta: metadataDelta,
                        observation: current.observation, verification: current.verification,
                        limitations: current.limitations, safeNextStep: current.safeNextStep,
                        creationMaterials: result.creationMaterials)
                }
            }
            return result
        } catch {
            if case RelationLinkPrimitiveError.isolationFailed(let code) = error,
               [EXDEV, ENOTSUP, EINVAL, EACCES, EPERM, EROFS].contains(code), fileEvents.isEmpty {
                let recovered = recover(authorization: authorization, rootURL: rootURL, currentInstallation: currentInstallation)
                return blocked(relation: relation, reason: .identityBoundRemovalUnavailable,
                    events: fileEvents, observation: recovered.observation)
            }
            if let primitiveError = error as? RelationLinkPrimitiveError,
               [.identityChanged, .createdNodeChanged].contains(primitiveError),
               createdNode == nil,
               createdLocation == nil,
               fileEvents.isEmpty {
                let recovered = recover(authorization: authorization, rootURL: rootURL, currentInstallation: currentInstallation)
                return blocked(
                    relation: relation,
                    reason: .currentFactsChanged,
                    events: fileEvents,
                    observation: recovered.observation
                )
            }
            if metadataWasCommitted == false,
               metadataCommitIsVisible(
                   authorization: authorization,
                   rootURL: rootURL,
                   expectedGeneration: authorization.facts.metadataGeneration + 1
               ) {
                metadataWasCommitted = true
                metadataDelta = .committed
            }

            if metadataWasCommitted {
                try? appendOperationObservation(
                    to: &operationRecord,
                    checkpoint: .recoveryObservation,
                    rootURL: rootURL,
                    fileEvents: fileEvents,
                    completed: false
                )
                let recovered = recover(authorization: authorization, rootURL: rootURL, currentInstallation: currentInstallation)
                return RelationActionExecutionResult(
                    relation: relation,
                    status: .unknown,
                    blockReason: nil,
                    fileEvents: fileEvents,
                    metadataDelta: metadataDelta,
                    observation: recovered.observation,
                    verification: recovered.verification,
                    limitations: recovered.limitations + [String(describing: error)],
                    safeNextStep: "observe-current-relation"
                )
            }

            let localRestored: Bool
            if let localBackup, localStateWriteAttempted {
                localRestored = restoreLocalState(localBackup)
                if localRestored { metadataDelta = .restored }
            } else {
                localRestored = true
            }
            let compensationSucceeded = compensate(
                authorization: authorization,
                createdNode: createdNode,
                createdLocation: createdLocation,
                fileEvents: &fileEvents
            )
            try? appendOperationObservation(
                to: &operationRecord,
                checkpoint: .recoveryObservation,
                rootURL: rootURL,
                fileEvents: fileEvents,
                completed: false
            )
            if localRestored, compensationSucceeded {
                let recovered = recover(authorization: authorization, rootURL: rootURL, currentInstallation: currentInstallation)
                return RelationActionExecutionResult(
                    relation: relation,
                    status: .failed,
                    blockReason: nil,
                    fileEvents: fileEvents,
                    metadataDelta: metadataDelta,
                    observation: recovered.observation,
                    verification: recovered.verification,
                    limitations: recovered.limitations + [String(describing: error)],
                    safeNextStep: "reauthorize-current-relation"
                )
            }

            let recovered = recover(authorization: authorization, rootURL: rootURL, currentInstallation: currentInstallation)
            return RelationActionExecutionResult(
                relation: relation,
                status: .unknown,
                blockReason: nil,
                fileEvents: fileEvents,
                metadataDelta: localRestored ? metadataDelta : .unknown,
                observation: recovered.observation,
                verification: recovered.verification,
                limitations: recovered.limitations + [String(describing: error)],
                safeNextStep: "observe-current-relation"
            )
        }
    }

    func recover(
        authorization: RelationActionAuthorization,
        rootURL: URL,
        currentInstallation: @Sendable () -> AgentInstallationEvidence?
    ) -> RelationActionRecoveryResult {
        if let record = try? operationRecordStore.load(operationID: authorization.actionID, rootURL: rootURL) {
            return recover(record: record, rootURL: rootURL, currentInstallation: currentInstallation)
        }
        return recoverCurrentFacts(
            authorization: authorization,
            rootURL: rootURL,
            currentInstallation: currentInstallation
        )
    }

    func recover(
        operationID: UUID,
        rootURL: URL,
        currentInstallation: @Sendable () -> AgentInstallationEvidence?,
        recordObservation: Bool = true
    ) -> RelationActionRecoveryResult {
        do {
            let record = try operationRecordStore.load(operationID: operationID, rootURL: rootURL)
            return recover(
                record: record,
                rootURL: rootURL,
                currentInstallation: currentInstallation,
                recordObservation: recordObservation
            )
        } catch {
            return RelationActionRecoveryResult(
                relation: nil,
                observation: nil,
                verification: nil,
                components: [
                    RelationActionRecoveryComponent(
                        kind: .operationMaterials,
                        state: .unknown,
                        path: SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: rootURL)
                            .operationRecoveryDirectory.appendingPathComponent(operationID.uuidString).path,
                        detail: "operation-record-unavailable"
                    )
                ],
                limitations: [String(describing: error)],
                safeNextStep: "restore-current-access-and-observe"
            )
        }
    }

    /// Explicit calls reuse the same primitive as new creation; recovery never calls this method.
    func settleCreationMaterials(operationID: UUID, rootURL: URL) -> CreationMaterialSettlement {
        var record: RelationActionOperationRecord?
        do {
            record = try operationRecordStore.load(operationID: operationID, rootURL: rootURL)
            guard let current = record, let creation = current.creation else {
                throw RelationActionOperationRecordError.invalidRecord
            }
            let review = try reviewCreationMaterials(record: current, rootURL: rootURL)
            guard review.canSettle else { throw RelationLinkPrimitiveError.identityChanged }
            let directory = metadataStore.rootLayout(for: rootURL).operationRecoveryDirectory
                .appendingPathComponent(operationID.uuidString, isDirectory: true)
            try faultHook?(.beforeMaterialSettlement)
            try linkService.settleCreationDirectory(creation: creation,
                operationDirectory: directory, expectedOperationIdentity: current.operationDirectoryIdentity,
                previous: current.creationMaterials,
                recordSettlement: { materials in
                    guard var updated = record else { throw RelationActionOperationRecordError.recordUnavailable }
                    updated.creationMaterials = materials
                    if materials.status == .settled { try faultHook?(.beforeMaterialResultRecord) }
                    let originalPath = URL(fileURLWithPath: creation.stagingPath).deletingLastPathComponent().path
                    if materials.status != .settled, materials.observedIdentity != nil, let path = materials.isolationPath {
                        updated.retainedPaths.removeAll { $0 == originalPath }
                        if !updated.retainedPaths.contains(path) { updated.retainedPaths.append(path) }
                    }
                    if materials.status == .settled {
                        updated.retainedPaths.removeAll { $0 == review.path || $0 == originalPath || $0 == materials.isolationPath }
                    }
                    try operationRecordStore.save(updated, rootURL: rootURL)
                    record = updated
                }, verifyRecord: {
                    guard let current = record,
                          try operationRecordStore.load(operationID: operationID, rootURL: rootURL) == current,
                          try reviewCreationMaterials(record: current, rootURL: rootURL, checkMaterial: false).canSettle else {
                        throw RelationActionOperationRecordError.readbackFailed
                    }
                })
            return record?.creationMaterials ?? CreationMaterialSettlement(status: .retained)
        } catch {
            var result = record?.creationMaterials ?? CreationMaterialSettlement(status: .retained)
            result.status = .retained
            result.limitation = String(describing: error)
            if var current = record {
                current.creationMaterials = result
                // Best effort only. Missing writeback is explained from durable pending facts on restart.
                try? operationRecordStore.save(current, rootURL: rootURL)
            }
            return result
        }
    }

    private func reviewCreationMaterials(
        record: RelationActionOperationRecord, rootURL: URL, checkMaterial: Bool = true
    ) throws -> CreationMaterialReview {
        guard let creation = record.creation else { throw RelationActionOperationRecordError.invalidRecord }
        let staging = URL(fileURLWithPath: creation.stagingPath).deletingLastPathComponent()
        let snapshot = try metadataStore.loadCurrentSnapshot(from: rootURL)
        let evidence = snapshot.metadata.managedRelationEvidence.first { $0.relation == record.relation }
        let inspection = try inspector.inspect(linkURL: URL(fileURLWithPath: record.linkPath),
            relation: record.relation, canonicalTargetPath: record.canonicalTargetPath, evidence: evidence)
        let intent = currentIntent(in: snapshot, relation: record.relation)
        let relationResolved = (intent?.isEnabled == true && evidence?.creation == creation
            && inspection.classification == .exactManagedLink)
            || (intent?.isEnabled == false && evidence == nil && inspection.classification == .vacant)
        let ready = record.completedAt != nil && record.desiredEnabled && relationResolved
            && inspection.observation.parentIdentity == creation.parentIdentity
        let path = record.creationMaterials?.isolationPath ?? staging.path
        guard ready else { return CreationMaterialReview(path: path, canSettle: false, detail: "Creation responsibilities are not resolved.") }
        if !checkMaterial { return CreationMaterialReview(path: path, canSettle: true, detail: "Ready to settle empty creation directory") }
        func identity(_ url: URL) throws -> LinkNodeIdentity? {
            var status = stat()
            if Darwin.lstat(url.path, &status) == 0 { return LinkNodeIdentity(status) }
            if errno == ENOENT { return nil }
            throw RelationLinkPrimitiveError.parentUnavailable(errno)
        }
        var materialURL = staging
        let original = try identity(staging)
        if let materials = record.creationMaterials, let isolationPath = materials.isolationPath {
            let isolated = URL(fileURLWithPath: isolationPath)
            guard try identity(isolated.deletingLastPathComponent()) == materials.isolationDirectoryIdentity,
                  try identity(isolated.deletingLastPathComponent().deletingLastPathComponent()) == materials.operationDirectoryIdentity else {
                return CreationMaterialReview(path: isolationPath, canSettle: false, detail: "Creation directory identity changed.")
            }
            let isolatedIdentity = try identity(isolated)
            if isolatedIdentity != nil {
                guard original == nil else { return CreationMaterialReview(path: isolationPath, canSettle: false, detail: "Creation directory identity changed.") }
                materialURL = isolated
            }
        }
        guard let actual = try identity(materialURL) else {
            return CreationMaterialReview(path: materialURL.path, canSettle: false,
                detail: record.creationMaterials?.status == .settled ? "Creation directory settled" : "Creation directory absent; deletion history unverified.")
        }
        guard actual == creation.stagingDirectoryIdentity else {
            return CreationMaterialReview(path: materialURL.path, canSettle: false, detail: "Creation directory identity changed.")
        }
        guard try fileManager.contentsOfDirectory(atPath: materialURL.path).isEmpty else {
            return CreationMaterialReview(path: materialURL.path, canSettle: false, detail: "Creation directory contains unknown contents.")
        }
        let operation = metadataStore.rootLayout(for: rootURL).operationRecoveryDirectory.appendingPathComponent(record.operationID.uuidString)
        if record.creationMaterials?.isolationPath == nil,
           try identity(operation.appendingPathComponent("creation-settlement")) != nil {
            return CreationMaterialReview(path: materialURL.path, canSettle: false, detail: "Creation materials could not be verified.")
        }
        guard try LinkNodeIdentity.read(at: operation).file.volumeNumber == creation.parentIdentity.file.volumeNumber else {
            return CreationMaterialReview(path: materialURL.path, canSettle: false, detail: "Creation directory retained: no same-volume private isolation.")
        }
        return CreationMaterialReview(path: materialURL.path, canSettle: true, detail: "Ready to settle empty creation directory")
    }

    private func recoverCurrentFacts(
        authorization: RelationActionAuthorization,
        rootURL: URL,
        currentInstallation: @Sendable () -> AgentInstallationEvidence?
    ) -> RelationActionRecoveryResult {
        do {
            let snapshot = try metadataStore.loadCurrentSnapshot(from: rootURL)
            let relation = authorization.relation
            let evidence = snapshot.metadata.managedRelationEvidence.first { $0.relation == relation }
            let inspection = try inspector.inspect(
                linkURL: URL(fileURLWithPath: authorization.facts.linkPath),
                relation: relation,
                canonicalTargetPath: authorization.facts.canonicalPath,
                evidence: evidence
            )
            guard let intent = currentIntent(in: snapshot, relation: relation) else {
                return RelationActionRecoveryResult(
                    relation: relation,
                    observation: inspection.observation,
                    verification: nil,
                    limitations: ["enablement-intent-missing"],
                    safeNextStep: "reauthorize-current-relation"
                )
            }
            let record = RelationVerifier.verify(
                actionFacts: revalidatedFacts(authorization.facts, currentInstallation: currentInstallation),
                rootGeneration: snapshot.generation,
                intent: intent,
                observation: inspection.observation,
                evidence: evidence,
                limitations: []
            )
            return RelationActionRecoveryResult(
                relation: relation,
                observation: inspection.observation,
                verification: record,
                limitations: record.limitations,
                safeNextStep: record.safeNextStep
            )
        } catch {
            return RelationActionRecoveryResult(
                relation: authorization.relation,
                observation: nil,
                verification: nil,
                limitations: [String(describing: error)],
                safeNextStep: "restore-current-access-and-observe"
            )
        }
    }

    private func recover(
        record: RelationActionOperationRecord,
        rootURL: URL,
        currentInstallation: @Sendable () -> AgentInstallationEvidence?,
        recordObservation: Bool = true
    ) -> RelationActionRecoveryResult {
        let snapshotResult = Result { try metadataStore.loadCurrentSnapshot(from: rootURL) }
        let snapshot = try? snapshotResult.get()
        let evidence = snapshot?.metadata.managedRelationEvidence.first { $0.relation == record.relation }
        let inspectionResult = Result {
            try inspector.inspect(
                linkURL: URL(fileURLWithPath: record.linkPath),
                relation: record.relation,
                canonicalTargetPath: record.canonicalTargetPath,
                evidence: evidence
            )
        }
        let inspection = try? inspectionResult.get()
        let intent = snapshot?.metadata.enablementIntents.first { relationForIntent($0) == record.relation }
        let metadataOwnershipMatches = if record.desiredEnabled {
            evidence.map {
                URL(fileURLWithPath: $0.linkPath).standardizedFileURL.path == record.linkPath
                    && URL(fileURLWithPath: $0.canonicalTargetPath).standardizedFileURL.path == record.canonicalTargetPath
                    && $0.profileID == record.facts.profileID
                    && $0.profileVersion == record.facts.profileVersion
            } ?? false
        } else {
            evidence == nil
        }
        let verification: VerificationRecord? = if let snapshot, let inspection, let intent {
            RelationVerifier.verify(
                actionFacts: revalidatedFacts(record.facts, currentInstallation: currentInstallation),
                rootGeneration: snapshot.generation,
                intent: intent,
                observation: inspection.observation,
                evidence: evidence,
                limitations: []
            )
        } else {
            nil
        }
        let metadataState: RelationActionRecoveryState
        if snapshot != nil,
           intent?.isEnabled == record.desiredEnabled,
           metadataOwnershipMatches {
            metadataState = .completed
        } else if snapshot?.metadataDigest == record.originalMetadataDigest {
            metadataState = .notCompleted
        } else {
            metadataState = .unknown
        }
        let nodeState: RelationActionRecoveryState = switch (record.desiredEnabled, inspection?.classification) {
        case (true, .exactManagedLink), (false, .vacant): .completed
        case (true, .vacant), (false, .exactManagedLink): .notCompleted
        default: .unknown
        }
        let targetIdentity = try? directoryIdentity(
            of: URL(fileURLWithPath: record.facts.targetPath, isDirectory: true)
        )
        let currentTargetIdentity = try? LinkNodeIdentity.read(at: URL(fileURLWithPath: record.facts.targetPath))
        let directoryState: RelationActionRecoveryState = targetIdentity == record.targetDirectoryIdentity
            && currentTargetIdentity == record.targetNodeIdentity
            ? .completed
            : .unknown
        let operationDirectory = SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: rootURL)
            .operationRecoveryDirectory.appendingPathComponent(record.operationID.uuidString, isDirectory: true)
        var currentRecord: RelationActionOperationRecord? = record
        var materialState = RelationActionRecoveryState.completed
        var limitations = record.observations.compactMap(\.limitation)
        if case .failure(let error) = snapshotResult { limitations.append(String(describing: error)) }
        if case .failure(let error) = inspectionResult { limitations.append(String(describing: error)) }
        if recordObservation {
            do {
                try appendOperationObservation(
                    to: &currentRecord,
                    checkpoint: .recoveryObservation,
                    rootURL: rootURL,
                    fileEvents: record.retainedPaths.map(RelationActionFileEvent.retainedForRecovery),
                    completed: false
                )
            } catch {
                materialState = .unknown
                limitations.append(String(describing: error))
            }
        }
        let retainedPaths = currentRecord?.retainedPaths ?? record.retainedPaths
        var components = [
            RelationActionRecoveryComponent(
                kind: .metadata,
                state: metadataState,
                path: SkillsHubMetadataStore(fileManager: fileManager).rootLayout(for: rootURL).skillshubMetadataFile.path,
                detail: "observed-current-metadata"
            ),
            RelationActionRecoveryComponent(
                kind: .linkNode,
                state: nodeState,
                path: record.linkPath,
                detail: "observed-current-link-node"
            ),
            RelationActionRecoveryComponent(
                kind: .targetDirectory,
                state: directoryState,
                path: record.facts.targetPath,
                detail: "observed-current-target-directory"
            ),
            RelationActionRecoveryComponent(
                kind: .operationMaterials,
                state: materialState,
                path: operationDirectory.path,
                detail: retainedPaths.isEmpty
                    ? "recovery-record-and-original-metadata-readable"
                    : "retained-paths:\(retainedPaths.joined(separator: ","))"
            )
        ]
        var materialReview: CreationMaterialReview?
        if let creation = record.creation {
            let stagingURL = URL(fileURLWithPath: creation.stagingPath)
            let staged = try? inspector.inspect(linkURL: stagingURL, relation: record.relation,
                canonicalTargetPath: record.canonicalTargetPath, evidence: nil).observation
            let state: RelationActionRecoveryState
            materialReview = (try? reviewCreationMaterials(record: record, rootURL: rootURL))
                ?? CreationMaterialReview(path: stagingURL.deletingLastPathComponent().path,
                    canSettle: false, detail: "Creation materials could not be verified.")
            let materialAbsent = materialReview?.detail == "Creation directory settled"
                || materialReview?.detail == "Creation directory absent; deletion history unverified."
            if directoryState == .completed,
               inspection?.observation.nodeIdentity == creation.nodeIdentity,
               inspection?.observation.linkText == creation.linkText {
                state = .completed
            } else if directoryState != .completed || staged?.parentIdentity != creation.stagingDirectoryIdentity {
                state = .unknown
            } else if staged?.nodeIdentity == creation.nodeIdentity, staged?.linkText == creation.linkText {
                state = .notCompleted
            } else if staged?.nodeKind == .vacant,
                      inspection?.observation.nodeIdentity == creation.nodeIdentity,
                      inspection?.observation.linkText == creation.linkText {
                state = .completed
            } else {
                state = .unknown
            }
            components.append(RelationActionRecoveryComponent(kind: .preparationNode, state: state,
                path: creation.stagingPath, detail: "creation-publication-observation-only"))
            if let review = materialReview {
                components.append(RelationActionRecoveryComponent(kind: .creationDirectory,
                    state: review.detail == "Creation directory settled" ? .completed
                        : (review.canSettle ? .notCompleted : .unknown),
                    path: review.path, detail: review.detail))
            }
        }
        if let removal = record.removal {
            let isolated = try? inspector.inspect(linkURL: URL(fileURLWithPath: removal.isolationPath),
                relation: record.relation, canonicalTargetPath: record.canonicalTargetPath, evidence: nil).observation
            let state: RelationActionRecoveryState
            if directoryState != .completed || isolated?.parentIdentity != removal.isolationDirectoryIdentity
                || (try? LinkNodeIdentity.read(at: operationDirectory)) != removal.operationDirectoryIdentity {
                state = .unknown
            } else if isolated?.nodeIdentity == removal.creation.nodeIdentity,
                      isolated?.linkText == removal.creation.linkText {
                state = .notCompleted
            } else if isolated?.nodeKind == .vacant,
                      inspection?.observation.nodeIdentity == removal.creation.nodeIdentity {
                state = .notCompleted
            } else if isolated?.nodeKind == .vacant, inspection?.classification == .vacant,
                      metadataState == .completed {
                state = .completed
            } else {
                // Absence cannot distinguish deletion from an external move without matching facts.
                state = .unknown
            }
            components.append(RelationActionRecoveryComponent(kind: .isolationNode, state: state,
                path: removal.isolationPath, detail: "isolation-observation-only"))
        }
        return RelationActionRecoveryResult(
            relation: record.relation,
            observation: inspection?.observation,
            verification: verification,
            components: components,
            limitations: limitations,
            safeNextStep: components.allSatisfy { $0.state == .completed }
                ? "none"
                : (materialReview != nil ? "Review creation materials in Operation Details." : "reauthorize-current-relation"),
            creationMaterials: materialReview
        )
    }

    private func revalidatedFacts(
        _ facts: RelationActionFacts,
        currentInstallation: @Sendable () -> AgentInstallationEvidence?
    ) -> RelationActionFacts {
        facts
    }

    private func appendOperationObservation(
        to record: inout RelationActionOperationRecord?,
        checkpoint: RelationActionOperationCheckpoint,
        rootURL: URL,
        fileEvents: [RelationActionFileEvent],
        completed: Bool
    ) throws {
        guard var current = record else { return }
        let snapshot = try? metadataStore.loadCurrentSnapshot(from: rootURL)
        let evidence = snapshot?.metadata.managedRelationEvidence.first { $0.relation == current.relation }
        let inspection = try? inspector.inspect(
            linkURL: URL(fileURLWithPath: current.linkPath),
            relation: current.relation,
            canonicalTargetPath: current.canonicalTargetPath,
            evidence: evidence
        )
        let targetIdentity = try? directoryIdentity(
            of: URL(fileURLWithPath: current.facts.targetPath, isDirectory: true)
        )
        current.retainedPaths = Array(Set(current.retainedPaths + fileEvents.compactMap { event in
            if case .retainedForRecovery(let path) = event { return path }
            return nil
        })).sorted()
        current.observations.append(
            RelationActionOperationObservation(
                checkpoint: checkpoint,
                metadataGeneration: snapshot?.generation,
                metadataDigest: snapshot?.metadataDigest,
                metadataFileIdentity: snapshot?.metadataFileIdentity,
                metadataParentIdentity: snapshot?.metadataParentIdentity,
                linkObservation: inspection?.observation,
                targetDirectoryIdentity: targetIdentity,
                limitation: snapshot == nil || inspection == nil || targetIdentity == nil
                    ? "current-operation-facts-incomplete"
                    : nil,
                observedAt: now()
            )
        )
        if completed { current.completedAt = now() }
        try operationRecordStore.save(current, rootURL: rootURL)
        record = current
    }

    private func directoryIdentity(of url: URL) throws -> TargetFileIdentity {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &status) } ?? -1
        }
        guard result == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw RelationActionOperationRecordError.recordUnavailable
        }
        return TargetFileIdentity(volumeNumber: UInt64(status.st_dev), fileNumber: UInt64(status.st_ino))
    }

    private func compensate(
        authorization: RelationActionAuthorization,
        createdNode: ManagedLinkNode?,
        createdLocation: String?,
        fileEvents: inout [RelationActionFileEvent]
    ) -> Bool {
        if fileEvents.contains(where: { if case .isolated = $0 { true } else { false } }) {
            // Isolation, deletion, or restoration may already have happened. Never compensate them.
            return false
        }
        do {
            try faultHook?(.beforeCompensation)
            guard let createdNode else {
                if let createdLocation {
                    fileEvents.append(.created(createdLocation))
                    fileEvents.append(.retainedForRecovery(createdLocation))
                    return false
                }
                return true
            }
            // Keep the scene until removal can atomically check the authorized identity.
            fileEvents.append(.retainedForRecovery(createdNode.linkURL.path))
            return false
        } catch {
            fileEvents.append(.compensationFailed(createdNode?.linkURL.path ?? authorization.facts.linkPath))
            return false
        }
    }

    private func observeAndPersist(
        authorization: RelationActionAuthorization,
        rootURL: URL,
        snapshot: RootSnapshot,
        fallbackIntent: EnablementIntent,
        existingEvidence: ManagedRelationEvidence?,
        currentInstallation: @Sendable () -> AgentInstallationEvidence?
    ) throws -> (observation: TargetObservation, verification: VerificationRecord, limitations: [String]) {
        let relation = authorization.relation
        let local = try localStateStore.load(from: rootURL)
        let intent = currentIntent(in: snapshot, relation: relation) ?? fallbackIntent
        let inspection = try inspector.inspect(
            linkURL: URL(fileURLWithPath: authorization.facts.linkPath),
            relation: relation,
            canonicalTargetPath: authorization.facts.canonicalPath,
            evidence: existingEvidence
        )
        let record = RelationVerifier.verify(
            actionFacts: revalidatedFacts(authorization.facts, currentInstallation: currentInstallation),
            rootGeneration: snapshot.generation,
            intent: intent,
            observation: inspection.observation,
            evidence: existingEvidence,
            limitations: !authorization.desiredEnabled && inspection.observation.nodeKind != .vacant
                ? ["original-position-reoccupied"] : []
        )
        let next = local.replacingRelationState(
            relation,
            observation: inspection.observation,
            evidence: existingEvidence,
            verification: record
        )
        try localStateStore.save(next, to: rootURL)
        return (inspection.observation, record, record.limitations)
    }

    private func evidenceForDesiredState(
        authorization: RelationActionAuthorization,
        observation: TargetObservation,
        existingEvidence: ManagedRelationEvidence?,
        targetGeneration: UInt64,
        createdNode: ManagedLinkNode?
    ) throws -> ManagedRelationEvidence? {
        guard authorization.desiredEnabled else { return nil }
        if let existingEvidence,
           createdNode == nil,
           existingEvidence.createdAtGeneration == targetGeneration,
           RelationOwnershipInspector.classify(observation: observation,
               canonicalTargetPath: authorization.facts.canonicalPath, evidence: existingEvidence) == .exactManagedLink {
            return existingEvidence
        }
        guard let createdNode,
              observation.nodeIdentity == createdNode.creation.nodeIdentity,
              observation.parentIdentity == createdNode.creation.parentIdentity,
              observation.linkText == createdNode.linkText,
              observation.limitation == nil else {
            throw RelationLinkPrimitiveError.createdNodeChanged
        }
        return ManagedRelationEvidence(
            relation: authorization.relation,
            linkPath: authorization.facts.linkPath,
            canonicalTargetPath: authorization.facts.canonicalPath,
            profileID: authorization.facts.profileID,
            profileVersion: authorization.facts.profileVersion,
            createdAtGeneration: targetGeneration,
            fileIdentity: createdNode.fileIdentity,
            createdAt: now(),
            creation: createdNode.creation
        )
    }

    private func snapshotMatchesAuthorization(
        _ snapshot: RootSnapshot,
        authorization: RelationActionAuthorization
    ) -> Bool {
        let facts = authorization.facts
        guard snapshot.generation == facts.metadataGeneration,
              snapshot.metadataDigest == facts.metadataDigest,
              snapshot.metadataFileIdentity == facts.metadataFileIdentity,
              snapshot.metadataParentIdentity == facts.metadataParentIdentity,
              snapshot.metadata.rootConfig.rootPath == facts.rootPath,
              let asset = snapshot.metadata.installedSkills.first(where: {
                  $0.assetID == authorization.relation.assetID
              }),
              asset.currentRevision == facts.assetRevision,
              asset.manifestDigest == facts.assetManifestDigest,
              URL(fileURLWithPath: asset.installedPath).standardizedFileURL.path == facts.canonicalPath,
              currentIntent(in: snapshot, relation: authorization.relation) == facts.currentIntent else {
            return false
        }
        return true
    }

    private func inspectionMatchesAuthorization(
        _ inspection: RelationOwnershipInspection,
        evidence: ManagedRelationEvidence?,
        authorization: RelationActionAuthorization
    ) -> Bool {
        let observation = inspection.observation
        let facts = authorization.facts
        return observation.relation == authorization.relation
            && observation.linkPath == facts.linkPath
            && observation.nodeKind == facts.nodeKind
            && observation.fileIdentity?.fingerprint == facts.nodeFingerprint
            && observation.linkText == facts.linkText
            && observation.resolvedTargetPath == facts.resolvedTargetPath
            && observation.isReadable == facts.targetIsReadable
            && observation.isWritable == facts.targetIsWritable
            && observation.limitation == facts.observationLimitation
            && RelationActionTokenBuilder().observationDigest(of: observation) == facts.observationDigest
            && inspection.classification == facts.ownership
            && (inspection.classification != .exactManagedLink
                || evidenceMatchesAuthorization(evidence, authorization: authorization))
    }

    private func evidenceMatchesAuthorization(
        _ evidence: ManagedRelationEvidence?,
        authorization: RelationActionAuthorization
    ) -> Bool {
        guard let evidence else { return false }
        let facts = authorization.facts
        return evidence.relation == authorization.relation
            && URL(fileURLWithPath: evidence.linkPath).standardizedFileURL.path == facts.linkPath
            && URL(fileURLWithPath: evidence.canonicalTargetPath).standardizedFileURL.path == facts.canonicalPath
            && evidence.profileID == facts.profileID
            && evidence.profileVersion == facts.profileVersion
            && evidence.fileIdentity.fingerprint == facts.nodeFingerprint
            && evidence.createdAtGeneration == facts.currentIntent?.generation
    }

    private func ownershipAllowsAction(
        _ ownership: RelationOwnershipClassification,
        desiredEnabled: Bool
    ) -> Bool {
        switch (desiredEnabled, ownership) {
        case (true, .vacant), (true, .exactManagedLink),
             (false, .vacant), (false, .exactManagedLink):
            true
        case (true, _), (false, _):
            false
        }
    }

    private func currentIntent(
        in snapshot: RootSnapshot,
        relation: AgentRelationIdentity
    ) -> EnablementIntent? {
        snapshot.metadata.enablementIntents.first { relationForIntent($0) == relation }
    }

    private func metadataCommitIsVisible(
        authorization: RelationActionAuthorization,
        rootURL: URL,
        expectedGeneration: UInt64
    ) -> Bool {
        guard let snapshot = try? metadataStore.loadCurrentSnapshot(from: rootURL),
              snapshot.generation == expectedGeneration,
              let intent = currentIntent(in: snapshot, relation: authorization.relation) else {
            return false
        }
        return intent.isEnabled == authorization.desiredEnabled
            && intent.generation == expectedGeneration
    }

    private func blocked(
        relation: AgentRelationIdentity,
        reason: RelationActionExecutionBlockReason,
        events: [RelationActionFileEvent],
        observation: TargetObservation? = nil
    ) -> RelationActionExecutionResult {
        RelationActionExecutionResult(
            relation: relation,
            status: .blocked,
            blockReason: reason,
            fileEvents: events,
            metadataDelta: .none,
            observation: observation,
            verification: nil,
            limitations: [reason.rawValue],
            safeNextStep: "observe-current-relation"
        )
    }

    private func backupLocalState(at rootURL: URL) throws -> RelationLocalStateBackup {
        let fileURL = localStateStore.localStateFile(for: rootURL)
        if fileManager.fileExists(atPath: fileURL.path) {
            return RelationLocalStateBackup(fileURL: fileURL, data: try Data(contentsOf: fileURL))
        }
        return RelationLocalStateBackup(fileURL: fileURL, data: nil)
    }

    private func restoreLocalState(_ backup: RelationLocalStateBackup) -> Bool {
        do {
            if let data = backup.data {
                try data.write(to: backup.fileURL, options: [.atomic])
            } else if fileManager.fileExists(atPath: backup.fileURL.path) {
                try fileManager.removeItem(at: backup.fileURL)
            }
            return true
        } catch {
            return false
        }
    }

    private func verifyBrokenLinkDeletionFacts(
        _ facts: BrokenLinkDeletionFacts,
        rootURL: URL,
        requireLink: Bool
    ) throws {
        guard rootURL.standardizedFileURL.path == facts.rootPath,
              try LinkNodeIdentity.read(at: rootURL.standardizedFileURL) == facts.rootIdentity,
              try LinkNodeIdentity.read(at: URL(fileURLWithPath: facts.authorizedDirectoryPath)) == facts.parentIdentity else {
            throw BrokenLinkDeletionError.confirmedFactsChanged
        }
        let inspector = BrokenLinkDeletionInspector(fileManager: fileManager)
        let link = URL(fileURLWithPath: facts.linkPath)
        guard try inspector.resolvedTarget(
            rawTarget: facts.rawTarget,
            relativeTo: link.deletingLastPathComponent()
        ).path == facts.resolvedTargetPath else {
            throw BrokenLinkDeletionError.confirmedFactsChanged
        }
        try inspector.verifyMissingTarget(at: URL(fileURLWithPath: facts.resolvedTargetPath))
        guard requireLink else { return }
        guard try LinkNodeIdentity.read(at: link) == facts.nodeIdentity,
              try fileManager.destinationOfSymbolicLink(atPath: link.path) == facts.rawTarget else {
            throw BrokenLinkDeletionError.confirmedFactsChanged
        }
    }

    private func retainedBrokenLinkPath(
        record: BrokenLinkDeletionOperationRecord?,
        facts: BrokenLinkDeletionFacts
    ) -> String? {
        if let isolated = record?.removal?.isolationPath,
           (try? LinkNodeIdentity.read(at: URL(fileURLWithPath: isolated))) != nil {
            return isolated
        }
        if (try? LinkNodeIdentity.read(at: URL(fileURLWithPath: facts.linkPath))) != nil {
            return facts.linkPath
        }
        return nil
    }
}

nonisolated private struct RelationLocalStateBackup: Sendable {
    let fileURL: URL
    let data: Data?
}

nonisolated private func relationForIntent(_ intent: EnablementIntent) -> AgentRelationIdentity {
    AgentRelationIdentity(
        assetID: intent.assetID,
        agentID: intent.agentID,
        scope: intent.scope
    )
}
