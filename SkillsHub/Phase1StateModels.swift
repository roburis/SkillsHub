import CryptoKit
import Foundation

nonisolated enum SHA256Digest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct RootSnapshot: Codable, Hashable, Sendable {
    var metadata: SkillsHubMetadata
    var generation: UInt64
    var metadataDigest: String
    var metadataFileIdentity: TargetFileIdentity? = nil
    var metadataParentIdentity: TargetFileIdentity? = nil
}

nonisolated struct RootInspectionFacts: Hashable, Sendable {
    var url: URL
    var snapshot: RootSnapshot?

    init(url: URL, snapshot: RootSnapshot? = nil) {
        self.url = url.standardizedFileURL
        self.snapshot = snapshot
    }
}

nonisolated enum RootInspectionFailure: Error, Hashable, Sendable {
    case missing(path: String)
    case notDirectory(path: String)
    case symbolicLink(path: String)
    case unreadable(path: String)
    case invalidMetadata(path: String, reason: String)
}

nonisolated enum RootInspectionResult: Hashable, Sendable {
    case existingRoot(RootInspectionFacts)
    case initializationRequired(RootInspectionFacts)
    case invalid(RootInspectionFailure)
    case cancelled
}

nonisolated enum MetadataWritePhase: String, CaseIterable, Codable, Sendable {
    case encoding
    case staging
    case stagingFileSync
    case stagingDirectorySync
    case replacement
    case displacedOriginal
    case publishedFileSync
    case publishedDirectorySync
    case readback
}

nonisolated enum Phase1RootPresentationStatus: Hashable, Sendable {
    case unavailable
    case initializationRequired
    case initializing(Phase1OperationPhase)
    case authorized
    case invalid
    case needsAttention
    case unknown
}

nonisolated enum Phase1RootPresentationAction: Hashable, Sendable {
    case openTasks
    case none
}

