import Foundation
import Testing
@testable import SkillsHub

@MainActor
struct ReloadConsistencyTests {
    @Test func rootSwitchAndMetadataRebuildPreserveAppLanguageAndSkillBytes() async throws {
        let rootA = try reloadTemporaryDirectory()
        let rootB = try reloadTemporaryDirectory()
        let suiteName = "ReloadConsistencyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let skillA = rootA.appendingPathComponent("local/alpha", isDirectory: true)
        let skillB = rootB.appendingPathComponent("local/beta", isDirectory: true)
        try writeReloadSkill(skillA, name: "Alpha")
        try writeReloadSkill(skillB, name: "Beta")
        let skillABytes = try Data(contentsOf: skillA.appendingPathComponent("SKILL.md"))
        let skillBBytes = try Data(contentsOf: skillB.appendingPathComponent("SKILL.md"))
        let preferences = AppLanguagePreferences(defaults: defaults)
        preferences.language = .chinese
        let controller = SkillsHubLibraryController(languagePreferences: preferences)
        try SkillsHubMetadataStore().save(
            SkillsHubMetadata(
                rootConfig: RootConfig(rootPath: rootA.path, languageOverride: AppLanguage.japanese.rawValue)
            ),
            to: rootA
        )

        try connectInitializedTestRoot(controller, at: rootA)
        await controller.waitForPendingRechecks()
        #expect(controller.language == .chinese)
        #expect(controller.installedSkills.map(\.id) == ["alpha"])

        try connectInitializedTestRoot(controller, at: rootB)
        await controller.waitForPendingRechecks()
        #expect(controller.language == .chinese)
        #expect(controller.installedSkills.map(\.id) == ["beta"])

        let metadataFile = SkillsHubMetadataStore().rootLayout(for: rootA).skillshubMetadataFile
        try Data("invalid metadata".utf8).write(to: metadataFile)
        try controller.connectExistingRoot(rootA)
        await controller.waitForPendingRechecks()

        #expect(controller.language == .chinese)
        #expect(controller.installedSkills.map(\.id) == ["alpha"])
        #expect(controller.agentLinks.isEmpty)
        #expect(try Data(contentsOf: skillA.appendingPathComponent("SKILL.md")) == skillABytes)
        #expect(try Data(contentsOf: skillB.appendingPathComponent("SKILL.md")) == skillBBytes)
    }

    @Test func linkedRecoveryDirectoryIsReportedUnknownWithoutFollowingIt() throws {
        let root = try reloadTemporaryDirectory()
        let external = try reloadTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let operationID = UUID()
        let operations = root.appendingPathComponent(".skillshub-operations", isDirectory: true)
        try FileManager.default.createDirectory(at: operations, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: external.appendingPathComponent("marker"))
        try FileManager.default.createSymbolicLink(
            at: operations.appendingPathComponent(operationID.uuidString),
            withDestinationURL: external
        )
        let controller = SkillsHubLibraryController()

        try connectInitializedTestRoot(controller, at: root)

        let task = try #require(controller.phase1Tasks.first { $0.id == operationID })
        #expect(task.phase == .needsAttention)
        let component = try #require(task.recoveryEvidence?.components.first)
        #expect(component.kind == "operation-materials")
        #expect(component.state == .unknown)
        #expect(component.path == operations.appendingPathComponent(operationID.uuidString).path)
        #expect(try String(contentsOf: external.appendingPathComponent("marker"), encoding: .utf8) == "outside")
    }

