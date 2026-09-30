import Foundation
import Testing
@testable import SkillsHub

struct RootMutationOwnerTests {
    #if DEBUG
    @Test(.timeLimit(.minutes(1))) @MainActor
    func operationCompletionCannotReplaceAnotherRootSnapshot() async throws {
        let fixture = try RootMutationFixture()
        defer { fixture.remove() }
        let other = try RootMutationFixture()
        defer { other.remove() }
        let owner = RootMutationOwner()
        let gate = RootMutationTestGate()
        let blocker = Task { await owner.perform(at: fixture.root) { await gate.enterAndWait() } }
        await gate.waitUntilEntered()
        let controller = SkillsHubLibraryController(
            appSupportURL: fixture.fixtureRoot.appendingPathComponent("support"),
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: RecordingSecurityScopedResourceAccessAdapter())
        )
        controller.rootURL = fixture.root
        controller.rootSnapshot = try fixture.store.loadCurrentSnapshot(from: fixture.root)
        controller.phase1OperationCoordinator = Phase1OperationCoordinator(metadataStore: fixture.store, rootMutationOwner: owner)
        controller.pendingPhase1OperationPlan = try fixture.planner.sourceRegistrationPlan(
            directory: fixture.source, snapshot: #require(controller.rootSnapshot), sourceID: fixture.sourceID
        )
        let execution = Task { await controller.confirmPendingPhase1Operation() }
        await owner.waitUntilContendedForTesting(at: fixture.root)
        let otherSnapshot = try other.store.loadCurrentSnapshot(from: other.root)
        controller.rootURL = other.root
        controller.rootSnapshot = otherSnapshot
        controller.phase1Tasks = []
        await gate.release()
        await blocker.value
        await execution.value
        #expect(controller.rootSnapshot == otherSnapshot)
        #expect(controller.phase1Tasks.isEmpty)
        #expect(controller.sources.isEmpty)
    }
    #endif

    @Test(.timeLimit(.minutes(1)))
    func writeQualificationRefusesSecondLiveHolderAndReleasesOnExit() async throws {
        let fixture = try RootMutationFixture()
        defer { fixture.remove() }
        let lockFile = fixture.store.rootLayout(for: fixture.root).writeLockFile

        // A live holder occupies the exclusive advisory lock through an independent open file
        // description — the same real contention a second SkillsHub process would create.
        switch RootProcessWriteLock.acquire(at: lockFile) {
        case .success(let holder):
            // While held, a fresh acquisition is refused (kernel EWOULDBLOCK), not queued or timestamped.
            if case .failure(let reason) = RootProcessWriteLock.acquire(at: lockFile) {
                #expect(reason == .heldByAnotherProcess)
            } else {
                Issue.record("expected the second acquisition to be refused while held")
            }
            // The write qualification API surfaces read-only, not a blocked commit.
            let owner = RootMutationOwner(metadataStore: fixture.store)
            var operationRan = false
            let outcome = await owner.withWriteQualification(at: fixture.root) { () -> Bool in
                operationRan = true
                return true
            }
            #expect(operationRan == false)
            #expect(outcome == .writeUnavailable(.heldByAnotherProcess))
            // Releasing the holder (as a process exit would) lets the next request qualify.
            holder.release()
            let after = await owner.withWriteQualification(at: fixture.root) { true }
            #expect(after == .performed(true))
        case .failure(let reason):
            Issue.record("could not establish the initial holder: \(reason)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func writeQualificationLockNodeIsIndependentOfMetadataNode() async throws {
        let fixture = try RootMutationFixture()
        defer { fixture.remove() }
        let layout = fixture.store.rootLayout(for: fixture.root)
        // The lock lives in its own file, so replacing the metadata node cannot drop the qualification.
        #expect(layout.writeLockFile.lastPathComponent == RootLayout.writeLockFileName)
        #expect(layout.writeLockFile.path != layout.skillshubMetadataFile.path)

        let owner = RootMutationOwner(metadataStore: fixture.store)
        // Replacing the metadata node during the qualified operation does not release the lock: a
        // concurrent acquisition against the lock file stays refused for the whole operation.
        let outcome = await owner.withWriteQualification(at: fixture.root) { () -> Bool in
            let replacement = try? Data(contentsOf: layout.skillshubMetadataFile)
            try? replacement?.write(to: layout.skillshubMetadataFile)
            if case .failure(.heldByAnotherProcess) = RootProcessWriteLock.acquire(at: layout.writeLockFile) {
                return true
            }
            return false
        }
        #expect(outcome == .performed(true))
        // After the operation the lock is released, so a new holder can take it.
        if case .success(let holder) = RootProcessWriteLock.acquire(at: layout.writeLockFile) {
            holder.release()
        } else {
            Issue.record("expected the lock to be released after the qualified operation")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func writeQualificationReleasesLockWhenOperationThrows() async throws {
        let fixture = try RootMutationFixture()
        defer { fixture.remove() }
        let layout = fixture.store.rootLayout(for: fixture.root)
        let owner = RootMutationOwner(metadataStore: fixture.store)
        struct SampleError: Error {}
        await #expect(throws: SampleError.self) {
            _ = try await owner.withWriteQualification(at: fixture.root) { () -> Bool in
                throw SampleError()
            }
        }
        // A thrown operation must still release both the in-process slot and the cross-process lock.
        if case .success(let holder) = RootProcessWriteLock.acquire(at: layout.writeLockFile) {
            holder.release()
        } else {
            Issue.record("expected the lock to be released after a thrown operation")
        }
        let after = await owner.withWriteQualification(at: fixture.root) { true }
        #expect(after == .performed(true))
    }

    #if DEBUG
    @Test(.timeLimit(.minutes(1)))
    func directActionAndPhase1PlanShareOneRootSequence() async throws {
        let fixture = try RootMutationFixture()
        defer { fixture.remove() }
        let other = try RootMutationFixture()
        defer { other.remove() }
        let initial = try fixture.store.loadCurrentSnapshot(from: fixture.root)
        let plan = try fixture.planner.sourceRegistrationPlan(
            directory: fixture.source,
            snapshot: initial,
            sourceID: fixture.sourceID
        )
        let owner = RootMutationOwner()
        let directGate = RootMutationTestGate()
        let directAction = RelationMutationProbe(
            owner: owner,
            metadataStore: fixture.store
        )
        let phase1 = Phase1OperationCoordinator(
            metadataStore: fixture.store,
            rootMutationOwner: owner
        )
        let credential = RelationMutationProbeCredential(
            id: UUID(),
            rootPath: fixture.root.standardizedFileURL.path,
            expectedSnapshot: initial
        )

        let directTask = Task {
            await directAction.commit(
                credential: credential,
                rootURL: fixture.root,
                gate: directGate
            )
        }
        await directGate.waitUntilEntered()

        let phase1Task = Task {
            await phase1.commit(
                plan: plan,
                confirmation: fixture.planner.confirmation(for: plan)
            )
        }
        await owner.waitUntilContendedForTesting(at: fixture.root)

        #expect(try fixture.store.loadCurrentSnapshot(from: fixture.root).generation == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.journal.path) == false)

        let otherPlan = try other.planner.sourceRegistrationPlan(
            directory: other.source,
            snapshot: other.store.loadCurrentSnapshot(from: other.root),
            sourceID: other.sourceID
        )
        let otherResult = await phase1.commit(
            plan: otherPlan,
            confirmation: other.planner.confirmation(for: otherPlan)
        )
        #expect(otherResult.succeeded)
        #expect(try fixture.store.loadCurrentSnapshot(from: fixture.root).generation == 0)

        await directGate.release()
        let directResult = await directTask.value
        let phase1Result = await phase1Task.value
        let final = try fixture.store.loadCurrentSnapshot(from: fixture.root)

        #expect(directResult == .committed(generation: 1))
        #expect(phase1Result.succeeded == false)
        #expect(phase1Result.task.phase == .needsAttention)
        #expect(final.generation == 1)
        #expect(final.metadata.tags.map(\.id) == ["direct-action"])
        #expect(final.metadata.sources.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.journal.path) == false)
    }
    #endif
}

private struct RelationMutationProbeCredential: Sendable {
    let id: UUID
    let rootPath: String
    let expectedSnapshot: RootSnapshot
}

private enum RelationMutationProbeResult: Equatable, Sendable {
    case committed(generation: UInt64)
    case rejected
}

private actor RelationMutationProbe {
    let owner: RootMutationOwner
    let metadataStore: SkillsHubMetadataStore

    init(owner: RootMutationOwner, metadataStore: SkillsHubMetadataStore) {
        self.owner = owner
        self.metadataStore = metadataStore
    }

    func commit(
        credential: RelationMutationProbeCredential,
        rootURL: URL,
        gate: RootMutationTestGate
    ) async -> RelationMutationProbeResult {
        await owner.perform(at: rootURL) {
            guard credential.rootPath == rootURL.standardizedFileURL.path else {
                return .rejected
            }
            await gate.enterAndWait()
            do {
                let snapshot = try metadataStore.commit(
                    at: rootURL,
                    expected: credential.expectedSnapshot
                ) { metadata in
                    metadata.tags.append(TagRecord(id: "direct-action", displayName: "Direct action"))
                }
                return .committed(generation: snapshot.generation)
            } catch {
                return .rejected
            }
        }
    }
}

private actor RootMutationTestGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard released == false else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard entered == false else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct RootMutationFixture {
    let fixtureRoot: URL
    let root: URL
    let source: URL
    let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let store = SkillsHubMetadataStore()
    let planner = Phase1OperationPlanner()

    init() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        fixtureRoot = repositoryRoot
            .appendingPathComponent(".tmp/root-mutation-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = fixtureRoot.appendingPathComponent("root", isDirectory: true)
        source = fixtureRoot.appendingPathComponent("source/review", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try """
        ---
        name: Review
        description: Reviews local changes.
        ---
        Body.
        """.write(
            to: source.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try store.save(SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)), to: root)
    }

    var journal: URL {
        store.rootLayout(for: root).operationJournalFile
    }

    func remove() {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }
}
