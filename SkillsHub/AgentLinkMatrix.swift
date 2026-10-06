import Foundation

nonisolated struct AgentCapabilityProfileDefinition: Codable, Hashable {
    let profileID: String
    let profileVersion: Int
    let schemaVersion: Int
    let agent: AgentKind
    let scope: AgentLinkScope
}

nonisolated enum AgentProfileQualificationFailure: String, Codable, Hashable {
    case unsupportedAgent
    case profileMissing
    case profileStale
    case schemaInvalid
    case agentMismatch
    case scopeMismatch
}

nonisolated enum AgentProfileQualification: Equatable {
    case qualified(AgentCapabilityProfileDefinition)
    case unavailable(AgentProfileQualificationFailure)
}

nonisolated struct AgentCapabilityProfileRegistry {
    static let currentSchemaVersion = 1
    static let builtIn = AgentCapabilityProfileRegistry(profiles: [
        AgentCapabilityProfileDefinition(
            profileID: "skillshub.agent-profile.codex.global@1",
            profileVersion: 1,
            schemaVersion: currentSchemaVersion,
            agent: .codex,
            scope: .global
        ),
        AgentCapabilityProfileDefinition(
            profileID: "skillshub.agent-profile.claude-code.global@1",
            profileVersion: 1,
            schemaVersion: currentSchemaVersion,
            agent: .claudeCode,
            scope: .global
        )
    ])

    private let profilesByAgent: [AgentKind: AgentCapabilityProfileDefinition]

    private init(profiles: [AgentCapabilityProfileDefinition]) {
        profilesByAgent = Dictionary(uniqueKeysWithValues: profiles.map { ($0.agent, $0) })
    }

    func profile(for agent: AgentKind, scope: AgentLinkScope) -> AgentCapabilityProfileDefinition? {
        guard scope == .global else {
            return nil
        }
        return profilesByAgent[agent]
    }

    func qualification(for agent: AgentKind, scope: AgentLinkScope) -> AgentProfileQualification {
        guard let profile = profilesByAgent[agent] else {
            return .unavailable(.unsupportedAgent)
        }
        return qualification(of: profile, for: agent, scope: scope)
    }

    func qualification(
        of profile: AgentCapabilityProfileDefinition?,
        for agent: AgentKind,
        scope: AgentLinkScope
    ) -> AgentProfileQualification {
        guard let current = profilesByAgent[agent] else {
            return .unavailable(.unsupportedAgent)
        }
        guard let profile else {
            return .unavailable(.profileMissing)
        }
        guard profile.agent == agent else {
            return .unavailable(.agentMismatch)
        }
        guard scope == .global, profile.scope == scope else {
            return .unavailable(.scopeMismatch)
        }
        guard profile.schemaVersion == Self.currentSchemaVersion else {
            return .unavailable(.schemaInvalid)
        }
        guard profile.profileID == current.profileID,
              profile.profileVersion == current.profileVersion,
              profile.profileVersion > 0 else {
            return .unavailable(.profileStale)
        }
        return .qualified(profile)
    }
}

nonisolated enum AgentTargetQualificationFailure: Equatable {
    case profileUnavailable(AgentProfileQualificationFailure)
    case targetMissing
    case targetAmbiguous
    case permissionRequired
    case bookmarkStale
    case authorizationTargetMismatch
}

nonisolated enum AgentTargetAuthorizationStatus: Equatable {
    case missing
    case stale
    case current
}

nonisolated struct AgentTargetQualification: Equatable {
    let agentID: String
    let agent: AgentKind?
    let agentDetected: Bool
    let profileID: String?
    let profileVersion: Int?
    let schemaVersion: Int?
    let scope: AgentLinkScope
    let candidates: [URL]
    let authorizationStatus: AgentTargetAuthorizationStatus
    let target: URL?
    let failure: AgentTargetQualificationFailure?

    var allowsManagedWrite: Bool { failure == nil }
}