nonisolated struct Phase1RootPresentation: Hashable, Sendable {
    var status: Phase1RootPresentationStatus
    var title: String
    var detail: String
    var statusLabel: String
    var rootPath: String?
    var primaryAction: Phase1RootPresentationAction
    var primaryActionTitle: String?

    private init(
        status: Phase1RootPresentationStatus,
        title: String,
        detail: String,
        statusLabel: String,
        rootPath: String?,
        primaryAction: Phase1RootPresentationAction,
        primaryActionTitle: String?
    ) {
        self.status = status
        self.title = title
        self.detail = detail
        self.statusLabel = statusLabel
        self.rootPath = rootPath
        self.primaryAction = primaryAction
        self.primaryActionTitle = primaryActionTitle
    }

    var accessibilityValue: String {
        [statusLabel, rootPath, detail]
            .compactMap { $0 }
            .joined(separator: ". ")
    }

    func accessibilityValue(language: AppLanguage) -> String {
        [statusLabel, rootPath, detail]
            .compactMap { $0 }
            .map { SkillsHubLocalization().localized($0, language: language) }
            .joined(separator: ". ")
    }

    init(
        rootURL: URL?,
        inspectionResult: RootInspectionResult?,
        pendingInitialization: RootInspectionFacts?,
        tasks: [Phase1TaskRecord],
        language: AppLanguage = .english
    ) {
        if let rootURL {
            self.init(
                status: .authorized,
                title: "Management Directory connected",
                detail: "The current Root was read back successfully. Source registration and managed-copy plans are available.",
                statusLabel: "Authorized",
                rootPath: rootURL.standardizedFileURL.path,
                primaryAction: .none,
                primaryActionTitle: nil
            )
            return
        }

        if let task = tasks
            .filter({ $0.kind == .initializeRoot })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            switch task.phase {
            case .preparing, .executing, .observing, .verifying:
                self.init(
                    status: .initializing(task.phase),
                    title: "Initializing Management Directory",
                    detail: SkillsHubLocalization().localized(task.result, language: language),
                    statusLabel: task.phase.presentationLabel,
                    rootPath: task.objectID,
                    primaryAction: .openTasks,
                    primaryActionTitle: "View Root establishment task"
                )
                return
            case .waitingConfirmation:
                self.init(
                    status: .needsAttention,
                    title: "Root establishment needs attention",
                    detail: "Review the current directory before continuing. Start a new establishment action from current facts.",
                    statusLabel: "Needs attention · no writes",
                    rootPath: task.objectID,
                    primaryAction: .openTasks,
                    primaryActionTitle: "View Root task"
                )
                return
            case .needsAttention:
                self.init(
                    status: .needsAttention,
                    title: "Root establishment needs attention",
                    detail: SkillsHubLocalization().localized(task.result, language: language),
                    statusLabel: "Needs attention · success is not established",
                    rootPath: task.objectID,
                    primaryAction: .openTasks,
                    primaryActionTitle: "View current Root evidence"
                )
                return
            case .completed:
                break
            }
        }

        if let pendingInitialization {
            self.init(
                status: .initializationRequired,
                title: "Root establishment is not complete",
                detail: "The selected directory remains unchanged unless an operation record below shows a completed step.",
                statusLabel: "Not ready · inspect current facts",
                rootPath: pendingInitialization.url.path,
                primaryAction: .none,
                primaryActionTitle: nil
            )
            return
        }

        switch inspectionResult {
        case .initializationRequired(let facts):
            self.init(
                status: .initializationRequired,
                title: "Directory can be established as a Management Directory",
                detail: "Selection and system authorization did not create content. Use Establish Management Directory to start one explicit action.",
                statusLabel: "Ready for establishment · no writes",
                rootPath: facts.url.path,
                primaryAction: .none,
                primaryActionTitle: nil
            )
        case .invalid:
            self.init(
                status: .invalid,
                title: "The selected Root is unavailable",
                detail: "The object is invalid or unreadable. No Root session was activated and no business write occurred.",
                statusLabel: "Invalid or unreadable · no writes",
                rootPath: nil,
                primaryAction: .none,
                primaryActionTitle: nil
            )
        case .cancelled:
            self.init(
                status: .unavailable,
                title: "Management Directory is not authorized",
                detail: "Root selection was canceled. No business write occurred; you can choose an exact directory when ready.",
                statusLabel: "Selection canceled · no writes",
                rootPath: nil,
                primaryAction: .none,
                primaryActionTitle: nil
            )
        case .existingRoot(let facts):
            self.init(
                status: .unknown,
                title: "Root connection is not verified",
                detail: "An existing Root was inspected, but there is no active Root session. Reinspect current facts before continuing.",
                statusLabel: "Unknown · success is not established",
                rootPath: facts.url.path,
                primaryAction: .none,
                primaryActionTitle: nil
            )
        case nil:
            self.init(
                status: .unavailable,
                title: "Authorize Management Directory",
                detail: "Manage one explicit Root. Skills Hub does not scan Home, common project folders, or the disk.",
                statusLabel: "Not authorized · source registration and managed copies are unavailable",
                rootPath: nil,
                primaryAction: .none,
                primaryActionTitle: nil
            )
        }
    }
}

nonisolated extension Phase1OperationPhase {
    var presentationLabel: String {
        switch self {
        case .preparing: "Preparing"
        case .waitingConfirmation: "Waiting for confirmation"
        case .executing: "Executing"
        case .observing: "Observing"
        case .verifying: "Verifying"
        case .completed: "Completed"
        case .needsAttention: "Needs attention"
        }
    }
}

nonisolated extension Phase1TaskRecord {
    var safeNextStep: String {
        if phase == .waitingConfirmation { return "Review the current plan before confirming." }
        if phase == .needsAttention { return "Re-observe the current object before preparing a new plan." }
        if phase == .completed { return "Open the current object to inspect current facts." }
        return "You can leave this page while the confirmed operation continues."
    }
}

