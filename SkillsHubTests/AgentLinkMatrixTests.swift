import Foundation
import Testing
@testable import SkillsHub

struct AgentLinkMatrixTests {
    @Test(arguments: [AgentKind.codex, .claudeCode])
    func authorizedTargetQualifiesWithoutInstallationEvidence(_ agent: AgentKind) {
        let target = URL(fileURLWithPath: "/authorized/\(agent.rawValue)/skills", isDirectory: true)
        let qualification = AgentTargetQualifier().qualify(
            agent: agent,
            detected: true,
            candidates: [target],
            authorization: StartupAccessBookmarkResolution(url: target, isStale: false)
        )
        #expect(qualification.allowsManagedWrite)
        #expect(qualification.allowsVerifiedConsistent)
    }

    enum ProfileQualificationSample: CaseIterable {
        case validCodex
        case validClaudeCode
        case missing
        case stale
        case invalidDefinition
        case invalidSchema
        case scopeMismatch
        case additionalAgent
    }

    enum TargetQualificationScenario: CaseIterable {
        case qualified
        case absent
        case targetMissing
        case targetAmbiguous
        case permissionRequired
        case bookmarkStale
        case authorizationTargetMismatch
    }

    @Test(arguments: ProfileQualificationSample.allCases)
    func registryQualifiesOnlyCurrentIndependentGlobalProfiles(_ sample: ProfileQualificationSample) throws {
        let registry = AgentCapabilityProfileRegistry.builtIn

        switch sample {
        case .validCodex:
            let profile = try #require(registry.profile(for: .codex, scope: .global))
            #expect(registry.qualification(of: profile, for: .codex, scope: .global) == .qualified(profile))
        case .validClaudeCode:
            let profile = try #require(registry.profile(for: .claudeCode, scope: .global))
            #expect(registry.qualification(of: profile, for: .claudeCode, scope: .global) == .qualified(profile))
        case .missing:
            #expect(registry.qualification(of: nil, for: .codex, scope: .global) == .unavailable(.profileMissing))
        case .stale:
            let current = try #require(registry.profile(for: .codex, scope: .global))
            let stale = profile(from: current, profileVersion: 0)
            #expect(registry.qualification(of: stale, for: .codex, scope: .global) == .unavailable(.profileStale))
        case .invalidDefinition:
            let current = try #require(registry.profile(for: .codex, scope: .global))
            let invalid = profile(from: current, globalTargetRule: .claudeCodeSkillsDirectory)
            #expect(registry.qualification(of: invalid, for: .codex, scope: .global) == .unavailable(.profileInvalid))
        case .invalidSchema:
            let current = try #require(registry.profile(for: .codex, scope: .global))
            let invalid = profile(from: current, schemaVersion: AgentCapabilityProfileRegistry.currentSchemaVersion + 1)
            #expect(registry.qualification(of: invalid, for: .codex, scope: .global) == .unavailable(.schemaInvalid))
        case .scopeMismatch:
            let profile = try #require(registry.profile(for: .codex, scope: .global))
            #expect(registry.qualification(of: profile, for: .codex, scope: .project) == .unavailable(.scopeMismatch))
        case .additionalAgent:
            #expect(registry.qualification(for: .cursor, scope: .global) == .unavailable(.unsupportedAgent))
        }
    }

    @Test(arguments: [
        (AgentKind.codex, "skillshub.agent-profile.codex.global@1", AgentGlobalTargetRule.codexSkillsDirectory, "phase-007/T-008/codex-global@1"),
        (AgentKind.claudeCode, "skillshub.agent-profile.claude-code.global@1", AgentGlobalTargetRule.claudeCodeSkillsDirectory, "phase-007/T-008/claude-code-global@1")
    ])
    func builtInProfilesExposeCompleteVersionedContracts(
        agent: AgentKind,
        profileID: String,
        targetRule: AgentGlobalTargetRule,
        evidenceLocation: String
    ) throws {
        let profile = try #require(AgentCapabilityProfileRegistry.builtIn.profile(for: agent, scope: .global))

        #expect(profile.profileID == profileID)
        #expect(profile.profileVersion == 1)
        #expect(profile.schemaVersion == AgentCapabilityProfileRegistry.currentSchemaVersion)
        #expect(profile.agent == agent)
        #expect(profile.scope == .global)
        #expect(profile.globalTargetRule == targetRule)
        #expect(profile.linkNamingRule == .validatedManifestIdentity)
        #expect(profile.allowedDirectActions == Set(AgentDirectAction.allCases))
        #expect(profile.ownershipRule == .managedEvidenceAndExactNodeIdentity)
        #expect(profile.observationRule == .currentTargetAndCanonicalFacts)
        #expect(profile.verificationRule == .completeCurrentObservation)
        #expect(profile.invalidationConditions == Set(AgentProfileInvalidationCondition.allCases))
        #expect(profile.evidenceLocation == evidenceLocation)
    }

