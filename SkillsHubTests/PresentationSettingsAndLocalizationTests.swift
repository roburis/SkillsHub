import AppKit
import Foundation
import Testing
@testable import SkillsHub

struct PresentationSettingsAndLocalizationTests {
    @MainActor
    @Test func nativeListWidthClampsWithoutOverwritingTheSavedPreference() {
        let key = "SkillsHub.test-width.\(UUID())"
        UserDefaults.standard.set(480.0, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let controller = WorkspaceSplitController(key: key)
        let split = controller.view as! NSSplitView
        split.frame = NSRect(x: 0, y: 0, width: 700, height: 560)
        controller.splitView(split, resizeSubviewsWithOldSize: .zero)
        #expect(controller.trailing.view.frame.width >= 360)
        #expect(controller.leading.view.frame.width == 700 - split.dividerThickness - 360)
        #expect(UserDefaults.standard.double(forKey: key) == 480)
        split.frame.size.width = 1000
        controller.splitView(split, resizeSubviewsWithOldSize: .zero)
        #expect(controller.leading.view.frame.width == 480)
        #expect(!controller.splitView(split, canCollapseSubview: controller.leading.view))
        #expect(controller.splitView(split, constrainSplitPosition: 520, ofSubviewAt: 0) == 520)
        #expect(UserDefaults.standard.double(forKey: key) == 520)
        split.frame.size.width = 750
        controller.splitView(split, resizeSubviewsWithOldSize: .zero)
        #expect(controller.trailing.view.frame.width >= 360)
        #expect(UserDefaults.standard.double(forKey: key) == 520)
        split.frame.size.width = 1000
        controller.splitView(split, resizeSubviewsWithOldSize: .zero)
        #expect(controller.leading.view.frame.width == 520)
        split.setPosition(288, ofDividerAt: 0)
        #expect(controller.leading.view.frame.width == 288)
    }

    @Test func phase1CatalogUsesLocationForUnnamedCandidatesAndStableFiltering() {
        let source = SkillSource(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            kind: .localDirectory,
            name: "Local Source",
            localPath: "/fixture/local-source"
        )
        let invalid = AvailableSkill(
            id: "invalid",
            sourceID: source.id,
            skillPath: "nested/invalid",
            name: "   ",
            description: "Missing a usable name.",
            validation: SkillValidationResult(
                status: .invalid,
                messages: [ValidationMessage(id: "missing-name", severity: .error, message: "Missing name.")],
                risks: []
            ),
            candidateID: "invalid-candidate"
        )
        let enabledAssetID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let enabled = InstalledSkill(
            id: "review",
            sourceID: source.id,
            name: "Review",
            description: "Reviews changes.",
            installedPath: "/fixture/root/local/review",
            sourceKind: .localDirectory,
            validation: .valid,
            purpose: nil,
            tagIDs: [],
            installedAt: .distantPast,
            assetID: enabledAssetID
        )
        let service = SkillCatalogPresentationService()
        let items = service.phase1Items(
            availableSkills: [invalid],
            installedSkills: [enabled],
            sources: [source],
            enablementIntents: [
                EnablementIntent(
                    assetID: enabledAssetID,
                    agentID: AgentKind.codex.rawValue,
                    scope: .global,
                    isEnabled: true,
                    generation: 1
                )
            ]
        )

        #expect(items.map(\.name) == ["Review", "Unnamed skill · nested/invalid"])
        #expect(service.filteredPhase1Items(items, query: "local source", filter: .needsAttention).map(\.id) == ["invalid-candidate"])
        #expect(service.filteredPhase1Items(items, query: "", filter: .notEnabled).map(\.id) == ["invalid-candidate"])
    }

    @Test(arguments: [AppLanguage.chinese, .japanese])
    func operationTaskPhasesAndRecoveryHaveLocalizedText(language: AppLanguage) {
        let keys = [
            "Preparing", "Waiting for confirmation", "Executing", "Observing",
            "Verifying", "Completed", "Needs attention", "Running",
            "Recently completed", "View current Root", "View authoritative object",
            "Re-observe the current object before preparing a new plan.",
            "Cancelled before confirmation; no authorized write occurred."
        ]
        for key in keys {
            #expect(SkillsHubLocalization().localized(key, language: language) != key)
        }
    }

    @Test func settingsCustomRootDoesNotPromiseSystemRewrite() {
        let service = AppSettingsService()
        let state = service.state(rootPath: "/custom/root", language: .chinese, cachePolicyName: "manual")

        #expect(state.customRootWarning == "Custom root is only applied inside Skills Hub.")
    }

    @Test func localizationCoversEnglishChineseAndJapaneseKeys() {
        let localization = SkillsHubLocalization()

        #expect(localization.missingKeys(for: .english).isEmpty)
        #expect(localization.missingKeys(for: .chinese).isEmpty)
        #expect(localization.missingKeys(for: .japanese).isEmpty)
        #expect(localization.missingUIKeys(for: .chinese).isEmpty)
        #expect(localization.missingUIKeys(for: .japanese).isEmpty)
        #expect(localization.localized(.settings, language: .english) == "Settings")
        #expect(localization.localized(.settings, language: .chinese) == "设置")
        #expect(localization.localized(.settings, language: .japanese) == "設定")
        #expect(localization.localized("Choose Root", language: .chinese) == "选择 Root")
        #expect(localization.localized("Choose Root", language: .japanese) == "Rootを選択")
        // Settings language options use UX names, never raw language codes.
        #expect(AppLanguage.allCases.map(\.displayName) == ["Follow System", "English", "简体中文", "日本語"])
        #expect(localization.localized(AppLanguage.system.displayName, language: .chinese) == "跟随系统")
        #expect(localization.localized(AppLanguage.system.displayName, language: .japanese) == "システムに従う")
        // Relationship accessibility names are whole-sentence templates, so each language keeps its own word order.
        func relationLabel(_ template: String, _ arguments: [String], _ language: AppLanguage) -> String {
            localization.localized(LocalizedMessage(template, arguments: arguments), language: language)
        }
        #expect(relationLabel("Enable %@ relationship", ["Claude Code"], .english) == "Enable Claude Code relationship")
        #expect(relationLabel("Enable %@ relationship", ["Claude Code"], .chinese) == "启用 Claude Code 关系")
        #expect(relationLabel("Enable %@ relationship", ["Claude Code"], .japanese) == "Claude Codeとの関係を有効にする")
        #expect(relationLabel("Disable %@ relationship", ["Codex"], .japanese) == "Codexとの関係を無効にする")
        #expect(relationLabel("Re-establish Link %@ relationship", ["Codex"], .english) == "Re-establish Link Codex relationship")
        #expect(relationLabel("%@ relationship for %@", ["Codex", "Review Fixture"], .english) == "Codex relationship for Review Fixture")
        #expect(relationLabel("%@ relationship for %@", ["Codex", "Review Fixture"], .japanese) == "CodexとReview Fixtureの関係")
        for template in ["Enable %@ relationship", "Disable %@ relationship", "Re-establish Link %@ relationship",
                         "Working on %@ relationship", "%@ relationship for %@"] {
            for language in [AppLanguage.chinese, .japanese] {
                #expect(localization.localized(template, language: language) != template, "\(template) missing for \(language)")
            }
        }
        // User decision 2026-09-28: the Chinese page name and title are both 所有技能.
        #expect(localization.localized("All Skills", language: .chinese) == "所有技能")
        #expect(localization.localized("Search All Skills…", language: .chinese) == "搜索所有技能…")
        #expect(localization.localized(Phase1NavigationDestination.localSources.title, language: .chinese) == "本地来源")
        #expect(localization.localized(Phase1NavigationDestination.localSources.title, language: .japanese) == "ローカルソース")
        #expect(localization.localized(Phase1NavigationDestination.githubSources.title, language: .chinese) == "GitHub 来源")
        #expect(localization.localized(Phase1NavigationDestination.githubSources.title, language: .japanese) == "GitHubソース")
        #expect(localization.localized(SourceUpdateConfirmationKind.update.title, language: .chinese) == "更新整个来源")
        #expect(localization.localized(SourceUpdateConfirmationKind.update.title, language: .japanese) == "ソース全体を更新")
        #expect(localization.localized(SourceUpdateConfirmationKind.overwriteLocalChanges.title, language: .chinese) == "覆盖本地修改并更新")
        #expect(localization.localized(SourceUpdateConfirmationKind.overwriteLocalChanges.title, language: .japanese) == "ローカルの変更を上書きして更新")
        #expect(localization.localized(SourceUpdateConfirmationKind.replaceUnknownBaseline.title, language: .chinese) == "确认整体替换")
        #expect(localization.localized(SourceUpdateConfirmationKind.replaceUnknownBaseline.title, language: .japanese) == "ソース全体の置き換えを確認")
        #expect(localization.localized(LocalizedMessage("Current ownership is %@; the object remains unchanged.", arguments: ["unmanaged-node"]), language: .chinese) == "当前归属为 unmanaged-node；对象保持不变。")
        #expect(localization.localized(LocalizedMessage("Current ownership is %@; the object remains unchanged.", arguments: ["unmanaged-node"]), language: .japanese) == "現在の所有状態は unmanaged-node です。対象は変更されません。")
        let workspaceCopy = [
            "Search All Skills…", "Search This Source’s Skills…", "Check for Updates…", "Needs Attention", "View Source…",
            "Add Agent", "Agent Configuration", "Save name and abbreviation", "Custom Agent", "Built-in Agent",
            "Global skills directory", "Current directory", "Relationship management available", "Default directory verified", "Agent directory has not been verified.", "Action in progress",
            "Expanded", "Collapsed", "Will clear", "Blocked", "Cancel Fetch", "Imported · Readable", "Imported · Needs Attention",
            "Remove the verified Skills Hub-managed link and disable this relationship.",
            "Disable this relationship; no link node is currently present.",
            "Agent configuration is unavailable; no cleanup was authorized.",
            "Current ownership is %@; the object remains unchanged.", "Current facts could not be verified: %@",
            "Remove GitHub Source", "Remove Local Source", "Update Applied", "Update Needs Attention",
            "Cancel and Keep Current Content", "Content: moved to Trash", "Content: not verified as moved; inspect current paths",
            "Content: prepared source is active", "Content: not verified as applied", "Metadata and baseline: committed",
            "Metadata and baseline: not committed", "Metadata: removed", "Metadata: retained or needs verification",
            "Old content: moved to Trash", "Old content: retained for recovery", "Operation record: completed",
            "Operation record: needs attention",
            "No source update was found. Managed content and its success baseline are unchanged."
        ]
        for key in ["All Sources", "Enabled", "Not Enabled", "Not set", "No current observation", "Not verified", "Verified consistent", "Drifted", "Currently unverifiable", "Agent name is required.", "Enter 1–4 visible characters for the icon abbreviation."] + workspaceCopy {
            for language in [AppLanguage.chinese, .japanese] {
                #expect(localization.localized(key, language: language) != key)
            }
        }
    }

    @Test func agentPresentationUsesCompleteVisibleCharactersForMonograms() {
        #expect(AgentPresentation.normalizedIconMonogram(" A ") == "A")
        #expect(AgentPresentation.normalizedIconMonogram("e\u{301}") == "e\u{301}")
        #expect(AgentPresentation.normalizedIconMonogram("👨‍👩‍👧‍👦") == "👨‍👩‍👧‍👦")
        #expect(AgentPresentation.normalizedIconMonogram("日本語A") == "日本語A")
        #expect(AgentPresentation.normalizedIconMonogram("e\u{301}👨‍👩‍👧‍👦AB") == "e\u{301}👨‍👩‍👧‍👦AB")
        #expect(AgentPresentation.normalizedIconMonogram("e\u{301}👨‍👩‍👧‍👦ABC") == nil)
        #expect(AgentPresentation.normalizedIconMonogram("ABCDE") == nil)
        #expect(AgentPresentation.normalizedIconMonogram("A B") == nil)
        #expect(AgentPresentation.normalizedIconMonogram("\u{0007}") == nil)

        let presentation = AgentPresentation(descriptor: InstalledAgentDescriptor(
            id: "custom",
            displayName: "長い Custom Agent Name",
            iconMonogram: "日本語A",
            agent: nil,
            skillsDirectory: "/fixture/custom",
            isCustom: true,
            isDetected: true,
            isUnresolved: false,
            globalCapability: .available(path: "/fixture/custom")
        ))
        #expect(presentation.monogramRows == ["日本", "語A"])
        #expect(presentation.displayName == "長い Custom Agent Name")
        var repeated = presentation
        repeated.iconMonogram = "AAAA"
        #expect(repeated.monogramRows == ["AA", "AA"])
    }

    @MainActor
    @Test func producedMessagesRerenderWithoutReplayingOrChangingArguments() throws {
        let controller = SkillsHubLibraryController()
        controller.setStatus("Updated %@ for %@.", "原始 Skill", "Codex")
        let status = try #require(controller.statusMessage)

        controller.language = .chinese
        #expect(controller.localized(status) == "已为 原始 Skill 更新 Codex。")
        controller.language = .japanese
        #expect(controller.localized(status) == "原始 Skill の Codex を更新しました。")
        #expect(status.arguments == ["原始 Skill", "Codex"])

        let error: LocalizedMessage = "Skill not found: \("ユーザー入力")."
        #expect(SkillsHubLocalization().localized(error, language: .chinese).contains("ユーザー入力"))
        #expect(SkillsHubLocalization().localized(error, language: .japanese).contains("ユーザー入力"))
        #expect(error.arguments == ["ユーザー入力"])

        let recovery: LocalizedMessage = "Current facts: \(2) completed, \(1) not completed, \(0) unknown. No action was replayed."
        #expect(SkillsHubLocalization().localized(recovery, language: .chinese) == "当前事实：2 项已完成、1 项未完成、0 项未知。未重放任何操作。")
        #expect(SkillsHubLocalization().localized(recovery, language: .japanese) == "現在の情報：完了2件、未完了1件、不明0件。操作は再実行していません。")
        #expect(recovery.arguments == ["2", "1", "0"])
    }

    @Test func systemLanguageResolvesFromPreferredLanguages() {
        let localization = SkillsHubLocalization()

        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "ja-JP", "en-US"]) == .japanese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-TW", "en-US"]) == .chinese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "ja-JP"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR"]) == .english)
        #expect(AppLanguage.japanese.resolved(preferredLanguages: ["zh-CN"]) == .japanese)
        #expect(localization.localized("Settings", language: .system, preferredLanguages: ["ja"]) == "設定")
    }

    @MainActor
    @Test func explicitLanguagePersistsAcrossControllerRestart() throws {
        let suiteName = "PresentationSettingsAndLocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppLanguagePreferences(defaults: defaults)
        let controller = SkillsHubLibraryController(languagePreferences: preferences)

        #expect(controller.language == .system)
        #expect(SkillsHubLocalization().localized("Settings", language: controller.language, preferredLanguages: ["ja-JP"]) == "設定")

        controller.language = .japanese

        let restarted = SkillsHubLibraryController(languagePreferences: preferences)
        #expect(restarted.language == .japanese)
    }

    @Test func unconnectedRootStatesAndAgentGroupAreLocalized() {
        let localization = SkillsHubLocalization()
        let presentations = [
            Phase1RootPresentation(rootURL: nil, inspectionResult: nil, pendingInitialization: nil, tasks: []),
            Phase1RootPresentation(rootURL: nil, inspectionResult: .cancelled, pendingInitialization: nil, tasks: []),
            Phase1RootPresentation(rootURL: nil, inspectionResult: .invalid(.unreadable(path: "/fixture/root")), pendingInitialization: nil, tasks: [])
        ]
        for language in [AppLanguage.chinese, .japanese] {
            #expect(localization.localized("Agents", language: language) == "Agents")
            #expect(localization.localized("Management Directory", language: language) != "Management Directory")
            #expect(localization.localized("Managed by Skills Hub", language: language).contains("Skills Hub"))
            for presentation in presentations {
                #expect(localization.localized(presentation.title, language: language) != presentation.title)
                #expect(localization.localized(presentation.detail, language: language) != presentation.detail)
                #expect(localization.localized(presentation.statusLabel, language: language) != presentation.statusLabel)
            }
        }
    }

    @Test func rootPresentationProjectsUnavailableAndAuthorizedFacts() {
        let unavailable = Phase1RootPresentation(rootURL: nil, inspectionResult: nil, pendingInitialization: nil, tasks: [])
        let authorized = Phase1RootPresentation(
            rootURL: URL(fileURLWithPath: "/fixture/root", isDirectory: true),
            inspectionResult: nil,
            pendingInitialization: nil,
            tasks: []
        )

        #expect(unavailable.status == .unavailable)
        #expect(unavailable.primaryAction == .none)
        #expect(authorized.status == .authorized)
        #expect(authorized.primaryAction == .none)
    }

    @Test func rootPresentationMakesInitializationAndNoWriteBoundaryExplicit() {
        let root = URL(fileURLWithPath: "/fixture/pending-root", isDirectory: true)
        let presentation = Phase1RootPresentation(
            rootURL: nil,
            inspectionResult: .initializationRequired(RootInspectionFacts(url: root)),
            pendingInitialization: nil,
            tasks: []
        )

        #expect(presentation.status == .initializationRequired)
        #expect(presentation.primaryAction == .none)
        #expect(presentation.statusLabel.contains("no writes"))
        #expect(presentation.accessibilityValue.contains(root.path))
    }


    @Test func rootPresentationUsesActiveInitializationTaskAsAuthoritativeStatus() {
        let task = phase1RootTask(phase: .verifying, result: "Verifying the Root read-back.", updatedAt: Date(timeIntervalSince1970: 2))
        let presentation = Phase1RootPresentation(rootURL: nil, inspectionResult: nil, pendingInitialization: nil, tasks: [task])

        #expect(presentation.status == .initializing(.verifying))
        #expect(presentation.statusLabel == "Verifying")
        #expect(presentation.primaryAction == .openTasks)
        #expect(presentation.detail == task.result)
    }

    @Test func rootPresentationNeverReportsUnknownInitializationAsSuccess() {
        let task = phase1RootTask(
            phase: .needsAttention,
            result: "The current state is unknown after interrupted verification.",
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        let presentation = Phase1RootPresentation(rootURL: nil, inspectionResult: nil, pendingInitialization: nil, tasks: [task])

        #expect(presentation.status == .needsAttention)
        #expect(presentation.primaryAction == .openTasks)
        #expect(presentation.statusLabel.contains("success is not established"))
        #expect(presentation.accessibilityValue.contains("Completed") == false)
    }
}

private func phase1RootTask(
    phase: Phase1OperationPhase,
    result: String,
    updatedAt: Date
) -> Phase1TaskRecord {
    let identifier = UUID(uuid: (
        0x99, 0x99, 0x99, 0x99,
        0x99, 0x99, 0x99, 0x99,
        0x99, 0x99, 0x99, 0x99,
        0x99, 0x99, 0x99, 0x99
    ))
    return Phase1TaskRecord(
        id: identifier,
        kind: .initializeRoot,
        title: "Initialize Root",
        objectID: "/fixture/root",
        phase: phase,
        result: LocalizedMessage(result),
        planDigest: "fixture-plan",
        events: [Phase1TaskEvent(id: identifier, phase: phase, message: LocalizedMessage(result), occurredAt: updatedAt)],
        updatedAt: updatedAt
    )
}
