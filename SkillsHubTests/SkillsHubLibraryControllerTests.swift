import Foundation
import Testing
@testable import SkillsHub

@MainActor
struct SkillsHubLibraryControllerTests {
    @Test(arguments: [AgentKind.codex, .claudeCode])
    func authorizedDirectoryWithoutInstallationCanEnableManagedCapability(_ agent: AgentKind) throws {
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
        try connectInitializedTestRoot(controller, at: root)

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
        try connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()

        #expect(controller.hasRoot)
        #expect(controller.rootPathDisplay == root.path)
        // T-006: connecting a Root discovers manual local/ content and registers it as
        // a manual-filesystem skill, but never enables it for any Agent and never
        // records a source (REQ-003 auto-discovery, REQ-014 re-check).
        #expect(controller.installedSkills.map(\.id) == ["manual-review"])
        let registeredManual = try #require(controller.installedSkills.first)
        #expect(registeredManual.sourceKind == .manualFilesystem)
        #expect(registeredManual.sourceID == nil)
        #expect(controller.sources.isEmpty)
        #expect(controller.availableSkills.isEmpty)
        #expect(controller.agentLinks.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".skillshub.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("local").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("github").path))

        let metadata = try SkillsHubMetadataStore().load(from: root)
        #expect(metadata.schemaVersion == 4)
        #expect(metadata.installedSkills.map(\.id) == ["manual-review"])
    }

    @Test func settingsRootDefaultsToSkillsHubDirectoryUntilUserConfiguresRoot() throws {
        let home = try temporaryDirectory()
        let controller = SkillsHubLibraryController(agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation), agentHomeDirectory: home)

        #expect(controller.settingsRootPathDisplay == home.appendingPathComponent("ai-projects/skills-hub").path)
        #expect(controller.suggestedRootURL.path == home.appendingPathComponent("ai-projects/skills-hub").path)

        let root = try temporaryDirectory()
        try connectInitializedTestRoot(controller, at: root)
        controller.refreshAgentLightScan(checkInstallation: true)

