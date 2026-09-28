import Foundation

nonisolated enum SecurityScopedAccessOwner: Hashable, Sendable {
    case inspection(UUID)
    case rootSession(UUID)
    case source(UUID)
    case operation(UUID)
    case agentTarget(actionID: UUID, agent: AgentKind)
    case configuredAgentTarget(actionID: UUID, agentID: String)

    var identity: String {
        switch self {
        case .inspection(let id):
            return "inspection:\(id.uuidString)"
        case .rootSession(let id):
            return "root-session:\(id.uuidString)"
        case .source(let id):
            return "source:\(id.uuidString)"
        case .operation(let id):
            return "operation:\(id.uuidString)"
        case .agentTarget(let actionID, let agent):
            return "agent-target:\(agent.rawValue):\(actionID.uuidString)"
        case .configuredAgentTarget(let actionID, let agentID):
            return "agent-target:\(agentID):\(actionID.uuidString)"
        }
    }
}

nonisolated enum StartupAuthorizationTargetKind: Equatable {
    case defaultRoot
    case builtInAgent(AgentKind)
}

nonisolated struct StartupAuthorizationTarget: Identifiable, Equatable {
    var kind: StartupAuthorizationTargetKind
    var displayName: String
    var authorizationURL: URL

    var id: String {
        switch kind {
        case .defaultRoot:
            return "default-root"
        case .builtInAgent(let agent):
            return "agent-\(agent.rawValue)"
        }
    }
}

nonisolated struct StartupAuthorizationRequest: Equatable {
    var targets: [StartupAuthorizationTarget]
}
