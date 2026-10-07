import Foundation

enum AgentDirectoryAccessFailure: Equatable {
    case authorizationRequired
    case accessFailed(LocalizedMessage)

    var message: LocalizedMessage {
        switch self {
        case .authorizationRequired: "Authorize this Agent’s skills directory to check its relationships."
        case .accessFailed(let reason): reason
        }
    }
}

@MainActor
struct AgentDirectoryAuthorizationRequest: Identifiable {
    let id = UUID()
    let agentID: String
    let displayName: String
    let directory: URL
    let root: RootSnapshot?
    let sessionID: UUID?
    let observations: [TargetObservation]
    var retry: (@MainActor () async throws -> Void)?
}

nonisolated extension RelationOwnershipClassification {
    var clearMessage: LocalizedMessage {
        switch self {
        case .exactManagedLink: "Remove the verified Skills Hub-managed link and disable this relationship."
        case .vacant: "Disable this relationship; no link node is currently present."
        case .unmanagedNode: "The current node is not managed by Skills Hub; the object remains unchanged."
        case .externalLink: "The current link does not match the expected managed target; the object remains unchanged."
        case .brokenLink: "The current link is broken; the object remains unchanged."
        case .unreadable: "Current ownership could not be verified; the object remains unchanged."
        }
    }
}

nonisolated extension AgentFindingType {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .pendingAudit: "Agent entries have not been fully checked."
        case .missingSkillsDirectory: "Agent detected, skills directory not created."
        case .permissionDenied: "Agent skills directory is not readable or writable."
        case .directoryEnumerationFailed: "The Agent directory could not be completely checked."
        case .localDirectoryNotManaged: "Local directory is not governed by Skills Hub."
        case .externalSymlinkNotManaged: "Agent link does not match a verified managed relationship."
        case .brokenSymlink: "Agent entry is a broken symlink."
        case .duplicateWithHub: "Agent entry may duplicate a Hub skill."
        case .aliasConflict: "The Agent entry conflicts with a recorded link name."
        case .copiedButAgentStillLocal: "A managed copy exists; the Agent still uses its local directory."
        case .copiedButAgentStillExternal: "A managed copy exists; the Agent still uses its external link."
        case .linkDrift: "The recorded managed link no longer matches current facts."
        case .rootMovedRepairAvailable: "Broken Hub-managed link can be repaired after root move."
        case .rollbackFailed: "Recovery of the Agent relationship needs attention."
        case .invalidEntry: "Agent entry is not a supported skill directory."
        }
    }
}

nonisolated extension AgentDirectoryFinding {
    var presentationMessage: LocalizedMessage {
        if type == .externalSymlinkNotManaged,
           summary == "Agent entry points outside the Management Directory." {
            return "Agent entry points outside the Management Directory."
        }
        return type.presentationMessage
    }
}

extension AgentKind {
    nonisolated var displayName: String {
        switch self {
        case .claudeCode:
            return "Claude Code"
        case .codex:
            return "Codex"
        case .cursor:
            return "Cursor"
        case .hermesAgent:
            return "Hermes Agent"
        case .geminiCLI:
            return "Gemini CLI"
        }
    }

    nonisolated var systemImage: String {
        switch self {
        case .claudeCode:
            return "sparkles"
        case .codex:
            return "sparkles"
        case .cursor:
            return "cursorarrow.click"
        case .hermesAgent:
            return "paperplane"
        case .geminiCLI:
            return "diamond"
        }
    }


}

nonisolated struct AgentPathSettingRecord: Identifiable, Equatable {
    var agent: AgentKind
    var markerPath: String
    var configuredPath: String?
    var defaultPath: String
    var resolvedPath: String
    var detected: Bool
    var isOverride: Bool
    var directoryExists: Bool
    var skillsDirectoryExists: Bool
    var isWritable: Bool
    var status: AgentPathStatus

    var id: AgentKind { agent }
}

nonisolated enum AgentPathStatus: String, Equatable {
    case detected = "Detected"
    case missing = "Missing"
    case custom = "Custom"
    case notWritable = "Not writable"
}

nonisolated struct AgentCapabilityPresentation: Identifiable, Equatable {
    var agentID: String
    var displayName: String
    var isPresent: Bool
    var targetPath: String?
    var authorizationStatus: AgentTargetAuthorizationStatus
    var profileID: String?
    var profileVersion: Int?
    var profileSchemaVersion: Int?
    var canDetect: Bool
    var canClassify: Bool
    var canManageRelations: Bool
    var unavailableReason: String?

    var id: String { agentID }
}

nonisolated struct AgentRelationPresentation: Identifiable, Equatable {
    var relation: AgentRelationIdentity
    var agentDisplayName: String
    var skillID: String
    var skillName: String
    var intendedEnabled: Bool?
    var observation: TargetNodeKind?
    var verification: VerificationConclusion
    var isInFlight: Bool
    var canPerformAction: Bool
    var unavailableReason: String?
    var lastOutcome: ControllerRelationActionOutcome?
    var safeNextStep: String
    var linkPath: String? = nil
    var linkText: String? = nil
    var resolvedTargetPath: String? = nil
    var ownership: RelationOwnershipClassification = .unreadable
    var lastObservation: TargetObservation? = nil
    var checkFailure: LocalizedMessage? = nil

    var id: String { relation.id }
    var desiredEnabled: Bool { !(intendedEnabled ?? false) }
    var canReestablish: Bool { intendedEnabled == true && observation == .vacant }
}