        #expect(controller.rootPathDisplay == root.path)
        #expect(controller.settingsRootPathDisplay == root.path)
        #expect(controller.suggestedRootURL.path == root.path)
    }

    @Test func settingsStateTreatsControllerDefaultRootAsDefault() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let controller = SkillsHubLibraryController(agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation), agentHomeDirectory: home)

        #expect(controller.settingsState.rootPath == "/Users/test/ai-projects/skills-hub")
        #expect(controller.settingsState.customRootWarning == nil)
    }

    @Test func localSourceRootDoesNotBypassRegistrationPlan() async throws {
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
        try connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()

        // T-006: local/ directories with candidates are discovered and registered as
        // manual-filesystem skills, but this never creates a source (which still
        // requires a confirmed registration plan) and never populates availableSkills.
        #expect(Set(controller.installedSkills.map(\.id)) == ["review", "write"])
        #expect(controller.installedSkills.allSatisfy { $0.sourceKind == .manualFilesystem })
        #expect(controller.installedSkills.allSatisfy { $0.sourceID == nil })
        #expect(controller.sources.isEmpty)
        #expect(controller.availableSkills.isEmpty)
    }

    @Test func reloadKeepsUnregisteredRootContentOutsideManagedMetadata() async throws {
        let root = try temporaryDirectory()
        let manual = root.appendingPathComponent("local/manual-review", isDirectory: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try skillText(name: "Manual Review", description: "Reviews manually installed skills.")
            .write(to: manual.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let controller = SkillsHubLibraryController()
        try connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()
        // T-006: the manual directory was discovered and registered on connect.
        #expect(controller.installedSkills.map(\.id) == ["manual-review"])
        let metadataFile = SkillsHubMetadataStore().rootLayout(for: root).skillshubMetadataFile
        // Capture the authoritative metadata AFTER registration; reload must not write
        // again and must not prune the deleted directory's registration.
        let metadataAfterRegistration = try Data(contentsOf: metadataFile)

        try FileManager.default.removeItem(at: manual)
        try controller.reloadFromDisk()

        // The registration and its missing record are preserved (Q-002/REQ-018); the
        // deleted directory is marked invalid, not pruned, and no JSON is rewritten.
        #expect(controller.installedSkills.map(\.id) == ["manual-review"])
        #expect(controller.installedSkills.first?.validation.status == .invalid)
        #expect(controller.scanStatusMessage?.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: manual.path))

        #expect(try Data(contentsOf: metadataFile) == metadataAfterRegistration)
        let metadata = try SkillsHubMetadataStore().load(from: root)
        #expect(metadata.installedSkills.map(\.id) == ["manual-review"])
    }

    @Test func reloadFailureKeepsPreviousInstalledState() async throws {
        let root = try temporaryDirectory()
        let manual = root.appendingPathComponent("local/manual-review", isDirectory: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try skillText(name: "Manual Review", description: "Reviews manually installed skills.")
            .write(to: manual.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let controller = SkillsHubLibraryController()
        try connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()
        #expect(controller.installedSkills.map(\.id) == ["manual-review"])
        let previousInstalled = controller.installedSkills
        let previousScanStatus = controller.scanStatusMessage

        try "{".write(to: root.appendingPathComponent(".skillshub.local.json"), atomically: true, encoding: .utf8)

        do {
            try controller.reloadFromDisk()
            Issue.record("Expected reloadFromDisk to fail on corrupted local state.")
        } catch {
            #expect(controller.installedSkills.map(\.id) == previousInstalled.map(\.id))
            #expect(controller.scanStatusMessage == previousScanStatus)
        }
    }

    @Test func bootstrapDefaultRootDoesNotAdoptWritableDirectoryWithoutPersistedAuthorization() throws {
        let home = try temporaryDirectory()
        let defaultRoot = home.appendingPathComponent("ai-projects/skills-hub", isDirectory: true)
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
        try controller.bootstrapDefaultRootIfPresent()

        #expect(!controller.hasRoot)
        #expect(controller.settingsRootPathDisplay == defaultRoot.path)
        #expect(controller.installedSkills.isEmpty)
        #expect(FileManager.default.fileExists(atPath: defaultRoot.appendingPathComponent(".skillshub.json").path))
        #expect(!FileManager.default.fileExists(atPath: defaultRoot.appendingPathComponent(".skillshub.local.json").path))
    }

    @Test func bootstrapDefaultRootDoesNotCreateMissingDefaultDirectory() throws {
        let home = try temporaryDirectory()
        let controller = SkillsHubLibraryController(agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation), agentHomeDirectory: home)

        try controller.bootstrapDefaultRootIfPresent()

        #expect(!controller.hasRoot)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("ai-projects/skills-hub").path))
    }

    @Test func bootstrapDefaultRootDoesNotReadMetadataWithoutPersistedAuthorization() throws {
        let home = try temporaryDirectory()
        let defaultRoot = home.appendingPathComponent("ai-projects/skills-hub", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        try "{ invalid json".write(to: defaultRoot.appendingPathComponent(".skillshub.json"), atomically: true, encoding: .utf8)

        let controller = SkillsHubLibraryController(agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation), agentHomeDirectory: home)

        try controller.bootstrapDefaultRootIfPresent()

        #expect(controller.rootURL == nil)
        #expect(!controller.hasRoot)
        #expect(controller.settingsRootPathDisplay == defaultRoot.path)
    }

    @Test func startupAuthorizationRequestIncludesDefaultRootAndDetectedBuiltInAgentsWithoutWriteAccess() throws {
        let home = try temporaryDirectory()
        let defaultRoot = home.appendingPathComponent("ai-projects/skills-hub", isDirectory: true)
        let codexMarker = home.appendingPathComponent(".codex", isDirectory: true)
        let claudeSkills = home.appendingPathComponent(".claude/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexMarker, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: defaultRoot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: codexMarker.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.appendingPathComponent(".claude", isDirectory: true).path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: claudeSkills.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: defaultRoot.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexMarker.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent(".claude", isDirectory: true).path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeSkills.path)
        }

        let controller = SkillsHubLibraryController(agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation), agentHomeDirectory: home, agentEnvironment: [:])
        try controller.bootstrapDefaultRootIfPresent()

        #expect(controller.hasRoot == false)
        let request = try #require(try controller.startupAuthorizationRequest())
        #expect(request.targets.map(\.id) == ["default-root", "agent-claudeCode", "agent-codex"])
        #expect(request.targets.first?.authorizationURL.path == defaultRoot.path)
        let claudeTarget = try #require(request.targets.first { $0.id == "agent-claudeCode" })
        #expect(claudeTarget.authorizationURL.path == claudeSkills.path)
        let codexTarget = try #require(request.targets.first { $0.id == "agent-codex" })
        #expect(codexTarget.authorizationURL.path == codexMarker.path)
    }

    @Test func startupAuthorizationRestoresPersistedDefaultRootAccessWithoutPromptingAgain() throws {
        let home = try temporaryDirectory()
        let defaultRoot = home.appendingPathComponent("ai-projects/skills-hub", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        try SkillsHubMetadataStore().save(
            SkillsHubMetadata(rootConfig: RootConfig(rootPath: defaultRoot.path)),
            to: defaultRoot
        )
        let accessStore = InMemoryStartupAccessStore(restorablePaths: [defaultRoot.standardizedFileURL.path])
        let controller = SkillsHubLibraryController(agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation), agentHomeDirectory: home, startupAccessStore: accessStore)

        try controller.bootstrapDefaultRootIfPresent()

        #expect(controller.hasRoot)
        let request = try controller.startupAuthorizationRequest()
        #expect(request == nil)
        #expect(accessStore.restoredPaths.contains(defaultRoot.standardizedFileURL.path))
    }

    @Test func startupAuthorizationSkipsBuiltInAgentWhenPersistedAccessRestores() throws {
        let root = try temporaryDirectory()
        let home = try temporaryDirectory()
        let codexMarker = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexMarker, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: codexMarker.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexMarker.path)
        }
        let accessStore = InMemoryStartupAccessStore(restorablePaths: [codexMarker.standardizedFileURL.path])
        let controller = SkillsHubLibraryController(agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation), agentHomeDirectory: home, agentEnvironment: [:], startupAccessStore: accessStore)
        try connectInitializedTestRoot(controller, at: root)
        controller.refreshAgentLightScan(checkInstallation: true)

        let request = try controller.startupAuthorizationRequest()

        #expect(request?.targets.contains(where: { $0.id == "agent-codex" }) != true)
        #expect(accessStore.restoredPaths.contains(codexMarker.standardizedFileURL.path))
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

    @Test func authorizationTargetReturnsDetectedBuiltInAgentDirectoryNeedingAccess() throws {
        let root = try temporaryDirectory()
        let home = try temporaryDirectory()
        let codexMarker = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexMarker, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: codexMarker.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexMarker.path)
        }

        let controller = SkillsHubLibraryController(agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation), agentHomeDirectory: home, agentEnvironment: [:])
        try connectInitializedTestRoot(controller, at: root)
        controller.refreshAgentLightScan(checkInstallation: true)

        let target = try controller.authorizationTarget(for: .codex)

        #expect(target?.id == "agent-codex")
        #expect(target?.authorizationURL.path == codexMarker.path)
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
        try connectInitializedTestRoot(controller, at: root)
        controller.refreshAgentLightScan(checkInstallation: true)

        let enabled = try await controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            skillID: "writer",
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
        #expect(enabledSnapshot.metadata.managedRelationEvidence.count == 1)
        #expect(try SkillsHubLocalStateStore().load(from: root).managedRelationEvidence.isEmpty)

        let repeated = try await controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            skillID: "writer",
            enabled: true
        )
        #expect(repeated.outcome == .noChange)
        #expect(try SkillsHubMetadataStore().loadCurrentSnapshot(from: root).generation == enabledSnapshot.generation)

        let disabled = try await controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            skillID: "writer",
            enabled: false
        )
        #expect(disabled.outcome == .succeeded)
        #expect((try? LinkNodeIdentity.read(at: link)) == nil)
        let disabledSnapshot = try SkillsHubMetadataStore().loadCurrentSnapshot(from: root)
        #expect(disabledSnapshot.metadata.enablementIntents.first?.isEnabled == false)
        #expect(disabledSnapshot.metadata.managedRelationEvidence.isEmpty)
        #expect(controller.agentLinks.isEmpty)
    }

    @Test func savingAgentDisplayFieldsChangesNoDirectoryRelationshipOrContent() async throws {
        let fixture = try makeControllerRelationFixture(agents: [.codex])
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
        let fixture = try makeControllerRelationFixture(agents: [.codex])
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
        let fixture = try makeControllerRelationFixture(agents: [.codex])

        let enabled = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            skillID: "writer",
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
            skillID: "writer",
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
        let fixture = try makeControllerRelationFixture(agents: [.codex])

        async let first = fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            skillID: "writer",
            enabled: true
        )
        async let duplicate = fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            skillID: "writer",
            enabled: true
        )
        let results = try await [first, duplicate]

        #expect(results.filter { $0.outcome == .succeeded }.count == 1)
        #expect(results.filter { $0.outcome == .replayed }.count == 1)
        let snapshot = try SkillsHubMetadataStore().loadCurrentSnapshot(from: fixture.root)
        #expect(snapshot.metadata.enablementIntents.count == 1)
        let creation = try #require(snapshot.metadata.managedRelationEvidence.first?.creation)
        let stagingDirectory = URL(fileURLWithPath: creation.stagingPath).deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.targets[.codex]!.path).sorted()
            == [stagingDirectory.lastPathComponent, "Writer"].sorted())
        #expect(try FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path).isEmpty)
    }

    @Test func oneAgentRelationActionLeavesTheOtherAgentUnchanged() async throws {
        let fixture = try makeControllerRelationFixture(agents: [.codex, .claudeCode])

        let result = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            skillID: "writer",
            enabled: true
        )

        #expect(result.outcome == .succeeded)
        #expect(FileManager.default.fileExists(atPath: fixture.targets[.codex]!.appendingPathComponent("Writer").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.targets[.claudeCode]!.path).isEmpty)
        let intents = try SkillsHubMetadataStore().loadCurrentSnapshot(from: fixture.root).metadata.enablementIntents
        #expect(intents.map(\.agentID) == [AgentKind.codex.rawValue])
    }

    @Test func dualAgentEnablementSharesCanonicalSkillAndDisablePreservesOtherRelation() async throws {
        let fixture = try makeControllerRelationFixture(agents: [.codex, .claudeCode])
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
            skillID: "writer",
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
            skillID: "writer",
            enabled: true
        )
        #expect(claudeEnabled.outcome == .succeeded)
        #expect(codexLink.resolvingSymlinksInPath().standardizedFileURL.path == canonicalSkill.path)
        #expect(claudeLink.resolvingSymlinksInPath().standardizedFileURL.path == canonicalSkill.path)

        let dualState = fixture.controller.localState
        let dualEvidence = fixture.controller.rootSnapshot?.metadata.managedRelationEvidence ?? []
        let dualVerifications = dualState.verificationRecords
        #expect(Set(dualEvidence.map(\.profileID)) == [
            "skillshub.agent-profile.codex.global@1",
            "skillshub.agent-profile.claude-code.global@1"
        ])
        #expect(Set(dualEvidence.map(\.canonicalTargetPath)) == [canonicalSkill.path])
        #expect(Set(dualVerifications.map(\.relation.agentID)) == [
            AgentKind.codex.rawValue,
            AgentKind.claudeCode.rawValue
        ])
        #expect(dualVerifications.allSatisfy { $0.conclusion == .verifiedConsistent })
        let installedSkill = try #require(fixture.controller.installedSkills.first { $0.id == "writer" })
        let dualPresentations = fixture.controller.relationPresentations(for: installedSkill)
        #expect(dualPresentations.first { $0.agentKind == .codex }?.verification == .verifiedConsistent)
        #expect(dualPresentations.first { $0.agentKind == .claudeCode }?.verification == .verifiedConsistent)
        let claudeLinkText = try FileManager.default.destinationOfSymbolicLink(atPath: claudeLink.path)

        let codexDisabled = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            skillID: "writer",
            enabled: false
        )
        #expect(codexDisabled.outcome == .succeeded)
        #expect((try? LinkNodeIdentity.read(at: codexLink)) == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: claudeLink.path) == claudeLinkText)
        #expect(claudeLink.resolvingSymlinksInPath().standardizedFileURL.path == canonicalSkill.path)
        #expect(
            fixture.controller.relationPresentations(for: installedSkill)
                .first { $0.agentKind == .claudeCode }?.verification == .verifiedConsistent
        )

        _ = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            skillID: "writer",
            enabled: true
        )
        let codexLinkText = try FileManager.default.destinationOfSymbolicLink(atPath: codexLink.path)
        let claudeDisabled = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.claudeCode.rawValue,
            skillID: "writer",
            enabled: false
        )
        #expect(claudeDisabled.outcome == .succeeded)
        #expect((try? LinkNodeIdentity.read(at: claudeLink)) == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: codexLink.path) == codexLinkText)
        #expect(codexLink.resolvingSymlinksInPath().standardizedFileURL.path == canonicalSkill.path)
        #expect(
            fixture.controller.relationPresentations(for: installedSkill)
                .first { $0.agentKind == .codex }?.verification == .verifiedConsistent
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
        let fixture = try makeControllerRelationFixture(agents: [.codex])
        _ = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            skillID: "writer",
            enabled: true
        )
        let link = fixture.targets[.codex]!.appendingPathComponent("Writer")
        try FileManager.default.moveItem(at: link, to: fixture.root.appendingPathComponent("removed-link"))
        try fixture.controller.auditAgentDirectory(agentID: AgentKind.codex.rawValue)

        let skill = try #require(fixture.controller.installedSkills.first { $0.id == "writer" })
        let presentation = try #require(
            fixture.controller.relationPresentations(for: skill).first { $0.agentKind == .codex }
        )
        #expect(presentation.intendedEnabled == true)
        #expect(presentation.desiredEnabled == false)
        #expect(presentation.canReestablish)

        let result = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            skillID: "writer",
            enabled: true
        )
        #expect(result.outcome == .succeeded)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == skill.installedPath)
    }

    @Test func customAgentUsesTheSameRelationActionPath() async throws {
        let fixture = try makeControllerRelationFixture(agents: [])
        let target = try temporaryDirectory()
        try fixture.controller.rememberUserSelectedAccess(to: target)
        let custom = try await fixture.controller.addCustomAgent(
            displayName: "Custom Bench",
            iconMonogram: "CB",
            skillsDirectory: target
        )

        let result = try await fixture.controller.setGlobalAgentEnablement(
            agentID: custom.id,
            skillID: "writer",
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
        #expect(relation.agentKind == nil)
        #expect(relation.agentDisplayName == "Custom Bench")
        #expect(relation.iconMonogram == "CB")
        #expect(relation.verification == .verifiedConsistent)
    }

    @Test func agentCapabilityAndRelationPresentationUseCurrentIndependentFacts() async throws {
        let fixture = try makeControllerRelationFixture(agents: [.codex, .claudeCode])

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
            skillID: "writer",
            enabled: true
        )

        let skill = try #require(fixture.controller.installedSkills.first { $0.id == "writer" })
        var relations = fixture.controller.relationPresentations(for: skill)
        let codex = try #require(relations.first { $0.agentKind == .codex })
        let claude = try #require(relations.first { $0.agentKind == .claudeCode })
        #expect(codex.intendedEnabled == true)
        #expect(codex.observation == .symbolicLink)
        #expect(codex.verification == .verifiedConsistent)
        #expect(codex.lastOutcome == .succeeded)
        #expect(codex.canPerformAction)
        #expect(!codex.isInFlight)
        #expect(claude.intendedEnabled == nil)
        #expect(claude.observation == nil)
        #expect(claude.verification == .notVerified)

        let currentGeneration = try #require(fixture.controller.rootSnapshot?.generation)
        fixture.controller.rootSnapshot?.generation = currentGeneration + 1
        relations = fixture.controller.relationPresentations(for: skill)
        #expect(relations.first { $0.agentKind == .codex }?.verification == .notVerified)
        #expect(relations.first { $0.agentKind == .claudeCode }?.verification == .notVerified)

        fixture.controller.rootSnapshot?.generation = currentGeneration
        let observationIndex = try #require(
            fixture.controller.localState.targetObservations.firstIndex { $0.relation.agentID == AgentKind.codex.rawValue }
        )
        fixture.controller.localState.targetObservations[observationIndex].isReadable = false
        relations = fixture.controller.relationPresentations(for: skill)
        #expect(relations.first { $0.agentKind == .codex }?.verification == .currentlyUnverifiable)
        #expect(relations.first { $0.agentKind == .codex }?.safeNextStep == "Restore current access and observe the relation again.")
    }

    @Test(arguments: [AgentKind.codex, .claudeCode])
    func relationPresentationRejectsReplacedNodeAfterAudit(_ agent: AgentKind) async throws {
        let fixture = try makeControllerRelationFixture(agents: [.codex, .claudeCode])
        for enabledAgent in [AgentKind.codex, .claudeCode] {
            _ = try await fixture.controller.setGlobalAgentEnablement(
                agentID: enabledAgent.rawValue, skillID: "writer", enabled: true
            )
        }
        let skill = try #require(fixture.controller.installedSkills.first { $0.id == "writer" })
        let before = try #require(fixture.controller.relationPresentations(for: skill).first { $0.agentKind == agent })
        try #require(before.verification == .verifiedConsistent)
        let otherObservation = fixture.controller.localState.targetObservations.first { $0.relation.agentID != agent.rawValue }
        let otherVerification = fixture.controller.localState.verificationRecords.first { $0.relation.agentID != agent.rawValue }
        let ownership = fixture.controller.rootSnapshot?.metadata.managedRelationEvidence ?? []
        let intents = fixture.controller.rootSnapshot?.metadata.enablementIntents
        let metadataURL = fixture.root.appendingPathComponent(".skillshub.json")
        let metadata = try Data(contentsOf: metadataURL)
        let target = try #require(fixture.targets[agent])
        let link = target.appendingPathComponent("Writer")
        try FileManager.default.moveItem(at: link, to: fixture.root.appendingPathComponent("original-link"))
        let externalContent = Data("External replacement".utf8)
        try externalContent.write(to: link)

        try fixture.controller.auditAgentDirectory(agentID: agent.rawValue)

        let after = try #require(fixture.controller.relationPresentations(for: skill).first { $0.agentKind == agent })
        #expect(after.verification != .verifiedConsistent)
        #expect(after.verification == .drifted)
        #expect(after.observation == .regularFile)
        #expect(after.safeNextStep == "Review the current relation before preparing another action.")
        #expect(fixture.controller.relationPresentations(for: skill).first { $0.agentKind != agent }?.verification == .verifiedConsistent)
        #expect(fixture.controller.rootSnapshot?.metadata.enablementIntents == intents)
        #expect(try Data(contentsOf: metadataURL) == metadata)
        #expect(try Data(contentsOf: link) == externalContent)
        #expect(fixture.controller.rootSnapshot?.metadata.managedRelationEvidence == ownership)
        #expect(fixture.controller.localState.managedRelationEvidence.isEmpty)
        #expect(fixture.controller.localState.targetObservations.first { $0.relation.agentID != agent.rawValue } == otherObservation)
        #expect(fixture.controller.localState.verificationRecords.first { $0.relation.agentID != agent.rawValue } == otherVerification)
        let persisted = try SkillsHubLocalStateStore().load(from: fixture.root)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(persisted) == encoder.encode(fixture.controller.localState))
        let observation = try #require(persisted.targetObservations.first { $0.relation.agentID == agent.rawValue })
        #expect(observation.fileIdentity != ownership.first { $0.relation.agentID == agent.rawValue }?.fileIdentity)
        #expect(persisted.verificationRecords.first { $0.relation.agentID == agent.rawValue }?.bindings.observationDigest == observation.digest)
    }

    @Test(arguments: [AgentKind.codex, .claudeCode], ["unchanged", "vacant", "directory", "external", "broken", "replacement", "permission"])
    func relationChecksUseCurrentFileFacts(_ agent: AgentKind, _ change: String) async throws {
        let fixture = try makeControllerRelationFixture(agents: [agent])
        try fixture.controller.saveLocalState()
        _ = try await fixture.controller.setGlobalAgentEnablement(agentID: agent.rawValue, skillID: "writer", enabled: true)
        let skill = try #require(fixture.controller.installedSkills.first { $0.id == "writer" })
        let target = try #require(fixture.targets[agent])
        let link = target.appendingPathComponent("Writer")
        let metadataURL = fixture.root.appendingPathComponent(".skillshub.json")
        let metadata = try Data(contentsOf: metadataURL)
        let ownership = fixture.controller.rootSnapshot?.metadata.managedRelationEvidence ?? []
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
        let expected: VerificationConclusion = change == "unchanged" ? .verifiedConsistent
            : change == "permission" ? .currentlyUnverifiable : .drifted

        fixture.controller.refreshAgentLightScan()
        var presentation = try #require(
            fixture.controller.relationPresentations(for: skill).first { $0.agentKind == agent }
        )
        #expect(presentation.observation == node)
        #expect(presentation.verification == expected)
        try fixture.controller.auditAllDetectedAgentDirectories()
        presentation = try #require(
            fixture.controller.relationPresentations(for: skill).first { $0.agentKind == agent }
        )
        #expect(presentation.observation == node)
        #expect(presentation.verification == expected)
        let persisted = try SkillsHubLocalStateStore().load(from: fixture.root)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(persisted) == encoder.encode(fixture.controller.localState))
        #expect(fixture.controller.rootSnapshot?.metadata.managedRelationEvidence == ownership)
        #expect(fixture.controller.localState.managedRelationEvidence.isEmpty)
        #expect(try Data(contentsOf: metadataURL) == metadata)

        if change == "permission" {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            try fixture.controller.auditAgentDirectory(agentID: agent.rawValue)
            #expect(
                fixture.controller.relationPresentations(for: skill)
                    .first { $0.agentKind == agent }?.verification == .verifiedConsistent
            )
        }
    }

    @Test func agentPathSettingsResolveEnvironmentDefaultsAndScanStatus() throws {
        let root = try temporaryDirectory()
        let home = try temporaryDirectory()
        let codexHome = try temporaryDirectory()
        let controller = SkillsHubLibraryController(
            agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation),
            agentHomeDirectory: home,
            agentEnvironment: ["CODEX_HOME": codexHome.path]
        )
        try connectInitializedTestRoot(controller, at: root)
        controller.refreshAgentLightScan(checkInstallation: true)

        var codex = try #require(controller.agentPathSettings.first { $0.agent == .codex })
        #expect(codex.defaultPath == codexHome.appendingPathComponent("skills").path)
        #expect(codex.resolvedPath == codex.defaultPath)
        #expect(codex.status == .missing)
        #expect(!codex.isOverride)
        #expect(!codex.skillsDirectoryExists)

        try FileManager.default.createDirectory(at: codexHome.appendingPathComponent("skills"), withIntermediateDirectories: true)
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
        try connectInitializedTestRoot(controller, at: root)
        controller.refreshAgentLightScan(checkInstallation: true)

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
        controller.refreshAgentLightScan(checkInstallation: true)

        #expect(controller.detectedBuiltInAgents == [.claudeCode, .codex])
        #expect(controller.rootSnapshot?.metadata.agents.contains { $0.id == customAgent.id } == true)
    }

    @Test func customAgentRejectsInvalidIconAbbreviation() async throws {
        let root = try temporaryDirectory()
        let target = try temporaryDirectory()
        let controller = SkillsHubLibraryController(
            startupAccessStore: InMemoryStartupAccessStore(restorablePaths: [root.path, target.path])
        )
        try connectInitializedTestRoot(controller, at: root)

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
        try connectInitializedTestRoot(controller, at: root)
        controller.refreshAgentLightScan(checkInstallation: true)

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

        try controller.auditAgentDirectory(agentID: customAgent.id)

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
        try connectInitializedTestRoot(controller, at: root)

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
        let evidenceBefore = controller.rootSnapshot?.metadata.managedRelationEvidence
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
        #expect(controller.rootSnapshot?.metadata.managedRelationEvidence == evidenceBefore)
    }

    @Test func localSourceAddRequiresRoot() async throws {
        let source = try temporaryDirectory()
        let controller = SkillsHubLibraryController()
        await controller.addLocalSource(from: source)
        #expect(controller.errorMessage == "Choose a root before continuing.")
    }

    @Test func manualBrokenSymlinkRemainsVisibleInNeedsAttention() throws {
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
        try connectInitializedTestRoot(controller, at: root)

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
    agents: [AgentKind]
) throws -> (
    controller: SkillsHubLibraryController,
    root: URL,
    targets: [AgentKind: URL]
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
        agentAuditService: AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation),
        agentHomeDirectory: home,
        agentEnvironment: [:],
        startupAccessStore: accessStore
    )
    try connectInitializedTestRoot(controller, at: root)
    controller.refreshAgentLightScan(checkInstallation: true)
    return (controller, root, targets)
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
