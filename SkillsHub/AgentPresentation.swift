import Foundation

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

    nonisolated var assetImageName: String? {
        AgentIconCatalog.specification(for: self).assetName
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
    var agentKind: AgentKind?
    var agentDisplayName: String
    var iconMonogram: String?
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

    init(relation: AgentRelationPresentation) {
        id = relation.relation.agentID
        displayName = relation.agentDisplayName
        agentKind = relation.agentKind
        iconMonogram = relation.iconMonogram
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
    nonisolated var agentPresentation: AgentPresentation {
        AgentPresentation(relation: self)
    }

    nonisolated var presentationStatusSymbol: String? {
        if unavailableReason != nil || verification == .drifted {
            return "exclamationmark.triangle.fill"
        }
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
    var detail: String

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
    var detail: String

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
        case .symbolicLink: "Managed link observed"
        case .brokenSymbolicLink: "Broken link"
        case .directory: "Directory"
        case .regularFile: "File"
        case .other: "Other node"
        case .unreadable: "Unreadable"
        }
    }
}
