import Foundation
import Testing
@testable import SkillsHub

@MainActor
struct RootInspectionTests {
    @Test(arguments: ["connect", "establish", "startup"])
    func invalidMetadataRebuildsThroughRootEntry(entry: String) async throws {
        let home = try temporaryDirectory()
        let root = home.appendingPathComponent("skills-hub", isDirectory: true)
        let store = SkillsHubMetadataStore()
        try store.save(SkillsHubMetadata(generation: 7, rootConfig: RootConfig(rootPath: root.path)), to: root)
        let before = try store.load(from: root)
        let skill = root.appendingPathComponent("local/review", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        let content = Data("---\nname: Review\ndescription: Review changes.\n---\nBody.".utf8)
        try content.write(to: skill.appendingPathComponent("SKILL.md"))
        let repository = root.appendingPathComponent("github/owner/repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try content.write(to: repository.appendingPathComponent("SKILL.md"))
        try Data("invalid JSON".utf8).write(to: root.appendingPathComponent(".skillshub.json"))
        let controller = SkillsHubLibraryController(
            agentHomeDirectory: home, agentEnvironment: [:],
            startupAccessStore: RootInspectionBookmarkStoreStub(authorizedURLs: [root.standardizedFileURL]),
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: RecordingSecurityScopedResourceAccessAdapter())
        )
        switch entry {
        case "startup": try await controller.bootstrapDefaultRootIfPresent()
        case "establish":
            try controller.rememberUserSelectedAccess(to: root)
            await controller.establishSelectedRoot(root)
        default: try await controller.connectExistingRoot(root)
        }
        await controller.waitForPendingRechecks()
        let snapshot = try #require(controller.rootSnapshot)
        #expect(snapshot.metadata.rootConfig.id != before.rootConfig.id)
        #expect(Set(controller.installedSkills.map { URL(fileURLWithPath: $0.installedPath).resolvingSymlinksInPath().path }) == Set([skill, repository].map { $0.resolvingSymlinksInPath().path }))
        #expect(snapshot.metadata.enablementIntents.isEmpty)
        #expect(controller.agentAuditLocalState.managedRelationEvidence.isEmpty)
        #expect(controller.errorMessage == nil)
        #expect(try Data(contentsOf: skill.appendingPathComponent("SKILL.md")) == content)
        try await controller.reloadFromDisk()
        #expect(controller.rootSnapshot?.metadata.rootConfig.id == snapshot.metadata.rootConfig.id)
    }

    @Test func unsettledOperationBlocksRootSwitchAndIdentifiesTheOperation() async throws {
        let firstRoot = try initializedRoot(generation: 0)
        let secondRoot = try initializedRoot(generation: 0)
        let controller = rootInspectionController(adapter: RecordingSecurityScopedResourceAccessAdapter())
        try await controller.connectExistingRoot(firstRoot)
        let tasks = [Phase1OperationPhase.waitingConfirmation, .needsAttention].map { phase in
            Phase1TaskRecord(
                id: UUID(), kind: .registerLocalSource, title: "Historical task", objectID: "source",
                phase: phase, result: "Recorded evidence", planDigest: "recorded", events: [], updatedAt: Date()
            )
        }
        controller.phase1Tasks = tasks
        try await controller.reloadFromDisk()
        #expect(Set(controller.phase1Tasks) == Set(tasks))
        try await controller.connectExistingRoot(firstRoot)
        #expect(Set(controller.phase1Tasks) == Set(tasks))
        await #expect(throws: SkillsHubLibraryFailure.self) {
            try await controller.connectExistingRoot(secondRoot)
        }
        #expect(controller.rootURL == firstRoot.standardizedFileURL)
        #expect(controller.errorMessage == nil)
        controller.phase1Tasks = tasks.map { task in
            var completed = task
            completed.phase = .completed
            return completed
        }
        try await controller.connectExistingRoot(secondRoot)
        #expect(controller.phase1Tasks.isEmpty)
    }

    @Test(arguments: [false, true])
    func reloadPreservesUnsubmittedTaskEvidence(cancelled: Bool) async throws {
        let root = try initializedRoot(generation: 0)
        let source = try temporaryDirectory()
        try "---\nname: Review\ndescription: Review changes.\n---\nBody.".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let controller = rootInspectionController(adapter: RecordingSecurityScopedResourceAccessAdapter())
        try await controller.connectExistingRoot(root)
        try controller.prepareLocalSourceRegistration(from: source)
        if cancelled { await controller.cancelPendingPhase1Operation() }
        let task = try #require(controller.phase1Tasks.first)
        try await controller.reloadFromDisk()
        #expect(controller.phase1Tasks.contains(task))
    }