    @Test func restartRechecksRelationRecordWithoutWritingOrReplaying() async throws {
        let fixture = try makeControllerRelationFixture(agents: [.codex])
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            if let target = fixture.targets[.codex] {
                try? FileManager.default.removeItem(at: target.deletingLastPathComponent().deletingLastPathComponent())
            }
        }
        _ = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            skillID: "writer",
            enabled: true
        )
        let operationID = try #require(
            fixture.controller.phase1Tasks.first { $0.kind == .setAgentRelation }?.id
        )
        let target = try #require(fixture.targets[.codex])
        let link = target.appendingPathComponent("Writer")
        let home = target.deletingLastPathComponent().deletingLastPathComponent()
        let store = SkillsHubMetadataStore()
        let metadataFile = store.rootLayout(for: fixture.root).skillshubMetadataFile
        let recordFile = store.rootLayout(for: fixture.root).operationRecoveryDirectory
            .appendingPathComponent(operationID.uuidString, isDirectory: true)
            .appendingPathComponent(RelationActionOperationRecordStore.recordFileName)
        let metadataBefore = try Data(contentsOf: metadataFile)
        let recordBefore = try Data(contentsOf: recordFile)

        let restarted = SkillsHubLibraryController(agentHomeDirectory: home, agentEnvironment: [:])
        try connectInitializedTestRoot(restarted, at: fixture.root)

        let recovered = try #require(restarted.phase1Tasks.first { $0.id == operationID })
        #expect(recovered.phase == .completed)
        #expect(recovered.recoveryEvidence?.components.first { $0.kind == "link-node" }?.state == .completed)
        #expect(try Data(contentsOf: metadataFile) == metadataBefore)
        #expect(try Data(contentsOf: recordFile) == recordBefore)

        try FileManager.default.removeItem(at: link)
        restarted.recheckRecoveryTasks()

        let changed = try #require(restarted.phase1Tasks.first { $0.id == operationID })
        #expect(changed.phase == .needsAttention)
        #expect(changed.recoveryEvidence?.components.first { $0.kind == "link-node" }?.state == .notCompleted)
        #expect(try Data(contentsOf: metadataFile) == metadataBefore)
        #expect(try Data(contentsOf: recordFile) == recordBefore)
    }

    @Test func deletingAndRestoringFixturePreservesMetadataWithoutWrites() throws {
        let root = try reloadTemporaryDirectory()
        let fakeHome = try reloadTemporaryDirectory()
        let bundle = root.appendingPathComponent("local/bundle", isDirectory: true)
        let alpha = bundle.appendingPathComponent("alpha", isDirectory: true)
        let beta = bundle.appendingPathComponent("beta", isDirectory: true)
        try writeReloadSkill(bundle, name: "Bundle")
        try writeReloadSkill(alpha, name: "Alpha")
        try writeReloadSkill(beta, name: "Beta")

        let installed = InstalledSkill(
            id: "bundle",
            sourceID: nil,
            name: "Bundle",
            description: "Bundle fixture.",
            installedPath: bundle.path,
            sourceKind: .localDirectory,
            validation: .valid,
            purpose: nil,
            tagIDs: ["review"],
            installedAt: .distantPast
        )
        let store = SkillsHubMetadataStore()
        try store.save(
            SkillsHubMetadata(
                rootConfig: RootConfig(rootPath: root.path),
                installedSkills: [installed],
                tags: [TagRecord(id: "review", displayName: "Review")]
            ),
            to: root
        )

        let controller = SkillsHubLibraryController(agentHomeDirectory: fakeHome, agentEnvironment: [:])
        try connectInitializedTestRoot(controller, at: root)
        let metadataFile = store.rootLayout(for: root).skillshubMetadataFile
        let metadataBefore = try Data(contentsOf: metadataFile)

        try FileManager.default.removeItem(at: beta)
        try controller.reloadFromDisk()

        #expect(try Data(contentsOf: metadataFile) == metadataBefore)

        try writeReloadSkill(beta, name: "Beta")
        try controller.reloadFromDisk()

        #expect(try Data(contentsOf: metadataFile) == metadataBefore)

        try FileManager.default.removeItem(at: bundle)
        try controller.reloadFromDisk()

        #expect(controller.installedSkills.map(\.id) == ["bundle"])
        #expect(controller.installedSkills.first?.validation.status == .invalid)
        #expect(try Data(contentsOf: metadataFile) == metadataBefore)

        try writeReloadSkill(bundle, name: "Bundle")
        try writeReloadSkill(alpha, name: "Alpha")
        try writeReloadSkill(beta, name: "Beta")
        try controller.reloadFromDisk()

        #expect(try Data(contentsOf: metadataFile) == metadataBefore)
    }

    @Test func runtimeLocalDiscoveryRegistersNewDirectoryWithoutEnabling() async throws {
        let root = try reloadTemporaryDirectory()
        let fakeHome = try reloadTemporaryDirectory()
        let existing = root.appendingPathComponent("local/review", isDirectory: true)
        try writeReloadSkill(existing, name: "Review")

        let controller = SkillsHubLibraryController(agentHomeDirectory: fakeHome, agentEnvironment: [:])
        try connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()
        #expect(controller.installedSkills.map(\.id) == ["review"])

        let store = SkillsHubMetadataStore()
        let metadataFile = store.rootLayout(for: root).skillshubMetadataFile
        let generationBefore = controller.rootSnapshot?.generation

        // A new local/ direct subdirectory appears at runtime.
        let added = root.appendingPathComponent("local/summarize", isDirectory: true)
        try writeReloadSkill(added, name: "Summarize")
        let registered = try await controller.runtimeLocalDiscovery()

        #expect(registered == 1)
        #expect(Set(controller.installedSkills.map(\.id)) == ["review", "summarize"])
        let summarize = try #require(controller.installedSkills.first { $0.id == "summarize" })
        #expect(summarize.sourceKind == .manualFilesystem)
        #expect(summarize.sourceID == nil)
        // Registration must not enable the skill for any Agent.
        #expect(controller.agentLinks.allSatisfy { $0.skillID != "summarize" })
        // A real registration advances the authoritative generation exactly once.
        #expect(controller.rootSnapshot?.generation == generationBefore.map { $0 + 1 })

        // Re-running with no new directory performs no write.
        let metadataAfterRegister = try Data(contentsOf: metadataFile)
        let generationAfterRegister = controller.rootSnapshot?.generation
        let noop = try await controller.runtimeLocalDiscovery()
        #expect(noop == 0)
        #expect(try Data(contentsOf: metadataFile) == metadataAfterRegister)
        #expect(controller.rootSnapshot?.generation == generationAfterRegister)
    }

    @Test func runtimeLocalDiscoveryPreservesDeletedRegistrationWithoutWrite() async throws {
        let root = try reloadTemporaryDirectory()
        let fakeHome = try reloadTemporaryDirectory()
        let review = root.appendingPathComponent("local/review", isDirectory: true)
        try writeReloadSkill(review, name: "Review")

        let controller = SkillsHubLibraryController(agentHomeDirectory: fakeHome, agentEnvironment: [:])
        try connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()
        #expect(controller.installedSkills.map(\.id) == ["review"])

        let store = SkillsHubMetadataStore()
        let metadataFile = store.rootLayout(for: root).skillshubMetadataFile
        let metadataBefore = try Data(contentsOf: metadataFile)

        // The directory is deleted at runtime; discovery must not prune the registration.
        try FileManager.default.removeItem(at: review)
        let registered = try await controller.runtimeLocalDiscovery()

        #expect(registered == 0)
        #expect(controller.installedSkills.map(\.id) == ["review"])
        #expect(try Data(contentsOf: metadataFile) == metadataBefore)

        // A reload keeps the missing record and marks it invalid (Q-002/REQ-018).
        try controller.reloadFromDisk()
        #expect(controller.installedSkills.map(\.id) == ["review"])
        #expect(controller.installedSkills.first?.validation.status == .invalid)
        #expect(try Data(contentsOf: metadataFile) == metadataBefore)
    }

    @Test func runtimeLocalDiscoveryDoesNotReRegisterImportedSourceDirectory() async throws {
        let root = try reloadTemporaryDirectory()
        let fakeHome = try reloadTemporaryDirectory()
        let imported = root.appendingPathComponent("local/imported", isDirectory: true)
        try writeReloadSkill(imported, name: "Imported")

        // Simulate a source-owned managed copy already registered as localDirectory.
        let sourceID = UUID()
        let sourceSkill = InstalledSkill(
            id: "imported",
            sourceID: sourceID,
            name: "Imported",
            description: "Imported fixture.",
            installedPath: imported.path,
            sourceKind: .localDirectory,
            validation: .valid,
            purpose: nil,
            tagIDs: [],
            installedAt: .distantPast
        )
        let store = SkillsHubMetadataStore()
        try store.save(
            SkillsHubMetadata(
                rootConfig: RootConfig(rootPath: root.path),
                sources: [
                    SkillSource(
                        id: sourceID,
                        kind: .localDirectory,
                        name: "Imported",
                        localPath: imported.path
                    )
                ],
                installedSkills: [sourceSkill]
            ),
            to: root
        )

        let controller = SkillsHubLibraryController(agentHomeDirectory: fakeHome, agentEnvironment: [:])
        try connectInitializedTestRoot(controller, at: root)
        let metadataFile = store.rootLayout(for: root).skillshubMetadataFile
        let metadataBefore = try Data(contentsOf: metadataFile)

        await controller.waitForPendingRechecks()
        let registered = try await controller.runtimeLocalDiscovery()

        // The path key already matches the source-owned registration; no re-registration.
        #expect(registered == 0)
        #expect(controller.installedSkills.map(\.id) == ["imported"])
        #expect(controller.installedSkills.first?.sourceKind == .localDirectory)
        #expect(controller.installedSkills.first?.sourceID == sourceID)
        #expect(try Data(contentsOf: metadataFile) == metadataBefore)
    }

    @Test func runtimeLocalDiscoveryIgnoresNonCandidateDirectChildren() async throws {
        let root = try reloadTemporaryDirectory()
        let fakeHome = try reloadTemporaryDirectory()
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(
            at: local.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeReloadSkill(local.appendingPathComponent("review", isDirectory: true), name: "Review")
        try "not a direct source".write(
            to: local.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: local.appendingPathComponent("linked"),
            withDestinationURL: local.appendingPathComponent("review", isDirectory: true)
        )

        let controller = SkillsHubLibraryController(agentHomeDirectory: fakeHome, agentEnvironment: [:])
        try connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()

        #expect(controller.installedSkills.map(\.id) == ["review"])
        #expect(FileManager.default.fileExists(atPath: local.appendingPathComponent("empty").path))
        #expect(FileManager.default.fileExists(atPath: local.appendingPathComponent("SKILL.md").path))
        #expect(try local.appendingPathComponent("linked").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    #if DEBUG
    @Test func syntheticManagedRootEventTriggersRuntimeDiscovery() async throws {
        let root = try reloadTemporaryDirectory()
        let fakeHome = try reloadTemporaryDirectory()
        try writeReloadSkill(root.appendingPathComponent("local/review", isDirectory: true), name: "Review")

        let stream = FakeFilesystemEventStream()
        let controller = SkillsHubLibraryController(
            agentHomeDirectory: fakeHome,
            agentEnvironment: [:],
            filesystemEventStreamFactory: { stream }
        )
        try connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()
        #expect(controller.installedSkills.map(\.id) == ["review"])
        #expect(controller.observationStatus == .observing)

        // A new directory appears, then a managed-root event fires.
        try writeReloadSkill(root.appendingPathComponent("local/summarize", isDirectory: true), name: "Summarize")
        controller.observation.injectForTesting([
            FilesystemRawEvent(path: root.appendingPathComponent("local/summarize").path, flags: [], eventID: 1)
        ])
        await controller.waitForPendingRechecks()

        #expect(Set(controller.installedSkills.map(\.id)) == ["review", "summarize"])
    }
    #endif

    #if DEBUG
    @Test func coalescedManagedRootEventsRunSingleRecheck() async throws {
        let root = try reloadTemporaryDirectory()
        let fakeHome = try reloadTemporaryDirectory()
        try writeReloadSkill(root.appendingPathComponent("local/review", isDirectory: true), name: "Review")

        let stream = FakeFilesystemEventStream()
        let controller = SkillsHubLibraryController(
            agentHomeDirectory: fakeHome,
            agentEnvironment: [:],
            filesystemEventStreamFactory: { stream }
        )
        try connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()
        let generationAfterInitial = controller.recheckGeneration

        // Several paths within the same scope coalesce into one dirty batch → one recheck.
        controller.observation.injectForTesting([
            FilesystemRawEvent(path: root.appendingPathComponent("local/a/SKILL.md").path, flags: [], eventID: 1),
            FilesystemRawEvent(path: root.appendingPathComponent("local/b/SKILL.md").path, flags: [], eventID: 2),
            FilesystemRawEvent(path: root.appendingPathComponent("local/c").path, flags: [], eventID: 3)
        ])

        #expect(controller.recheckGeneration == generationAfterInitial + 1)
    }
    #endif

    #if DEBUG
    @Test func droppedEventBatchForcesFullAuthorizedScan() async throws {
        let root = try reloadTemporaryDirectory()
        let fakeHome = try reloadTemporaryDirectory()
        try writeReloadSkill(root.appendingPathComponent("local/review", isDirectory: true), name: "Review")

        let stream = FakeFilesystemEventStream()
        let controller = SkillsHubLibraryController(
            agentHomeDirectory: fakeHome,
            agentEnvironment: [:],
            filesystemEventStreamFactory: { stream }
        )
        try connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()

        // A new directory appears; a dropped (MustScanSubDirs) batch with an unrelated
        // path must still escalate to a full authorized-range scan and find it.
        try writeReloadSkill(root.appendingPathComponent("local/summarize", isDirectory: true), name: "Summarize")
        controller.observation.injectForTesting([
            FilesystemRawEvent(path: "/unrelated/path", flags: .mustScanSubDirs, eventID: 1)
        ])
        await controller.waitForPendingRechecks()

        #expect(Set(controller.installedSkills.map(\.id)) == ["review", "summarize"])
    }
    #endif

    @Test func staleRecheckGenerationDoesNotOverrideNewerObservationStatus() async throws {
        let root = try reloadTemporaryDirectory()
        let fakeHome = try reloadTemporaryDirectory()
        try writeReloadSkill(root.appendingPathComponent("local/review", isDirectory: true), name: "Review")

        let stream = FakeFilesystemEventStream()
        let controller = SkillsHubLibraryController(
            agentHomeDirectory: fakeHome,
            agentEnvironment: [:],
            filesystemEventStreamFactory: { stream }
        )
        try connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()

        // Each recheck bumps the generation; a subsequent recheck supersedes the prior
        // one so only the newest completion lands.
        let before = controller.recheckGeneration
        controller.performScopedRecheck(scopes: [.managedRoot], fullScan: false)
        controller.performScopedRecheck(scopes: [.managedRoot], fullScan: false)
        await controller.waitForPendingRechecks()
        #expect(controller.recheckGeneration == before + 2)
        #expect(controller.observationStatus == .observing)
    }

    #if DEBUG
    @Test func eventsAfterRootSwitchDoNotLandOnNewRoot() async throws {
        let rootA = try reloadTemporaryDirectory()
        let rootB = try reloadTemporaryDirectory()
        let fakeHome = try reloadTemporaryDirectory()
        try writeReloadSkill(rootA.appendingPathComponent("local/alpha", isDirectory: true), name: "Alpha")
        try writeReloadSkill(rootB.appendingPathComponent("local/beta", isDirectory: true), name: "Beta")

        var streams: [FakeFilesystemEventStream] = []
        let controller = SkillsHubLibraryController(
            agentHomeDirectory: fakeHome,
            agentEnvironment: [:],
            filesystemEventStreamFactory: {
                let stream = FakeFilesystemEventStream()
                streams.append(stream)
                return stream
            }
        )
        try connectInitializedTestRoot(controller, at: rootA)
        await controller.waitForPendingRechecks()
        #expect(controller.installedSkills.map(\.id) == ["alpha"])
        let firstStream = try #require(streams.first)

        // Queue work for Root A, then switch before it completes. The cancelled old
        // task must neither consume nor clear Root B's initial scan.
        try writeReloadSkill(rootA.appendingPathComponent("local/late-alpha", isDirectory: true), name: "Late Alpha")
        controller.observation.injectForTesting([
            FilesystemRawEvent(path: rootA.appendingPathComponent("local/late-alpha").path, flags: [], eventID: 8)
        ])

        // Switch to Root B; the previous subscription and queued work are stopped.
        try connectInitializedTestRoot(controller, at: rootB)
        await controller.waitForPendingRechecks()
        #expect(controller.installedSkills.map(\.id) == ["beta"])
        #expect(firstStream.stopCount >= 1)

        // A late event from the old (stopped) stream must not land on the new Root.
        firstStream.emit([
            FilesystemRawEvent(path: rootA.appendingPathComponent("local/alpha").path, flags: [], eventID: 9)
        ])
        #expect(controller.installedSkills.map(\.id) == ["beta"])
    }
    #endif

    @Test func failedInitialSubscriptionSurfacesUnknownObservationMessage() async throws {
        let root = try reloadTemporaryDirectory()
        let fakeHome = try reloadTemporaryDirectory()
        try writeReloadSkill(root.appendingPathComponent("local/review", isDirectory: true), name: "Review")

        // A stream that refuses to start leaves observation unavailable (monitorFailed).
        let controller = SkillsHubLibraryController(
            agentHomeDirectory: fakeHome,
            agentEnvironment: [:],
            filesystemEventStreamFactory: { FakeFilesystemEventStream(allowsStart: false) }
        )
        try connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()

        #expect(controller.observationStatus == .unavailable(reason: .monitorFailed))
        // The initial scan still ran; the registration is present.
        #expect(controller.installedSkills.map(\.id) == ["review"])
        // The scan message reflects the unknown state, localized per language.
        controller.language = .english
        #expect(controller.observationStatusMessage?.contains("unavailable") == true)
        controller.language = .chinese
        #expect(controller.observationStatusMessage == "文件监听不可用。在其恢复前，受管事实状态未知。")
        controller.language = .japanese
        #expect(controller.observationStatusMessage?.contains("不明") == true)
    }

    @Test func successfulResubscriptionClearsUnknownObservationState() async throws {
        let root = try reloadTemporaryDirectory()
        let fakeHome = try reloadTemporaryDirectory()
        var allowsStart = false
        let controller = SkillsHubLibraryController(
            agentHomeDirectory: fakeHome,
            agentEnvironment: [:],
            filesystemEventStreamFactory: { FakeFilesystemEventStream(allowsStart: allowsStart) }
        )

        try connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()
        #expect(controller.observationStatus == .unavailable(reason: .monitorFailed))

        allowsStart = true
        controller.subscribeAndInitialScan()
        await controller.waitForPendingRechecks()

        #expect(controller.observationStatus == .observing)
        #expect(controller.observationStatusMessage == nil)
    }

}

private func reloadTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeReloadSkill(_ directory: URL, name: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let text = """
    ---
    name: \(name)
    description: \(name) fixture.
    ---
    Body.
    """
    try text.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
}
