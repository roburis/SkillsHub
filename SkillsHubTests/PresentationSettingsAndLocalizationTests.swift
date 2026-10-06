import AppKit
import Foundation
import Testing
@testable import SkillsHub

struct PresentationSettingsAndLocalizationTests {
    @Test func bundledThirdPartyNoticesIncludeCompleteLicensesAndIconUsage() throws {
        let notices = try AppSettingsService().thirdPartyNotices()
        let sections = notices.components(separatedBy: "Copyright (c) ")
        #expect(sections.count == 6)
        for owner in ["2016 JP Simard.", "2017-2020 Ingy döt Net", "2006-2016 Kirill Simonov",
                      "2023 LobeHub", "2026 GitHub Inc."] {
            #expect(notices.contains(owner))
        }
        #expect(notices.components(separatedBy: "Permission is hereby granted").count == 5)
        #expect(notices.components(separatedBy: "The above copyright notice and this permission notice").count == 5)
        #expect(notices.components(separatedBy: "THE SOFTWARE IS PROVIDED \"AS IS\"").count == 5)
        #expect(notices.components(separatedBy: "OUT OF OR IN CONNECTION WITH THE SOFTWARE").count == 5)
        for usage in ["Yams 6.0.2", "libyaml", "GitHubSourceIcon", "CodexAgentIcon", "ClaudeAgentIcon",
                      "never redistributed", "does not imply endorsement", "brand usage terms"] {
            #expect(notices.contains(usage))
        }
        for key in ["About Skills Hub", "Third-party notices",
                    "Could not read third-party notices. Original diagnostic: %@"] {
            for language in [AppLanguage.chinese, .japanese] {
                #expect(SkillsHubLocalization().localized(key, language: language) != key)
            }
        }
        #expect(throws: CocoaError.self) {
            try AppSettingsService().thirdPartyNotices(bundle: Bundle(for: NSApplication.self))
        }
    }

    @Test(arguments: [
        ("/root/local/L2", "L2"),
        ("/root/local/roles-skills/workflows/apple", "roles-skills"),
        ("/root/local/長いソース と空白 abcdefghijklmnopqrstuvwxyz", "長いソース と空白 abcdefghijklmnopqrstuvwxyz"),
        ("/root/local", nil), ("/root-other/local/L2", nil), ("/root/local/../../outside", nil)
    ] as [(String, String?)])
    func localSourceSummaryUsesManagedFirstFolder(sample: (String, String?)) {
        for kind in [SkillSourceKind.localDirectory, .manualFilesystem] {
            let source = SkillSource(kind: kind, name: "External display alias", localPath: sample.0,
                                     externalLocalPath: "/external/original-folder")
            let message = SkillCatalogPresentationService().sourceName(for: source, relativeTo: URL(fileURLWithPath: "/root"))
            if let folder = sample.1 {
                #expect(message == LocalizedMessage("Local/%@", arguments: [folder]))
                for (language, prefix) in [(AppLanguage.english, "Local"), (.chinese, "本地"), (.japanese, "ローカル")] {
                    #expect(SkillsHubLocalization().localized(message, language: language) == prefix + "/" + folder)
                }
            } else {
                #expect(message == "Unknown Source")
            }
        }
    }

    @Test func contradictoryCandidateAssociationStaysVisibleAsConflict() throws {
        let source = SkillSource(kind: .localDirectory, name: "Source", localPath: "/fixture/source")
        let candidate = AvailableSkill(id: "review", sourceID: source.id, skillPath: "review",
            name: "Review", description: "Fixture", validation: .valid, candidateID: "candidate-review")
        let managed = InstalledSkill(id: "review", sourceID: source.id, name: "Review", description: "Fixture",
            installedPath: "/fixture/source/other", sourceKind: .localDirectory, validation: .valid,
            purpose: nil, tagIDs: [], installedAt: .distantPast, candidateID: candidate.candidateID)
        let items = SkillCatalogPresentationService().phase1Items(availableSkills: [candidate],
            installedSkills: [managed], sources: [source], enablementIntents: [])
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.identityConflict })
        #expect(items.allSatisfy { $0.needsAttention })
        #expect(items.first { $0.managed != nil }?.id == managed.assetID.uuidString)
        #expect(items.first { $0.candidate != nil }?.contentDirectoryPath == "/fixture/source/review")
        #expect(items.first { $0.managed != nil }?.contentDirectoryPath == "/fixture/source/other")
        var unsafe = try #require(items.first { $0.candidate != nil })
        unsafe.candidate?.skillPath = "../outside"
        #expect(unsafe.contentDirectoryPath == nil)
        unsafe.candidate?.skillPath = "/outside"
        #expect(unsafe.contentDirectoryPath == nil)
        unsafe.candidate?.skillPath = "."
        #expect(unsafe.contentDirectoryPath == "/fixture/source")
        unsafe.source?.localPath = "/"
        unsafe.candidate?.skillPath = "review"
        #expect(unsafe.contentDirectoryPath == "/review")
        unsafe.source?.localPath = "/fixture/source\0other"
        #expect(unsafe.contentDirectoryPath == nil)
    }

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
            localPath: "/fixture/local/local-source"
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
            ], rootURL: URL(fileURLWithPath: "/fixture")
        )

        #expect(items.map(\.name) == ["Review", "Unnamed skill · nested/invalid"])
        #expect(service.filteredPhase1Items(items, query: "local-source", filter: .needsAttention).map(\.id) == ["invalid-candidate"])
        #expect(service.filteredPhase1Items(items, query: "", filter: .notEnabled).map(\.id) == ["invalid-candidate"])
    }

    @Test(arguments: [AppLanguage.chinese, .japanese])
    func operationTaskPhasesAndRecoveryHaveLocalizedText(language: AppLanguage) {
        let keys = [
            "Preparing", "Waiting for confirmation", "Executing", "Observing",
            "Verifying", "Completed", "Needs attention", "Running",
            "Recently completed", "View current Root", "View authoritative object",
            "Skill address", "Relative to the management directory", "Relative to %@ skills directory",
            "Skill address could not be verified.", "Recorded address; the Skill entry is missing.",
            "Recorded address; SKILL.md has not been verified.", "SKILL.md is missing or unreadable.",
            "Re-observe the current object before preparing a new plan.",
            "Cancelled before confirmation; no authorized write occurred."
        ]
        for key in keys {
            #expect(SkillsHubLocalization().localized(key, language: language) != key)
        }
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
        #expect(localization.localized(RelationOwnershipClassification.unmanagedNode.clearMessage, language: .chinese) == "当前节点不受 Skills Hub 管理；对象保持不变。")
        #expect(localization.localized(RelationOwnershipClassification.unmanagedNode.clearMessage, language: .japanese) == "現在のノードは Skills Hub の管理対象ではありません。対象は変更されません。")
        let workspaceCopy = [
            "Search All Skills…", "Search This Source’s Skills…", "Check for Updates…", "Needs Attention", "View Source…",
            "Add Agent", "Agent Configuration", "Save name and abbreviation", "Custom Agent", "Built-in Agent",
            "Global skills directory", "Current directory", "Relationship management available", "Default directory verified", "Agent directory has not been verified.", "Action in progress",
            "Expanded", "Collapsed", "Will clear", "Blocked", "Cancel Fetch", "Imported · Readable", "Imported · Needs Attention",
            "Remove the verified Skills Hub-managed link and disable this relationship.",
            "Disable this relationship; no link node is currently present.",
            "Agent configuration is unavailable; no cleanup was authorized.",
            "The current node is not managed by Skills Hub; the object remains unchanged.",
            "The current link points outside the Management Directory; the object remains unchanged.",
            "The current link is broken; the object remains unchanged.",
            "Current ownership could not be verified; the object remains unchanged.",
            "Remove GitHub Source", "Remove Local Source", "Update Applied", "Update Needs Attention",
            "Cancel and Keep Current Content", "Content: moved to Trash", "Content: not verified as moved; inspect current paths",
            "Content: prepared source is active", "Content: not verified as applied", "Metadata and baseline: committed",
            "Metadata and baseline: not committed", "Metadata: removed", "Metadata: retained or needs verification",
            "Old content: moved to Trash", "Old content: retained for recovery", "Operation record: completed",
            "Operation record: needs attention",
            "No source update was found. Managed content and its success baseline are unchanged."
        ]
        for key in ["All Sources", "Enabled", "Not Enabled", "Not connected to an Agent", "Not set", "No current observation", "Not verified", "Verified consistent", "Drifted", "Currently unverifiable", "Agent name is required.", "Enter 1–4 visible characters for the icon abbreviation."] + workspaceCopy {
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
        let suiteName = "PresentationSettingsAndLocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = SkillsHubLibraryController(languagePreferences: AppLanguagePreferences(defaults: defaults))
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

        let sourceID = UUID()
        controller.recordSourceUpdateFailure(sourceID: sourceID, error: SourceUpdateError.preparedSourceIncomplete)
        controller.handle(Phase1OperationError.targetConflict("/原始/長いパス %20"))
        let sourceFailure = try #require(controller.sourceUpdateFailures[sourceID])
        let producedError = try #require(controller.errorMessage)
        for language in [AppLanguage.english, .chinese, .japanese] {
            controller.language = language
            #expect(controller.localized(producedError).contains("/原始/長いパス %20"))
            if language != .english {
                #expect(controller.localized(sourceFailure) != sourceFailure.template)
            }
            #expect(controller.sourceUpdateFailures[sourceID] == sourceFailure)
            #expect(controller.errorMessage == producedError)
        }
        #expect(producedError.arguments == ["/原始/長いパス %20"])
        for failure in [AgentTargetQualificationFailure.profileUnavailable(.profileMissing), .targetMissing,
                        .targetAmbiguous, .permissionRequired, .bookmarkStale, .authorizationTargetMismatch] {
            let message = LocalizedMessage(controller.agentQualificationFailureDescription(failure))
            for language in [AppLanguage.chinese, .japanese] {
                controller.language = language
                #expect(controller.localized(message) != message.template)
            }
        }
    }

    @Test func domainFeedbackAndOriginalDiagnosticsHaveCompleteTranslations() throws {
        let errors: [any Error] = [
            Phase1OperationError.invalidPlan, Phase1OperationError.staleFacts,
            Phase1OperationError.confirmationMismatch, Phase1OperationError.candidateUnavailable,
            Phase1OperationError.targetConflict("/原始"), Phase1OperationError.stagingVerificationFailed,
            Phase1OperationError.metadataCommitFailed("errno=13"), Phase1OperationError.compensationFailed("raw % %@"),
            Phase1OperationError.journalUnavailable,
            SourceUpdateError.invalidSource, SourceUpdateError.sourceChangedDuringPreparation,
            SourceUpdateError.preparedSourceIncomplete, SourceUpdateError.confirmationChanged,
            SourceUpdateError.writeUnavailable, SourceUpdateError.relationshipCleanupIncomplete,
            SourceUpdateError.operationRecordUnavailable,
            SourceRemovalError.invalidScope, SourceRemovalError.planChanged, SourceRemovalError.relationshipsRemain,
            SourceRemovalError.recordUnavailable, SourceRemovalError.trashFailed("原始診断"),
            SourceRemovalError.trashResultUnverified, SourceRemovalError.metadataCommitFailed("raw error"),
            GitHubSourceIssue.networkFailure, GitHubSourceIssue.rateLimited, GitHubSourceIssue.treeTruncated,
            GitHubSourceIssue.repositoryTooLarge, GitHubSourceIssue.pathRestricted, GitHubSourceIssue.unsupportedProvider,
            GitHubSourceIssue.unsupportedVersion, GitHubSourceIssue.invalidURL, GitHubSourceIssue.repositoryChanged,
            GitHubSourceIssue.branchUnavailable, GitHubSourceIssue.timedOut, GitHubSourceIssue.cancelled,
            GitHubSourceIssue.archiveInvalid, GitHubSourceIssue.contentMismatch, GitHubSourceIssue.noSkills,
            GitHubAPIClientFailure.branchUnavailable,
            FileAccessFailure.outsideAuthorizedDirectory(path: "/原始"), FileAccessFailure.unreadable(path: "/原始"),
            FileAccessFailure.symlinkEscapesRoot(path: "/原始"), FileAccessFailure.symlinkCycle(path: "/原始"),
            RootInspectionFailure.missing(path: "/原始"), RootInspectionFailure.notDirectory(path: "/原始"),
            RootInspectionFailure.symbolicLink(path: "/原始"), RootInspectionFailure.unreadable(path: "/原始"),
            RootInspectionFailure.invalidMetadata(path: "/原始", reason: "raw reason"),
            SecurityScopedAccessError.startDenied(path: "/原始", ownerIdentity: "owner"),
            RootWriteUnavailableReason.heldByAnotherProcess, RootWriteUnavailableReason.lockUnavailable(errno: 13),
            ControllerRelationActionError.unsupportedAgent("Agent 原文"), ControllerRelationActionError.invalidSkillAlias("Name %"),
            ControllerRelationActionError.missingRootSession, ManagedRelationClearError.planChanged,
            AgentTargetAccessError.leaseUnavailable, MetadataCommitError.staleDigest,
            ContentManifestFailure.unsupportedNode(path: "/原始"), RelationActionTokenBuildError.targetUnavailable,
            NSError(domain: "External 原文 %", code: 7)
        ] + [
            "Agent configuration not found.",
            "The selected Agent skills target is not a directory.",
            "The Agent skills target cannot be a symbolic link.",
            "Authorize the exact Agent skills target before saving.",
            "Agent directory facts changed before saving. The old configuration was kept.",
            "Please resolve the listed Agent relationships or operations before changing the directory.",
            "Another Agent already uses this skills directory.",
            "The saved Agent directory could not be verified.",
            "Local source already registered.", "Local source already imported.",
            "Candidate is blocked or unreadable.", "Local source path is unavailable.",
            "No Phase 1 operation is waiting for confirmation.",
            "Root establishment must start from the Establish Management Directory button.",
            "Root selection access is unavailable.", "Folder authorization was not granted.",
            "The repository check did not produce a publishable source."
        ].map { SkillsHubLibraryFailure.invalidSource(LocalizedMessage($0)) }
        let localization = SkillsHubLocalization()
        for error in errors {
            let message = SkillsHubLocalization.errorPresentation(for: error)
            #expect(!message.isVerbatim)
            for language in [AppLanguage.chinese, .japanese] {
                #expect(localization.localized(message.template, language: language) != message.template)
                let rendered = localization.localized(message, language: language)
                for argument in message.arguments { #expect(rendered.contains(argument)) }
            }
        }
        #expect(SkillsHubLocalization.errorPresentation(for: SourceUpdateError.preparedSourceIncomplete)
            == "The prepared source is incomplete. Current content was retained.")
        let diagnostic = SkillsHubLocalization.errorPresentation(for: Phase1OperationError.compensationFailed("raw % %@"))
        #expect(diagnostic.arguments == ["raw % %@"])
        #expect(localization.localized(diagnostic, language: .chinese) == "恢复需要处理。诊断原文：raw % %@")
        let original = LocalizedMessage("Historical record (original): %@", arguments: ["unrecognized legacy: 已发生 %@"])
        #expect(localization.localized(original, language: .japanese) == "履歴記録の原文：unrecognized legacy: 已发生 %@")
        for type in AgentFindingType.allCases {
            for language in [AppLanguage.chinese, .japanese] {
                #expect(localization.localized(type.presentationMessage, language: language) != type.presentationMessage.template)
            }
        }
        for id in ["missing-skill-file", "unreadable-skill-file", "content-changed", "empty-skill-id", "skill-id-conflict",
                   "name-directory-mismatch", "description-length", "missing-source-metadata", "frontmatter-syntax",
                   "frontmatter-format", "frontmatter-capability", "frontmatter-budget"] {
            let message = ValidationMessage(id: id, severity: .error, message: "Original check").presentationMessage
            for language in [AppLanguage.chinese, .japanese] {
                #expect(localization.localized(message, language: language) != message.template)
            }
        }
        let unknown = ValidationMessage(id: "frontmatter-format-unknown", severity: .error, message: "原始 check %").presentationMessage
        #expect(unknown == LocalizedMessage("Check detail (original): %@", arguments: ["原始 check %"]))
        for title in ["Unfinished relationship operation", "Unfinished broken-link operation", "Unverifiable operation record",
                      "Wait for the current action on this relation to finish.",
                      "Review the current target authorization before trying again.",
                      "Review target access before preparing another action."] {
            for language in [AppLanguage.chinese, .japanese] {
                #expect(localization.localized(title, language: language) != title)
            }
        }
        for phase in [Phase1OperationPhase.preparing, .waitingConfirmation, .executing, .observing, .verifying, .completed, .needsAttention] {
            let record = Phase1JournalRecord(operationID: UUID(), kind: .initializeRoot, operationPlan: nil,
                sequence: 1, planDigest: "digest", event: .phase, phase: phase, objectID: "原始对象",
                result: "unrecognized historical result %@", confirmationTokenID: nil, occurredAt: .distantPast)
            let message = record.progressMessage
            #expect(!message.isVerbatim)
            for language in [AppLanguage.chinese, .japanese] {
                #expect(localization.localized(message, language: language) != message.template)
            }
            let stored = try JSONDecoder().decode(Phase1JournalRecord.self, from: JSONEncoder().encode(record))
            #expect(stored.result == "unrecognized historical result %@")
            #expect(stored.progressMessage == message)
        }
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

    @Test func nodeLabelsDescribeTypeIndependentlyOfOwnershipInThreeLanguages() {
        let localization = SkillsHubLocalization()
        let labels: [(TargetNodeKind, String, String, String)] = [
            (.symbolicLink, "Symbolic link", "软链接", "シンボリックリンク"),
            (.directory, "Real directory", "真实目录", "実ディレクトリ"),
            (.brokenSymbolicLink, "Broken symbolic link", "失效软链接", "無効なシンボリックリンク"),
            (.unreadable, "Type unverified", "类型待核实", "種類未確認")
        ]
        for (kind, english, chinese, japanese) in labels {
            #expect(localization.localized(kind.presentationLabel, language: .english) == english)
            #expect(localization.localized(kind.presentationLabel, language: .chinese) == chinese)
            #expect(localization.localized(kind.presentationLabel, language: .japanese) == japanese)
        }
        #expect(AgentSkillEntryKind.hubManagedSymlink.presentationLabel == AgentSkillEntryKind.externalSymlink.presentationLabel)
        #expect(AgentSkillEntryKind.localDirectory.presentationLabel == TargetNodeKind.directory.presentationLabel)
        #expect(AgentSkillEntryKind.invalid.presentationLabel == TargetNodeKind.unreadable.presentationLabel)
    }

    @MainActor
    @Test func invalidLanguagePreferenceFallsBackWithoutRewritingStoredValue() throws {
        let suiteName = "PresentationSettingsAndLocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("unsupported-language", forKey: "appLanguage")

        let controller = SkillsHubLibraryController(languagePreferences: AppLanguagePreferences(defaults: defaults))

        #expect(controller.language == .system)
        #expect(defaults.string(forKey: "appLanguage") == "unsupported-language")
    }

    @MainActor
    @Test(arguments: AppLanguage.allCases)
    func explicitLanguagePersistsAcrossControllerRestart(language: AppLanguage) throws {
        let suiteName = "PresentationSettingsAndLocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppLanguagePreferences(defaults: defaults)
        let controller = SkillsHubLibraryController(languagePreferences: preferences)

        #expect(controller.language == .system)
        #expect(defaults.object(forKey: "appLanguage") == nil)
        #expect(SkillsHubLocalization().localized("Settings", language: controller.language, preferredLanguages: ["ja-JP"]) == "設定")

        controller.language = language

        let restarted = SkillsHubLibraryController(languagePreferences: AppLanguagePreferences(defaults: defaults))
        #expect(restarted.language == language)
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