    #if DEBUG
    @Test func failedSourceFinalEvidenceStillPublishesCurrentMetadata() async throws {
        let root = try initializedRoot(generation: 0)
        let source = try temporaryDirectory()
        try "---\nname: Review\ndescription: Review changes.\n---\nBody.".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let controller = rootInspectionController(adapter: RecordingSecurityScopedResourceAccessAdapter())
        try await controller.connectExistingRoot(root)
        controller.phase1OperationCoordinator = Phase1OperationCoordinator(
            metadataStore: controller.metadataStore, faultInjection: .journal(.final, "source-registered")
        )
        try controller.prepareLocalSourceRegistration(from: source)
        await controller.confirmPendingPhase1Operation()
        let current = try controller.metadataStore.loadCurrentSnapshot(from: root)
        #expect(controller.rootSnapshot == current)
        #expect(controller.sources.count == 1)
        #expect(controller.phase1Tasks.first?.phase == .needsAttention)
    }
    #endif

    @Test func selectionAndCancellationDoNotWriteThenOneEstablishmentActionCompletes() async throws {
        let root = try temporaryDirectory()
        let marker = root.appendingPathComponent("keep.txt")
        try Data("unchanged".utf8).write(to: marker)
        let before = try rootTreeSnapshot(root)
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let controller = rootInspectionController(adapter: adapter)

        try controller.rememberUserSelectedAccess(to: root)
        let result = try await controller.inspectSelectedRoot(root)

        #expect(result == .initializationRequired(.init(url: root.standardizedFileURL)))
        #expect(controller.pendingRootInitialization == nil)
        #expect(controller.pendingPhase1OperationPlan == nil)
        #expect(controller.hasRoot == false)
        #expect(try rootTreeSnapshot(root) == before)
        #expect(adapter.startRecords.count == 1)
        #expect(adapter.startRecords[0].owner.isInspection)
        #expect(adapter.stoppedURLs == [root.standardizedFileURL])

        _ = controller.cancelRootSelection()

        #expect(controller.pendingRootInitialization == nil)
        #expect(controller.pendingPhase1OperationPlan == nil)
        #expect(controller.hasRoot == false)
        #expect(try rootTreeSnapshot(root) == before)
        #expect(adapter.stoppedURLs == [root.standardizedFileURL])

        try controller.rememberUserSelectedAccess(to: root)
        await controller.establishSelectedRoot(root)

        #expect(controller.rootURL == root.standardizedFileURL)
        #expect(controller.rootSnapshot?.generation == 0)
        #expect(controller.pendingPhase1OperationPlan == nil)
        #expect(controller.errorMessage == nil)
        #expect(try Data(contentsOf: marker) == Data("unchanged".utf8))
    }

    @Test func selectingExistingRootPreservesBytesGenerationAndTreeThenStartsRootSession() async throws {
        let root = try temporaryDirectory()
        let store = SkillsHubMetadataStore()
        try store.save(
            SkillsHubMetadata(
                generation: 7,
                rootConfig: RootConfig(rootPath: root.standardizedFileURL.path)
            ),
            to: root
        )
        try SkillsHubLocalStateStore().save(SkillsHubLocalState(), to: root)
        try Data().write(to: store.rootLayout(for: root).operationJournalFile)
        let metadataFile = store.rootLayout(for: root).skillshubMetadataFile
        let metadataBefore = try Data(contentsOf: metadataFile)
        let treeBefore = try rootTreeSnapshot(root)
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        var controller: SkillsHubLibraryController? = rootInspectionController(adapter: adapter)

        try controller?.rememberUserSelectedAccess(to: root)
        try await controller?.connectSelectedRoot(root)
        let result = try #require(controller?.lastRootInspectionResult)

        guard case .existingRoot(let facts) = result else {
            Issue.record("Expected an existing Root classification.")
            return
        }
        #expect(facts.url == root.standardizedFileURL)
        #expect(facts.snapshot?.generation == 7)
        do {
            let firstWindowConsumer = try #require(controller)
            let secondWindowConsumer = firstWindowConsumer
            #expect(firstWindowConsumer === secondWindowConsumer)
            #expect(firstWindowConsumer.rootSnapshot?.generation == 7)
            #expect(secondWindowConsumer.rootSnapshot?.generation == 7)
            #expect(firstWindowConsumer.rootURL == root.standardizedFileURL)
        }
        #expect(try Data(contentsOf: metadataFile) == metadataBefore)
        #expect(try rootTreeSnapshot(root) == treeBefore)
        await controller?.waitForPendingRechecks()
        await controller?.waitForPresentationObservation()
        #expect(adapter.startRecords.filter { $0.owner.isRootSession }.count == 1)
        #expect(adapter.activeAccessCount == 1)

        controller = nil
        #expect(adapter.activeAccessCount == 0)
    }

