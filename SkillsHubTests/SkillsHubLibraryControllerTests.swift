import Foundation
import Testing
@testable import SkillsHub

@MainActor
struct SkillsHubLibraryControllerTests {
    @Test func explicitDefaultAgentDirectoryRefreshKeepsExternalNodesAndRootMetadataUnchanged() async throws {
        let root = try temporaryDirectory()
        let home = try temporaryDirectory()
        let codex = AgentPathResolver().globalSkillsDirectory(for: .codex, environment: [:], homeDirectory: home)
        let claude = AgentPathResolver().globalSkillsDirectory(for: .claudeCode, environment: [:], homeDirectory: home)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let externalFile = codex.appendingPathComponent("existing.txt")
        try Data("untouched".utf8).write(to: externalFile)
        let externalLink = codex.appendingPathComponent("existing-link")
        try FileManager.default.createSymbolicLink(at: externalLink, withDestinationURL: externalFile)
        let brokenLink = codex.appendingPathComponent("broken-link")
        try FileManager.default.createSymbolicLink(at: brokenLink, withDestinationURL: codex.appendingPathComponent("missing"))
        let store = InMemoryStartupAccessStore(restorablePaths: [root.path, codex.path])
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let controller = SkillsHubLibraryController(
            agentAuditService: AgentDirectoryAuditService(installationPresence: { _, _ in .absent }),
            agentHomeDirectory: home,
            agentEnvironment: [:],
            startupAccessStore: store,
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: adapter)
        )
        #expect(controller.defaultAgentDirectoryRefresh.isEmpty)
        await controller.refreshDefaultAgentDirectories()
        #expect(controller.defaultAgentDirectoryRefresh.isEmpty)
        try await connectInitializedTestRoot(controller, at: root)
        let metadataURL = root.appendingPathComponent(".skillshub.json")
        let metadataBefore = try Data(contentsOf: metadataURL)
        let fileBefore = try Data(contentsOf: externalFile)
        let nodeBefore = try FileManager.default.attributesOfItem(atPath: externalFile.path)
        let linkBefore = try LinkNodeIdentity.read(at: externalLink)
        let baselineStarts = adapter.startRecords.count
        let baselineStops = adapter.stoppedURLs.count