nonisolated struct AgentPresentation: Identifiable, Equatable {
    var id: String
    var displayName: String
    var agentKind: AgentKind?
    var iconMonogram: String?

    init(descriptor: InstalledAgentDescriptor) {
        id = descriptor.id
        displayName = descriptor.displayName
        agentKind = descriptor.agent
        iconMonogram = descriptor.iconMonogram
    }

    var iconSpecification: AgentIconSpecification {
        AgentIconCatalog.specification(for: agentKind)
    }

    var monogramRows: [String] {
        guard agentKind == nil, let iconMonogram, iconMonogram.isEmpty == false else { return [] }
        let characters = Array(iconMonogram)
        guard characters.count > 2 else { return [iconMonogram] }
        return [String(characters.prefix(2)), String(characters.dropFirst(2))]
    }

    static func normalizedIconMonogram(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...4).contains(trimmed.count),
              trimmed.allSatisfy({ character in
                  character.isWhitespace == false
                      && character.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control }
              }) else {
            return nil
        }
        return trimmed
    }
}

extension AgentRelationPresentation {
    nonisolated var presentationStatusSymbol: String? {
        if verification == .drifted || observation == .brokenSymbolicLink {
            return "exclamationmark.triangle.fill"
        }
        guard intendedEnabled == true else { return nil }
        if unavailableReason != nil { return "exclamationmark.triangle.fill" }
        if verification == .notVerified || verification == .currentlyUnverifiable {
            return "questionmark.circle.fill"
        }
        return nil
    }

    nonisolated var hasPresentationIssue: Bool {
        presentationStatusSymbol != nil
    }
}

nonisolated enum ManagedRelationClearDisposition: String, Equatable, Sendable {
    case removable
    case blocked
}

nonisolated struct ManagedRelationClearItem: Identifiable, Equatable, Sendable {
    var relation: AgentRelationIdentity
    var agentDisplayName: String
    var linkPath: String
    var disposition: ManagedRelationClearDisposition
    var detail: LocalizedMessage

    var id: String { relation.id }
}

nonisolated struct ManagedRelationClearPlan: Identifiable, Equatable, Sendable {
    var assetID: UUID
    var skillID: String
    var skillName: String
    var rootGeneration: UInt64
    var assetRevision: String?
    var manifestDigest: String?
    var items: [ManagedRelationClearItem]

    var id: String { "\(assetID.uuidString)-\(rootGeneration)" }
    var removableItems: [ManagedRelationClearItem] {
        items.filter { $0.disposition == .removable }
    }
}

nonisolated struct ManagedRelationClearResultItem: Identifiable, Equatable, Sendable {
    var relation: AgentRelationIdentity
    var agentDisplayName: String
    var outcome: ControllerRelationActionOutcome
    var detail: LocalizedMessage

    var id: String { relation.id }
}

nonisolated struct ManagedRelationClearResult: Equatable, Sendable {
    var skillID: String
    var skillName: String
    var items: [ManagedRelationClearResultItem]
}

nonisolated enum ManagedRelationClearError: Error, Equatable, Sendable {
    case planChanged
}

extension AgentTargetAuthorizationStatus {
    nonisolated var presentationLabel: String {
        switch self {
        case .missing: "Permission required"
        case .stale: "Authorization stale"
        case .current: "Authorized"
        }
    }
}

extension VerificationConclusion {
    nonisolated var presentationLabel: String {
        switch self {
        case .notVerified: "Not verified"
        case .verifiedConsistent: "Verified consistent"
        case .drifted: "Drifted"
        case .currentlyUnverifiable: "Currently unverifiable"
        }
    }
}

extension TargetNodeKind {
    nonisolated var presentationLabel: String {
        switch self {
        case .vacant: "Vacant"
        case .symbolicLink: "Symbolic link"
        case .brokenSymbolicLink: "Broken symbolic link"
        case .directory: "Real directory"
        case .regularFile: "File"
        case .other: "Other node"
        case .unreadable: "Type unverified"
        }
    }
}

extension AgentSkillEntryKind {
    nonisolated var presentationLabel: String {
        switch self {
        case .hubManagedSymlink, .externalSymlink: TargetNodeKind.symbolicLink.presentationLabel
        case .brokenSymlink: TargetNodeKind.brokenSymbolicLink.presentationLabel
        case .localDirectory: TargetNodeKind.directory.presentationLabel
        case .plainFile: TargetNodeKind.regularFile.presentationLabel
        case .invalid: TargetNodeKind.unreadable.presentationLabel
        case .missing: TargetNodeKind.vacant.presentationLabel
        }
    }
}