    @Test func inspectionReportsInvalidNodeAndInitializationWithoutWriting() async throws {
        let container = try temporaryDirectory()
        let regularFile = container.appendingPathComponent("not-a-root")
        try Data("file".utf8).write(to: regularFile)
        let invalidAdapter = RecordingSecurityScopedResourceAccessAdapter()
        let invalidController = rootInspectionController(adapter: invalidAdapter)

        try invalidController.rememberUserSelectedAccess(to: regularFile)
        let invalidResult = try await invalidController.inspectSelectedRoot(regularFile)

        #expect(invalidResult == .invalid(.notDirectory(path: regularFile.standardizedFileURL.path)))
        #expect(invalidController.hasRoot == false)
        #expect(invalidAdapter.startRecords.count == 1)
        #expect(invalidAdapter.stoppedURLs == [regularFile.standardizedFileURL])

        let root = try temporaryDirectory()
        let store = SkillsHubMetadataStore()
        try store.save(SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)), to: root)
        let metadataFile = store.rootLayout(for: root).skillshubMetadataFile
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadataFile)) as? [String: Any])
        json["schemaVersion"] = 999
        let invalidBytes = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try invalidBytes.write(to: metadataFile, options: .atomic)
        let treeBefore = try rootTreeSnapshot(root)
        let schemaAdapter = RecordingSecurityScopedResourceAccessAdapter()
        let schemaController = rootInspectionController(adapter: schemaAdapter)

        try schemaController.rememberUserSelectedAccess(to: root)
        let schemaResult = try await schemaController.inspectSelectedRoot(root)

        #expect(schemaResult == .initializationRequired(.init(url: root.standardizedFileURL)))
        #expect(schemaController.hasRoot == false)
        #expect(try Data(contentsOf: metadataFile) == invalidBytes)
        #expect(try rootTreeSnapshot(root) == treeBefore)
        #expect(schemaAdapter.startRecords.count == 1)
        #expect(schemaAdapter.stoppedURLs == [root.standardizedFileURL])
    }

    @Test func inspectionOfMismatchedRootRequiresInitializationWithoutWriting() async throws {
        let root = try temporaryDirectory()
        let store = SkillsHubMetadataStore()
        try store.save(
            SkillsHubMetadata(
                rootConfig: RootConfig(rootPath: root.appendingPathComponent("other").path)
            ),
            to: root
        )
        let metadataFile = store.rootLayout(for: root).skillshubMetadataFile
        let bytesBefore = try Data(contentsOf: metadataFile)
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let controller = rootInspectionController(adapter: adapter)

        try controller.rememberUserSelectedAccess(to: root)
        let result = try await controller.inspectSelectedRoot(root)

        #expect(result == .initializationRequired(.init(url: root.standardizedFileURL)))
        #expect(controller.hasRoot == false)
        #expect(try Data(contentsOf: metadataFile) == bytesBefore)
        #expect(adapter.startRecords.count == 1)
        #expect(adapter.stoppedURLs == [root.standardizedFileURL])
    }

    @Test func cancellationProducesExplicitResultWithoutStartingAccess() {
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let controller = rootInspectionController(adapter: adapter)

        #expect(controller.cancelRootSelection() == .cancelled)
        #expect(controller.hasRoot == false)
        #expect(adapter.startRecords.isEmpty)
        #expect(adapter.stoppedURLs.isEmpty)
    }

    @Test func symbolicLinkRootIsRejectedWithoutFollowingItsTarget() async throws {
        let container = try temporaryDirectory()
        let target = try temporaryDirectory()
        let link = container.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let controller = rootInspectionController(adapter: adapter)

        try controller.rememberUserSelectedAccess(to: link)
        let result = try await controller.inspectSelectedRoot(link)

        #expect(result == .invalid(.symbolicLink(path: link.standardizedFileURL.path)))
        #expect(controller.hasRoot == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect(adapter.startRecords.count == 1)
        #expect(adapter.stoppedURLs == [link.standardizedFileURL])
    }

    /// The first-run establish entry must reach the same pre-check as Settings, with
    /// no initialize-over shortcut for a directory that already holds metadata.





    @Test func rootSessionStartFailurePreservesPreviousSessionAndReleasesNewInspection() async throws {
        let firstRoot = try initializedRoot(generation: 2)
        let secondRoot = try initializedRoot(generation: 4)
        let secondTreeBefore = try rootTreeSnapshot(secondRoot)
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        adapter.denyStart = { url, owner in url == secondRoot.standardizedFileURL && owner.isRootSession }
        let controller = rootInspectionController(adapter: adapter)

        try controller.rememberUserSelectedAccess(to: firstRoot)
        try await controller.connectSelectedRoot(firstRoot)
        await controller.waitForPendingRechecks()
        await controller.waitForPresentationObservation()
        try controller.rememberUserSelectedAccess(to: secondRoot)

        await #expect(throws: SecurityScopedAccessError.self) {
            try await controller.connectSelectedRoot(secondRoot)
        }
        await controller.waitForPendingRechecks()
        await controller.waitForPresentationObservation()

        #expect(controller.rootURL == firstRoot.standardizedFileURL)
        #expect(controller.rootSnapshot?.generation == 2)
        #expect(try rootTreeSnapshot(secondRoot) == secondTreeBefore)
        #expect(adapter.startRecords.filter { $0.owner.isRootSession }.count == 2)
        #expect(adapter.activeAccessCount == 1)
        #expect(adapter.stoppedURLs.contains(secondRoot.standardizedFileURL))
    }
}