nonisolated enum MetadataCommitError: Error, Equatable {
    case staleGeneration(expected: UInt64, actual: UInt64)
    case staleDigest
    case invalidSchema(Int)
    case writeVerificationFailed
    case invalidConfirmation
    case expectedSnapshotRequired
    case generationExhausted
    case metadataIdentityChanged
    case metadataParentIdentityChanged
    case filesystemFailure(phase: MetadataWritePhase, path: String, errno: Int32)
    case recoveryRequired(metadataPath: String, backupPath: String?, stagingPath: String, reason: String)
}

nonisolated enum ManifestNodeKind: String, Codable, Hashable, Sendable {
    case directory
    case file
    case symbolicLink
}

nonisolated struct ContentManifestEntry: Codable, Hashable, Sendable {
    var relativePath: String
    var kind: ManifestNodeKind
    var byteDigest: String?
    var symbolicLinkTarget: String?
    var isExecutable: Bool
    var byteCount: Int64
}

nonisolated struct ContentManifest: Codable, Hashable, Sendable {
    var entries: [ContentManifestEntry]
    var fileCount: Int
    var totalByteCount: Int64
    var digest: String
    var observedAt: Date
}

nonisolated enum LocalSourceObservationReason: String, Codable, Hashable, Sendable {
    case candidateValid
    case candidateWarning
    case candidateBlocked
    case candidateUnreadable
    case sourceMissing
    case sourceNotDirectory
    case pathMissing
    case directoryEnumerated
    case enumerationFailed
    case attributesUnreadable
    case noSkillEntry
    case symlinkEscapesSource
    case symlinkUnreadable
    case symbolicLinkSkipped
    case traversalBudgetExceeded
    case scanCancelled
    case sourceChanged
}

nonisolated struct LocalCandidateObservation: Codable, Hashable, Identifiable, Sendable {
    var candidateID: String
    var sourceID: UUID
    var relativePath: String
    var name: String
    var detail: String
    var status: CandidateCheckStatus
    var reason: LocalSourceObservationReason
    var fingerprint: String
    var observedAt: Date
    var manifest: ContentManifest?

    var id: String { "\(candidateID):\(reason.rawValue)" }

    init(
        candidateID: String,
        sourceID: UUID,
        relativePath: String,
        name: String,
        detail: String,
        status: CandidateCheckStatus,
        reason: LocalSourceObservationReason,
        fingerprint: String,
        observedAt: Date,
        manifest: ContentManifest?
    ) {
        self.candidateID = candidateID
        self.sourceID = sourceID
        self.relativePath = relativePath
        self.name = name
        self.detail = detail
        self.status = status
        self.reason = reason
        self.fingerprint = fingerprint
        self.observedAt = observedAt
        self.manifest = manifest
    }

    private enum CodingKeys: String, CodingKey {
        case candidateID, sourceID, relativePath, name, detail, status
        case reason, fingerprint, observedAt, manifest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidateID = try container.decode(String.self, forKey: .candidateID)
        sourceID = try container.decode(UUID.self, forKey: .sourceID)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        name = try container.decode(String.self, forKey: .name)
        detail = try container.decode(String.self, forKey: .detail)
        status = try container.decode(CandidateCheckStatus.self, forKey: .status)
        manifest = try container.decodeIfPresent(ContentManifest.self, forKey: .manifest)
        reason = try container.decodeIfPresent(LocalSourceObservationReason.self, forKey: .reason)
            ?? Self.observationReason(for: status)
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint)
            ?? manifest?.digest
            ?? SHA256Digest.hex(Data("\(sourceID.uuidString)|\(relativePath)|\(status.rawValue)|\(detail)".utf8))
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
            ?? manifest?.observedAt
            ?? .distantPast
    }

    private static func observationReason(for status: CandidateCheckStatus) -> LocalSourceObservationReason {
        switch status {
        case .valid: .candidateValid
        case .warning: .candidateWarning
        case .blocked: .candidateBlocked
        case .unreadable: .candidateUnreadable
        }
    }
}
