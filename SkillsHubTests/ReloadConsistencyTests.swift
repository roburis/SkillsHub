import Foundation
import Testing
@testable import SkillsHub

@MainActor
struct ReloadConsistencyTests {
    @Test func presentationSelectionUsesIndexesAndOnlyFactsInvalidateSnapshots() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex])
        let controller = fixture.controller
        await controller.waitForPresentationObservation()
        let initial = controller.catalogItems
        let item = try #require(initial.first)
        let generation = controller.presentationObservationGeneration
        for iteration in 0..<20 {
            controller.searchText = iteration.isMultiple(of: 2) ? "writer" : ""
            controller.language = iteration.isMultiple(of: 2) ? .english : .japanese
            #expect(controller.catalogItemsByID[item.id] == item)
            #expect(controller.catalogItemsBySource[try #require(item.source?.id)]?.contains(item) == true)
            #expect(controller.contentNodeObservation(for: item)?.nodeKind == .directory)
            _ = controller.relationPresentations(for: try #require(item.managed))
        }
        #expect(controller.catalogItems == initial)
        #expect(controller.presentationObservationGeneration == generation)
        #expect(controller.presentationObservationTask == nil)
        let added = fixture.root.appendingPathComponent("local/added")
        try writeReloadSkill(added, name: "Added")
        _ = try await controller.runtimeLocalDiscovery()
        await controller.waitForPresentationObservation()
        #expect(controller.catalogItems.count == 2)
        #expect(controller.catalogItemsByID[item.id]?.managed?.assetID == fixture.assetID)
        #expect(controller.presentationObservationGeneration > generation)
    }

    @Test func supersededPresentationResultCannotRestoreAnOldRoot() async throws {
        let access = DelayedPresentationAccessStore()
        let controller = SkillsHubLibraryController(startupAccessStore: access)
        let root = try reloadTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let skillURL = root.appendingPathComponent("local/review")
        try writeReloadSkill(skillURL, name: "Review")
        controller.rootURL = root
        controller.installedSkills = [InstalledSkill(id: "review", sourceID: nil, name: "Review",
            description: "Fixture", installedPath: skillURL.path, sourceKind: .localDirectory,
            validation: .valid, purpose: nil, tagIDs: [], installedAt: .distantPast)]
        await access.waitUntilRequested()
        let oldTask = try #require(controller.presentationObservationTask)
        let generation = controller.presentationObservationGeneration
        controller.rootURL = nil
        controller.rootSnapshot = nil
        access.resume()
        await oldTask.value
        await controller.waitForPresentationObservation()
        #expect(controller.presentationObservationGeneration > generation)
        #expect(controller.catalogItems.isEmpty)
        #expect(controller.catalogItemsByID.isEmpty)
        #expect(controller.contentObservationSnapshot.isEmpty)
        #expect(!controller.isRefreshingPresentation)
    }

    @Test func localRefreshRetainsMissingResponsibilitiesAndMergesRequests() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex])
        let controller = fixture.controller
        await controller.waitForPendingRechecks()
        _ = try await controller.setGlobalAgentEnablement(agentID: "codex", assetID: fixture.assetID, enabled: true)
        let before = try #require(controller.rootSnapshot)
        let original = try #require(controller.installedSkills.first { $0.assetID == fixture.assetID })
        let directory = URL(fileURLWithPath: original.installedPath)
        let sourceID = try #require(controller.localSourcesForPresentation.first).id
        try writeReloadSkill(directory, name: "Renamed Writer")
        let added = fixture.root.appendingPathComponent("local/added")
        try writeReloadSkill(added, name: "Added")
        controller.searchText = "Renamed"
        let generation = controller.recheckGeneration
        async let first: Void = controller.refreshLocalSources()
        async let second: Void = controller.refreshLocalSources()
        try await first
        try await second
        #expect(controller.recheckGeneration == generation + 1)
        #expect(controller.searchText == "Renamed")
        #expect(controller.localSourcesForPresentation.count == 2)
        let presented = controller.presentationService.phase1Items(availableSkills: controller.availableSkills,
            installedSkills: controller.installedSkills, sources: controller.localSourcesForInspection,
            enablementIntents: controller.rootSnapshot?.metadata.enablementIntents ?? [])
        #expect(presented.count == 2)
        #expect(controller.installedSkills.first { $0.assetID == fixture.assetID }?.name == "Renamed Writer")
        #expect(controller.rootSnapshot?.metadata.enablementIntents == before.metadata.enablementIntents)
        try FileManager.default.removeItem(at: directory)
        try await controller.refreshLocalSources()
        #expect(!controller.localSourcesForPresentation.contains { $0.id == sourceID })
        #expect(controller.localSourcesForInspection.contains { $0.id == sourceID })
        let missing = try #require(controller.installedSkills.first { $0.assetID == fixture.assetID })
        #expect(missing.validation.status == .invalid)
        #expect(controller.rootSnapshot?.metadata.managedRelationEvidence == before.metadata.managedRelationEvidence)
        let linkName = try #require(before.metadata.installedSkills.first { $0.assetID == fixture.assetID }?.stableLinkName)
        #expect(FileAccessService().isSymlink(try #require(fixture.targets[.codex]).appendingPathComponent(linkName)))
        #expect(try controller.prepareManagedRelationClearPlan(assetID: fixture.assetID).items.count == 1)
        let restarted = SkillsHubLibraryController(agentHomeDirectory: fixture.root.appendingPathComponent("fake-home"), agentEnvironment: [:])
        try await connectInitializedTestRoot(restarted, at: fixture.root)
        await restarted.waitForPendingRechecks()
        #expect(!restarted.localSourcesForPresentation.contains { $0.id == sourceID })
        #expect(restarted.installedSkills.contains { $0.assetID == fixture.assetID })
    }

    @Test func incompleteLocalRefreshPreservesLastCollectionAndReplacementIsNotDeletion() async throws {
        let root = try reloadTemporaryDirectory().standardizedFileURL
        let home = try reloadTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: home) }
        let directory = root.appendingPathComponent("local/review")
        try writeReloadSkill(directory, name: "Review")
        let controller = SkillsHubLibraryController(agentHomeDirectory: home, agentEnvironment: [:], filesystemEventStreamFactory: { FakeFilesystemEventStream() })
        try await connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()
        let before = controller.availableSkills
        let visible = controller.localSourcesForPresentation.map(\.id)
        let paths = controller.observedLocalSourceNames
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: home)
        try await controller.refreshLocalSources()
        #expect(controller.observationStatus == .unavailable(reason: .scanFailed))
        #expect(controller.availableSkills == before)
        #expect(controller.localSourcesForPresentation.map(\.id) == visible)
        #expect(controller.observedLocalSourceNames == paths)
        try FileManager.default.removeItem(at: directory)
        try writeReloadSkill(directory, name: "Restored")
        try await controller.refreshLocalSources()
        #expect(controller.observationStatus == .observing)
        #expect(controller.installedSkills.first?.name == "Restored")
        // A non-directory container is an enumeration failure, not an empty local tree.
        try FileManager.default.moveItem(at: root.appendingPathComponent("local"), to: root.appendingPathComponent("saved-local"))
        try Data("replacement".utf8).write(to: root.appendingPathComponent("local"))
        let restored = controller.availableSkills
        try await controller.refreshLocalSources()
        #expect(controller.observationStatus.isUnavailable)
        #expect(controller.availableSkills == restored)
        let retainedSources = controller.localSourcesForInspection
        #expect(retainedSources.map(\.localPath) == [directory.path])
        #expect(controller.installedSkills.count == 1)
        #expect(controller.rootURL?.path == root.path)
        #expect(controller.localSourcesForPresentation.map(\.id) == visible)
    }

    @Test func discoveryBackfillsOnlyUniqueAssociationAndFailedCommitKeepsSnapshot() async throws {
        let root = try reloadTemporaryDirectory()
        let home = try reloadTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: home)
        }
        let directory = root.appendingPathComponent("local/review").standardizedFileURL
        try writeReloadSkill(directory, name: "Review")
        let source = SkillSource(kind: .localDirectory, name: "Review", localPath: directory.path)
        let candidate = AvailableSkill(id: "review", sourceID: source.id, skillPath: ".", name: "Review",
            description: "Fixture", validation: .valid, candidateID: "legacy-candidate")
        let asset = InstalledSkill(id: "review", sourceID: source.id, name: "Review", description: "Fixture",
            installedPath: directory.path, sourceKind: .localDirectory, validation: .valid,
            purpose: nil, tagIDs: [], installedAt: .distantPast, stableLinkName: "Original Name")
        let intent = EnablementIntent(assetID: asset.assetID, agentID: AgentKind.codex.rawValue,
            scope: .global, isEnabled: true, generation: 1)
        let store = SkillsHubMetadataStore()
        try store.save(SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.standardizedFileURL.path),
            sources: [source], availableSkills: [candidate], installedSkills: [asset], enablementIntents: [intent]), to: root)
        let controller = SkillsHubLibraryController(agentHomeDirectory: home, agentEnvironment: [:])
        try await connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()
        let linked = try #require(controller.rootSnapshot)
        #expect(linked.metadata.installedSkills.first?.candidateID == candidate.candidateID)
        #expect(linked.metadata.installedSkills.first?.assetID == asset.assetID)
        #expect(linked.metadata.installedSkills.first?.stableLinkName == asset.stableLinkName)
        #expect(linked.metadata.enablementIntents == [intent])
        _ = try store.commit(at: root, expected: linked) { $0.uiState["fixture"] = "concurrent write" }
        try writeReloadSkill(directory.appendingPathComponent("added"), name: "Added")
        let items = controller.availableSkills
        let skills = controller.installedSkills
        await #expect(throws: MetadataCommitError.self) { try await controller.runtimeLocalDiscovery() }
        #expect(controller.availableSkills == items)
        #expect(controller.installedSkills == skills)
        #expect(controller.rootSnapshot == linked)
    }

    @Test func discoveryAndRecheckPairLegacyRecordsByLocationAcrossRenameMoveAndRestart() async throws {
        let root = try reloadTemporaryDirectory()
        let home = try reloadTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: home)
        }
        let parent = root.appendingPathComponent("local/bundle")
        let nested = parent.appendingPathComponent("nested/review")
        try writeReloadSkill(parent, name: "Review")
        try writeReloadSkill(nested, name: "Review")
        let controller = SkillsHubLibraryController(agentHomeDirectory: home, agentEnvironment: [:])
        try await connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()
        let original = controller.installedSkills
        #expect(original.count == 2)
        let nestedAsset = try #require(original.first { $0.installedPath.hasSuffix("/nested/review") })
        let source = try #require(controller.localSourcesForPresentation.first)
        func items(_ controller: SkillsHubLibraryController) -> [Phase1SkillPresentation] {
            controller.presentationService.phase1Items(availableSkills: controller.availableSkills,
                installedSkills: controller.installedSkills, sources: controller.localSourcesForPresentation,
                enablementIntents: controller.rootSnapshot?.metadata.enablementIntents ?? [])
        }
        #expect(items(controller).count == 2)
        let ids = Set(items(controller).map(\.id))
        try await controller.recheckSource(source.id)
        #expect(Set(items(controller).map(\.id)) == ids)
        #expect(items(controller).allSatisfy { $0.candidate != nil && $0.managed != nil })
        try writeReloadSkill(nested, name: "Renamed")
        try await controller.recheckSource(source.id)
        #expect(items(controller).first { $0.name == "Renamed" }?.managed?.assetID == nestedAsset.assetID)
        let moved = parent.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: nested, to: moved)
        #expect(try await controller.runtimeLocalDiscovery() == 1)
        #expect(items(controller).count == 3)
        #expect(items(controller).first { $0.managed?.assetID == nestedAsset.assetID }?.needsAttention == true)
        let restarted = SkillsHubLibraryController(agentHomeDirectory: home, agentEnvironment: [:])
        try await connectInitializedTestRoot(restarted, at: root)
        await restarted.waitForPendingRechecks()
        #expect(Set(items(restarted).map(\.id)) == Set(items(controller).map(\.id)))
        #expect(Set(original.map(\.assetID)).isSubset(of: Set(restarted.installedSkills.map(\.assetID))))
    }

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

        try await connectInitializedTestRoot(controller, at: rootA)
        await controller.waitForPendingRechecks()
        #expect(controller.language == .chinese)
        #expect(controller.installedSkills.map(\.id) == ["alpha"])

        try await connectInitializedTestRoot(controller, at: rootB)
        await controller.waitForPendingRechecks()
        #expect(controller.language == .chinese)
        #expect(controller.installedSkills.map(\.id) == ["beta"])

        let metadataFile = SkillsHubMetadataStore().rootLayout(for: rootA).skillshubMetadataFile
        try Data("invalid metadata".utf8).write(to: metadataFile)
        try await controller.connectExistingRoot(rootA)
        await controller.waitForPendingRechecks()

        #expect(controller.language == .chinese)
        #expect(controller.installedSkills.map(\.id) == ["alpha"])
        #expect(controller.agentLinks.isEmpty)
        #expect(try Data(contentsOf: skillA.appendingPathComponent("SKILL.md")) == skillABytes)
        #expect(try Data(contentsOf: skillB.appendingPathComponent("SKILL.md")) == skillBBytes)
    }

    @Test func linkedRecoveryDirectoryIsReportedUnknownWithoutFollowingIt() async throws {
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

        try await connectInitializedTestRoot(controller, at: root)

        let task = try #require(controller.phase1Tasks.first { $0.id == operationID })
        #expect(task.phase == .needsAttention)
        let component = try #require(task.recoveryEvidence?.components.first)
        #expect(component.kind == "operation-materials")
        #expect(component.state == .unknown)
        #expect(component.path == operations.appendingPathComponent(operationID.uuidString).path)
        #expect(try String(contentsOf: external.appendingPathComponent("marker"), encoding: .utf8) == "outside")
    }

    @Test func restartRechecksRelationRecordWithoutWritingOrReplaying() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex])
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            if let target = fixture.targets[.codex] {
                try? FileManager.default.removeItem(at: target.deletingLastPathComponent().deletingLastPathComponent())
            }
        }
        _ = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
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
        try await connectInitializedTestRoot(restarted, at: fixture.root)

        let recovered = try #require(restarted.phase1Tasks.first { $0.id == operationID })
        #expect(recovered.phase == .completed)
        #expect(recovered.recoveryEvidence?.components.first { $0.kind == "link-node" }?.state == .completed)
        #expect(try Data(contentsOf: metadataFile) == metadataBefore)
        #expect(try Data(contentsOf: recordFile) == recordBefore)

        try FileManager.default.removeItem(at: link)
        await restarted.recheckRecoveryTasks()

        let changed = try #require(restarted.phase1Tasks.first { $0.id == operationID })
        #expect(changed.phase == .needsAttention)
        #expect(changed.recoveryEvidence?.components.first { $0.kind == "link-node" }?.state == .notCompleted)
        #expect(try Data(contentsOf: metadataFile) == metadataBefore)
        #expect(try Data(contentsOf: recordFile) == recordBefore)
    }

    @Test func deletingAndRestoringFixturePreservesMetadataWithoutWrites() async throws {
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
        try await connectInitializedTestRoot(controller, at: root)
        let metadataFile = store.rootLayout(for: root).skillshubMetadataFile
        let metadataBefore = try Data(contentsOf: metadataFile)

        try FileManager.default.removeItem(at: beta)
        let registeredAssets = controller.installedSkills.map(\.assetID)
        try await controller.reloadFromDisk()

        #expect(try Data(contentsOf: metadataFile) == metadataBefore)

        try writeReloadSkill(beta, name: "Beta")
        try await controller.reloadFromDisk()

        #expect(try Data(contentsOf: metadataFile) == metadataBefore)

        try FileManager.default.removeItem(at: bundle)
        try await controller.reloadFromDisk()

        #expect(controller.installedSkills.map(\.assetID) == registeredAssets)
        #expect(controller.installedSkills.allSatisfy { $0.validation.status == .invalid })
        #expect(try Data(contentsOf: metadataFile) == metadataBefore)

        try writeReloadSkill(bundle, name: "Bundle")
        try writeReloadSkill(alpha, name: "Alpha")
        try writeReloadSkill(beta, name: "Beta")
        try await controller.reloadFromDisk()

        #expect(try Data(contentsOf: metadataFile) == metadataBefore)
    }

    @Test func runtimeLocalDiscoveryRegistersNewDirectoryWithoutEnabling() async throws {
        let root = try reloadTemporaryDirectory()
        let fakeHome = try reloadTemporaryDirectory()
        let existing = root.appendingPathComponent("local/review", isDirectory: true)
        try writeReloadSkill(existing, name: "Review")

        let controller = SkillsHubLibraryController(agentHomeDirectory: fakeHome, agentEnvironment: [:])
        try await connectInitializedTestRoot(controller, at: root)
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
        try await connectInitializedTestRoot(controller, at: root)
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
        try await controller.reloadFromDisk()
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
        try await connectInitializedTestRoot(controller, at: root)
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
        try await connectInitializedTestRoot(controller, at: root)
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
        try await connectInitializedTestRoot(controller, at: root)
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
        try await connectInitializedTestRoot(controller, at: root)
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
        try await connectInitializedTestRoot(controller, at: root)
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
        try await connectInitializedTestRoot(controller, at: root)
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
        try await connectInitializedTestRoot(controller, at: rootA)
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
        try await connectInitializedTestRoot(controller, at: rootB)
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
        try await connectInitializedTestRoot(controller, at: root)
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

        try await connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()
        #expect(controller.observationStatus == .unavailable(reason: .monitorFailed))

        allowsStart = true
        await controller.subscribeAndInitialScan()
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

@MainActor
private final class DelayedPresentationAccessStore: StartupAccessStoring {
    private var response: CheckedContinuation<Void, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var requested = false
    func resolveAccess(to url: URL) throws -> StartupAccessBookmarkResolution? { nil }
    func saveAccess(to url: URL) throws {}
    func resolvePresentationAccess(to urls: [URL]) async throws -> [String: StartupAccessBookmarkResolution] {
        if !requested {
            requested = true
            await withCheckedContinuation { continuation in
                response = continuation
                requestWaiter?.resume()
                requestWaiter = nil
            }
        }
        return [:]
    }
    func waitUntilRequested() async {
        if !requested { await withCheckedContinuation { requestWaiter = $0 } }
    }
    func resume() { response?.resume(); response = nil }
}