        await controller.refreshDefaultAgentDirectories()
        #expect(controller.defaultAgentDirectoryRefresh[.codex] == .manageable)
        #expect(controller.defaultAgentDirectoryRefresh[.claudeCode] == .missing)
        #expect(controller.agentFindings.contains { $0.agentID == AgentKind.codex.rawValue && $0.entryName == "existing.txt" })
        #expect(controller.agentFindings.contains { $0.agentID == AgentKind.codex.rawValue && $0.entryName == "existing-link" })
        #expect(controller.agentFindings.contains { $0.entryName == "broken-link" && $0.type == .brokenSymlink })
        let addedEntry = codex.appendingPathComponent("new-entry.txt")
        try Data("new".utf8).write(to: addedEntry)
        await controller.refreshAgentLightScan()
        #expect(controller.defaultAgentDirectoryRefresh[.codex] == .unverifiable)
        #expect(!controller.agentFindings.contains { $0.agentID == AgentKind.codex.rawValue && $0.entryName == "existing.txt" })
        #expect(controller.agentFindings.contains { $0.agentID == AgentKind.codex.rawValue && $0.type == .pendingAudit })
        let pendingAudit = try #require(controller.agentFindings.first { $0.agentID == AgentKind.codex.rawValue && $0.type == .pendingAudit })
        #expect(controller.entryAddress(for: pendingAudit).path == nil)
        #expect(controller.entryAddress(for: pendingAudit).status?.template == "Skill address could not be verified.")
        await controller.refreshDefaultAgentDirectories()
        let renamedEntry = codex.appendingPathComponent("renamed-entry.txt")
        try FileManager.default.moveItem(at: addedEntry, to: renamedEntry)
        await controller.refreshAgentLightScan()
        #expect(controller.defaultAgentDirectoryRefresh[.codex] == .unverifiable)
        #expect(controller.agentFindings.contains { $0.agentID == AgentKind.codex.rawValue && $0.type == .pendingAudit })
        try FileManager.default.moveItem(at: renamedEntry, to: addedEntry)
        try FileManager.default.removeItem(at: addedEntry)
        await controller.refreshDefaultAgentDirectories()
        #expect(controller.defaultAgentDirectoryRefresh[.codex] == .manageable)
        #expect(!controller.agentFindings.contains { $0.agentID == AgentKind.claudeCode.rawValue })
        await controller.refreshAgentLightScan()
        #expect(controller.defaultAgentDirectoryRefresh[.codex] == .manageable)
        #expect(controller.agentFindings.contains { $0.agentID == AgentKind.codex.rawValue && $0.entryName == "existing.txt" })
        #expect(controller.agentFindings.contains { $0.agentID == AgentKind.codex.rawValue && $0.entryName == "existing-link" })
        #expect(controller.agentFindings.contains { $0.entryName == "broken-link" && $0.type == .brokenSymlink })
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: false)
        await controller.refreshDefaultAgentDirectories()
        #expect(controller.defaultAgentDirectoryRefresh[.claudeCode] == .authorizationRequired)
        try FileManager.default.removeItem(at: claude)
        store.restorablePaths.insert(claude.path)
        await controller.refreshDefaultAgentDirectories()
        #expect(controller.defaultAgentDirectoryRefresh[.claudeCode] == .missing)
        try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: codex)
        await controller.refreshDefaultAgentDirectories()
        #expect(controller.defaultAgentDirectoryRefresh[.claudeCode] == .unverifiable)
        var snapshot = try #require(controller.rootSnapshot)
        snapshot.metadata.agents[1].skillsDirectory = codex.path
        controller.rootSnapshot = snapshot
        await controller.refreshDefaultAgentDirectories()
        #expect(controller.defaultAgentDirectoryRefresh[.claudeCode] == .otherDirectoryConfigured)
        #expect(try Data(contentsOf: externalFile) == fileBefore)
        #expect(try LinkNodeIdentity.read(at: externalLink) == linkBefore)
        let nodeAfter = try FileManager.default.attributesOfItem(atPath: externalFile.path)
        for key in [FileAttributeKey.systemFileNumber, .posixPermissions, .modificationDate] {
            #expect((nodeBefore[key] as? AnyHashable) == (nodeAfter[key] as? AnyHashable))
        }
        #expect(try Data(contentsOf: metadataURL) == metadataBefore)
        #expect(store.savedPaths.isEmpty)
        #expect(adapter.startRecords.count - baselineStarts == adapter.stoppedURLs.count - baselineStops)

        let denied = SkillsHubLibraryController(
            agentHomeDirectory: home,
            agentEnvironment: [:],
            startupAccessStore: store,
            securityScopedAccessProvider: SecurityScopedAccessProvider(
                adapter: RecordingSecurityScopedResourceAccessAdapter(allowsStart: false)
            )
        )
        denied.rootURL = root
        await denied.refreshDefaultAgentDirectories()
        #expect(denied.defaultAgentDirectoryRefresh[.codex] == .unverifiable)
    }

    @Test(arguments: [AgentKind.codex, .claudeCode])
    func authorizedDirectoryWithoutInstallationCanEnableManagedCapability(_ agent: AgentKind) async throws {
        let root = try temporaryDirectory()
        let home = try temporaryDirectory()
        let target = AgentPathResolver().globalSkillsDirectory(for: agent, environment: [:], homeDirectory: home)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let controller = SkillsHubLibraryController(
            agentAuditService: AgentDirectoryAuditService(installationPresence: { _, _ in .absent }),
            agentHomeDirectory: home,
            agentEnvironment: [:],
            startupAccessStore: InMemoryStartupAccessStore(restorablePaths: [root.path, target.path])
        )
        try await connectInitializedTestRoot(controller, at: root)

        let capability = controller.configuredAgentCapabilities.first { $0.agentID == agent.rawValue }
        #expect(capability?.canManageRelations == true)
        #expect(capability?.isPresent != true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func connectingExistingRootDiscoversFilesystemSkillsWithoutEnabling() async throws {
        let root = try temporaryDirectory()
        let manual = root.appendingPathComponent("local/manual-review", isDirectory: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try skillText(name: "Manual Review", description: "Reviews manually installed skills.").write(to: manual.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let controller = SkillsHubLibraryController()
        try await connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()

        #expect(controller.hasRoot)
        // T-006: connecting a Root discovers manual local/ content and registers it as
        // a manual-filesystem skill, but never enables it for any Agent and never
        // records a source (REQ-003 auto-discovery, REQ-014 re-check).
        #expect(controller.installedSkills.map(\.id) == ["manual-review"])
        let registeredManual = try #require(controller.installedSkills.first)
        #expect(registeredManual.sourceKind == .manualFilesystem)
        #expect(registeredManual.sourceID == nil)
        #expect(controller.sources.isEmpty)
        #expect(controller.availableSkills.map(\.name) == ["Manual Review"])
        #expect(controller.agentLinks.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".skillshub.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("local").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("github").path))

        let metadata = try SkillsHubMetadataStore().load(from: root)
        #expect(metadata.schemaVersion == 4)
        #expect(metadata.installedSkills.map(\.id) == ["manual-review"])
    }

    @Test func settingsRootDefaultsToSkillsHubDirectoryUntilUserConfiguresRoot() async throws {
        let home = try temporaryDirectory()
        let controller = SkillsHubLibraryController(agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation), agentHomeDirectory: home)

        #expect(controller.settingsRootPathDisplay == home.appendingPathComponent("skills-hub").path)
        #expect(controller.suggestedRootURL.path == home.appendingPathComponent("skills-hub").path)

        let root = try temporaryDirectory()
        try await connectInitializedTestRoot(controller, at: root)
        await controller.refreshAgentLightScan(checkInstallation: true)

        #expect(controller.settingsRootPathDisplay == root.path)
        #expect(controller.suggestedRootURL.path == root.path)
    }

    @Test func localRootDiscoveryExposesCandidatesWithoutExternalSourceOrEnablement() async throws {
        let root = try temporaryDirectory()
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local.appendingPathComponent("review", isDirectory: true), withIntermediateDirectories: true)
        try skillText(name: "Review", description: "Reviews local skills safely.").write(
            to: local.appendingPathComponent("review/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(at: local.appendingPathComponent("collection/write", isDirectory: true), withIntermediateDirectories: true)
        try skillText(name: "Write", description: "Writes local collection skills.").write(
            to: local.appendingPathComponent("collection/write/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let controller = SkillsHubLibraryController()
        try await connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()

        // Directly maintained content has observations and registrations, without
        // inventing an external update source or enabling Agent relationships.
        #expect(Set(controller.installedSkills.map(\.id)) == ["review", "write"])
        #expect(controller.installedSkills.allSatisfy { $0.sourceKind == .manualFilesystem })
        #expect(controller.installedSkills.allSatisfy { $0.sourceID == nil })
        #expect(controller.sources.isEmpty)
        #expect(Set(controller.availableSkills.map(\.name)) == ["Review", "Write"])
        #expect(controller.rootSnapshot?.metadata.enablementIntents.isEmpty == true)
    }

    @Test func reloadKeepsUnregisteredRootContentOutsideManagedMetadata() async throws {
        let root = try temporaryDirectory()
        let manual = root.appendingPathComponent("local/manual-review", isDirectory: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try skillText(name: "Manual Review", description: "Reviews manually installed skills.")
            .write(to: manual.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let controller = SkillsHubLibraryController()
        try await connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()
        // T-006: the manual directory was discovered and registered on connect.
        #expect(controller.installedSkills.map(\.id) == ["manual-review"])
        let metadataFile = SkillsHubMetadataStore().rootLayout(for: root).skillshubMetadataFile
        // Capture authority after registration; confirmed missing records are pruned.
        let metadataAfterRegistration = try Data(contentsOf: metadataFile)

        try FileManager.default.removeItem(at: manual)
        try await controller.reloadFromDisk()

        #expect(controller.installedSkills.isEmpty)
        #expect(controller.scanStatusMessage?.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: manual.path))

        #expect(try Data(contentsOf: metadataFile) != metadataAfterRegistration)
        let metadata = try SkillsHubMetadataStore().load(from: root)
        #expect(metadata.installedSkills.isEmpty)
    }

    @Test func reloadFailureKeepsPreviousInstalledState() async throws {
        let root = try temporaryDirectory()
        let manual = root.appendingPathComponent("local/manual-review", isDirectory: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try skillText(name: "Manual Review", description: "Reviews manually installed skills.")
            .write(to: manual.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let controller = SkillsHubLibraryController()
        try await connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()
        #expect(controller.installedSkills.map(\.id) == ["manual-review"])
        let previousInstalled = controller.installedSkills
        let previousScanStatus = controller.scanStatusMessage

        try "{".write(to: root.appendingPathComponent(".skillshub.local.json"), atomically: true, encoding: .utf8)

        do {
            try await controller.reloadFromDisk()
            Issue.record("Expected reloadFromDisk to fail on corrupted local state.")
        } catch {
            #expect(controller.installedSkills.map(\.id) == previousInstalled.map(\.id))
            #expect(controller.scanStatusMessage == previousScanStatus)
        }
    }

    @Test func bootstrapDefaultRootDoesNotAdoptWritableDirectoryWithoutPersistedAuthorization() async throws {
        let home = try temporaryDirectory()
        let defaultRoot = home.appendingPathComponent("skills-hub", isDirectory: true)
        let roles = defaultRoot.appendingPathComponent("local/roles-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: roles, withIntermediateDirectories: true)
        try skillText(name: "roles-skills", description: "Composite local roles pack.").write(
            to: roles.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try saveManagedSkillFixture(
            root: defaultRoot,
            directory: roles,
            id: "roles-skills",
            name: "roles-skills",
            description: "Composite local roles pack."
        )

        let controller = SkillsHubLibraryController(agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation), agentHomeDirectory: home)
        try await controller.bootstrapDefaultRootIfPresent()

        #expect(!controller.hasRoot)
        #expect(controller.settingsRootPathDisplay == defaultRoot.path)
        #expect(controller.installedSkills.isEmpty)
        #expect(FileManager.default.fileExists(atPath: defaultRoot.appendingPathComponent(".skillshub.json").path))
        #expect(!FileManager.default.fileExists(atPath: defaultRoot.appendingPathComponent(".skillshub.local.json").path))
    }

    @Test func bootstrapDefaultRootDoesNotCreateMissingDefaultDirectory() async throws {
        let home = try temporaryDirectory()
        let controller = SkillsHubLibraryController(agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation), agentHomeDirectory: home)

        try await controller.bootstrapDefaultRootIfPresent()

        #expect(!controller.hasRoot)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("skills-hub").path))
    }

    @Test func bootstrapDefaultRootDoesNotReadMetadataWithoutPersistedAuthorization() async throws {
        let home = try temporaryDirectory()
        let defaultRoot = home.appendingPathComponent("skills-hub", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        try "{ invalid json".write(to: defaultRoot.appendingPathComponent(".skillshub.json"), atomically: true, encoding: .utf8)

        let controller = SkillsHubLibraryController(agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation), agentHomeDirectory: home)

        try await controller.bootstrapDefaultRootIfPresent()

        #expect(controller.rootURL == nil)
        #expect(!controller.hasRoot)
        #expect(controller.settingsRootPathDisplay == defaultRoot.path)
    }

    @Test func startupAuthorizationRestoresPersistedDefaultRootAccessWithoutPromptingAgain() async throws {
        let home = try temporaryDirectory()
        let defaultRoot = home.appendingPathComponent("skills-hub", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        try SkillsHubMetadataStore().save(
            SkillsHubMetadata(rootConfig: RootConfig(rootPath: defaultRoot.path)),
            to: defaultRoot
        )
        let accessStore = InMemoryStartupAccessStore(restorablePaths: [defaultRoot.standardizedFileURL.path])
        let controller = SkillsHubLibraryController(agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation), agentHomeDirectory: home, startupAccessStore: accessStore)

        try await controller.bootstrapDefaultRootIfPresent()

        #expect(controller.hasRoot)
        #expect(accessStore.restoredPaths.contains(defaultRoot.standardizedFileURL.path))
    }

    @Test func startupRestoresAuthorizedAgentEntriesWithoutChangingRootMetadata() async throws {
        let home = try temporaryDirectory()
        let root = home.appendingPathComponent("skills-hub", isDirectory: true)
        let target = home.appendingPathComponent(".codex/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let entry = target.appendingPathComponent("outside-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data("---\nname: Outside\ndescription: Startup consumer.\n---\n".utf8).write(to: entry.appendingPathComponent("SKILL.md"))
        try FileManager.default.createDirectory(at: target.appendingPathComponent("ordinary-folder"), withIntermediateDirectories: true)
        try SkillsHubMetadataStore().save(SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)), to: root)
        let metadataURL = root.appendingPathComponent(".skillshub.json")
        let before = try Data(contentsOf: metadataURL)
        let store = InMemoryStartupAccessStore(restorablePaths: [root.path, target.path])
        let controller = SkillsHubLibraryController(
            agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation),
            agentHomeDirectory: home, agentEnvironment: [:], startupAccessStore: store
        )

        try await controller.bootstrapDefaultRootIfPresent()

        #expect(controller.agentFindings.contains { $0.agentID == AgentKind.codex.rawValue && $0.entryName == "outside-skill" })
        #expect(!controller.agentFindings.contains { $0.entryName == "ordinary-folder" })
        #expect(try Data(contentsOf: metadataURL) == before)
        #expect(store.savedPaths.isEmpty)
    }

    @Test func rememberUserSelectedAccessRejectsSelectionWhenAuthorizationCannotBeRetained() throws {
        let selectedDirectory = try temporaryDirectory()
        let accessStore = InMemoryStartupAccessStore()
        let accessAdapter = RecordingSecurityScopedResourceAccessAdapter(allowsStart: false)
        let controller = SkillsHubLibraryController(
            startupAccessStore: accessStore,
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: accessAdapter)
        )

        do {
            try controller.rememberUserSelectedAccess(to: selectedDirectory)
            Issue.record("A selection without retained security-scoped access must be rejected.")
        } catch let error as SkillsHubLibraryFailure {
            #expect(error == .invalidSource("Folder authorization was not granted."))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(accessStore.savedPaths.isEmpty)
    }

    @Test func globalRelationActionUsesCoordinatorAndWritesOwnershipEvidence() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("local/writer", isDirectory: true)
        let agentHome = try temporaryDirectory()
        let agentDirectory = agentHome.appendingPathComponent(".codex/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        try skillText(name: "Writer", description: "Writes concise local documents.").write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try saveManagedSkillFixture(
            root: root,
            directory: source,
            id: "writer",
            name: "Writer",
            description: "Writes concise local documents."
        )
        let accessStore = InMemoryStartupAccessStore(restorablePaths: [root.path, agentDirectory.path])
        let controller = SkillsHubLibraryController(
            agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation),
            agentHomeDirectory: agentHome,
            agentEnvironment: [:],
            startupAccessStore: accessStore
        )
        try await connectInitializedTestRoot(controller, at: root)
        await controller.refreshAgentLightScan(checkInstallation: true)

        let enabled = try await controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: try #require(controller.installedSkills.first).assetID,
            enabled: true
        )

        let link = agentDirectory.appendingPathComponent("Writer")
        #expect(enabled.outcome == .succeeded)
        #expect((try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
        #expect(controller.agentLinks.isEmpty)
        let enabledSnapshot = try SkillsHubMetadataStore().loadCurrentSnapshot(from: root)
        #expect(enabledSnapshot.metadata.enablementIntents.count == 1)
        #expect(enabledSnapshot.metadata.enablementIntents.first?.agentID == AgentKind.codex.rawValue)
        #expect(enabledSnapshot.metadata.enablementIntents.first?.isEnabled == true)

        let repeated = try await controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: try #require(controller.installedSkills.first).assetID,
            enabled: true
        )
        #expect(repeated.outcome == .noChange)
        #expect(try SkillsHubMetadataStore().loadCurrentSnapshot(from: root).generation == enabledSnapshot.generation)

        let disabled = try await controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: try #require(controller.installedSkills.first).assetID,
            enabled: false
        )
        #expect(disabled.outcome == .succeeded)
        #expect((try? LinkNodeIdentity.read(at: link)) == nil)
        let disabledSnapshot = try SkillsHubMetadataStore().loadCurrentSnapshot(from: root)
        #expect(disabledSnapshot.metadata.enablementIntents.first?.isEnabled == false)
        #expect(controller.agentLinks.isEmpty)
    }

    @Test(arguments: ["empty", "unknown", "drift", "absent"])
    func historicalMaterialEntryConsumesQualificationAndRechecks(_ state: String) async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex],
            linkService: AgentLinkService(relationPrimitiveHook: { point, _ in
                if point == (state == "absent" ? .afterMaterialRemoval : .afterMaterialIsolation) {
                    throw CocoaError(.fileWriteUnknown)
                }
            }))
        await fixture.controller.waitForPendingRechecks()
        let enabled = try await fixture.controller.setGlobalAgentEnablement(agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID, enabled: true)
        #expect(enabled.outcome == .succeeded)
        let task = try #require(fixture.controller.phase1Tasks.first { $0.relationEvidence?.relation == enabled.relation })
        let material = try #require(task.recoveryEvidence?.creationMaterials)
        await fixture.controller.recheckRecoveryTasks()
        let projected = try #require(fixture.controller.phase1Tasks.first { $0.id == task.id })
        #expect(projected.relationEvidence?.actualDelta.contains(material.detail) == true)
        for language in [AppLanguage.chinese, .japanese] {
            #expect(projected.events.contains {
                SkillsHubLocalization().localized($0.message, language: language)
                    == SkillsHubLocalization().localized(material.detail, language: language)
            })
        }
        if state == "absent" {
            #expect(!material.canSettle)
            #expect(material.detail == "Creation directory absent; deletion history unverified.")
            #expect(task.phase == .needsAttention)
            await fixture.controller.recheckRecoveryTasks()
            #expect(fixture.controller.phase1Tasks.first { $0.id == task.id }?.recoveryEvidence?.creationMaterials == material)
            return
        }
        #expect(material.canSettle)
        let node = URL(fileURLWithPath: material.path)
        let before = try LinkNodeIdentity.read(at: node)
        let link = fixture.targets[.codex]!.appendingPathComponent("Writer")
        let originalLink = try LinkNodeIdentity.read(at: link)
        let metadata = try SkillsHubMetadataStore().loadCurrentSnapshot(from: fixture.root)
        await fixture.controller.recheckRecoveryTasks()
        #expect(try LinkNodeIdentity.read(at: node) == before)
        if state != "empty" {
            try Data("keep".utf8).write(to: node.appendingPathComponent("unknown"))
            if state == "unknown" {
                await fixture.controller.recheckRecoveryTasks()
                #expect(fixture.controller.phase1Tasks.first { $0.id == task.id }?.recoveryEvidence?.creationMaterials?.canSettle == false)
            }
        }
        await fixture.controller.settleCreationMaterials(operationID: task.id)
        let updated = try #require(fixture.controller.phase1Tasks.first { $0.id == task.id }?.recoveryEvidence?.creationMaterials)
        #expect(updated.canSettle == false)
        if state == "empty" {
            #expect((try? LinkNodeIdentity.read(at: node)) == nil)
            #expect(updated.detail == "Creation directory settled")
        } else {
            #expect(try LinkNodeIdentity.read(at: node) == before)
            #expect(try String(contentsOf: node.appendingPathComponent("unknown"), encoding: .utf8) == "keep")
            #expect(updated.detail == "Creation directory contains unknown contents.")
        }
        #expect(try LinkNodeIdentity.read(at: link) == originalLink)
        #expect(try SkillsHubMetadataStore().loadCurrentSnapshot(from: fixture.root).metadataDigest == metadata.metadataDigest)
    }

    @Test func sameNameRelationsUseSelectedAssetAndRejectContradictoryIdentity() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex, .claudeCode])
        await fixture.controller.waitForPendingRechecks()
        let directory = fixture.root.appendingPathComponent("local/other").standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try skillText(name: "Writer", description: "Second location.").write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let other = InstalledSkill(id: "writer", sourceID: nil, name: "Writer", description: "Second location.",
            installedPath: directory.path, sourceKind: .manualFilesystem, validation: .valid,
            purpose: nil, tagIDs: [], installedAt: .distantPast)
        let store = SkillsHubMetadataStore()
        var snapshot = try store.commit(at: fixture.root, expected: try #require(fixture.controller.rootSnapshot)) {
            $0.installedSkills.append(other)
        }
        fixture.controller.rootSnapshot = snapshot
        fixture.controller.installedSkills = snapshot.metadata.installedSkills
        let selected = try await fixture.controller.setGlobalAgentEnablement(agentID: AgentKind.codex.rawValue,
            assetID: other.assetID, enabled: true)
        #expect(selected.outcome == .succeeded)
        #expect(selected.relation.assetID == other.assetID)
        let occupied = try await fixture.controller.setGlobalAgentEnablement(agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID, enabled: true)
        #expect(occupied.outcome == .blocked)
        let blockedMessage = try #require(fixture.controller.statusMessage)
        #expect(blockedMessage.template == "%@ for %@ was not changed. View the current relationship for the next step.")
        #expect(blockedMessage.arguments == ["Writer", "Codex"])
        for language in [AppLanguage.chinese, .japanese] {
            #expect(SkillsHubLocalization().localized(blockedMessage, language: language) != blockedMessage.template)
        }
        #expect(try await fixture.controller.setGlobalAgentEnablement(agentID: AgentKind.claudeCode.rawValue,
            assetID: fixture.assetID, enabled: true).outcome == .succeeded)
        let plan = try fixture.controller.prepareManagedRelationClearPlan(assetID: other.assetID)
        #expect(plan.items.allSatisfy { $0.relation.assetID == other.assetID })
        let cleared = try await fixture.controller.clearAllManagedRelations(using: plan)
        #expect(cleared.items.count == 1)
        #expect(cleared.items.first?.outcome == .succeeded)
        #expect((try? LinkNodeIdentity.read(at: fixture.targets[.codex]!.appendingPathComponent("Writer"))) == nil)
        #expect(try LinkNodeIdentity.read(at: fixture.targets[.claudeCode]!.appendingPathComponent("Writer")).kind == S_IFLNK)
        // Cancelling an absent link's record uses the selected asset, never its shared name.
        _ = try await fixture.controller.setGlobalAgentEnablement(agentID: "codex", assetID: other.assetID, enabled: true)
        let otherLink = fixture.targets[.codex]!.appendingPathComponent("Writer")
        try FileManager.default.removeItem(at: otherLink)
        let recordCancelled = try await fixture.controller.setGlobalAgentEnablement(agentID: "codex",
            assetID: other.assetID, enabled: false, recordOnly: true)
        #expect(recordCancelled.outcome == .succeeded)
        #expect(recordCancelled.execution?.fileEvents.isEmpty == true)
        #expect(fixture.controller.rootSnapshot?.metadata.enablementIntents.first {
            $0.assetID == fixture.assetID && $0.agentID == "claudeCode"
        }?.isEnabled == true)
        #expect(try LinkNodeIdentity.read(at: fixture.targets[.claudeCode]!.appendingPathComponent("Writer")).kind == S_IFLNK)
        await #expect(throws: SkillsHubLibraryFailure.self) {
            try await fixture.controller.setGlobalAgentEnablement(agentID: AgentKind.codex.rawValue, assetID: UUID(), enabled: true)
        }
        let source = SkillSource(kind: .localDirectory, name: "Wrong association",
            localPath: fixture.root.appendingPathComponent("local/writer").standardizedFileURL.path)
        let candidate = AvailableSkill(id: "writer", sourceID: source.id, skillPath: ".", name: "Writer",
            description: "Fixture", validation: .valid)
        snapshot = try store.commit(at: fixture.root, expected: try #require(fixture.controller.rootSnapshot)) { metadata in
            metadata.sources.append(source)
            metadata.availableSkills.append(candidate)
            let offset = metadata.installedSkills.firstIndex { $0.assetID == other.assetID }!
            metadata.installedSkills[offset].sourceID = source.id
            metadata.installedSkills[offset].candidateID = candidate.candidateID
        }
        fixture.controller.rootSnapshot = snapshot
        await #expect(throws: SkillsHubLibraryFailure.self) {
            try await fixture.controller.setGlobalAgentEnablement(agentID: AgentKind.codex.rawValue, assetID: other.assetID, enabled: true)
        }
        #expect(throws: SkillsHubLibraryFailure.self) {
            try fixture.controller.prepareManagedRelationClearPlan(assetID: other.assetID)
        }
        #expect(try store.loadCurrentSnapshot(from: fixture.root) == snapshot)
    }

    @Test func savingAgentDisplayFieldsChangesNoDirectoryRelationshipOrContent() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex])
        let target = try #require(fixture.targets[.codex])
        let targetChildrenBefore = try FileManager.default.contentsOfDirectory(atPath: target.path)
        let tasksBefore = fixture.controller.phase1Tasks
        let intentsBefore = try #require(fixture.controller.rootSnapshot).metadata.enablementIntents

        try await fixture.controller.saveAgentDisplayFields(
            agentID: AgentKind.codex.rawValue,
            displayName: "Codex Personal",
            iconMonogram: nil
        )

        let saved = try #require(fixture.controller.rootSnapshot?.metadata.agents.first { $0.id == AgentKind.codex.rawValue })
        #expect(saved.displayName == "Codex Personal")
        #expect(saved.skillsDirectory == nil)
        #expect(fixture.controller.resolvedAgentSkillsDirectory(for: .codex) == target)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == targetChildrenBefore)
        #expect(fixture.controller.phase1Tasks == tasksBefore)
        #expect(try #require(fixture.controller.rootSnapshot).metadata.enablementIntents == intentsBefore)
        #expect(fixture.controller.relationActionResults.isEmpty)
    }

    @Test func invalidDisplayFieldsDoNotChangeSavedAgentConfiguration() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex])
        let before = try #require(fixture.controller.rootSnapshot).metadata

        await #expect(throws: SkillsHubLibraryFailure.invalidSource("Agent name is required.")) {
            try await fixture.controller.saveAgentDisplayFields(
                agentID: AgentKind.codex.rawValue,
                displayName: "   ",
                iconMonogram: nil
            )
        }

        #expect(try #require(fixture.controller.rootSnapshot).metadata == before)
    }

    @Test func rootAgentConfigurationUsesCurrentDefaults() {
        let overrides = SkillsHubLibraryController.agentPathOverrides(
            from: AgentConfigurationRecord.phase1BuiltIns
        )

        #expect(overrides[.codex] == nil)
    }

    @Test func relationTaskPreservesTimelineEvidenceAndPriorConclusionAcrossNewActions() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex])

        let enabled = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
            enabled: true
        )
        #expect(enabled.outcome == .succeeded)

        let firstTask = try #require(fixture.controller.phase1Tasks.first { $0.kind == .setAgentRelation })
        let firstEvidence = try #require(firstTask.relationEvidence)
        #expect(firstTask.phase == .completed)
        #expect(firstTask.events.map(\.phase) == [.preparing, .executing, .observing, .verifying, .completed])
        #expect(firstEvidence.relation.agentID == AgentKind.codex.rawValue)
        #expect(firstEvidence.skillID == "writer")
        #expect(firstEvidence.desiredEnabled)
        #expect(firstEvidence.outcome == "Succeeded")
        #expect(firstEvidence.verification == .verifiedConsistent)
        #expect(firstEvidence.actualDelta.contains { $0.contains("Created link") })
        #expect(firstEvidence.safeNextStep == "No action is required.")

        let repeated = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
            enabled: true
        )
        #expect(repeated.outcome == .noChange)

        let tasks = fixture.controller.phase1Tasks.filter { $0.kind == .setAgentRelation }
        #expect(tasks.count == 2)
        #expect(tasks.contains(firstTask))
        let noChangeTask = try #require(tasks.first { $0.id != firstTask.id })
        let noChangeEvidence = try #require(noChangeTask.relationEvidence)
        #expect(noChangeTask.phase == .completed)
        #expect(noChangeEvidence.outcome == "No change")
        #expect(noChangeEvidence.actualDelta == ["No filesystem or metadata change."])
        #expect(noChangeEvidence.verification == .verifiedConsistent)
    }

    @Test func relationTaskOutcomeGroupingRequiresAttentionForNonSuccessfulConclusions() {
        for outcome in [ControllerRelationActionOutcome.succeeded, .noChange] {
            #expect(Phase1RelationTaskProjection.finalPhase(for: outcome) == .completed)
        }
        for outcome in [
            ControllerRelationActionOutcome.blocked,
            .failed,
            .unknown,
            .stale,
            .replayed,
            .cancelled
        ] {
            #expect(Phase1RelationTaskProjection.finalPhase(for: outcome) == .needsAttention)
        }
    }

    @Test func concurrentDuplicateRelationActionsSubmitOnlyOneRelationWrite() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex])

        async let first = fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
            enabled: true
        )
        async let duplicate = fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
            enabled: true
        )
        let results = try await [first, duplicate]

        #expect(results.filter { $0.outcome == .succeeded }.count == 1)
        #expect(results.filter { $0.outcome == .replayed }.count == 1)
        let snapshot = try SkillsHubMetadataStore().loadCurrentSnapshot(from: fixture.root)
        #expect(snapshot.metadata.enablementIntents.count == 1)
        let operation = try #require(RelationActionOperationRecordStore().recoveryOperationIDs(rootURL: fixture.root).first)
        let record = try RelationActionOperationRecordStore().load(operationID: operation, rootURL: fixture.root)
        let creation = try #require(record.creation)
        let stagingDirectory = URL(fileURLWithPath: creation.stagingPath).deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.targets[.codex]!.path).sorted()
            == ["Writer"])
        #expect((try? LinkNodeIdentity.read(at: stagingDirectory)) == nil)
    }

    @Test func oneAgentRelationActionLeavesTheOtherAgentUnchanged() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex, .claudeCode])

        let result = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
            enabled: true
        )

        #expect(result.outcome == .succeeded)
        #expect(FileManager.default.fileExists(atPath: fixture.targets[.codex]!.appendingPathComponent("Writer").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.targets[.claudeCode]!.path).isEmpty)
        let intents = try SkillsHubMetadataStore().loadCurrentSnapshot(from: fixture.root).metadata.enablementIntents
        #expect(intents.map(\.agentID) == [AgentKind.codex.rawValue])
    }

    @Test func dualAgentEnablementSharesCanonicalSkillAndDisablePreservesOtherRelation() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex, .claudeCode])
        let canonicalSkill = fixture.root
            .appendingPathComponent("local/writer", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let codexLink = fixture.targets[.codex]!.appendingPathComponent("Writer")
        let claudeLink = fixture.targets[.claudeCode]!.appendingPathComponent("Writer")

        #expect(!FileManager.default.fileExists(atPath: codexLink.path))
        #expect(!FileManager.default.fileExists(atPath: claudeLink.path))

        let codexEnabled = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
            enabled: true
        )
        #expect(codexEnabled.outcome == .succeeded)
        #expect(codexLink.resolvingSymlinksInPath().standardizedFileURL.path == canonicalSkill.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.targets[.claudeCode]!.path).isEmpty)
        let namedSkill = try #require(
            SkillsHubMetadataStore().loadCurrentSnapshot(from: fixture.root).metadata.installedSkills.first
        )
        #expect(namedSkill.stableLinkName == "Writer")
        var renamedSkill = namedSkill
        renamedSkill.name = "Renamed Writer"
        #expect(fixture.controller.relationLinkName(asset: renamedSkill) == "Writer")

        let claudeEnabled = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.claudeCode.rawValue,
            assetID: fixture.assetID,
            enabled: true
        )
        #expect(claudeEnabled.outcome == .succeeded)
        #expect(codexLink.resolvingSymlinksInPath().standardizedFileURL.path == canonicalSkill.path)
        #expect(claudeLink.resolvingSymlinksInPath().standardizedFileURL.path == canonicalSkill.path)

        let dualState = fixture.controller.localState
        let dualIntents = fixture.controller.rootSnapshot?.metadata.enablementIntents ?? []
        let dualVerifications = dualState.verificationRecords
        #expect(Set(dualIntents.filter(\.isEnabled).map(\.agentID)) == ["codex", "claudeCode"])
        #expect(Set(dualState.targetObservations.compactMap(\.resolvedTargetPath)) == [canonicalSkill.path])
        #expect(Set(dualVerifications.map(\.relation.agentID)) == [
            AgentKind.codex.rawValue,
            AgentKind.claudeCode.rawValue
        ])
        #expect(dualVerifications.allSatisfy { $0.conclusion == .verifiedConsistent })
        let installedSkill = try #require(fixture.controller.installedSkills.first { $0.id == "writer" })
        let dualPresentations = fixture.controller.relationPresentations(for: installedSkill)
        #expect(dualPresentations.first { $0.relation.agentID == AgentKind.codex.rawValue }?.verification == .verifiedConsistent)
        #expect(dualPresentations.first { $0.relation.agentID == AgentKind.claudeCode.rawValue }?.verification == .verifiedConsistent)
        let claudeLinkText = try FileManager.default.destinationOfSymbolicLink(atPath: claudeLink.path)

        let codexDisabled = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
            enabled: false
        )
        #expect(codexDisabled.outcome == .succeeded)
        #expect((try? LinkNodeIdentity.read(at: codexLink)) == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: claudeLink.path) == claudeLinkText)
        #expect(claudeLink.resolvingSymlinksInPath().standardizedFileURL.path == canonicalSkill.path)
        #expect(
            fixture.controller.relationPresentations(for: installedSkill)
                .first { $0.relation.agentID == AgentKind.claudeCode.rawValue }?.verification == .verifiedConsistent
        )

        _ = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
            enabled: true
        )
        let codexLinkText = try FileManager.default.destinationOfSymbolicLink(atPath: codexLink.path)
        let claudeDisabled = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.claudeCode.rawValue,
            assetID: fixture.assetID,
            enabled: false
        )
        #expect(claudeDisabled.outcome == .succeeded)
        #expect((try? LinkNodeIdentity.read(at: claudeLink)) == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: codexLink.path) == codexLinkText)
        #expect(codexLink.resolvingSymlinksInPath().standardizedFileURL.path == canonicalSkill.path)
        #expect(
            fixture.controller.relationPresentations(for: installedSkill)
                .first { $0.relation.agentID == AgentKind.codex.rawValue }?.verification == .verifiedConsistent
        )

        let intents = try SkillsHubMetadataStore()
            .loadCurrentSnapshot(from: fixture.root)
            .metadata.enablementIntents
        #expect(intents.count == 2)
        #expect(intents.first { $0.agentID == AgentKind.codex.rawValue }?.isEnabled == true)
        #expect(intents.first { $0.agentID == AgentKind.claudeCode.rawValue }?.isEnabled == false)
        #expect(fixture.controller.phase1Tasks.filter { $0.kind == .setAgentRelation }.count == 5)
        let blockedTasks = fixture.controller.phase1Tasks.filter { $0.relationEvidence?.outcome == "Blocked" }
        #expect(blockedTasks.isEmpty)
    }

    @Test func missingSelectedNodeCanBeExplicitlyReestablished() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex])
        _ = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
            enabled: true
        )
        let link = fixture.targets[.codex]!.appendingPathComponent("Writer")
        try FileManager.default.moveItem(at: link, to: fixture.root.appendingPathComponent("removed-link"))
        try await fixture.controller.auditAgentDirectory(agentID: AgentKind.codex.rawValue)

        let skill = try #require(fixture.controller.installedSkills.first { $0.id == "writer" })
        let presentation = try #require(
            fixture.controller.relationPresentations(for: skill).first { $0.relation.agentID == AgentKind.codex.rawValue }
        )
        #expect(presentation.intendedEnabled == true)
        #expect(presentation.desiredEnabled == false)
        #expect(presentation.canReestablish)

        let result = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
            enabled: true
        )
        #expect(result.outcome == .succeeded)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == skill.installedPath)
    }

    @Test func customAgentUsesTheSameRelationActionPath() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [])
        let target = try temporaryDirectory()
        try fixture.controller.rememberUserSelectedAccess(to: target)
        let custom = try await fixture.controller.addCustomAgent(
            displayName: "Custom Bench",
            iconMonogram: "CB",
            skillsDirectory: target
        )

        let result = try await fixture.controller.setGlobalAgentEnablement(
            agentID: custom.id,
            assetID: fixture.assetID,
            enabled: true
        )
        let link = target.appendingPathComponent("Writer")
        #expect(result.outcome == .succeeded)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            == fixture.root.appendingPathComponent("local/writer").path)
        let skill = try #require(fixture.controller.installedSkills.first { $0.id == "writer" })
        let relation = try #require(
            fixture.controller.relationPresentations(for: skill).first { $0.relation.agentID == custom.id }
        )
        let descriptor = try #require(fixture.controller.visibleInstalledAgentDescriptors.first { $0.id == custom.id })
        #expect(descriptor.agent == nil)
        #expect(relation.agentDisplayName == "Custom Bench")
        #expect(descriptor.iconMonogram == "CB")
        #expect(relation.verification == .verifiedConsistent)
    }

    @Test func agentCapabilityAndRelationPresentationUseCurrentIndependentFacts() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex, .claudeCode])

        let codexCapability = try #require(
            fixture.controller.configuredAgentCapabilities.first { $0.agentID == AgentKind.codex.rawValue }
        )
        #expect(codexCapability.isPresent)
        #expect(codexCapability.authorizationStatus == .current)
        #expect(codexCapability.profileID == "skillshub.agent-profile.codex.global@1")
        #expect(codexCapability.profileVersion == 1)
        #expect(codexCapability.profileSchemaVersion == 1)
        #expect(codexCapability.canDetect)
        #expect(codexCapability.canClassify)
        #expect(codexCapability.canManageRelations)
        #expect(codexCapability.unavailableReason == nil)

        _ = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
            enabled: true
        )

        let skill = try #require(fixture.controller.installedSkills.first { $0.id == "writer" })
        var relations = fixture.controller.relationPresentations(for: skill)
        let codex = try #require(relations.first { $0.relation.agentID == AgentKind.codex.rawValue })
        let claude = try #require(relations.first { $0.relation.agentID == AgentKind.claudeCode.rawValue })
        #expect(codex.intendedEnabled == true)
        #expect(codex.observation == .symbolicLink)
        #expect(codex.verification == .verifiedConsistent)
        #expect(codex.lastOutcome == .succeeded)
        #expect(codex.canPerformAction)
        #expect(!codex.isInFlight)
        #expect(claude.intendedEnabled == nil)
        #expect(claude.observation == nil)
        #expect(claude.verification == .notVerified)

        fixture.controller.relationActionResults[codex.relation.id]?.safeNextStep = "reauthorize-current-relation"
        let currentNextStep = try #require(fixture.controller.relationPresentations(for: skill)
            .first { $0.relation == codex.relation }?.safeNextStep)
        #expect(currentNextStep == "Review current relation facts and authorize a new action.")
        for language in [AppLanguage.chinese, .japanese] {
            #expect(SkillsHubLocalization().localized(currentNextStep, language: language) != currentNextStep)
        }
        fixture.controller.relationActionResults.removeValue(forKey: codex.relation.id)
        let verificationIndex = try #require(fixture.controller.localState.verificationRecords
            .firstIndex { $0.relation == codex.relation })
        fixture.controller.localState.verificationRecords[verificationIndex].safeNextStep = "原始 history %@"
        #expect(fixture.controller.relationPresentations(for: skill)
            .first { $0.relation == codex.relation }?.safeNextStep == "No action is required.")

        let currentGeneration = try #require(fixture.controller.rootSnapshot?.generation)
        fixture.controller.rootSnapshot?.generation = currentGeneration + 1
        relations = fixture.controller.relationPresentations(for: skill)
        #expect(relations.first { $0.relation.agentID == AgentKind.codex.rawValue }?.verification == .notVerified)
        #expect(relations.first { $0.relation.agentID == AgentKind.claudeCode.rawValue }?.verification == .notVerified)

        fixture.controller.rootSnapshot?.generation = currentGeneration
        let observationIndex = try #require(
            fixture.controller.localState.targetObservations.firstIndex { $0.relation.agentID == AgentKind.codex.rawValue }
        )
        fixture.controller.localState.targetObservations[observationIndex].isReadable = false
        relations = fixture.controller.relationPresentations(for: skill)
        #expect(relations.first { $0.relation.agentID == AgentKind.codex.rawValue }?.verification == .currentlyUnverifiable)
        #expect(relations.first { $0.relation.agentID == AgentKind.codex.rawValue }?.safeNextStep == "Restore current access and observe the relation again.")
    }

    @Test(arguments: [AgentKind.codex, .claudeCode])
    func relationPresentationRejectsReplacedNodeAfterAudit(_ agent: AgentKind) async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex, .claudeCode])
        for enabledAgent in [AgentKind.codex, .claudeCode] {
            _ = try await fixture.controller.setGlobalAgentEnablement(
                agentID: enabledAgent.rawValue, assetID: fixture.assetID, enabled: true
            )
        }
        let skill = try #require(fixture.controller.installedSkills.first { $0.id == "writer" })
        let before = try #require(fixture.controller.relationPresentations(for: skill).first { $0.relation.agentID == agent.rawValue })
        try #require(before.verification == .verifiedConsistent)
        #expect(before.linkPath == fixture.controller.localState.targetObservations.first { $0.relation == before.relation }?.linkPath)
        #expect(before.linkText != nil)
        #expect(before.resolvedTargetPath == URL(fileURLWithPath: skill.installedPath).resolvingSymlinksInPath().path)
        let item = try #require(fixture.controller.presentationService.phase1Items(
            availableSkills: [], installedSkills: [skill], sources: [], enablementIntents: []).first)
        #expect(fixture.controller.contentNodeObservation(for: item)?.nodeKind == .directory)
        #expect(fixture.controller.entryAddress(for: item).path == "local/writer/SKILL.md")
        #expect(fixture.controller.entryAddress(for: item).status != nil) // A historical record alone does not verify SKILL.md.
        let otherObservation = fixture.controller.localState.targetObservations.first { $0.relation.agentID != agent.rawValue }
        let otherVerification = fixture.controller.localState.verificationRecords.first { $0.relation.agentID != agent.rawValue }
        let intents = fixture.controller.rootSnapshot?.metadata.enablementIntents
        let metadataURL = fixture.root.appendingPathComponent(".skillshub.json")
        let metadata = try Data(contentsOf: metadataURL)
        let target = try #require(fixture.targets[agent])
        let link = target.appendingPathComponent("Writer")
        try FileManager.default.moveItem(at: link, to: fixture.root.appendingPathComponent("original-link"))
        let externalContent = Data("External replacement".utf8)
        try externalContent.write(to: link)

        try await fixture.controller.auditAgentDirectory(agentID: agent.rawValue)

        let after = try #require(fixture.controller.relationPresentations(for: skill).first { $0.relation.agentID == agent.rawValue })
        #expect(after.verification != .verifiedConsistent)
        #expect(after.verification == .drifted)
        #expect(after.observation == .regularFile)
        #expect(after.linkPath == link.path)
        #expect(after.linkText == nil)
        #expect(after.resolvedTargetPath == nil)
        #expect(after.safeNextStep == "Review the current relation before preparing another action.")
        #expect(fixture.controller.relationPresentations(for: skill).first { $0.relation.agentID != agent.rawValue }?.verification == .verifiedConsistent)
        #expect(fixture.controller.rootSnapshot?.metadata.enablementIntents == intents)
        #expect(try Data(contentsOf: metadataURL) == metadata)
        #expect(try Data(contentsOf: link) == externalContent)
        #expect(fixture.controller.localState.targetObservations.first { $0.relation.agentID != agent.rawValue } == otherObservation)
        #expect(fixture.controller.localState.verificationRecords.first { $0.relation.agentID != agent.rawValue } == otherVerification)
        let persisted = try SkillsHubLocalStateStore().load(from: fixture.root)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(persisted) == encoder.encode(fixture.controller.localState))
        let observation = try #require(persisted.targetObservations.first { $0.relation.agentID == agent.rawValue })
        #expect(observation.nodeKind == .regularFile)
        #expect(persisted.verificationRecords.first { $0.relation.agentID == agent.rawValue }?.bindings.observationDigest == observation.digest)
        fixture.controller.agentDirectoryAuditFailures[agent.rawValue] = "Access unavailable"
        let unavailable = try #require(fixture.controller.relationPresentations(for: skill).first { $0.relation.agentID == agent.rawValue })
        #expect(unavailable.observation == nil)
        #expect(unavailable.linkPath == nil)
        #expect(unavailable.linkText == nil)
        #expect(unavailable.resolvedTargetPath == nil)
        #expect(fixture.controller.relationPresentations(for: skill).first { $0.relation.agentID != agent.rawValue }?.observation == .symbolicLink)
    }

    @Test(arguments: [AgentKind.codex, .claudeCode], ["unchanged", "vacant", "directory", "external", "broken", "replacement", "permission"])
    func relationChecksUseCurrentFileFacts(_ agent: AgentKind, _ change: String) async throws {
        let fixture = try await makeControllerRelationFixture(agents: [agent])
        try fixture.controller.saveLocalState()
        _ = try await fixture.controller.setGlobalAgentEnablement(agentID: agent.rawValue, assetID: fixture.assetID, enabled: true)
        let skill = try #require(fixture.controller.installedSkills.first { $0.id == "writer" })
        let target = try #require(fixture.targets[agent])
        let link = target.appendingPathComponent("Writer")
        let metadataURL = fixture.root.appendingPathComponent(".skillshub.json")
        let metadata = try Data(contentsOf: metadataURL)
        let node: TargetNodeKind
        if change != "unchanged" && change != "permission" {
            try FileManager.default.moveItem(at: link, to: fixture.root.appendingPathComponent("original-link"))
        }
        switch change {
        case "vacant": node = .vacant
        case "directory":
            try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
            node = .directory
        case "external", "broken", "replacement":
            let destination = change == "replacement" ? skill.installedPath
                : change == "external" ? fixture.root.path : fixture.root.appendingPathComponent("missing").path
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
            node = change == "broken" ? .brokenSymbolicLink : .symbolicLink
        case "permission":
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: target.path)
            node = .unreadable
        default: node = .symbolicLink
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
        let expected: VerificationConclusion = change == "unchanged" || change == "replacement" ? .verifiedConsistent
            : change == "permission" ? .currentlyUnverifiable : .drifted

        await fixture.controller.refreshAgentLightScan()
        var presentation = try #require(
            fixture.controller.relationPresentations(for: skill).first { $0.relation.agentID == agent.rawValue }
        )
        #expect(presentation.observation == node)
        #expect(presentation.verification == expected)
        if change == "permission" {
            await #expect(throws: (any Error).self) {
                try await fixture.controller.auditAllDetectedAgentDirectories()
            }
            let failure = try #require(fixture.controller.agentDirectoryAuditFailures[agent.rawValue])
            #expect(!failure.isVerbatim)
            for language in [AppLanguage.chinese, .japanese] {
                #expect(SkillsHubLocalization().localized(failure.template, language: language) != failure.template)
            }
        } else {
            try await fixture.controller.auditAllDetectedAgentDirectories()
        }
        presentation = try #require(
            fixture.controller.relationPresentations(for: skill).first { $0.relation.agentID == agent.rawValue }
        )
        #expect(presentation.observation == node)
        #expect(presentation.verification == expected)
        let persisted = try SkillsHubLocalStateStore().load(from: fixture.root)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if change != "permission" {
            #expect(try encoder.encode(persisted) == encoder.encode(fixture.controller.localState))
        }
        #expect(try Data(contentsOf: metadataURL) == metadata)

        if change == "permission" {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            try await fixture.controller.auditAgentDirectory(agentID: agent.rawValue)
            #expect(
                fixture.controller.relationPresentations(for: skill)
                    .first { $0.relation.agentID == agent.rawValue }?.verification == .verifiedConsistent
            )
        }
    }

    @Test func agentPathSettingsResolveEnvironmentDefaultsAndScanStatus() async throws {
        let root = try temporaryDirectory()
        let home = try temporaryDirectory()
        let codexHome = try temporaryDirectory()
        let controller = SkillsHubLibraryController(
            agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation),
            agentHomeDirectory: home,
            agentEnvironment: ["CODEX_HOME": codexHome.path]
        )
        try await connectInitializedTestRoot(controller, at: root)
        await controller.refreshAgentLightScan(checkInstallation: true)

        var codex = try #require(controller.agentPathSettings.first { $0.agent == .codex })
        #expect(codex.defaultPath == codexHome.appendingPathComponent("skills").path)
        #expect(codex.resolvedPath == codex.defaultPath)
        #expect(codex.status == .missing)
        #expect(!codex.isOverride)
        #expect(!codex.skillsDirectoryExists)

        try FileManager.default.createDirectory(at: codexHome.appendingPathComponent("skills"), withIntermediateDirectories: true)
        await controller.refreshAgentLightScan()
        codex = try #require(controller.agentPathSettings.first { $0.agent == .codex })
        #expect(codex.status == .detected)
        #expect(codex.directoryExists)
        #expect(codex.skillsDirectoryExists)
        #expect(codex.isWritable)

        let claudeSkills = home.appendingPathComponent(".claude/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: claudeSkills.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeSkills.path)
        }
        await controller.refreshAgentLightScan()
        let claude = try #require(controller.agentPathSettings.first { $0.agent == .claudeCode })
        #expect(claude.status == .notWritable)
        #expect(!claude.isWritable)
    }

    @Test func detectedBuiltInAgentsFollowLightScanAndPreserveCustomAgents() async throws {
        let root = try temporaryDirectory()
        let home = try temporaryDirectory()
        let codexSkills = home.appendingPathComponent(".codex/skills", isDirectory: true)
        let claudeSkills = home.appendingPathComponent(".claude/skills", isDirectory: true)
        let customSkills = try temporaryDirectory().appendingPathComponent("custom-agent-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: codexSkills, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customSkills, withIntermediateDirectories: true)

        let controller = SkillsHubLibraryController(
            agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation),
            agentHomeDirectory: home,
            agentEnvironment: [:],
            startupAccessStore: InMemoryStartupAccessStore(restorablePaths: [root.path, customSkills.path])
        )
        try await connectInitializedTestRoot(controller, at: root)
        await controller.refreshAgentLightScan(checkInstallation: true)

        #expect(controller.detectedBuiltInAgents == [.codex])

        let customAgent = try await controller.addCustomAgent(
            displayName: "Custom Bench",
            iconMonogram: "CB",
            skillsDirectory: customSkills
        )
        #expect(controller.rootSnapshot?.metadata.agents.contains { $0.id == customAgent.id } == true)
        #expect(controller.localState.customAgents.isEmpty)
        #expect(controller.agentDetections.contains { $0.agentID == customAgent.id && $0.detected && $0.isCustom })
        #expect(controller.detectedBuiltInAgents == [.codex])

        try FileManager.default.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
        await controller.refreshAgentLightScan(checkInstallation: true)

        #expect(controller.detectedBuiltInAgents == [.claudeCode, .codex])
        #expect(controller.rootSnapshot?.metadata.agents.contains { $0.id == customAgent.id } == true)
    }

    @Test func customAgentRejectsInvalidIconAbbreviation() async throws {
        let root = try temporaryDirectory()
        let target = try temporaryDirectory()
        let controller = SkillsHubLibraryController(
            startupAccessStore: InMemoryStartupAccessStore(restorablePaths: [root.path, target.path])
        )
        try await connectInitializedTestRoot(controller, at: root)

        await #expect(throws: SkillsHubLibraryFailure.invalidSource("Enter 1–4 visible characters for the icon abbreviation.")) {
            _ = try await controller.addCustomAgent(
                displayName: "Custom Agent",
                iconMonogram: "ABCDE",
                skillsDirectory: target
            )
        }
    }

    @Test func customAgentIsRootManagedAndParticipatesInAuditWithoutDirectoryMutation() async throws {
        let root = try temporaryDirectory()
        let home = try temporaryDirectory()
        let customSkills = try temporaryDirectory().appendingPathComponent("my-agent-skills", isDirectory: true)
        let customEntry = customSkills.appendingPathComponent("local-review", isDirectory: true)
        try FileManager.default.createDirectory(at: customEntry, withIntermediateDirectories: true)
        try skillText(name: "Local Review", description: "Reviews local custom agent skills.")
            .write(to: customEntry.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let controller = SkillsHubLibraryController(
            agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation),
            agentHomeDirectory: home,
            agentEnvironment: [:],
            startupAccessStore: InMemoryStartupAccessStore(restorablePaths: [root.path, customSkills.path])
        )
        try await connectInitializedTestRoot(controller, at: root)
        await controller.refreshAgentLightScan(checkInstallation: true)

        let customAgent = try await controller.addCustomAgent(
            displayName: "My Custom Agent",
            iconMonogram: "MC",
            skillsDirectory: customSkills
        )

        let metadataText = try String(contentsOf: root.appendingPathComponent(".skillshub.json"), encoding: .utf8)
        let localState = try SkillsHubLocalStateStore().load(from: root)
        #expect(metadataText.contains("My Custom Agent"))
        let persistedCustomAgent = try #require(controller.rootSnapshot?.metadata.agents.first { $0.id == customAgent.id })
        #expect(localState.customAgents.isEmpty)
        #expect(persistedCustomAgent.id == customAgent.id)
        #expect(persistedCustomAgent.displayName == customAgent.displayName)
        #expect(persistedCustomAgent.skillsDirectory == customAgent.skillsDirectory)
        #expect(persistedCustomAgent.iconMonogram == "MC")
        #expect(controller.agentDetections.contains { $0.agentID == customAgent.id && $0.isCustom && $0.entryCount == 1 })

        try await controller.auditAgentDirectory(agentID: customAgent.id)

        let customFinding = try #require(controller.agentFindings.first { $0.agentID == customAgent.id })
        #expect(customFinding.agentDisplayName == "My Custom Agent")
        #expect(customFinding.entryName == "local-review")
        #expect(customFinding.type == AgentFindingType.localDirectoryNotManaged)

        #expect(FileManager.default.fileExists(atPath: customEntry.path))
    }

    @Test func sameCustomAgentNameKeepsIndependentStableIdentities() async throws {
        let root = try temporaryDirectory()
        let firstDirectory = try temporaryDirectory()
        let secondDirectory = try temporaryDirectory()
        let controller = SkillsHubLibraryController(
            startupAccessStore: InMemoryStartupAccessStore(
                restorablePaths: [root.path, firstDirectory.path, secondDirectory.path]
            )
        )
        try await connectInitializedTestRoot(controller, at: root)

        let first = try await controller.addCustomAgent(
            displayName: "Reviewer",
            iconMonogram: "R1",
            skillsDirectory: firstDirectory
        )
        let second = try await controller.addCustomAgent(
            displayName: "Reviewer",
            iconMonogram: "R2",
            skillsDirectory: secondDirectory
        )

        #expect(first.id != second.id)
        #expect(controller.rootSnapshot?.metadata.agents.filter { $0.displayName == "Reviewer" }.count == 2)
        let intentsBefore = controller.rootSnapshot?.metadata.enablementIntents
        try await controller.saveAgentDisplayFields(
            agentID: first.id,
            displayName: "Reviewer Renamed",
            iconMonogram: "AAAA"
        )
        let renamed = try #require(controller.visibleInstalledAgentDescriptors.first { $0.id == first.id })
        #expect(renamed.displayName == "Reviewer Renamed")
        #expect(renamed.iconMonogram == "AAAA")
        #expect(AgentPresentation(descriptor: renamed).monogramRows == ["AA", "AA"])
        #expect(controller.rootSnapshot?.metadata.agents.first { $0.id == first.id }?.skillsDirectory == firstDirectory.path)
        #expect(controller.rootSnapshot?.metadata.agents.first { $0.id == second.id }?.displayName == "Reviewer")
        #expect(controller.rootSnapshot?.metadata.enablementIntents == intentsBefore)
    }

    @Test func localSourceAddRequiresRoot() async throws {
        let source = try temporaryDirectory()
        let controller = SkillsHubLibraryController()
        await controller.addLocalSource(from: source)
        #expect(controller.errorMessage == "Choose a root before continuing.")
    }

    @Test func manualBrokenSymlinkRemainsVisibleInNeedsAttention() async throws {
        let root = try temporaryDirectory()
        let broken = root.appendingPathComponent("local/broken-link")
        try FileManager.default.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: broken.path, withDestinationPath: root.appendingPathComponent("missing").path)
        try saveManagedSkillFixture(
            root: root,
            directory: broken,
            id: "broken-link",
            name: "Broken Link",
            description: "Managed link with a missing target."
        )

        let controller = SkillsHubLibraryController()
        try await connectInitializedTestRoot(controller, at: root)

        #expect(controller.installedSkills.map(\.id) == ["broken-link"])
        #expect(controller.installedSkills.first?.validation.status == .invalid)
        #expect(controller.installedSkills.first?.validation.messages.isEmpty == false)
    }

}

