import Darwin
import Foundation
import Testing
@testable import SkillsHub

struct RelationVerificationTests {
    @Test func inspectorDistinguishesNodesByTheirCurrentTargets() throws {
        let root = try temporaryDirectory()
        let canonical = root.appendingPathComponent("canonical", isDirectory: true)
        let external = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let relation = canonicalRelation()
        let inspector = RelationOwnershipInspector(now: { Date(timeIntervalSince1970: 100) })

        let vacant = try inspector.inspect(
            linkURL: root.appendingPathComponent("vacant"),
            relation: relation,
            canonicalTargetPath: canonical.path)
        #expect(vacant.classification == .vacant)

        let regularFile = root.appendingPathComponent("regular-file")
        try Data("plain".utf8).write(to: regularFile)
        let regular = try inspector.inspect(
            linkURL: regularFile,
            relation: relation,
            canonicalTargetPath: canonical.path)
        #expect(regular.classification == .unmanagedNode)
        #expect(regular.observation.nodeKind == .regularFile)

        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let localDirectory = try inspector.inspect(
            linkURL: directory,
            relation: relation,
            canonicalTargetPath: canonical.path)
        #expect(localDirectory.classification == .unmanagedNode)
        #expect(localDirectory.observation.nodeKind == .directory)

        let externalLink = root.appendingPathComponent("external-link")
        try FileManager.default.createSymbolicLink(at: externalLink, withDestinationURL: external)
        let externalInspection = try inspector.inspect(
            linkURL: externalLink,
            relation: relation,
            canonicalTargetPath: canonical.path)
        #expect(externalInspection.classification == .externalLink)

        let brokenLink = root.appendingPathComponent("broken-link")
        try FileManager.default.createSymbolicLink(
            atPath: brokenLink.path,
            withDestinationPath: root.appendingPathComponent("missing").path
        )
        let broken = try inspector.inspect(
            linkURL: brokenLink,
            relation: relation,
            canonicalTargetPath: canonical.path)
        #expect(broken.classification == .brokenLink)
        #expect(broken.observation.nodeKind == .brokenSymbolicLink)

        let managedLink = root.appendingPathComponent("managed-link")
        try FileManager.default.createSymbolicLink(atPath: managedLink.path, withDestinationPath: "canonical")
        let managed = try inspector.inspect(linkURL: managedLink, relation: relation, canonicalTargetPath: canonical.path)
        #expect(managed.classification == .exactManagedLink)
        // Recreating the same relation does not require its previous creation history.
        try FileManager.default.removeItem(at: managedLink)
        try FileManager.default.createSymbolicLink(at: managedLink, withDestinationURL: canonical)
        #expect(try inspector.inspect(linkURL: managedLink, relation: relation, canonicalTargetPath: canonical.path).classification == .exactManagedLink)
        #expect(RelationOwnershipInspector.classify(observation: managed.observation,
            expectedLinkPath: root.appendingPathComponent("another-name").path,
            canonicalTargetPath: canonical.path) == .externalLink)

        var unreadable = managed.observation
        unreadable.nodeKind = .unreadable
        unreadable.isReadable = false
        unreadable.limitation = "permission-denied"
        #expect(
            RelationOwnershipInspector.classify(
                observation: unreadable,
                expectedLinkPath: managedLink.path,
                canonicalTargetPath: canonical.path) == .unreadable
        )
    }

    @Test func verifierProducesFourValuesFromCurrentCompleteFacts() throws {
        let verifiedInput = canonicalInput()
        #expect(RelationVerifier.verify(verifiedInput).conclusion == .verifiedConsistent)

        var driftedInput = verifiedInput
        driftedInput.bindings.canonicalPath = "/root/local/other"
        #expect(RelationVerifier.verify(driftedInput).conclusion == .drifted)

        var brokenInput = verifiedInput
        brokenInput.observation?.nodeKind = .brokenSymbolicLink
        brokenInput.observation?.resolvedTargetPath = "/root/local/missing"
        brokenInput.bindings.nodeKind = .brokenSymbolicLink
        brokenInput.bindings.resolvedTargetPath = "/root/local/missing"
        brokenInput.bindings.observationDigest = brokenInput.observation?.digest ?? ""
        #expect(RelationVerifier.verify(brokenInput).conclusion == .drifted)

        var unavailableInput = verifiedInput
        unavailableInput.bindings.isReadable = false
        unavailableInput.limitations = ["permission-denied"]
        #expect(RelationVerifier.verify(unavailableInput).conclusion == .currentlyUnverifiable)

        var notVerifiedInput = verifiedInput
        notVerifiedInput.observation = nil
        notVerifiedInput.bindings.observationDigest = ""
        #expect(RelationVerifier.verify(notVerifiedInput).conclusion == .notVerified)

        var disabledVacant = verifiedInput
        disabledVacant.bindings.enablementIntent.isEnabled = false
        let vacant = TargetObservation(
            relation: disabledVacant.relation,
            linkPath: disabledVacant.bindings.linkPath,
            nodeKind: .vacant,
            linkText: nil,
            resolvedTargetPath: nil,
            fileIdentity: nil,
            isReadable: true,
            isWritable: true,
            observedAt: Date(timeIntervalSince1970: 101),
            limitation: nil
        )
        disabledVacant.observation = vacant
        disabledVacant.bindings.nodeKind = vacant.nodeKind
        disabledVacant.bindings.nodeFingerprint = nil
        disabledVacant.bindings.linkText = nil
        disabledVacant.bindings.resolvedTargetPath = nil
        disabledVacant.bindings.observationDigest = vacant.digest
        #expect(RelationVerifier.verify(disabledVacant).conclusion == .verifiedConsistent)

        var disabledExternal = disabledVacant
        let external = TargetObservation(
            relation: disabledExternal.relation,
            linkPath: disabledExternal.bindings.linkPath,
            nodeKind: .symbolicLink,
            linkText: "/external/review",
            resolvedTargetPath: "/external/review",
            fileIdentity: TargetFileIdentity(volumeNumber: 12, fileNumber: 30),
            isReadable: true,
            isWritable: true,
            observedAt: Date(timeIntervalSince1970: 102),
            limitation: nil
        )
        disabledExternal.observation = external
        disabledExternal.bindings.nodeKind = external.nodeKind
        disabledExternal.bindings.nodeFingerprint = external.fileIdentity?.fingerprint
        disabledExternal.bindings.linkText = external.linkText
        disabledExternal.bindings.resolvedTargetPath = external.resolvedTargetPath
        disabledExternal.bindings.observationDigest = external.digest
        #expect(RelationVerifier.verify(disabledExternal).conclusion == .verifiedConsistent)
    }

    @Test func everyBoundFactChangeInvalidatesPreviouslyVerifiedConsistency() throws {
        let input = canonicalInput()
        let record = RelationVerifier.verify(input)
        #expect(record.conclusion == .verifiedConsistent)

        var staleEvidence = input
        staleEvidence.bindings.enablementIntent.isEnabled = false
        let vacant = TargetObservation(
            relation: input.relation,
            linkPath: input.bindings.linkPath,
            nodeKind: .vacant,
            linkText: nil,
            resolvedTargetPath: nil,
            fileIdentity: nil,
            isReadable: true,
            isWritable: true,
            observedAt: Date(timeIntervalSince1970: 101),
            limitation: nil
        )
        staleEvidence.observation = vacant
        staleEvidence.bindings.nodeKind = vacant.nodeKind
        staleEvidence.bindings.nodeFingerprint = nil
        staleEvidence.bindings.linkText = nil
        staleEvidence.bindings.resolvedTargetPath = nil
        staleEvidence.bindings.observationDigest = vacant.digest
        #expect(RelationVerifier.verify(staleEvidence).conclusion == .verifiedConsistent)

        let mutations: [(inout RelationVerificationInput) -> Void] = [
            { $0.bindings.rootGeneration += 1 },
            { $0.bindings.assetRevision = "revision-v2" },
            { $0.bindings.manifestDigest = "manifest-v2" },
            { $0.bindings.canonicalPath = "/root/local/renamed" },
            { $0.bindings.canonicalPathFingerprint = "canonical-v2" },
            { $0.bindings.profileID = "skillshub.agent-profile.codex.global.changed" },
            { $0.bindings.profileVersion += 1 },
            { $0.bindings.profileSchemaVersion += 1 },
            { $0.bindings.profileIsValid = false },
            { $0.bindings.agentExists = false },
            { $0.bindings.globalTargetPath = "/agent-v2" },
            { $0.bindings.authorizationFingerprint = "authorization-v2" },
            { $0.bindings.targetIsAuthorized = false },
            { $0.bindings.isReadable = false },
            { $0.bindings.isWritable = false },
            { $0.bindings.linkPath = "/agent/review-v2" },
            { $0.bindings.nodeKind = .brokenSymbolicLink },
            { $0.bindings.nodeFingerprint = "node-v2" },
            { $0.bindings.linkText = "../other" },
            { $0.bindings.resolvedTargetPath = "/root/local/other" },
            { $0.bindings.observationDigest = "observation-v2" },
            { $0.bindings.enablementIntent.isEnabled.toggle() },
            { $0.bindings.enablementIntent.generation += 1 },
            { $0.limitations.append("permission-changed") }
        ]

        for mutate in mutations {
            var changed = input
            mutate(&changed)
            #expect(RelationVerifier.consume(record, against: changed) != .verifiedConsistent)
        }
    }
}

