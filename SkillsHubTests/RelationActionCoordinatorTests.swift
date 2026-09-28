import Foundation
import Testing
@testable import SkillsHub

struct RelationActionCoordinatorTests {
    @Test(arguments: ["", ".", "..", "a/b", "a\\b", "a\nb"])
    func linkNameMustBeOneSafePathComponent(_ name: String) {
        let runtime = RelationActionControllerRuntime(
            metadataStore: SkillsHubMetadataStore(),
            localStateStore: SkillsHubLocalStateStore(),
            linkService: AgentLinkService(),
            fileManager: .default
        )

        #expect(throws: ControllerRelationActionError.invalidSkillAlias(name)) {
            try runtime.linkURL(linkName: name, targetDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true))
        }
    }

    @Test func tokenBindsCompleteFactsAndEveryBoundFactChangesItsDigest() throws {
        let fixture = try RelationActionFixture()
        defer { fixture.remove() }
        let access = try fixture.access(actionID: fixture.actionID)
        defer { _ = access.end(by: fixture.actionID) }
        let token = try fixture.token(actionID: fixture.actionID, targetAccess: access)

        #expect(token.actionID == fixture.actionID)
        #expect(token.relation == fixture.relation)
        #expect(token.desiredEnabled)
        #expect(token.facts.rootPath == fixture.root.standardizedFileURL.path)
        #expect(token.facts.metadataGeneration == fixture.snapshot.generation)
        #expect(token.facts.metadataDigest == fixture.snapshot.metadataDigest)
        #expect(token.facts.assetID == fixture.asset.assetID)
        #expect(token.facts.assetRevision == fixture.asset.currentRevision)
        #expect(token.facts.assetManifestDigest == fixture.asset.manifestDigest)
        #expect(token.facts.profileID == fixture.qualification.profileID)
        #expect(token.facts.targetPath == fixture.target.standardizedFileURL.path)
        #expect(token.facts.observationDigest == fixture.builder.observationDigest(of: fixture.observation))
        #expect(token.targetLeaseOwnerIdentity == access.owner.identity)
        #expect(token.factsDigest == fixture.builder.digest(of: fixture.facts))
        #expect(token.tokenDigest == fixture.builder.tokenDigest(
            actionID: fixture.actionID,
            desiredEnabled: true,
            factsDigest: token.factsDigest,
            targetLeaseOwnerIdentity: access.owner.identity
        ))
        #expect(token.tokenDigest != fixture.builder.tokenDigest(
            actionID: UUID(),
            desiredEnabled: true,
            factsDigest: token.factsDigest,
            targetLeaseOwnerIdentity: access.owner.identity
        ))
        #expect(token.tokenDigest != fixture.builder.tokenDigest(
            actionID: fixture.actionID,
            desiredEnabled: false,
            factsDigest: token.factsDigest,
            targetLeaseOwnerIdentity: access.owner.identity
        ))

        let changes: [(inout RelationActionFacts) -> Void] = [
            { $0.relation.agentID = AgentKind.claudeCode.rawValue },
            { $0.rootPath += "-changed" },
            { $0.rootSessionOwnerIdentity += "-changed" },
            { $0.metadataGeneration += 1 },
            { $0.metadataDigest += "-changed" },
            { $0.assetID = UUID() },
            { $0.assetRevision = "revision-2" },
            { $0.assetManifestDigest = "manifest-2" },
            { $0.assetValidationStatus = .invalid },
            { $0.canonicalPath += "-changed" },
            { $0.profileID += "-changed" },
            { $0.profileVersion += 1 },
            { $0.profileSchemaVersion += 1 },
            { $0.agentDetected.toggle() },
            { $0.targetPath += "-changed" },
            { $0.authorizationFingerprint += "-changed" },
            { $0.linkPath += "-changed" },
            { $0.nodeKind = .regularFile },
            { $0.nodeFingerprint = "node-2" },
            { $0.linkText = "elsewhere" },
            { $0.resolvedTargetPath = "/elsewhere" },
            { $0.targetIsReadable.toggle() },
            { $0.targetIsWritable.toggle() },
            { $0.observationLimitation = "limited" },
            { $0.observationDigest += "-changed" },
            { $0.ownership = .unmanagedNode },
            { $0.currentIntent?.isEnabled.toggle() }
        ]
        for change in changes {
            var changed = fixture.facts
            change(&changed)
            #expect(fixture.builder.digest(of: changed) != token.factsDigest)
        }
    }

    @Test func rejectedTokenPreparationReleasesTheAcquiredLease() throws {
        let fixture = try RelationActionFixture()
        defer { fixture.remove() }
        let access = try fixture.access(actionID: fixture.actionID)
        var staleSnapshot = fixture.snapshot
        staleSnapshot.metadata.installedSkills = []

        #expect(throws: RelationActionTokenBuildError.assetSnapshotMismatch) {
            try fixture.builder.build(
                actionID: fixture.actionID,
                desiredEnabled: true,
                relation: fixture.relation,
                rootURL: fixture.root,
                rootSessionOwner: fixture.rootSessionOwner,
                snapshot: staleSnapshot,
                asset: fixture.asset,
                targetAccess: access,
                observation: fixture.observation,
                ownership: .vacant,
                currentIntent: fixture.intent
            )
        }
        #expect(fixture.adapter.stopCount == 1)
        #expect(access.end(by: fixture.actionID) == .alreadyStopped)
    }

    @Test func invalidFormatBlocksCreationButNotCleanup() throws {
        let fixture = try RelationActionFixture()
        defer { fixture.remove() }
        var invalidAsset = fixture.asset
        invalidAsset.validation = SkillValidationResult(status: .invalid, messages: [], risks: [])
        var invalidSnapshot = fixture.snapshot
        invalidSnapshot.metadata.installedSkills = [invalidAsset]

        let createAccess = try fixture.access(actionID: fixture.actionID)
        #expect(throws: RelationActionTokenBuildError.invalidSkillFormat) {
            try fixture.builder.build(
                actionID: fixture.actionID,
                desiredEnabled: true,
                relation: fixture.relation,
                rootURL: fixture.root,
                rootSessionOwner: fixture.rootSessionOwner,
                snapshot: invalidSnapshot,
                asset: invalidAsset,
                targetAccess: createAccess,
                observation: fixture.observation,
                ownership: .vacant,
                currentIntent: fixture.intent
            )
        }

        let cleanupActionID = UUID()
        let cleanupAccess = try fixture.access(actionID: cleanupActionID)
        defer { _ = cleanupAccess.end(by: cleanupActionID) }
        _ = try fixture.builder.build(
            actionID: cleanupActionID,
            desiredEnabled: false,
            relation: fixture.relation,
            rootURL: fixture.root,
            rootSessionOwner: fixture.rootSessionOwner,
            snapshot: invalidSnapshot,
            asset: invalidAsset,
            targetAccess: cleanupAccess,
            observation: fixture.observation,
            ownership: .vacant,
            currentIntent: fixture.intent
        )
    }

    @Test func aFreshObservationTimestampDoesNotInvalidateUnchangedNodeFacts() async throws {
        let fixture = try RelationActionFixture()
        defer { fixture.remove() }
        let access = try fixture.access(actionID: fixture.actionID)
        let token = try fixture.token(actionID: fixture.actionID, targetAccess: access)
        var refreshedObservation = fixture.observation
        refreshedObservation.observedAt = fixture.observation.observedAt.addingTimeInterval(10)
        let refreshedFacts = try fixture.builder.facts(
            relation: fixture.relation,
            rootURL: fixture.root,
            rootSessionOwner: fixture.rootSessionOwner,
            snapshot: fixture.snapshot,
            asset: fixture.asset,
            qualification: fixture.qualification,
            observation: refreshedObservation,
            ownership: .vacant,
            currentIntent: fixture.intent
        )

        let result = await RelationActionCoordinator(rootMutationOwner: RootMutationOwner()).coordinate(
            token: token,
            rootURL: fixture.root,
            targetAccess: access,
            currentFacts: { refreshedFacts },
            perform: { $0.relation.id }
        )

        #expect(result.outcome == .completed(fixture.relation.id))
        #expect(result.leaseRelease == .stopped)
    }

    @Test func concurrentConsumptionExecutesExactlyOnceAndRejectsReplayBeforeWrite() async throws {
        let fixture = try RelationActionFixture()
        defer { fixture.remove() }
        let firstAccess = try fixture.access(actionID: fixture.actionID)
        let replayAccess = try fixture.access(actionID: fixture.actionID)
        let token = try fixture.token(actionID: fixture.actionID, targetAccess: firstAccess)
        let coordinator = RelationActionCoordinator(rootMutationOwner: RootMutationOwner())
        let recorder = RelationActionRecorder()

        async let first = coordinator.coordinate(
            token: token,
            rootURL: fixture.root,
            targetAccess: firstAccess,
            currentFacts: { fixture.facts },
            perform: { authorization in
                await recorder.record(authorization)
                return authorization.relation.id
            }
        )
        async let replay = coordinator.coordinate(
            token: token,
            rootURL: fixture.root,
            targetAccess: replayAccess,
            currentFacts: { fixture.facts },
            perform: { authorization in
                await recorder.record(authorization)
                return authorization.relation.id
            }
        )

        let outcomes = await [first, replay]
        #expect(outcomes.filter(\.outcome.isCompleted).count == 1)
        #expect(outcomes.filter { $0.outcome == .replayed }.count == 1)
        #expect(outcomes.allSatisfy { $0.leaseRelease == .stopped })
        #expect(await recorder.count == 1)
        #expect(fixture.adapter.stopCount == 2)
    }

    @Test func allStaleFactsStopBeforeFirstWriteAndReleaseLease() async throws {
        let fixture = try RelationActionFixture()
        defer { fixture.remove() }
        let cases: [(RelationActionStaleReason, (inout RelationActionFacts) -> Void)] = [
            (.relationChanged, { $0.relation.agentID = AgentKind.claudeCode.rawValue }),
            (.rootSessionInvalidated, { $0.rootSessionOwnerIdentity = SecurityScopedAccessOwner.rootSession(UUID()).identity }),
            (.metadataGenerationChanged, { $0.metadataGeneration += 1 }),
            (.metadataDigestChanged, { $0.metadataDigest += "-changed" }),
            (.factsChanged, { $0.profileVersion += 1 }),
            (.factsChanged, { $0.authorizationFingerprint += "-changed" }),
            (.factsChanged, { $0.observationDigest += "-changed" }),
            (.factsChanged, { $0.currentIntent?.isEnabled.toggle() })
        ]

        for (expectedReason, change) in cases {
            let actionID = UUID()
            let access = try fixture.access(actionID: actionID)
            let token = try fixture.token(actionID: actionID, targetAccess: access)
            var changed = fixture.facts
            change(&changed)
            let recorder = RelationActionRecorder()
            let result = await RelationActionCoordinator(rootMutationOwner: RootMutationOwner()).coordinate(
                token: token,
                rootURL: fixture.root,
                targetAccess: access,
                currentFacts: { changed },
                perform: { authorization in
                    await recorder.record(authorization)
                    return authorization.relation.id
                }
            )

            #expect(result.outcome == .stale(expectedReason))
            #expect(result.leaseRelease == .stopped)
            #expect(await recorder.count == 0)
        }
    }

    @Test func leaseOwnerMismatchBlocksAndReleasesThePresentedLease() async throws {
        let fixture = try RelationActionFixture()
        defer { fixture.remove() }
        let tokenAccess = try fixture.access(actionID: fixture.actionID)
        defer { _ = tokenAccess.end(by: fixture.actionID) }
        let token = try fixture.token(actionID: fixture.actionID, targetAccess: tokenAccess)
        let otherActionID = UUID()
        let mismatchedAccess = try fixture.access(actionID: otherActionID)
        let recorder = RelationActionRecorder()

        let result = await RelationActionCoordinator(rootMutationOwner: RootMutationOwner()).coordinate(
            token: token,
            rootURL: fixture.root,
            targetAccess: mismatchedAccess,
            currentFacts: { fixture.facts },
            perform: { authorization in
                await recorder.record(authorization)
                return authorization.relation.id
            }
        )

        #expect(result.outcome == .blocked(.targetLeaseOwnerMismatch))
        #expect(result.leaseRelease == .stopped)
        #expect(await recorder.count == 0)
    }

    @Test func sameActionLeaseForSubstituteTargetIsBlockedAndReleased() async throws {
        let fixture = try RelationActionFixture()
        defer { fixture.remove() }
        let tokenAccess = try fixture.access(actionID: fixture.actionID)
        defer { _ = tokenAccess.end(by: fixture.actionID) }
        let token = try fixture.token(actionID: fixture.actionID, targetAccess: tokenAccess)
        let substitute = fixture.fixtureRoot.appendingPathComponent("substitute/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: substitute, withIntermediateDirectories: true)
        var substituteQualification = fixture.qualification
        substituteQualification = AgentTargetQualification(
            agentID: substituteQualification.agentID,
            agent: substituteQualification.agent,
            agentDetected: substituteQualification.agentDetected,
            profileID: substituteQualification.profileID,
            profileVersion: substituteQualification.profileVersion,
            schemaVersion: substituteQualification.schemaVersion,
            scope: substituteQualification.scope,
            candidates: [substitute],
            authorizationStatus: .current,
            target: substitute,
            failure: nil
        )
        let substituteLease = try SecurityScopedAccessProvider(adapter: fixture.adapter).acquire(
            url: substitute,
            owner: .agentTarget(actionID: fixture.actionID, agent: .codex)
        )
        let substituteAccess = AgentTargetAccess(
            qualification: substituteQualification,
            lease: substituteLease
        )

        let result = await RelationActionCoordinator(rootMutationOwner: RootMutationOwner()).coordinate(
            token: token,
            rootURL: fixture.root,
            targetAccess: substituteAccess,
            currentFacts: { fixture.facts },
            perform: { $0.relation.id }
        )

        #expect(result.outcome == .blocked(.targetLeaseFactsMismatch))
        #expect(result.leaseRelease == .stopped)
    }

    @Test func failureAndCancellationReleaseTheActionLease() async throws {
        let fixture = try RelationActionFixture()
        defer { fixture.remove() }

        let failedActionID = UUID()
        let failedAccess = try fixture.access(actionID: failedActionID)
        let failedToken = try fixture.token(actionID: failedActionID, targetAccess: failedAccess)
        let failed = await RelationActionCoordinator(rootMutationOwner: RootMutationOwner()).coordinate(
            token: failedToken,
            rootURL: fixture.root,
            targetAccess: failedAccess,
            currentFacts: { fixture.facts },
            perform: { _ -> String in throw RelationActionTestError.injected }
        )
        #expect(failed.outcome == .failed)
        #expect(failed.leaseRelease == .stopped)

        let cancelledActionID = UUID()
        let cancelledAccess = try fixture.access(actionID: cancelledActionID)
        let cancelledToken = try fixture.token(
            actionID: cancelledActionID,
            desiredEnabled: false,
            targetAccess: cancelledAccess
        )
        let cancelled = await RelationActionCoordinator(rootMutationOwner: RootMutationOwner()).coordinate(
            token: cancelledToken,
            rootURL: fixture.root,
            targetAccess: cancelledAccess,
            currentFacts: { throw CancellationError() },
            perform: { _ in "unreachable" }
        )
        #expect(cancelled.outcome == .cancelled)
        #expect(cancelled.leaseRelease == .stopped)
    }
}