nonisolated struct AgentTargetQualifier {
    private let registry: AgentCapabilityProfileRegistry

    init(registry: AgentCapabilityProfileRegistry = .builtIn) {
        self.registry = registry
    }

    func qualify(
        agent: AgentKind,
        detected: Bool,
        candidates: [URL],
        authorization: StartupAccessBookmarkResolution?
    ) -> AgentTargetQualification {
        let uniqueTargets = Dictionary(
            candidates.map { ($0.standardizedFileURL.path, $0.standardizedFileURL) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.path < $1.path }
        let authorizationStatus: AgentTargetAuthorizationStatus
        switch authorization {
        case nil:
            authorizationStatus = .missing
        case .some(let resolution) where resolution.isStale:
            authorizationStatus = .stale
        case .some:
            authorizationStatus = .current
        }

        let profile: AgentCapabilityProfileDefinition
        switch registry.qualification(for: agent, scope: .global) {
        case .qualified(let current):
            profile = current
        case .unavailable(let failure):
            return unavailable(
                agent: agent,
                detected: detected,
                profile: nil,
                candidates: uniqueTargets,
                authorizationStatus: authorizationStatus,
                failure: .profileUnavailable(failure)
            )
        }
        guard uniqueTargets.isEmpty == false else {
            return unavailable(
                agent: agent,
                detected: detected,
                profile: profile,
                candidates: uniqueTargets,
                authorizationStatus: authorizationStatus,
                failure: .targetMissing
            )
        }
        guard uniqueTargets.count == 1, let target = uniqueTargets.first else {
            return unavailable(
                agent: agent,
                detected: detected,
                profile: profile,
                candidates: uniqueTargets,
                authorizationStatus: authorizationStatus,
                failure: .targetAmbiguous
            )
        }
        guard let authorization else {
            return unavailable(
                agent: agent,
                detected: detected,
                profile: profile,
                candidates: uniqueTargets,
                authorizationStatus: authorizationStatus,
                target: target,
                failure: .permissionRequired
            )
        }
        guard authorization.isStale == false else {
            return unavailable(
                agent: agent,
                detected: detected,
                profile: profile,
                candidates: uniqueTargets,
                authorizationStatus: authorizationStatus,
                target: target,
                failure: .bookmarkStale
            )
        }
        guard authorization.url.standardizedFileURL.path == target.path else {
            return unavailable(
                agent: agent,
                detected: detected,
                profile: profile,
                candidates: uniqueTargets,
                authorizationStatus: authorizationStatus,
                target: target,
                failure: .authorizationTargetMismatch
            )
        }
        return AgentTargetQualification(
            agentID: agent.rawValue,
            agent: agent,
            agentDetected: detected,
            profileID: profile.profileID,
            profileVersion: profile.profileVersion,
            schemaVersion: profile.schemaVersion,
            scope: profile.scope,
            candidates: uniqueTargets,
            authorizationStatus: authorizationStatus,
            target: target,
            failure: nil
        )
    }

    func qualify(
        customAgentID: String,
        detected: Bool,
        candidates: [URL],
        authorization: StartupAccessBookmarkResolution?
    ) -> AgentTargetQualification {
        let uniqueTargets = Dictionary(
            candidates.map { ($0.standardizedFileURL.path, $0.standardizedFileURL) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.path < $1.path }
        let authorizationStatus: AgentTargetAuthorizationStatus = switch authorization {
        case nil: .missing
        case .some(let resolution) where resolution.isStale: .stale
        case .some: .current
        }
        let profileID = "skillshub.agent-profile.custom.global@1"

        func result(target: URL?, failure: AgentTargetQualificationFailure?) -> AgentTargetQualification {
            AgentTargetQualification(
                agentID: customAgentID,
                agent: nil,
                agentDetected: detected,
                profileID: profileID,
                profileVersion: 1,
                schemaVersion: AgentCapabilityProfileRegistry.currentSchemaVersion,
                scope: .global,
                candidates: uniqueTargets,
                authorizationStatus: authorizationStatus,
                target: target,
                failure: failure
            )
        }

        guard uniqueTargets.count == 1, let target = uniqueTargets.first else {
            return result(target: nil, failure: uniqueTargets.isEmpty ? .targetMissing : .targetAmbiguous)
        }
        guard let authorization else { return result(target: target, failure: .permissionRequired) }
        guard authorization.isStale == false else { return result(target: target, failure: .bookmarkStale) }
        guard authorization.url.standardizedFileURL.path == target.path else {
            return result(target: target, failure: .authorizationTargetMismatch)
        }
        return result(target: target, failure: nil)
    }

    private func unavailable(
        agent: AgentKind,
        detected: Bool,
        profile: AgentCapabilityProfileDefinition?,
        candidates: [URL],
        authorizationStatus: AgentTargetAuthorizationStatus,
        target: URL? = nil,
        failure: AgentTargetQualificationFailure
    ) -> AgentTargetQualification {
        AgentTargetQualification(
            agentID: agent.rawValue,
            agent: agent,
            agentDetected: detected,
            profileID: profile?.profileID,
            profileVersion: profile?.profileVersion,
            schemaVersion: profile?.schemaVersion,
            scope: .global,
            candidates: candidates,
            authorizationStatus: authorizationStatus,
            target: target,
            failure: failure
        )
    }
}