private func canonicalInput() -> RelationVerificationInput {
    let relation = canonicalRelation()
    let identity = TargetFileIdentity(volumeNumber: 11, fileNumber: 29)
    var observation = TargetObservation(
        relation: relation,
        linkPath: "/agent/review",
        nodeKind: .symbolicLink,
        linkText: "/root/local/review",
        resolvedTargetPath: "/root/local/review",
        fileIdentity: identity,
        isReadable: true,
        isWritable: true,
        observedAt: Date(timeIntervalSince1970: 100),
        limitation: nil
    )
    var nodeStatus = stat()
    nodeStatus.st_dev = 11
    nodeStatus.st_ino = 29
    nodeStatus.st_mode = mode_t(S_IFLNK)
    nodeStatus.st_birthtimespec.tv_sec = 90
    let nodeIdentity = LinkNodeIdentity(nodeStatus)
    observation.nodeIdentity = nodeIdentity
    nodeStatus.st_ino = 28
    nodeStatus.st_mode = mode_t(S_IFDIR)
    observation.parentIdentity = LinkNodeIdentity(nodeStatus)
    let intent = EnablementIntent(
        assetID: relation.assetID,
        agentID: relation.agentID,
        scope: relation.scope,
        isEnabled: true,
        generation: 4
    )
    let bindings = RelationVerificationBindings(
        rootGeneration: 4,
        assetRevision: "revision-v1",
        manifestDigest: "manifest-v1",
        canonicalPath: "/root/local/review",
        canonicalPathFingerprint: "canonical-v1",
        profileID: "skillshub.agent-profile.codex.global",
        profileVersion: 1,
        profileSchemaVersion: 1,
        profileIsValid: true,
        agentExists: true,
        globalTargetPath: "/agent",
        authorizationFingerprint: "authorization-v1",
        targetIsAuthorized: true,
        isReadable: true,
        isWritable: true,
        linkPath: observation.linkPath,
        nodeKind: observation.nodeKind,
        nodeFingerprint: observation.fileIdentity?.fingerprint,
        linkText: observation.linkText,
        resolvedTargetPath: observation.resolvedTargetPath,
        observationDigest: observation.digest,
        enablementIntent: intent
    )
    return RelationVerificationInput(
        relation: relation,
        bindings: bindings,
        observation: observation,
        limitations: []
    )
}

private func canonicalRelation() -> AgentRelationIdentity {
    AgentRelationIdentity(
        assetID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        agentID: AgentKind.codex.rawValue,
        scope: .global
    )
}