private enum RelationActionTestError: Error {
    case injected
}

private actor RelationActionRecorder {
    private(set) var authorizations: [RelationActionAuthorization] = []

    var count: Int { authorizations.count }

    func record(_ authorization: RelationActionAuthorization) {
        authorizations.append(authorization)
    }
}

private final class RelationActionAccessAdapter: SecurityScopedResourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var stops = 0

    var stopCount: Int {
        lock.withLock { stops }
    }

    func startAccessing(_ url: URL, owner: SecurityScopedAccessOwner) -> Bool {
        true
    }

    func stopAccessing(_ url: URL) throws {
        lock.withLock { stops += 1 }
    }
}

private struct RelationActionFixture {
    let fixtureRoot: URL
    let root: URL
    let target: URL
    let actionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let relation: AgentRelationIdentity
    let snapshot: RootSnapshot
    let asset: InstalledSkill
    let qualification: AgentTargetQualification
    let observation: TargetObservation
    let rootSessionOwner: SecurityScopedAccessOwner
    let intent: EnablementIntent
    let facts: RelationActionFacts
    let builder = RelationActionTokenBuilder()
    let adapter = RelationActionAccessAdapter()

    init() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        fixtureRoot = repositoryRoot
            .appendingPathComponent(".tmp/relation-action-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = fixtureRoot.appendingPathComponent("root", isDirectory: true)
        target = fixtureRoot.appendingPathComponent("agent/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let assetID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        relation = AgentRelationIdentity(assetID: assetID, agentID: AgentKind.codex.rawValue, scope: .global)
        asset = InstalledSkill(
            id: "review",
            sourceID: nil,
            name: "Review",
            description: "Reviews changes.",
            installedPath: root.appendingPathComponent("local/review", isDirectory: true).path,
            sourceKind: .localDirectory,
            validation: .valid,
            purpose: nil,
            tagIDs: [],
            installedAt: Date(timeIntervalSince1970: 1),
            assetID: assetID,
            currentRevision: "revision-1",
            manifestDigest: "manifest-1",
            managedGeneration: 4
        )
        intent = EnablementIntent(
            assetID: assetID,
            agentID: AgentKind.codex.rawValue,
            scope: .global,
            isEnabled: false,
            generation: 4
        )
        let metadata = SkillsHubMetadata(
            logicalRevision: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            generation: 4,
            rootConfig: RootConfig(rootPath: root.path),
            installedSkills: [asset],
            enablementIntents: [intent]
        )
        snapshot = RootSnapshot(metadata: metadata, generation: 4, metadataDigest: "metadata-4")
        qualification = AgentTargetQualification(
            agentID: AgentKind.codex.rawValue,
            agent: .codex,
            agentDetected: true,
            profileID: "skillshub.agent-profile.codex.global@1",
            profileVersion: 1,
            schemaVersion: 1,
            scope: .global,
            candidates: [target],
            authorizationStatus: .current,
            target: target,
            failure: nil
        )
        observation = TargetObservation(
            relation: relation,
            linkPath: target.appendingPathComponent("review").path,
            nodeKind: .vacant,
            linkText: nil,
            resolvedTargetPath: nil,
            fileIdentity: nil,
            isReadable: true,
            isWritable: true,
            observedAt: Date(timeIntervalSince1970: 2),
            limitation: nil
        )
        rootSessionOwner = .rootSession(UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!)
        facts = try builder.facts(
            relation: relation,
            rootURL: root,
            rootSessionOwner: rootSessionOwner,
            snapshot: snapshot,
            asset: asset,
            qualification: qualification,
            observation: observation,
            ownership: .vacant,
            currentIntent: intent
        )
    }

    func access(actionID: UUID) throws -> AgentTargetAccess {
        let lease = try SecurityScopedAccessProvider(adapter: adapter).acquire(
            url: target,
            owner: .agentTarget(actionID: actionID, agent: .codex)
        )
        return AgentTargetAccess(qualification: qualification, lease: lease)
    }

    func token(
        actionID: UUID,
        desiredEnabled: Bool = true,
        targetAccess: AgentTargetAccess
    ) throws -> RelationActionToken {
        try builder.build(
            actionID: actionID,
            desiredEnabled: desiredEnabled,
            relation: relation,
            rootURL: root,
            rootSessionOwner: rootSessionOwner,
            snapshot: snapshot,
            asset: asset,
            targetAccess: targetAccess,
            observation: observation,
            ownership: .vacant,
            currentIntent: intent
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }
}

private extension RelationActionOutcome {
    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}