@MainActor
private func rootInspectionController(
    adapter: RecordingSecurityScopedResourceAccessAdapter
) -> SkillsHubLibraryController {
    SkillsHubLibraryController(
        agentHomeDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RootInspectionAgentHome-\(UUID().uuidString)"),
        agentEnvironment: [:],
        startupAccessStore: RootInspectionBookmarkStoreStub(),
        securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: adapter)
    )
}

private func initializedRoot(generation: UInt64) throws -> URL {
    let root = try temporaryDirectory()
    try SkillsHubMetadataStore().save(
        SkillsHubMetadata(
            generation: generation,
            rootConfig: RootConfig(rootPath: root.standardizedFileURL.path)
        ),
        to: root
    )
    return root
}

private final class RootInspectionBookmarkStoreStub: StartupAccessStoring {
    var authorizedURLs: Set<URL>

    init(authorizedURLs: Set<URL> = []) { self.authorizedURLs = authorizedURLs }

    func resolveAccess(to url: URL) throws -> StartupAccessBookmarkResolution? {
        guard authorizedURLs.contains(url.standardizedFileURL) else { return nil }
        return StartupAccessBookmarkResolution(url: url.standardizedFileURL, isStale: false)
    }

    func saveAccess(to url: URL) throws { authorizedURLs.insert(url.standardizedFileURL) }
}

private struct RootTreeEntry: Equatable {
    var relativePath: String
    var type: FileAttributeType
    var bytes: Data?
}

private func rootTreeSnapshot(_ root: URL) throws -> [RootTreeEntry] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: [],
        errorHandler: { _, _ in false }
    ) else {
        return []
    }
    return try enumerator.compactMap { value in
        guard let url = value as? URL else { return nil }
        let values = try url.resourceValues(forKeys: Set(keys))
        let type: FileAttributeType
        let bytes: Data?
        if values.isDirectory == true {
            type = .typeDirectory
            bytes = nil
        } else if values.isSymbolicLink == true {
            type = .typeSymbolicLink
            bytes = nil
        } else {
            type = .typeRegular
            bytes = try Data(contentsOf: url)
        }
        return RootTreeEntry(
            relativePath: String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)),
            type: type,
            bytes: bytes
        )
    }.sorted { $0.relativePath < $1.relativePath }
}
