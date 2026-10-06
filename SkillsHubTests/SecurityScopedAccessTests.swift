import Foundation
import Testing
@testable import SkillsHub

@MainActor
struct SecurityScopedAccessTests {
    @Test func successfulStartCreatesTraceableLeaseAndOneStop() throws {
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let provider = SecurityScopedAccessProvider(adapter: adapter)
        let url = URL(fileURLWithPath: "/test/root", isDirectory: true)
        let owner = SecurityScopedAccessOwner.rootSession(UUID())

        let lease = try provider.acquire(url: url, owner: owner)

        #expect(lease.owner == owner)
        #expect(lease.url == url.standardizedFileURL)
        #expect(adapter.startRecords == [.init(url: url.standardizedFileURL, owner: owner)])
        #expect(lease.end(by: owner) == .stopped)
        #expect(adapter.stoppedURLs == [url.standardizedFileURL])
    }

    @Test func failedStartDoesNotCreateLeaseOrStop() {
        let adapter = RecordingSecurityScopedResourceAccessAdapter(allowsStart: false)
        let provider = SecurityScopedAccessProvider(adapter: adapter)
        let url = URL(fileURLWithPath: "/test/denied", isDirectory: true)
        let owner = SecurityScopedAccessOwner.inspection(UUID())

        #expect(throws: SecurityScopedAccessError.startDenied(path: url.path, ownerIdentity: owner.identity)) {
            _ = try provider.acquire(url: url, owner: owner)
        }
        #expect(adapter.stoppedURLs.isEmpty)
    }

    @Test func repeatedEndIsNotASecondSuccessfulStop() throws {
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let provider = SecurityScopedAccessProvider(adapter: adapter)
        let owner = SecurityScopedAccessOwner.source(UUID())
        let lease = try provider.acquire(
            url: URL(fileURLWithPath: "/test/source", isDirectory: true),
            owner: owner
        )

        #expect(lease.end(by: owner) == .stopped)
        #expect(lease.end(by: owner) == .alreadyStopped)
        #expect(adapter.stoppedURLs.count == 1)
    }

    @Test func onlyTheBoundOwnerCanEndLease() throws {
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let provider = SecurityScopedAccessProvider(adapter: adapter)
        let owner = SecurityScopedAccessOwner.operation(UUID())
        let otherOwner = SecurityScopedAccessOwner.operation(UUID())
        let lease = try provider.acquire(
            url: URL(fileURLWithPath: "/test/operation", isDirectory: true),
            owner: owner
        )

        #expect(
            lease.end(by: otherOwner) == .ownerMismatch(
                expectedOwnerIdentity: owner.identity,
                attemptedOwnerIdentity: otherOwner.identity
            )
        )
        #expect(adapter.stoppedURLs.isEmpty)
        #expect(lease.end(by: owner) == .stopped)
    }

    @Test func ownerLifetimeEndStopsAnActiveLease() throws {
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let provider = SecurityScopedAccessProvider(adapter: adapter)
        let url = URL(fileURLWithPath: "/test/lifetime", isDirectory: true)

        weak var weakLease: SecurityScopedAccessLease?
        do {
            let lease = try provider.acquire(url: url, owner: .inspection(UUID()))
            weakLease = lease
        }

        #expect(weakLease == nil)
        #expect(adapter.stoppedURLs == [url.standardizedFileURL])
    }

    @Test func failedStopBecomesDiagnosticUnknownAndIsNotRetried() throws {
        let adapter = RecordingSecurityScopedResourceAccessAdapter(stopError: ProbeError.stopFailed)
        let provider = SecurityScopedAccessProvider(adapter: adapter)
        let owner = SecurityScopedAccessOwner.operation(UUID())
        let lease = try provider.acquire(
            url: URL(fileURLWithPath: "/test/unknown", isDirectory: true),
            owner: owner
        )

        #expect(lease.end(by: owner) == .stopFailed)
        #expect(lease.end(by: owner) == .stopStatusUnknown)
        #expect(lease.stopFailureDescription?.contains("stopFailed") == true)
        #expect(adapter.stopAttemptCount == 1)
    }

    @Test func selectedInspectionTransitionsToRootSessionAndTerminationStopsSession() async throws {
        let root = try temporaryDirectory()
        try SkillsHubMetadataStore().save(
            SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)),
            to: root
        )
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let store = AccessBookmarkStoreStub()
        var controller: SkillsHubLibraryController? = SkillsHubLibraryController(
            startupAccessStore: store,
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: adapter)
        )

        try controller?.rememberUserSelectedAccess(to: root)
        try await controller?.connectSelectedRoot(root)
        await controller?.waitForPendingRechecks()
        await controller?.waitForPresentationObservation()

        #expect(adapter.startRecords.filter { $0.owner.isRootSession }.count == 1)
        #expect(adapter.startRecords[0].owner.isInspection)
        #expect(adapter.activeAccessCount == 1)
        #expect(controller?.rootURL == root.standardizedFileURL)

        await controller?.waitForPendingRechecks()
        await controller?.waitForPresentationObservation()
        controller = nil

        #expect(adapter.activeAccessCount == 0)
    }

    @Test func explicitRootEstablishmentUsesDistinctOperationAndSessionLeases() async throws {
        let root = try temporaryDirectory()
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        var controller: SkillsHubLibraryController? = SkillsHubLibraryController(
            startupAccessStore: AccessBookmarkStoreStub(),
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: adapter)
        )

        try controller?.rememberUserSelectedAccess(to: root)
        await controller?.establishSelectedRoot(root)
        let operationID = try #require(controller?.phase1Tasks.first?.id)

        #expect(controller?.rootURL == root.standardizedFileURL)
        #expect(controller?.rootSnapshot?.generation == 0)
        #expect(controller?.pendingRootInitialization == nil)
        #expect(controller?.errorMessage == nil)
        await controller?.waitForPendingRechecks()
        await controller?.waitForPresentationObservation()
        #expect(adapter.startRecords.filter { $0.owner == .operation(operationID) }.count == 1)
        #expect(adapter.startRecords.filter { $0.owner.isRootSession }.count == 1)
        #expect(adapter.activeAccessCount == 1)
        controller = nil
        #expect(adapter.activeAccessCount == 0)
    }

    @Test func rootActivationStartsObservationAndSwitchReSubscribesWithNewSession() async throws {
        let rootA = try temporaryDirectory()
        let rootB = try temporaryDirectory()
        for root in [rootA, rootB] {
            try SkillsHubMetadataStore().save(
                SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)),
                to: root
            )
        }
        let fakeHome = try temporaryDirectory()
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        var streams: [FakeFilesystemEventStream] = []
        let controller = SkillsHubLibraryController(
            agentHomeDirectory: fakeHome,
            agentEnvironment: [:],
            startupAccessStore: AccessBookmarkStoreStub(),
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: adapter),
            filesystemEventStreamFactory: {
                let stream = FakeFilesystemEventStream()
                streams.append(stream)
                return stream
            }
        )

        try controller.rememberUserSelectedAccess(to: rootA)
        try await controller.connectSelectedRoot(rootA)
        #expect(controller.rootURL == rootA.standardizedFileURL)
        #expect(controller.observation.isObserving)
        #expect(controller.observationStatus == .observing)
        let firstStream = try #require(streams.first)
        #expect(firstStream.startCount == 1)
        #expect(firstStream.startedPaths.contains(rootA.standardizedFileURL.path))
        let firstSessionLease = try #require(controller.rootSessionLease)

        // Switch to Root B: the previous stream is stopped and a new rootSession lease is
        // established for the new subscription.
        try controller.rememberUserSelectedAccess(to: rootB)
        try await controller.connectSelectedRoot(rootB)

        #expect(controller.rootURL == rootB.standardizedFileURL)
        #expect(firstStream.stopCount >= 1)
        #expect(streams.count == 2)
        #expect(streams[1].startCount == 1)
        #expect(streams[1].startedPaths.contains(rootB.standardizedFileURL.path))
        let secondSessionLease = try #require(controller.rootSessionLease)
        #expect(secondSessionLease.id != firstSessionLease.id)
        // The old rootSession lease was released when the Root switched.
        #expect(adapter.stoppedURLs.contains(rootA.standardizedFileURL))
    }

    @Test func rootSessionStartFailureAfterEstablishmentDoesNotActivateRoot() async throws {
        let root = try temporaryDirectory()
        let adapter = RecordingSecurityScopedResourceAccessAdapter(
            startResults: [true, true, false]
        )
        let controller = SkillsHubLibraryController(
            startupAccessStore: AccessBookmarkStoreStub(),
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: adapter)
        )

        try controller.rememberUserSelectedAccess(to: root)
        await controller.establishSelectedRoot(root)
        let operationID = try #require(controller.phase1Tasks.first?.id)

        #expect(
            adapter.startRecords.map(\.owner) == [
                .inspection(try #require(adapter.startRecords.first?.owner.inspectionID)),
                .operation(operationID),
                .rootSession(try #require(adapter.startRecords.last?.owner.rootSessionID))
            ]
        )
        #expect(controller.hasRoot == false)
        #expect(controller.rootSnapshot == nil)
        #expect(controller.errorMessage?.template == "Folder permission was denied: %@")
        #expect(controller.errorMessage?.arguments == [root.path])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".skillshub.json").path))
        #expect(adapter.stoppedURLs == [root.standardizedFileURL, root.standardizedFileURL])
    }

    @Test func rootSwitchStopsPreviousSessionAndFailedSwitchStopsOnlyNewSession() async throws {
        let firstRoot = try temporaryDirectory()
        let secondRoot = try temporaryDirectory()
        try SkillsHubMetadataStore().save(
            SkillsHubMetadata(rootConfig: RootConfig(rootPath: firstRoot.path)),
            to: firstRoot
        )
        try SkillsHubMetadataStore().save(
            SkillsHubMetadata(rootConfig: RootConfig(rootPath: secondRoot.path)),
            to: secondRoot
        )
        let invalidRoot = firstRoot.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: invalidRoot)
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let controller = SkillsHubLibraryController(
            startupAccessStore: AccessBookmarkStoreStub(),
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: adapter)
        )

        try await controller.connectExistingRoot(firstRoot)
        try await controller.connectExistingRoot(secondRoot)
        await controller.waitForPendingRechecks()
        await controller.waitForPresentationObservation()

        #expect(adapter.startRecords.map(\.owner).filter(\.isRootSession).count == 2)
        #expect(adapter.startRecords.map(\.owner).filter(\.isInspection).count >= 2)
        #expect(adapter.activeAccessCount == 1)

        do {
            try await controller.connectExistingRoot(invalidRoot)
            Issue.record("A regular file cannot become a Root session.")
        } catch {
            // Expected: activation failed after acquiring the candidate Root lease.
        }
        #expect(controller.rootURL == secondRoot.standardizedFileURL)
        #expect(adapter.activeAccessCount == 1)
        #expect(adapter.stoppedURLs.contains(invalidRoot))
    }

    @Test func staleBookmarkRefreshUsesInspectionLeaseAndReleasesIt() throws {
        let directory = try temporaryDirectory()
        let store = AccessBookmarkStoreStub(restorablePaths: [directory.path], stalePaths: [directory.path])
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let controller = SkillsHubLibraryController(
            startupAccessStore: store,
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: adapter)
        )

        #expect(try controller.inspectPersistedAccess(to: directory))

        #expect(store.savedPaths == [directory.standardizedFileURL.path])
        #expect(adapter.startRecords.count == 1)
        #expect(adapter.startRecords[0].owner.isInspection)
        #expect(adapter.stoppedURLs == [directory.standardizedFileURL])
    }

    @MainActor
    @Test(arguments: [AgentKind.codex, .claudeCode])
    func agentTargetAccessIsBoundToOneActionOwnerAndStopsExactlyOnce(agent: AgentKind) throws {
        let home = try temporaryDirectory()
        let target = agentSkillsTarget(for: agent, home: home)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = AccessBookmarkStoreStub(restorablePaths: [target.path])
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let controller = SkillsHubLibraryController(
            agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation),
            agentHomeDirectory: home,
            agentEnvironment: [:],
            startupAccessStore: store,
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: adapter)
        )
        controller.agentDetections = [agentDetection(agent, target: target)]
        let actionID = UUID()
        let otherActionID = UUID()

        let access = try controller.acquireAgentTargetAccess(agent: agent, actionID: actionID)

        #expect(access.owner == .agentTarget(actionID: actionID, agent: agent))
        #expect(access.qualification.allowsManagedWrite)
        #expect(access.end(by: otherActionID) == .ownerMismatch(
            expectedOwnerIdentity: access.owner.identity,
            attemptedOwnerIdentity: SecurityScopedAccessOwner.agentTarget(actionID: otherActionID, agent: agent).identity
        ))
        #expect(access.end(by: actionID) == .stopped)
        #expect(access.end(by: actionID) == .alreadyStopped)
        #expect(adapter.startRecords.map(\.owner) == [access.owner])
        #expect(adapter.stoppedURLs == [target.standardizedFileURL])
    }

    @MainActor
    @Test(arguments: [AgentKind.codex, .claudeCode])
    func agentTargetActionLifetimeEndStopsActiveAccess(agent: AgentKind) throws {
        let home = try temporaryDirectory()
        let target = agentSkillsTarget(for: agent, home: home)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = AccessBookmarkStoreStub(restorablePaths: [target.path])
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let controller = SkillsHubLibraryController(
            agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation),
            agentHomeDirectory: home,
            agentEnvironment: [:],
            startupAccessStore: store,
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: adapter)
        )
        controller.agentDetections = [agentDetection(agent, target: target)]

        do {
            let access = try controller.acquireAgentTargetAccess(agent: agent, actionID: UUID())
            #expect(access.qualification.allowsManagedWrite)
        }

        #expect(adapter.startRecords.count == 1)
        #expect(adapter.stoppedURLs == [target.standardizedFileURL])
    }

    @MainActor
    @Test(arguments: [AgentKind.codex, .claudeCode], [false, true])
    func invalidAgentTargetAccessDoesNotLeakAStartedLease(
        agent: AgentKind,
        bookmarkIsStale: Bool
    ) throws {
        let home = try temporaryDirectory()
        let target = agentSkillsTarget(for: agent, home: home)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = AccessBookmarkStoreStub(
            restorablePaths: bookmarkIsStale ? [target.path] : [],
            stalePaths: bookmarkIsStale ? [target.path] : []
        )
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let controller = SkillsHubLibraryController(
            agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation),
            agentHomeDirectory: home,
            agentEnvironment: [:],
            startupAccessStore: store,
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: adapter)
        )
        controller.agentDetections = [agentDetection(agent, target: target)]

        #expect(throws: AgentTargetAccessError.qualificationFailed(bookmarkIsStale ? .bookmarkStale : .permissionRequired)) {
            try controller.acquireAgentTargetAccess(agent: agent, actionID: UUID())
        }
        #expect(adapter.startRecords.isEmpty)
        #expect(adapter.stoppedURLs.isEmpty)
    }

    @MainActor
    @Test(arguments: [AgentKind.codex, .claudeCode])
    func agentTargetLeaseStartFailureCreatesNoLeaseOrStop(agent: AgentKind) throws {
        let home = try temporaryDirectory()
        let target = agentSkillsTarget(for: agent, home: home)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = AccessBookmarkStoreStub(restorablePaths: [target.path])
        let adapter = RecordingSecurityScopedResourceAccessAdapter(allowsStart: false)
        let controller = SkillsHubLibraryController(
            agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation),
            agentHomeDirectory: home,
            agentEnvironment: [:],
            startupAccessStore: store,
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: adapter)
        )
        controller.agentDetections = [agentDetection(agent, target: target)]

        #expect(throws: AgentTargetAccessError.leaseUnavailable) {
            try controller.acquireAgentTargetAccess(agent: agent, actionID: UUID())
        }
        #expect(adapter.startRecords.count == 1)
        #expect(adapter.stoppedURLs.isEmpty)
    }

    @Test func sourceImportReleasesPartialLeasesAndCanRetryWithFreshAuthorization() async throws {
        let fixture = try await ControllerAccessFixture()
        defer { fixture.remove() }
        try fixture.controller.rememberUserSelectedAccess(to: fixture.source)
        fixture.adapter.denyStart = { url, owner in
            if case .operation = owner { return url == fixture.source }; return false
        }
        await fixture.controller.importLocalSource(from: fixture.source)

        let operationStarts = fixture.adapter.startRecords.filter { if case .operation = $0.owner { return true }; return false }
        #expect(operationStarts.count == 2)
        #expect(fixture.adapter.stoppedURLs.last == fixture.root)
        #expect(fixture.controller.errorMessage != nil)
        #expect(fixture.controller.sources.isEmpty)

        fixture.adapter.denyStart = nil
        try fixture.controller.rememberUserSelectedAccess(to: fixture.source)
        await fixture.controller.importLocalSource(from: fixture.source)
        await fixture.controller.waitForPendingRechecks()
        await fixture.controller.waitForPresentationObservation()
        let operationID = try #require(fixture.controller.phase1Tasks.first?.id)
        let successfulStarts = fixture.adapter.startRecords.filter { $0.owner == .operation(operationID) }
        #expect(successfulStarts.map(\.url) == [fixture.root, fixture.source])
        #expect(fixture.controller.phase1Tasks.first?.phase == .completed)
        #expect(fixture.controller.sources.count == 1)
        #expect(fixture.adapter.activeAccessCount == 1)
    }
}

