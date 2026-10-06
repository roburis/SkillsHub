import Foundation
import Testing
@testable import SkillsHub

struct CoreModelsTests {
    @Test(arguments: [
        ("/root", "/root", "SKILL.md"),
        ("/root/local/L2", "/root", "local/L2/SKILL.md"),
        ("/root/local/L2/nested/UX 設計", "/root", "local/L2/nested/UX 設計/SKILL.md"),
        ("/root/github/owner/repo/review", "/root", "github/owner/repo/review/SKILL.md"),
        ("/agent/skills/review", "/agent/skills", "review/SKILL.md"),
        ("/private/tmp/skills/review", "/tmp/skills", "review/SKILL.md"),
        ("/var/folders/skills/review", "/private/var/folders/skills", "review/SKILL.md"),
        ("/private/tmp-other/review", "/tmp", nil),
        ("/root/local/a/../review", "/root", "local/review/SKILL.md"),
        ("/root-other/review", "/root", nil),
        ("/root/../outside/review", "/root", nil),
        ("relative/review", "/root", nil),
        ("/root/review", "relative", nil),
        ("/root/review\0other", "/root", nil),
        ("/review", "/", "review/SKILL.md")
    ] as [(String, String, String?)])
    func entryAddressUsesExactBaselineWithoutResolvingLinks(sample: (String, String, String?)) {
        let address = SkillCatalogPresentationService.entryAddress(directoryPath: sample.0,
            relativeTo: sample.1, nodeKind: .directory, entryVerified: true)
        #expect(address.path == sample.2)
        #expect((address.status == nil) == (sample.2 != nil))
        for kind in [TargetNodeKind.vacant, .brokenSymbolicLink, .unreadable, .regularFile, .other] {
            let uncertain = SkillCatalogPresentationService.entryAddress(directoryPath: sample.0,
                relativeTo: sample.1, nodeKind: kind, entryVerified: true)
            #expect(uncertain.status != nil)
            #expect(uncertain.path == ([.regularFile, .other].contains(kind) ? nil : sample.2))
        }
        let missing = SkillCatalogPresentationService.entryAddress(directoryPath: "/root/review",
            relativeTo: "/root", nodeKind: .vacant, entryVerified: false)
        #expect(missing.status?.template == "Recorded address; the Skill entry is missing.")
        let unreadable = SkillCatalogPresentationService.entryAddress(directoryPath: "/root/review",
            relativeTo: "/root", nodeKind: .directory, entryVerified: false, entryUnavailable: true)
        #expect(unreadable.status?.template == "SKILL.md is missing or unreadable.")
    }

    @Test func modelsEncodeManifestWithoutCredentialFields() throws {
        let source = SkillSource(kind: .githubRepository, name: "owner/repo", urlString: "https://github.com/owner/repo", ref: "main")
        let validation = SkillValidationResult.valid
        let skill = InstalledSkill(
            id: "code-review",
            sourceID: source.id,
            name: "Code Review",
            description: "Reviews source code.",
            installedPath: "/root/skills/code-review",
            sourceKind: .githubRepository,
            validation: validation,
            purpose: PurposeMetadata(text: "Review code", source: .user, updatedAt: Date(timeIntervalSince1970: 0)),
            tagIDs: ["review"],
            installedAt: Date(timeIntervalSince1970: 0)
        )
        let manifest = SkillsHubMetadata(
            rootConfig: RootConfig(rootPath: "/root"),
            sources: [source], installedSkills: [skill]
        )

        let data = try JSONEncoder().encode(manifest)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains("code-review"))
        #expect(!json.localizedCaseInsensitiveContains("token"))
        #expect(!json.localizedCaseInsensitiveContains("password"))
        #expect(!json.localizedCaseInsensitiveContains("bookmark"))
        #expect(!json.localizedCaseInsensitiveContains("privateKey"))
    }

    @Test func agentLinkRecordDecodesCustomIdentityWithoutBuiltInKind() throws {
        let input: [String: Any] = [
            "id": UUID().uuidString,
            "agentID": "custom-agent",
            "scope": "global",
            "skillID": "review",
            "linkPath": "/custom/review",
            "targetPath": "/root/local/review"
        ]
        let data = try JSONSerialization.data(withJSONObject: input)

        var encoded: [String: Any]?
        do {
            let record = try JSONDecoder().decode(AgentLinkRecord.self, from: data)
            encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        } catch {
            encoded = nil
        }

        #expect(encoded?["agentID"] as? String == "custom-agent")
        #expect(encoded?["agent"] == nil)
    }

    @Test func phase1IdentityAndCandidateStatesAreStable() {
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let candidateA = StableIdentity.candidateID(sourceID: sourceID, relativePath: "review")
        let candidateB = StableIdentity.candidateID(sourceID: sourceID, relativePath: "review")
        let otherSourceCandidate = StableIdentity.candidateID(sourceID: UUID(), relativePath: "review")
        let assetA = StableIdentity.assetID(candidateID: candidateA, canonicalPathComponent: "review")
        let assetB = StableIdentity.assetID(candidateID: candidateB, canonicalPathComponent: "review")

        #expect(candidateA == candidateB)
        #expect(candidateA != otherSourceCandidate)
        #expect(assetA == assetB)
        #expect(Set(CandidateCheckStatus.allCases) == Set([.valid, .warning, .blocked, .unreadable]))
    }

    @Test func candidateIdentityIsAllocatedOnceAndSurvivesLocatorAndDisplayChanges() throws {
        let source = SkillSource(kind: .localDirectory, name: "Local", localPath: "/source")
        var candidate = AvailableSkill(
            id: "review", sourceID: source.id, skillPath: "review",
            name: "Review", description: "Review changes.", validation: .valid
        )
        let identity = candidate.candidateID
        #expect(UUID(uuidString: identity) != nil)
        candidate.name = "Renamed"
        candidate.skillPath = "relocated/review"
        let reread = try JSONDecoder().decode(AvailableSkill.self, from: JSONEncoder().encode(candidate))
        #expect(reread.candidateID == identity)
        #expect(reread.sourceID == source.id)
    }
}