private func writeSkillFixture(_ directory: URL, name: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try skillText(name: name, description: "\(name) fixture.").write(
        to: directory.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
}

private func saveManagedSkillFixture(
    root: URL,
    directory: URL,
    id: String,
    name: String,
    description: String
) throws {
    let store = SkillsHubMetadataStore()
    let metadata = SkillsHubMetadata(
        rootConfig: RootConfig(rootPath: root.path),
        installedSkills: [
            InstalledSkill(
                id: id,
                sourceID: nil,
                name: name,
                description: description,
                installedPath: directory.path,
                sourceKind: .localDirectory,
                validation: .valid,
                purpose: nil,
                tagIDs: [],
                installedAt: Date(timeIntervalSince1970: 0)
            )
        ]
    )
    try store.save(metadata, to: root)
}

private func skillText(name: String, description: String) -> String {
    """
    ---
    name: \(name)
    description: \(description)
    ---
    Body.
    """
}

@MainActor
func makeControllerRelationFixture(
    agents: [AgentKind], linkService: AgentLinkService = AgentLinkService(),
    startupAccessStore: (any StartupAccessStoring)? = nil
) async throws -> (
    controller: SkillsHubLibraryController,
    root: URL,
    targets: [AgentKind: URL],
    assetID: UUID
) {
    let root = try temporaryDirectory()
    let source = root.appendingPathComponent("local/writer", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try skillText(
        name: "Writer",
        description: "Writes concise local documents."
    ).write(
        to: source.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
    try saveManagedSkillFixture(
        root: root,
        directory: source,
        id: "writer",
        name: "Writer",
        description: "Writes concise local documents."
    )

    let home = try temporaryDirectory()
    var targets: [AgentKind: URL] = [:]
    for agent in agents {
        let target = AgentPathResolver().globalSkillsDirectory(
            for: agent,
            environment: [:],
            homeDirectory: home
        )
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        targets[agent] = target
    }
    let accessStore = InMemoryStartupAccessStore(
        restorablePaths: Set([root.path] + targets.values.map(\.path))
    )
    let controller = SkillsHubLibraryController(
        agentLinkService: linkService,
        agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation),
        agentHomeDirectory: home,
        agentEnvironment: [:],
        startupAccessStore: startupAccessStore ?? accessStore
    )
    try await connectInitializedTestRoot(controller, at: root)
    await controller.refreshAgentLightScan(checkInstallation: true)
    let assetID = try #require(controller.installedSkills.first).assetID
    return (controller, root, targets, assetID)
}

private final class InMemoryStartupAccessStore: StartupAccessStoring {
    var restorablePaths: Set<String>
    var restoredPaths: [String] = []
    var savedPaths: [String] = []

    init(restorablePaths: Set<String> = []) {
        self.restorablePaths = restorablePaths
    }

    func resolveAccess(to url: URL) throws -> StartupAccessBookmarkResolution? {
        let path = url.standardizedFileURL.path
        guard restorablePaths.contains(path) else {
            return nil
        }
        restoredPaths.append(path)
        return StartupAccessBookmarkResolution(url: url.standardizedFileURL, isStale: false)
    }

    func saveAccess(to url: URL) throws {
        let path = url.standardizedFileURL.path
        savedPaths.append(path)
        restorablePaths.insert(path)
    }
}