private enum ProbeError: Error {
    case stopFailed
}

private func agentDetection(_ agent: AgentKind, target: URL) -> AgentDetectionSnapshot {
    AgentDetectionSnapshot(
        agentID: agent.rawValue,
        agent: agent,
        displayName: agent.displayName,
        markerPath: target.deletingLastPathComponent().path,
        skillsDirectory: target.path,
        detected: true,
        skillsDirectoryExists: true,
        entryCount: 0,
        readable: true,
        writable: true,
        isCustom: false
    )
}

private func agentSkillsTarget(for agent: AgentKind, home: URL) -> URL {
    AgentPathResolver().globalSkillsDirectory(for: agent, environment: [:], homeDirectory: home)
}

nonisolated final class RecordingSecurityScopedResourceAccessAdapter: SecurityScopedResourceAccessing {
    struct StartRecord: Equatable {
        var url: URL
        var owner: SecurityScopedAccessOwner
    }

    let allowsStart: Bool
    let stopError: Error?
    var denyStart: ((URL, SecurityScopedAccessOwner) -> Bool)?
    private(set) var successfulStartCount = 0
    var activeAccessCount: Int { successfulStartCount - stoppedURLs.count }
    private var startResults: [Bool]
    private(set) var startRecords: [StartRecord] = []
    private(set) var stoppedURLs: [URL] = []
    private(set) var stopAttemptCount = 0

    init(allowsStart: Bool = true, stopError: Error? = nil, startResults: [Bool] = []) {
        self.allowsStart = allowsStart
        self.stopError = stopError
        self.startResults = startResults
    }

    func startAccessing(_ url: URL, owner: SecurityScopedAccessOwner) -> Bool {
        startRecords.append(StartRecord(url: url, owner: owner))
        let allowed = denyStart?(url, owner) != true && (startResults.isEmpty ? allowsStart : startResults.removeFirst())
        if allowed { successfulStartCount += 1 }
        return allowed
    }

    func stopAccessing(_ url: URL) throws {
        stopAttemptCount += 1
        if let stopError {
            throw stopError
        }
        stoppedURLs.append(url)
    }
}

