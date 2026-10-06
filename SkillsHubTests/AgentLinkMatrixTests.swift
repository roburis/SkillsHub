import Foundation
import Testing
@testable import SkillsHub

struct AgentLinkMatrixTests {
    @Test func presentationSeparatesUnselectedAvailabilityFromRealRelationshipIssues() {
        var relation = AgentRelationPresentation(
            relation: AgentRelationIdentity(assetID: UUID(), agentID: "codex", scope: .global),
            agentDisplayName: "Codex",
            skillID: "review", skillName: "Review", intendedEnabled: nil,
            observation: nil, verification: .notVerified, isInFlight: false,
            canPerformAction: false, unavailableReason: "Permission required",
            lastOutcome: nil, safeNextStep: "Observe current facts before preparing another action.")
        for intent in [Bool?.none, false] {
            relation.intendedEnabled = intent
            for verification in [VerificationConclusion.notVerified, .currentlyUnverifiable, .verifiedConsistent] {
                relation.verification = verification
                #expect(!relation.hasPresentationIssue)
            }
        }
        relation.intendedEnabled = true
        #expect(relation.hasPresentationIssue)
        relation.unavailableReason = nil
        relation.verification = .currentlyUnverifiable
        #expect(relation.presentationStatusSymbol == "questionmark.circle.fill")
        relation.verification = .drifted
        relation.observation = .vacant
        #expect(relation.presentationStatusSymbol == "exclamationmark.triangle.fill")
        relation.intendedEnabled = false
        #expect(relation.hasPresentationIssue, "A verified mismatch remains a real issue after disabling")
        relation.verification = .notVerified
        relation.observation = .brokenSymbolicLink
        #expect(relation.hasPresentationIssue)
    }

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
    }

    enum ProfileQualificationSample: CaseIterable {
        case validCodex
        case validClaudeCode
        case missing
        case stale
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
        #expect(qualification.target == expectedTarget)
    }

    private func profile(
        from source: AgentCapabilityProfileDefinition,
        profileVersion: Int? = nil,
        schemaVersion: Int? = nil
    ) -> AgentCapabilityProfileDefinition {
        AgentCapabilityProfileDefinition(
            profileID: source.profileID,
            profileVersion: profileVersion ?? source.profileVersion,
            schemaVersion: schemaVersion ?? source.schemaVersion,
            agent: source.agent,
            scope: source.scope
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

}