    @Test(
        arguments: [AgentKind.codex, .claudeCode],
        TargetQualificationScenario.allCases
    )
    func targetQualificationFailsClosedWithoutDiscardingDetectionFacts(
        agent: AgentKind,
        scenario: TargetQualificationScenario
    ) {
        let detected = scenario != .absent
        let target = URL(fileURLWithPath: "/authorized/\(agent.rawValue)/skills", isDirectory: true)
        let candidates: [URL]
        switch scenario {
        case .targetMissing:
            candidates = []
        case .targetAmbiguous:
            candidates = [target, URL(fileURLWithPath: "/other/skills", isDirectory: true)]
        default:
            candidates = [target]
        }
        let authorization: StartupAccessBookmarkResolution?
        switch scenario {
        case .permissionRequired:
            authorization = nil
        case .bookmarkStale:
            authorization = StartupAccessBookmarkResolution(url: target, isStale: true)
        case .authorizationTargetMismatch:
            authorization = StartupAccessBookmarkResolution(
                url: URL(fileURLWithPath: "/wrong/skills", isDirectory: true),
                isStale: false
            )
        default:
            authorization = StartupAccessBookmarkResolution(url: target, isStale: false)
        }

        let qualification = AgentTargetQualifier().qualify(
            agent: agent,
            detected: detected,
            candidates: candidates,
            authorization: authorization
        )

        let expectedFailure: AgentTargetQualificationFailure?
        switch scenario {
        case .qualified, .absent:
            expectedFailure = nil
        case .targetMissing:
            expectedFailure = .targetMissing
        case .targetAmbiguous:
            expectedFailure = .targetAmbiguous
        case .permissionRequired:
            expectedFailure = .permissionRequired
        case .bookmarkStale:
            expectedFailure = .bookmarkStale
        case .authorizationTargetMismatch:
            expectedFailure = .authorizationTargetMismatch
        }
        let expectedAuthorizationStatus: AgentTargetAuthorizationStatus
        switch scenario {
        case .permissionRequired:
            expectedAuthorizationStatus = .missing
        case .bookmarkStale:
            expectedAuthorizationStatus = .stale
        default:
            expectedAuthorizationStatus = .current
        }
        let expectedTarget: URL?
        switch scenario {
        case .qualified, .absent, .permissionRequired, .bookmarkStale, .authorizationTargetMismatch:
            expectedTarget = target
        case .targetMissing, .targetAmbiguous:
            expectedTarget = nil
        }
        #expect(qualification.failure == expectedFailure)
        #expect(qualification.agentDetected == detected)
        #expect(qualification.profileID != nil)
        #expect(qualification.profileVersion == 1)
        #expect(qualification.schemaVersion == AgentCapabilityProfileRegistry.currentSchemaVersion)
        #expect(qualification.scope == .global)
        #expect(qualification.candidates == candidates.map(\.standardizedFileURL).sorted { $0.path < $1.path })
        #expect(qualification.authorizationStatus == expectedAuthorizationStatus)
        #expect(qualification.allowsManagedWrite == (expectedFailure == nil))
        #expect(qualification.allowsVerifiedConsistent == (expectedFailure == nil))
        #expect(qualification.target == expectedTarget)
    }

    private func profile(
        from source: AgentCapabilityProfileDefinition,
        profileVersion: Int? = nil,
        schemaVersion: Int? = nil,
        globalTargetRule: AgentGlobalTargetRule? = nil
    ) -> AgentCapabilityProfileDefinition {
        AgentCapabilityProfileDefinition(
            profileID: source.profileID,
            profileVersion: profileVersion ?? source.profileVersion,
            schemaVersion: schemaVersion ?? source.schemaVersion,
            agent: source.agent,
            scope: source.scope,
            globalTargetRule: globalTargetRule ?? source.globalTargetRule,
            linkNamingRule: source.linkNamingRule,
            allowedDirectActions: source.allowedDirectActions,
            ownershipRule: source.ownershipRule,
            observationRule: source.observationRule,
            verificationRule: source.verificationRule,
            invalidationConditions: source.invalidationConditions,
            evidenceLocation: source.evidenceLocation
        )
    }

    @Test func customAgentUsesTheSameAuthorizedTargetQualification() {
        let target = URL(fileURLWithPath: "/authorized/custom/skills", isDirectory: true)
        let qualification = AgentTargetQualifier().qualify(
            customAgentID: "custom-agent",
            detected: true,
            candidates: [target],
            authorization: StartupAccessBookmarkResolution(url: target, isStale: false)
        )

        #expect(qualification.agentID == "custom-agent")
        #expect(qualification.agent == nil)
        #expect(qualification.allowsManagedWrite)
        #expect(qualification.target == target)
    }

    @Test func matrixSummarizesParentChildMixedAndDisabledAgentStates() throws {
        let parent = InstallableEntry(
            id: "roles-skills",
            name: "roles-skills",
            path: "/root/roles-skills",
            kind: .composite,
            validation: .valid,
            children: [
                InstallableEntry(id: "workflow-apple-feature-delivery", name: "workflow-apple-feature-delivery", path: "/root/roles-skills/workflows/apple", kind: .skill, validation: .valid)
            ]
        )
        let service = AgentLinkMatrixService()
        let childLink = AgentLinkRecord(agent: .codex, scope: .global, skillID: "workflow-apple-feature-delivery", linkPath: "/agent/workflow", targetPath: "/root/roles-skills/workflows/apple")

        var state = service.state(for: parent, agent: .codex, links: [childLink], agentTargetExists: true)
        #expect(state == .partialChildren(count: 1))

        let parentLink = AgentLinkRecord(agent: .codex, scope: .global, skillID: "roles-skills", linkPath: "/agent/roles-skills", targetPath: "/root/roles-skills")
        state = service.state(for: parent, agent: .codex, links: [parentLink, childLink], agentTargetExists: true)
        #expect(state == .linkedWithChildren(count: 1))

        state = service.state(for: parent, agent: .claudeCode, links: [], agentTargetExists: false)
        #expect(state == .disabled)
    }

}