extension SecurityScopedAccessOwner {
    var inspectionID: UUID? {
        guard case .inspection(let id) = self else { return nil }
        return id
    }

    var rootSessionID: UUID? {
        guard case .rootSession(let id) = self else { return nil }
        return id
    }

    var isInspection: Bool {
        if case .inspection = self { return true }
        return false
    }

    var isRootSession: Bool {
        if case .rootSession = self { return true }
        return false
    }
}

private final class AccessBookmarkStoreStub: StartupAccessStoring {
    var restorablePaths: Set<String>
    var stalePaths: Set<String>
    private(set) var savedPaths: [String] = []

    init(restorablePaths: Set<String> = [], stalePaths: Set<String> = []) {
        self.restorablePaths = restorablePaths
        self.stalePaths = stalePaths
    }

    func resolveAccess(to url: URL) throws -> StartupAccessBookmarkResolution? {
        let normalized = url.standardizedFileURL
        guard restorablePaths.contains(normalized.path) else {
            return nil
        }
        return StartupAccessBookmarkResolution(
            url: normalized,
            isStale: stalePaths.contains(normalized.path)
        )
    }

    func saveAccess(to url: URL) throws {
        let path = url.standardizedFileURL.path
        savedPaths.append(path)
        restorablePaths.insert(path)
        stalePaths.remove(path)
    }
}

@MainActor
private final class ControllerAccessFixture {
    let base: URL
    let root: URL
    let source: URL
    let adapter: RecordingSecurityScopedResourceAccessAdapter
    let controller: SkillsHubLibraryController

    init(startResults: [Bool] = []) async throws {
        base = try temporaryDirectory()
        root = base.appendingPathComponent("root", isDirectory: true).standardizedFileURL
        source = base.appendingPathComponent("source", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try """
        ---
        name: Lease Fixture
        description: Exercises scoped source access.
        ---
        Body.
        """.write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        adapter = RecordingSecurityScopedResourceAccessAdapter(startResults: startResults)
        controller = SkillsHubLibraryController(
            startupAccessStore: AccessBookmarkStoreStub(),
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: adapter)
        )
        try SkillsHubMetadataStore().save(
            SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)),
            to: root
        )
        try await controller.connectExistingRoot(root)
        await controller.waitForPendingRechecks()
        await controller.waitForPresentationObservation()
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
