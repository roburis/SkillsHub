import AppKit
import XCTest

final class SkillsHubUITests: XCTestCase {
    private var activeApp: XCUIApplication?
    private var activeFixture: Phase1UITestFixture?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        activeApp?.terminate()
        activeApp = nil
        if let activeFixture {
            try activeFixture.cleanup()
        }
        activeFixture = nil
    }

    func testFixtureOwnsCanonicalRunScopedPathsBeforeLaunch() throws {
        let fixture = try makeFixture()

        XCTAssertEqual(fixture.runRoot.lastPathComponent, fixture.runID.uuidString)
        XCTAssertEqual(fixture.runRoot.deletingLastPathComponent().lastPathComponent, "phase1-ui-tests")
        XCTAssertEqual(fixture.runRoot.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, ".tmp")
        XCTAssertEqual(fixture.root.deletingLastPathComponent(), fixture.runRoot)
        XCTAssertEqual(fixture.source.deletingLastPathComponent(), fixture.runRoot)
        XCTAssertEqual(fixture.home.deletingLastPathComponent(), fixture.runRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceCandidate.appending(path: "SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.managedCandidate.path))
        XCTAssertTrue(fixture.expectedLocalSourceImportWritePaths.contains(fixture.managedCandidate.deletingLastPathComponent().path))
        XCTAssertTrue(fixture.expectedLocalSourceImportWritePaths.contains(fixture.metadata.path))
        XCTAssertTrue(fixture.expectedLocalSourceImportWritePaths.contains(fixture.journal.path))
    }

    @MainActor
    func testRootAuthorizationPlatformProtocol() throws {
        let fixture = try makeFixture()
        let fixtureApp = try launch(fixture: fixture, additionalArguments: ["--skillshub-ui-github-removal-fixture"])
        XCTAssertTrue(
            fixtureApp.descendants(matching: .any)["skill-library-list"]
                .waitForExistence(timeout: 3)
        )
        fixtureApp.terminate()
        activeApp = nil

        let fileManager = FileManager.default
        let cancelledRoot = fixture.runRoot.appending(path: "platform-cancelled-root", directoryHint: .isDirectory)
        let emptyRoot = fixture.runRoot.appending(path: "platform-empty-root", directoryHint: .isDirectory)
        let invalidRoot = fixture.runRoot.appending(path: "platform-invalid-root", directoryHint: .isDirectory)
        for root in [cancelledRoot, emptyRoot, invalidRoot] {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        }
        let invalidMetadata = Data("{\"schemaVersion\":999}".utf8)
        try invalidMetadata.write(to: invalidRoot.appending(path: ".skillshub.json"), options: .atomic)

        let cancelledBefore = try treeSnapshot(of: cancelledRoot)
        var app = launchPlatformRootApp(fixture: fixture, scenario: "cancelled")
        openEstablishRootPanel(in: app)
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(app.buttons["establish-root-primary"].waitForExistence(timeout: 2))
        XCTAssertEqual(try treeSnapshot(of: cancelledRoot), cancelledBefore)
        app.terminate()
        activeApp = nil

        app = launchPlatformRootApp(fixture: fixture, scenario: "empty")
        openEstablishRootPanel(in: app)
        chooseDirectory(emptyRoot, in: app)
        XCTAssertTrue(waitForText("root-initialized", at: emptyRoot.appending(path: ".skillshub.operations.jsonl")))
        XCTAssertFalse(app.descendants(matching: .any)["phase1-operation-confirmation"].exists)
        app.terminate()
        activeApp = nil

        let marker = invalidRoot.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: marker)
        app = launchPlatformRootApp(fixture: fixture, scenario: "invalid")
        openEstablishRootPanel(in: app)
        chooseDirectory(invalidRoot, in: app)
        XCTAssertTrue(app.staticTexts["No Skills yet"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["phase1-operation-confirmation"].exists)
        let rebuiltFile = invalidRoot.appending(path: ".skillshub.json")
        let rebuilt = try metadataObject(at: rebuiltFile)
        XCTAssertEqual(rebuilt["schemaVersion"] as? Int, 4)
        XCTAssertNotNil(rebuilt["logicalRevision"])
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        app.terminate()
        activeApp = nil

        let rebuiltBytes = try Data(contentsOf: rebuiltFile)
        app = launchPlatformRootApp(fixture: fixture, scenario: "reconnected")
        openConnectRootPanel(in: app)
        chooseDirectory(invalidRoot, in: app)
        XCTAssertTrue(app.staticTexts["No Skills yet"].waitForExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: rebuiltFile), rebuiltBytes)
        app.terminate()
        activeApp = nil

        let rootBefore = try treeSnapshot(of: fixture.root)
        app = launchPlatformRootApp(fixture: fixture, scenario: "existing")
        openConnectRootPanel(in: app)
        chooseDirectory(fixture.root, in: app)
        XCTAssertTrue(waitForConfiguredRoot(in: app, expectedCount: 1))
        XCTAssertEqual(try treeSnapshot(of: fixture.root), rootBefore)

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 3))
        XCTAssertTrue(waitForConfiguredRoot(in: app, expectedCount: 2))
        XCTAssertEqual(try treeSnapshot(of: fixture.root), rootBefore)
    }

    @MainActor
    func testLocalSourceAuthorizationPlatformProtocol() throws {
        let fixture = try makeFixture()
        let seeded = try launch(fixture: fixture)
        XCTAssertTrue(seeded.descendants(matching: .any)["skill-library-list"].waitForExistence(timeout: 3))
        seeded.terminate()
        activeApp = nil

        let source = fixture.runRoot.appending(path: "platform-source", directoryHint: .isDirectory)
        for path in ["review", ".agents/skills/write", "group/too-deep", ".hidden/ignored"] {
            let directory = source.appending(path: path, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("---\nname: Same Name\ndescription: Platform discovery sample.\n---\n# Static content\n".utf8)
                .write(to: directory.appending(path: "SKILL.md"))
        }
        let sourceBefore = try treeSnapshot(of: source)
        let local = fixture.root.appending(path: "local", directoryHint: .isDirectory)
        let localBefore = try treeSnapshot(of: local)
        let app = launchPlatformRootApp(fixture: fixture, scenario: "source")
        openConnectRootPanel(in: app)
        chooseDirectory(fixture.root, in: app)
        XCTAssertTrue(waitForConfiguredRoot(in: app, expectedCount: 1))
        // Connecting the Root performs its own discovery; cancellation is measured after that settles.
        let scan = app.descendants(matching: .any)["filesystem-observation-status"]
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "Scanned"), object: scan)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 6), .completed)
        let metadataBefore = try Data(contentsOf: fixture.metadata)
        let journalBefore = try? Data(contentsOf: fixture.journal)
        selectNavigation("local-sources", in: app)

        app.buttons["add-local-source"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
        app.sheets.buttons["Cancel"].click()
        XCTAssertEqual(try Data(contentsOf: fixture.metadata), metadataBefore)
        XCTAssertEqual(try? Data(contentsOf: fixture.journal), journalBefore)

        app.buttons["add-local-source"].click()
        chooseDirectory(source, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["local-source-import-sheet"].waitForExistence(timeout: 3))
        app.buttons["cancel-local-source-import"].click()
        XCTAssertTrue(app.descendants(matching: .any)["local-source-import-sheet"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(try Data(contentsOf: fixture.metadata), metadataBefore)
        XCTAssertEqual(try? Data(contentsOf: fixture.journal), journalBefore)
        XCTAssertEqual(try treeSnapshot(of: source), sourceBefore)

        app.buttons["add-local-source"].click()
        chooseDirectory(source, in: app)
        XCTAssertTrue(app.buttons["confirm-local-source-import"].waitForExistence(timeout: 3))
        app.buttons["confirm-local-source-import"].click()
        XCTAssertTrue(waitForText("local-source-imported", at: fixture.journal))
        XCTAssertFalse(app.descendants(matching: .any)["phase1-operation-confirmation"].exists)
        let metadataAfter = try Data(contentsOf: fixture.metadata)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: metadataAfter) as? [String: Any])
        let sources = try XCTUnwrap(metadata["sources"] as? [[String: Any]])
        let managedSource = local.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
        let imported = try XCTUnwrap(sources.first { $0["localPath"] as? String == managedSource.path })
        let sourceID = try XCTUnwrap(imported["id"] as? String)
        XCTAssertEqual(imported["externalLocalPath"] as? String, source.path)
        XCTAssertNotNil(imported["directoryIdentity"])
        XCTAssertNotNil(imported["baselineManifest"])
        let candidates = try XCTUnwrap(metadata["availableSkills"] as? [[String: Any]])
            .filter { $0["sourceID"] as? String == sourceID }
        XCTAssertEqual(
            Set(candidates.compactMap { $0["skillPath"] as? String }),
            ["review", ".agents/skills/write", "group/too-deep", ".hidden/ignored"]
        )
        let identities = candidates.compactMap { $0["candidateID"] as? String }
        XCTAssertEqual(Set(identities).count, 4)
        XCTAssertTrue(identities.allSatisfy { UUID(uuidString: $0) != nil })
        let installed = try XCTUnwrap(metadata["installedSkills"] as? [[String: Any]])
            .filter { $0["sourceID"] as? String == sourceID }
        XCTAssertEqual(installed.count, 4)
        XCTAssertTrue((metadata["enablementIntents"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertEqual(try treeSnapshot(of: source), sourceBefore)
        XCTAssertNotEqual(try treeSnapshot(of: local), localBefore)
        XCTAssertEqual(try treeSnapshot(of: managedSource), sourceBefore)
        XCTAssertTrue(app.descendants(matching: .any)["source-detail"].waitForExistence(timeout: 3))
        for (name, bytes) in [
            ("source-metadata-before.json", metadataBefore),
            ("source-metadata-after.json", metadataAfter),
            ("source-journal.jsonl", try Data(contentsOf: fixture.journal))
        ] {
            let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.data")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "T-005 complete local source import"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testFilesystemObservationReflectsRuntimeAndOfflineChanges() throws {
        let fixture = try makeFixture()
        let seeded = try launch(fixture: fixture)
        XCTAssertTrue(seeded.descendants(matching: .any)["skill-library-list"].waitForExistence(timeout: 3))
        seeded.terminate()
        activeApp = nil

        let metadataBefore = try metadataObject(at: fixture.metadata)
        let sourceBefore = try treeSnapshot(of: fixture.source)
        var app = launchPlatformRootApp(fixture: fixture, scenario: "observation-running")
        openConnectRootPanel(in: app)
        chooseDirectory(fixture.root, in: app)
        XCTAssertTrue(waitForConfiguredRoot(in: app, expectedCount: 1))
        let observationStatus = app.descendants(matching: .any)["filesystem-observation-status"]
        XCTAssertTrue(observationStatus.waitForExistence(timeout: 3))
        let initialScanSettled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value BEGINSWITH %@", "Scanned"),
            object: observationStatus
        )
        XCTAssertEqual(XCTWaiter.wait(for: [initialScanSettled], timeout: 6), .completed)

        let runtimeSkill = fixture.root.appending(path: "local/runtime-event", directoryHint: .isDirectory)
        try writeObservedSkill(at: runtimeSkill, name: "Runtime Event")
        let runtimeRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Runtime Event")).firstMatch
        XCTAssertTrue(runtimeRow.waitForExistence(timeout: 6), "Production FSEvents did not surface the runtime addition.")

        app.terminate()
        activeApp = nil
        let offlineSkill = fixture.root.appending(path: "local/offline-event", directoryHint: .isDirectory)
        try writeObservedSkill(at: offlineSkill, name: "Offline Event")

        app = launchPlatformRootApp(fixture: fixture, scenario: "observation-relaunch")
        openConnectRootPanel(in: app)
        chooseDirectory(fixture.root, in: app)
        XCTAssertTrue(waitForConfiguredRoot(in: app, expectedCount: 1))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Offline Event")).firstMatch
                .waitForExistence(timeout: 6),
            "Initial subscribe-then-scan did not surface the offline addition."
        )
        XCTAssertTrue(app.buttons["recheck-filesystem"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["filesystem-observation-status"].exists)

        let metadataAfter = try metadataObject(at: fixture.metadata)
        XCTAssertEqual(
            try metadataFieldData("sources", in: metadataBefore),
            try metadataFieldData("sources", in: metadataAfter)
        )
        XCTAssertEqual(
            try metadataFieldData("enablementIntents", in: metadataBefore),
            try metadataFieldData("enablementIntents", in: metadataAfter)
        )
        XCTAssertEqual(try treeSnapshot(of: fixture.source), sourceBefore)

        app.terminate()
        activeApp = nil
        app = launchPlatformRootApp(
            fixture: fixture,
            scenario: "observation-unavailable",
            additionalArguments: ["--skillshub-ui-observation-failure"]
        )
        openConnectRootPanel(in: app)
        chooseDirectory(fixture.root, in: app)
        XCTAssertTrue(waitForConfiguredRoot(in: app, expectedCount: 1))
        let unavailableStatus = app.descendants(matching: .any)["filesystem-observation-status"]
        XCTAssertTrue(unavailableStatus.waitForExistence(timeout: 3))
        XCTAssertTrue(((unavailableStatus.value as? String) ?? unavailableStatus.label).contains("unknown"))
    }

    @MainActor
    func testPhaseOneRootToFirstManagedSkillEndToEnd() throws {
        let fixture = try makeFixture()
        let fileManager = FileManager.default
        let root = fixture.runRoot.appending(path: "m004-root", directoryHint: .isDirectory)
        let managedSource = root.appending(path: "local/\(fixture.source.lastPathComponent)", directoryHint: .isDirectory)
        let managedCandidate = managedSource.appending(path: "candidate-fixture", directoryHint: .isDirectory)
        let metadata = root.appending(path: ".skillshub.json")
        let journal = root.appending(path: ".skillshub.operations.jsonl")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        let sourceBefore = try treeSnapshot(of: fixture.source)

        let app = launchPlatformRootApp(fixture: fixture, scenario: "m004")
        openEstablishRootPanel(in: app)
        chooseDirectory(root, in: app)
        XCTAssertTrue(waitForText("root-initialized", at: journal))
        let rootOperationID = try operationIdentity(inJournal: journal)
        XCTAssertFalse(app.descendants(matching: .any)["phase1-operation-confirmation"].exists)
        XCTAssertTrue(fileManager.fileExists(atPath: metadata.path))

        selectNavigation("local-sources", in: app)
        app.buttons["add-local-source"].click()
        chooseDirectory(fixture.source, in: app)
        XCTAssertTrue(app.buttons["confirm-local-source-import"].waitForExistence(timeout: 3))
        app.buttons["confirm-local-source-import"].click()
        XCTAssertTrue(waitForText("local-source-imported", at: journal))
        let sourceOperationID = try operationIdentity(inJournal: journal)
        XCTAssertFalse(app.descendants(matching: .any)["phase1-operation-confirmation"].exists)
        XCTAssertEqual(try treeSnapshot(of: managedSource), sourceBefore)

        let metadataData = try Data(contentsOf: metadata)
        let metadataObject = try XCTUnwrap(JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
        let candidates = try XCTUnwrap(metadataObject["availableSkills"] as? [[String: Any]])
        let candidate = try XCTUnwrap(candidates.first { $0["skillPath"] as? String == "candidate-fixture" })
        let candidateID = try XCTUnwrap(candidate["candidateID"] as? String)

        selectNavigation("all-skills", in: app)
        let candidateRow = app.descendants(matching: .any)["skill-row-\(candidateID)"]
        XCTAssertTrue(candidateRow.waitForExistence(timeout: 3))
        let managedSkill = managedCandidate.appending(path: "SKILL.md")
        XCTAssertTrue(waitForFile(at: managedSkill))
        XCTAssertEqual(try Data(contentsOf: managedSkill), fixture.sourceSkillData)
        XCTAssertEqual(try treeSnapshot(of: fixture.source), sourceBefore)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "candidate-agent-action-")).firstMatch.exists)

        selectNavigation("tasks", in: app)
        for operationID in [rootOperationID, sourceOperationID] {
            assertTaskResult(contains: "Completed", operationID: operationID, in: app)
        }
        selectNavigation("all-skills", in: app)
        XCTAssertTrue(candidateRow.waitForExistence(timeout: 2))

        for (name, bytes) in [
            ("m004-metadata.json", try Data(contentsOf: metadata)),
            ("m004-journal.jsonl", try Data(contentsOf: journal))
        ] {
            let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.data")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "M-004 Root to first managed Skill"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testFirstRunStaysInFinalShellAndUsesApprovedNavigation() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture, empty: true)

        XCTAssertTrue(app.staticTexts["Authorize Management Directory"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Start using SkillsHub"].exists)
        let sidebar = app.descendants(matching: .any)["phase1-product-sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2))
        XCTAssertGreaterThanOrEqual(sidebar.frame.width, 176)
        XCTAssertLessThanOrEqual(sidebar.frame.width, 262)
        XCTAssertTrue(app.descendants(matching: .any)["nav-agent-codex"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["nav-agent-claudeCode"].exists)
        for destination in ["all-skills", "local-sources", "github-sources", "settings"] {
            XCTAssertTrue(app.descendants(matching: .any)["nav-\(destination)"].exists, "Missing approved destination \(destination)")
        }
        XCTAssertFalse(app.descendants(matching: .any)["nav-needs-attention"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["nav-tasks"].exists)
        let window = app.windows.firstMatch
        let windowFrame = window.frame
        XCTAssertGreaterThanOrEqual(windowFrame.height, 560, "The approved minimum height prevents the former clipping range")
        for destination in ["settings"] {
            let navigationItem = app.descendants(matching: .any)["nav-\(destination)"]
            XCTAssertLessThanOrEqual(
                navigationItem.frame.maxY,
                windowFrame.maxY,
                "\(destination) must remain inside the app window"
            )
        }
        let rootStatus = app.descendants(matching: .any)["phase1-root-status"]
        XCTAssertTrue(rootStatus.exists)
        let rootAccessibilityProjection = "\(rootStatus.label) \(String(describing: rootStatus.value))"
        XCTAssertTrue(
            rootAccessibilityProjection.contains("Not authorized"),
            "Unexpected Root accessibility projection: \(rootAccessibilityProjection)"
        )
        let establishRoot = app.buttons["establish-root-primary"]
        XCTAssertTrue(establishRoot.exists)
        XCTAssertTrue(app.buttons["connect-root-primary"].exists)
        let rootScroll = app.descendants(matching: .any)["first-run-workspace"]
        for _ in 0..<3 where establishRoot.frame.maxY > window.frame.maxY - 8 {
            rootScroll.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(establishRoot.isHittable)
        XCTAssertLessThanOrEqual(establishRoot.frame.maxY, window.frame.maxY - 8)
        establishRoot.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Nothing runs automatically"].exists)

        selectNavigation("settings", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings-workspace"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["refresh-default-agent-directories"].isEnabled)
        XCTAssertTrue(app.buttons["manage-root-settings"].exists)
        app.buttons["manage-root-settings"].click()
        XCTAssertTrue(app.buttons["connect-root-primary"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testInstallationEvidenceControlsSidebarButKeepsSettingsAndRelations() throws {
        let fixture = try makeFixture()
        let status = fixture.runRoot.appendingPathComponent("installation-status")
        try "desktop".write(to: status, atomically: true, encoding: .utf8)
        let app = try launch(fixture: fixture, additionalArguments: ["--skillshub-ui-installation-status-fixture"])
        XCTAssertTrue(app.descendants(matching: .any)["nav-agent-codex"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["nav-agent-claudeCode"].exists)
        selectNavigation("settings", in: app)
        XCTAssertTrue(app.staticTexts["Desktop App installed"].exists)
        XCTAssertTrue(app.buttons["configure-agent-claudeCode"].exists)
        selectNavigation("all-skills", in: app)
        app.descendants(matching: .any)["skill-row-fixture-review-candidate"].click()
        XCTAssertTrue(app.descendants(matching: .any)["relation-detail-claudeCode-review-fixture"].waitForExistence(timeout: 2))

        selectNavigation("agent-codex", in: app)
        try "absent".write(to: status, atomically: true, encoding: .utf8)
        app.buttons["recheck-agent-directory-codex"].click()
        XCTAssertTrue(app.descendants(matching: .any)["skill-library-list"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["nav-agent-codex"].exists)
        selectNavigation("settings", in: app)
        app.buttons["refresh-default-agent-directories"].click()
        XCTAssertFalse(app.descendants(matching: .any)["nav-agent-codex"].exists)
        XCTAssertTrue(app.staticTexts["Installation not found"].exists)
        XCTAssertTrue(app.buttons["configure-agent-codex"].exists)
        selectNavigation("all-skills", in: app)
        app.descendants(matching: .any)["skill-row-fixture-review-candidate"].click()
        XCTAssertTrue(app.descendants(matching: .any)["relation-detail-codex-review-fixture"].waitForExistence(timeout: 2))
        try "unknown".write(to: status, atomically: true, encoding: .utf8)
        selectNavigation("settings", in: app)
        app.buttons["refresh-default-agent-directories"].click()
        XCTAssertTrue(app.staticTexts["Installation could not be verified"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["nav-agent-codex"].exists)
    }

    @MainActor
    func testUnconnectedDirectoryAndRefreshInThreeLanguages() throws {
        for (language, status) in [("system", "未授权"), ("en", "Not authorized"), ("zh-Hans", "未授权"), ("ja", "未許可")] {
            let fixture = try makeFixture()
            let app = try launch(fixture: fixture, empty: true, language: language, windowWidth: 1040)
            let rootStatus = app.descendants(matching: .any)["phase1-root-status"]
            XCTAssertTrue(rootStatus.waitForExistence(timeout: 3))
            let actualStatus = "\(rootStatus.label) \(String(describing: rootStatus.value))"
            XCTAssertTrue(actualStatus.contains(status), "\(language): \(actualStatus)")
            selectNavigation("settings", in: app)
            XCTAssertTrue(app.staticTexts["Agents"].exists)
            if language == "system" {
                XCTAssertEqual(app.popUpButtons.firstMatch.value as? String, "跟随系统")
            }
            XCTAssertFalse(app.buttons["refresh-default-agent-directories"].isEnabled)
            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "Unconnected \(language) 1040pt"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
            try fixture.cleanup()
            activeFixture = nil
        }
    }

    @MainActor
    func testFixedSidebarNavigationKeepsControlsAndStateReachable() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture, windowWidth: 1040)
        let metadataBefore = try Data(contentsOf: fixture.metadata)
        let sidebar = app.descendants(matching: .any)["phase1-product-sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 3))
        XCTAssertTrue(sidebar.isHittable)
        let initial = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        initial.name = "Production initial layout"
        initial.lifetime = .keepAlways
        add(initial)
        let initialTree = XCTAttachment(string: app.debugDescription)
        initialTree.name = "Production initial accessibility tree"
        initialTree.lifetime = .keepAlways
        add(initialTree)
        XCTAssertFalse(app.buttons["Show Sidebar"].exists)
        XCTAssertFalse(app.buttons["Hide Sidebar"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["skill-detail-empty"].exists)
        XCTAssertTrue(app.buttons["recheck-filesystem"].isHittable)
        XCTAssertTrue(app.buttons["check-all-source-updates"].isHittable)
        let search = app.descendants(matching: .any)["skill-search"]
        XCTAssertTrue(search.isHittable)
        search.click()
        search.typeText("review")
        XCTAssertEqual(search.value as? String, "review")
        selectNavigation("local-sources", in: app)
        XCTAssertTrue(app.buttons["add-local-source"].isHittable)
        selectNavigation("all-skills", in: app)
        XCTAssertEqual(app.descendants(matching: .any)["skill-search"].value as? String, "review")
        XCTAssertEqual(try Data(contentsOf: fixture.metadata), metadataBefore)
        let evidence = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        evidence.name = "Production persistent columns at 1040 points"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor
    func testNativeDividerDragsMinimumSizeAndSearchFocus() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture, windowWidth: 1200)
        let window = app.windows.firstMatch
        let list = app.descendants(matching: .any)["workspace-list-pane"]
        let detail = app.descendants(matching: .any)["workspace-detail-pane"]
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        let initial = XCTAttachment(screenshot: window.screenshot())
        initial.name = "Before production divider drag"
        initial.lifetime = .keepAlways
        add(initial)
        // press(forDuration:thenDragTo:) delivers no mouse events to the divider on macOS 27; click-drag does.
        func dragDivider(_ index: Int, by delta: CGFloat) {
            let start = app.splitters.element(boundBy: index).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.click(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: delta, dy: 0)))
        }
        dragDivider(1, by: -400)
        XCTAssertEqual(list.frame.width, 288, accuracy: 2, window.identifier)
        dragDivider(1, by: 500)
        XCTAssertEqual(list.frame.width, 520, accuracy: 2)
        dragDivider(0, by: -400)
        XCTAssertEqual(list.frame.minX - window.frame.minX, 176, accuracy: 2)
        dragDivider(0, by: 400)
        XCTAssertEqual(list.frame.minX - window.frame.minX, 260, accuracy: 2)
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.click(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -500, dy: -500)))
        XCTAssertEqual(window.frame.width, 1040, accuracy: 2)
        XCTAssertGreaterThanOrEqual(list.frame.height, 559)
        XCTAssertGreaterThanOrEqual(detail.frame.width, 359)
        XCTAssertLessThanOrEqual(list.frame.width, 420)
        let compactCorner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        compactCorner.click(forDuration: 0.1, thenDragTo: compactCorner.withOffset(CGVector(dx: 160, dy: 160)))
        XCTAssertEqual(list.frame.width, 520, accuracy: 2, "Window resize must not replace the user's divider width")
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "Production real divider drags and minimum size"
        shot.lifetime = .keepAlways
        add(shot)
        dragDivider(0, by: -64)
        dragDivider(1, by: 344 - list.frame.width)
    }

    @MainActor
    func testToolbarKeepsPageOrderOnBothSidesOfNineHundredPoints() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture, windowWidth: 1040)
        let metadataBefore = try Data(contentsOf: fixture.metadata)
        let window = app.windows.firstMatch
        var metrics: [String] = []
        var toolbarHeight: CGFloat?
        func checkToolbarHeight(_ page: String) {
            let height = app.toolbars.firstMatch.frame.height
            if let toolbarHeight { XCTAssertEqual(height, toolbarHeight, accuracy: 1, "\(page): toolbar height changed") }
            else { toolbarHeight = height }
            metrics.append("\(page) toolbar height=\(height)")
        }
        for side in ["narrow", "wide"] {
            if side == "wide" {
                let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
                corner.click(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 160, dy: 0)))
                XCTAssertEqual(window.frame.width, 1200, accuracy: 2)
            }
            selectNavigation("all-skills", in: app)
            let body = window.frame.maxX - app.descendants(matching: .any)["workspace-list-pane"].frame.minX
            if side == "narrow" { XCTAssertLessThan(body, 900) } else { XCTAssertGreaterThanOrEqual(body, 900) }
            metrics.append("\(side) window=\(window.frame.width) body=\(body)")
            metrics += assertToolbar(page: "all-skills", title: "All Skills",
                                     order: ["recheck-filesystem", "check-all-source-updates", "skill-source-filter", "skill-filter", "skill-search"], in: app)
            checkToolbarHeight("all-skills")
            XCTAssertEqual(app.toolbars.firstMatch.searchFields["skill-search"].placeholderValue, "Search All Skills…")
            XCTAssertGreaterThanOrEqual(app.toolbars.firstMatch.searchFields["skill-search"].frame.width, side == "narrow" ? 190 : 246)
            let shot = XCTAttachment(screenshot: window.screenshot())
            shot.name = "Toolbar \(side) body \(Int(body)) points"
            shot.lifetime = .keepAlways
            add(shot)
            selectNavigation("local-sources", in: app)
            metrics += assertToolbar(page: "local-sources", title: "Local Sources", order: ["add-local-source", "source-search"],
                                     absent: ["check-all-source-updates"], in: app)
            checkToolbarHeight("local-sources")
            XCTAssertGreaterThanOrEqual(app.toolbars.firstMatch.searchFields["source-search"].frame.width, 246)
            app.descendants(matching: .any)[Phase1UITestFixture.sourceRowIdentifier].click()
            app.buttons["view-source-skills"].click()
            metrics += assertToolbar(page: "source-skills", title: "Fixture Source", leading: "return-to-source",
                                     order: ["recheck-filesystem", "skill-filter", "skill-search"],
                                     absent: ["skill-source-filter", "check-all-source-updates"], in: app)
            checkToolbarHeight("source-skills")
            XCTAssertEqual(app.toolbars.firstMatch.searchFields["skill-search"].placeholderValue, "Search This Source’s Skills…")
            app.buttons["return-to-source"].click()
            selectNavigation("github-sources", in: app)
            metrics += assertToolbar(page: "github-sources", title: "GitHub Sources",
                                     order: ["add-github-source", "check-all-source-updates", "source-search"], in: app)
            checkToolbarHeight("github-sources")
            selectNavigation("agent-codex", in: app)
            metrics += assertToolbar(page: "agent-codex", title: "Codex",
                                     order: ["recheck-agent-directory-codex", "agent-ownership-filter", "agent-attention-filter", "agent-workspace-search"], in: app)
            checkToolbarHeight("agent-codex")
            XCTAssertGreaterThanOrEqual(app.toolbars.firstMatch.searchFields["agent-workspace-search"].frame.width, 210)
            selectNavigation("settings", in: app)
            XCTAssertTrue(app.staticTexts["Settings"].exists)
            checkToolbarHeight("settings")
            app.buttons["manage-root-settings"].click()
            let confirmation = app.alerts.firstMatch
            XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
            XCTAssertTrue(confirmation.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", fixture.root.path)
            ).firstMatch.exists)
            confirmation.buttons["Cancel"].click()
            XCTAssertTrue(app.descendants(matching: .any)["settings-workspace"].exists)
            app.buttons["manage-root-settings"].click()
            app.alerts.firstMatch.buttons["Choose Another Directory"].click()
            XCTAssertTrue(app.staticTexts["Management Directory"].exists)
            checkToolbarHeight("management-directory")
        }
        let report = XCTAttachment(string: metrics.joined(separator: "\n"))
        report.name = "Toolbar metrics"
        report.lifetime = .keepAlways
        add(report)
        XCTAssertEqual(try Data(contentsOf: fixture.metadata), metadataBefore)
    }

    /// Read-only observation run once per system accessibility condition (Reduce Transparency, Increase Contrast,
    /// Reduce Motion, VoiceOver). Records the actual system values, keyboard and accessibility semantics, and screenshots.
    @MainActor
    func testAccessibilityConditionObservation() throws {
        let workspace = NSWorkspace.shared
        let condition = [
            "reduceTransparency=\(workspace.accessibilityDisplayShouldReduceTransparency)",
            "increaseContrast=\(workspace.accessibilityDisplayShouldIncreaseContrast)",
            "reduceMotion=\(workspace.accessibilityDisplayShouldReduceMotion)",
            "voiceOver=\(workspace.isVoiceOverEnabled)",
            "fullKeyboardAccess=\(NSApplication.shared.isFullKeyboardAccessEnabled)"
        ].joined(separator: " ")
        var notes = ["condition: \(condition)"]
        for language in ["en", "zh-Hans", "ja"] {
            let fixture = try makeFixture()
            let app = try launch(fixture: fixture, language: language, windowWidth: 1040)
            let metadataBefore = try Data(contentsOf: fixture.metadata)
            let window = app.windows.firstMatch
            let search = app.toolbars.firstMatch.searchFields["skill-search"]
            XCTAssertTrue(search.waitForExistence(timeout: 3))
            notes.append("\(language) search placeholder=\(search.placeholderValue ?? "nil") width=\(search.frame.width)")
            XCTAssertTrue(app.buttons["recheck-filesystem"].isHittable)
            XCTAssertTrue(app.buttons["check-all-source-updates"].exists)
            XCTAssertFalse(app.buttons["recheck-filesystem"].label.isEmpty)
            XCTAssertFalse(app.buttons["check-all-source-updates"].label.isEmpty)

            // Mouse and keyboard focus both hide the search prompt without changing the field size.
            let unfocusedSize = search.frame.size
            search.click()
            let focusedShot = XCTAttachment(screenshot: window.screenshot())
            focusedShot.name = "\(language) focused search"
            focusedShot.lifetime = .keepAlways
            add(focusedShot)
            XCTAssertEqual(search.frame.size, unfocusedSize)
            XCTAssertTrue((search.placeholderValue ?? "").isEmpty, "\(language): click kept placeholder \(search.placeholderValue ?? "nil")")
            app.typeKey(.tab, modifierFlags: [])
            XCTAssertFalse((search.placeholderValue ?? "").isEmpty, "\(language): empty search did not restore its placeholder after focus left")
            // Keyboard: Cmd-F focuses search, Esc leaves it, list selection opens the detail without a file write.
            app.typeKey("f", modifierFlags: .command)
            XCTAssertTrue((search.placeholderValue ?? "").isEmpty, "\(language): Cmd-F kept placeholder \(search.placeholderValue ?? "nil")")
            app.typeText("review")
            XCTAssertEqual(search.value as? String, "review")
            let row = app.descendants(matching: .any)["skill-row-fixture-review-candidate"]
            XCTAssertTrue(row.waitForExistence(timeout: 2))
            notes.append("\(language) row label=\(row.label) value=\(String(describing: row.value))")
            // The filtered list relayouts after typing; click only once the row settles on screen, so an
            // overlapping System Settings window or a mid-layout frame cannot send XCTest into a scroll attempt.
            app.activate()
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: row)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 3), .completed, "\(language): filtered row never became hittable")
            row.click()
            let detail = app.descendants(matching: .any)["skill-detail"]
            XCTAssertTrue(detail.waitForExistence(timeout: 2))
            let actions = detail.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "relation-action-")).allElementsBoundByIndex
            XCTAssertFalse(actions.isEmpty, "\(language): detail exposes no relation actions")
            for action in actions {
                XCTAssertFalse(action.label.isEmpty, "\(language): relation action \(action.identifier) has no accessible name")
                if language == "ja" {
                    XCTAssertTrue(action.label.contains("との関係"), "Japanese relationship action: \(action.label)")
                }
                notes.append("\(language) action \(action.identifier) label=\(action.label)")
            }
            let skillShot = XCTAttachment(screenshot: window.screenshot())
            skillShot.name = "A11y \(language) skill detail"
            skillShot.lifetime = .keepAlways
            add(skillShot)

            selectNavigation("local-sources", in: app)
            let sourceTitle = language == "ja" ? "ローカルソース" : language == "zh-Hans" ? "本地来源" : "Local Sources"
            XCTAssertTrue(app.staticTexts[sourceTitle].exists, "\(language): source page title is not localized")
            app.descendants(matching: .any)[Phase1UITestFixture.sourceRowIdentifier].click()
            XCTAssertTrue(app.descendants(matching: .any)["source-detail"].waitForExistence(timeout: 2))
            XCTAssertTrue(app.buttons["view-source-skills"].isHittable)
            let sourceShot = XCTAttachment(screenshot: window.screenshot())
            sourceShot.name = "A11y \(language) source detail"
            sourceShot.lifetime = .keepAlways
            add(sourceShot)

            selectNavigation("settings", in: app)
            XCTAssertTrue(app.descendants(matching: .any)["settings-workspace"].waitForExistence(timeout: 2))
            let settingsShot = XCTAttachment(screenshot: window.screenshot())
            settingsShot.name = "A11y \(language) settings"
            settingsShot.lifetime = .keepAlways
            add(settingsShot)
            if language == "en" {
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "A11y accessibility tree"
                tree.lifetime = .keepAlways
                add(tree)
            }
            XCTAssertEqual(try Data(contentsOf: fixture.metadata), metadataBefore)
            app.terminate()
            try fixture.cleanup()
            activeFixture = nil
        }
        let report = XCTAttachment(string: notes.joined(separator: "\n"))
        report.name = "A11y observation notes"
        report.lifetime = .keepAlways
        add(report)
    }

    /// Asserts one page's toolbar: fixed left-to-right order inside the window, separate check buttons, expanded search,
    /// and no unnamed placeholder buttons. Returns the measured frames for the evidence attachment.
    @MainActor
    private func assertToolbar(
        page: String, title: String, leading: String? = nil, order: [String], absent: [String] = [],
        in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) -> [String] {
        let window = app.windows.firstMatch
        let toolbar = app.toolbars.firstMatch
        XCTAssertTrue(toolbar.descendants(matching: .any)[order[0]].waitForExistence(timeout: 3), "\(page): toolbar not shown", file: file, line: line)
        let titleElement = window.staticTexts.matching(NSPredicate(format: "value == %@", title)).allElementsBoundByIndex
            .first { $0.frame.midY >= toolbar.frame.minY && $0.frame.midY <= toolbar.frame.maxY }
        guard let titleElement else {
            XCTFail("\(page): title \(title) is not in the toolbar", file: file, line: line)
            return []
        }
        let bodyStart = app.descendants(matching: .any)["workspace-list-pane"].frame.minX
        var elements: [(String, XCUIElement)] = leading.map { [($0, toolbar.descendants(matching: .any)[$0])] } ?? []
        elements.append(("title", titleElement))
        elements += order.map { ($0, toolbar.descendants(matching: .any)[$0]) }
        var previousMaxX = bodyStart - 1
        var measured: [String] = []
        for (name, element) in elements {
            XCTAssertTrue(element.exists, "\(page): missing \(name)", file: file, line: line)
            let frame = element.frame
            XCTAssertGreaterThanOrEqual(frame.minX, previousMaxX - 1, "\(page): \(name) is out of order or overlaps", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, window.frame.maxX + 1, "\(page): \(name) is clipped by the window", file: file, line: line)
            if name.hasPrefix("recheck") || name.hasPrefix("check-") {
                XCTAssertGreaterThanOrEqual(frame.width, 32, "\(page): \(name) is narrower than 32pt", file: file, line: line)
                XCTAssertFalse(element.label.isEmpty, "\(page): \(name) has no accessible name", file: file, line: line)
            }
            if name.hasSuffix("search") {
                XCTAssertEqual(element.elementType, .searchField, "\(page): search collapsed into another control", file: file, line: line)
                XCTAssertGreaterThanOrEqual(frame.width, 120, "\(page): search is not expanded", file: file, line: line)
            }
            previousMaxX = frame.maxX
            measured.append("  \(page) \(name) x=\(Int(frame.minX - window.frame.minX)) w=\(Int(frame.width))")
        }
        for name in absent {
            XCTAssertFalse(toolbar.descendants(matching: .any)[name].exists, "\(page): \(name) must not be shown", file: file, line: line)
        }
        for button in toolbar.buttons.allElementsBoundByIndex where button.label.isEmpty && button.identifier.isEmpty {
            XCTFail("\(page): unnamed toolbar button at \(button.frame)", file: file, line: line)
        }
        return measured
    }

    @MainActor
    func testSearchKeyboardClearsExcludedSelectionWithoutJumping() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture, windowWidth: 1040)
        app.typeKey("f", modifierFlags: .command)
        app.typeText("review")
        XCTAssertEqual(app.descendants(matching: .any)["skill-search"].value as? String, "review")
        let row = app.descendants(matching: .any)["skill-row-fixture-review-candidate"]
        row.click()
        XCTAssertTrue(app.descendants(matching: .any)["skill-detail"].exists)
        app.typeKey("f", modifierFlags: .command)
        app.typeText("no-matching-fixture")
        XCTAssertTrue(app.descendants(matching: .any)["skill-detail-empty"].waitForExistence(timeout: 2))
        app.typeKey("f", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["skill-detail-empty"].exists)
    }

    @MainActor
    func testNativeListRestoresManualScrollWithoutSelectingAnObject() throws {
        let fixture = try makeFixture()
        for index in 0..<30 {
            let folder = fixture.source.appending(path: String(format: "scroll-%02d", index), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("---\nname: Scroll Fixture \(index)\ndescription: Native list scrolling fixture.\n---\n".utf8).write(to: folder.appending(path: "SKILL.md"))
        }
        let app = try launch(fixture: fixture, windowWidth: 1040)
        selectNavigation("local-sources", in: app)
        app.descendants(matching: .any)[Phase1UITestFixture.sourceRowIdentifier].click()
        app.buttons["recheck-source"].click()
        app.buttons["view-source-skills"].click()
        let list = app.descendants(matching: .any)["skill-library-list"]
        XCTAssertTrue(list.staticTexts["Scroll Fixture 0"].waitForExistence(timeout: 3))
        for _ in 0..<8 { list.swipeUp() }
        let visible = list.staticTexts.allElementsBoundByIndex.first { (($0.value as? String) ?? $0.label).hasPrefix("Scroll Fixture") && $0.isHittable }
        let anchor = try XCTUnwrap(visible)
        let name = (anchor.value as? String) ?? anchor.label
        let y = anchor.frame.minY
        XCTAssertTrue(app.descendants(matching: .any)["skill-detail-empty"].exists)
        app.buttons["return-to-source"].click()
        app.buttons["view-source-skills"].click()
        let restored = list.staticTexts[name]
        let visibleAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: restored)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleAgain], timeout: 3), .completed)
        XCTAssertEqual(restored.frame.minY, y, accuracy: 3)
        XCTAssertTrue(app.descendants(matching: .any)["skill-detail-empty"].exists)

        selectNavigation("all-skills", in: app)
        XCTAssertFalse(app.buttons["return-to-source"].exists)
        let allSkills = app.descendants(matching: .any)["skill-library-list"]
        XCTAssertTrue(allSkills.staticTexts["Scroll Fixture 0"].waitForExistence(timeout: 3))
        for _ in 0..<8 { allSkills.swipeUp() }
        let allAnchor = try XCTUnwrap(allSkills.staticTexts.allElementsBoundByIndex.first {
            (($0.value as? String) ?? $0.label).hasPrefix("Scroll Fixture") && $0.isHittable
        })
        let allName = (allAnchor.value as? String) ?? allAnchor.label
        let allY = allAnchor.frame.minY
        selectNavigation("local-sources", in: app)
        selectNavigation("all-skills", in: app)
        XCTAssertFalse(app.buttons["return-to-source"].exists)
        let allRestored = allSkills.staticTexts[allName]
        let allVisibleAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: allRestored)
        XCTAssertEqual(XCTWaiter.wait(for: [allVisibleAgain], timeout: 3), .completed)
        XCTAssertEqual(allRestored.frame.minY, allY, accuracy: 3)
    }

    @MainActor
    func testUnifiedSkillLibraryContainsCandidateManagedAndAttentionStates() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture)

        XCTAssertTrue(app.descendants(matching: .any)["skill-library-list"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)[Phase1UITestFixture.candidateRowIdentifier].exists)
        let managedRow = app.descendants(matching: .any)["skill-row-fixture-review-candidate"]
        XCTAssertTrue(managedRow.exists)
        XCTAssertFalse(app.buttons["relation-action-codex-review-fixture-card"].exists)
        XCTAssertFalse(app.buttons["candidate-agent-action-codex-fixture-publish-candidate"].exists)
        XCTAssertTrue(app.staticTexts["Broken Fixture"].exists)

        app.descendants(matching: .any)[Phase1UITestFixture.candidateRowIdentifier].click()
        XCTAssertTrue(app.descendants(matching: .any)["skill-detail"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["review-managed-copy-fixture-publish-candidate"].exists)

        app.descendants(matching: .any)["skill-filter"].click()
        app.menuItems["Needs Attention"].click()
        XCTAssertTrue(app.staticTexts["Broken Fixture"].waitForExistence(timeout: 2))
        XCTAssertTrue(managedRow.exists, "Unverified Agent relationships still need attention")
        XCTAssertFalse(app.descendants(matching: .any)[Phase1UITestFixture.candidateRowIdentifier].exists)
    }

    @MainActor
    func testLocalSourcesAndTaskGroupsMatchPhaseOneContract() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture)

        selectNavigation("local-sources", in: app)
        XCTAssertTrue(app.buttons["add-local-source"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["check-local-root"].exists)
        let sourceRow = app.descendants(matching: .any)[Phase1UITestFixture.sourceRowIdentifier]
        XCTAssertTrue(sourceRow.exists)
        sourceRow.click()
        XCTAssertTrue(app.descendants(matching: .any)["source-detail"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["view-source-skills"].exists)
        app.buttons["view-source-skills"].click()
        XCTAssertTrue(app.buttons["return-to-source"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)[Phase1UITestFixture.candidateRowIdentifier].exists)
        XCTAssertFalse(app.staticTexts["Broken Fixture"].exists)
        app.buttons["return-to-source"].click()

        selectNavigation("tasks", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["phase1-task-list"].waitForExistence(timeout: 2))
        assertTaskGroups(["Waiting for confirmation", "Running", "Needs attention", "Recently completed"], in: app)
        let back = app.buttons["back-to-settings"]
        XCTAssertTrue(back.waitForExistence(timeout: 2))
        back.click()
        XCTAssertTrue(app.descendants(matching: .any)["settings-workspace"].waitForExistence(timeout: 2))
        let refresh = app.buttons["refresh-default-agent-directories"]
        XCTAssertTrue(refresh.isEnabled)
        refresh.click()
        for agent in ["codex", "claudeCode"] {
            XCTAssertTrue(app.descendants(matching: .any)["default-agent-directory-status-\(agent)"].exists
                || app.descendants(matching: .any)["default-agent-directory-verified-\(agent)"].exists)
        }
    }

    @MainActor
    func testDefaultAgentRefreshShowsCurrentEntriesAtMinimumWidthInThreeLanguages() throws {
        for (language, title) in [
            ("en", "Refresh default Agent directories"),
            ("zh-Hans", "刷新默认 Agent 目录"),
            ("ja", "既定のAgentディレクトリを更新")
        ] {
            let fixture = try makeFixture()
            let hidden = fixture.home.appending(path: ".codex/skills/.hidden-review")
            try Data("hidden".utf8).write(to: hidden)
            let app = try launch(fixture: fixture, language: language, windowWidth: 1040)
            selectNavigation("settings", in: app)
            let refresh = app.buttons["refresh-default-agent-directories"]
            let heading = app.descendants(matching: .any)["settings-agents-heading"]
            XCTAssertTrue(refresh.isHittable)
            XCTAssertTrue(heading.exists)
            XCTAssertEqual(refresh.label, title)
            XCTAssertGreaterThan(refresh.frame.minX, heading.frame.maxX)
            XCTAssertEqual(refresh.frame.midY, heading.frame.midY, accuracy: 16)
            refresh.click()
            XCTAssertTrue(app.descendants(matching: .any)["default-agent-directory-verified-codex"].waitForExistence(timeout: 3))
            selectNavigation("agent-codex", in: app)
            XCTAssertTrue(app.staticTexts["agent-owned-review"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts[".hidden-review"].exists)
            selectNavigation("settings", in: app)
            selectNavigation("agent-codex", in: app)
            XCTAssertTrue(app.staticTexts["agent-owned-review"].waitForExistence(timeout: 3))
            app.terminate()
            try fixture.cleanup()
            activeFixture = nil
        }
    }

    @MainActor
    func testDefaultAgentDirectoryAuthorizationCancelAndExactSelection() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture, additionalArguments: ["--skillshub-ui-agent-authorization-fixture"])
        selectNavigation("settings", in: app)
        app.buttons["refresh-default-agent-directories"].click()
        let authorize = app.buttons["authorize-default-agent-directory-codex"]
        let verified = app.descendants(matching: .any)["default-agent-directory-verified-codex"]
        XCTAssertTrue(authorize.waitForExistence(timeout: 3))
        XCTAssertFalse(verified.exists)

        authorize.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(authorize.exists)
        XCTAssertFalse(verified.exists)

        authorize.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
        let target = fixture.home.appending(path: ".codex/skills", directoryHint: .isDirectory)
        chooseDirectory(target, in: app)
        XCTAssertTrue(verified.waitForExistence(timeout: 3))
        selectNavigation("agent-codex", in: app)
        XCTAssertTrue(app.staticTexts["agent-owned-review"].waitForExistence(timeout: 3))
        try FileManager.default.moveItem(at: target, to: fixture.runRoot.appending(path: "removed-codex-skills"))
        selectNavigation("settings", in: app)
        app.buttons["refresh-default-agent-directories"].click()
        XCTAssertFalse(verified.exists)
        XCTAssertTrue(app.descendants(matching: .any)["default-agent-directory-status-codex"].exists)
        selectNavigation("agent-codex", in: app)
        XCTAssertTrue(app.staticTexts["agent-owned-review"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Agent directory has not been verified."].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["No matching Skills"].exists)
    }

    @MainActor
    func testAuthorizedAgentEntriesReturnAfterAppRestart() throws {
        let fixture = try makeFixture()
        let root = fixture.home.appending(path: "skills-hub", directoryHint: .isDirectory)
        let target = fixture.home.appending(path: ".claude/skills", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.appending(path: "outside-skill"), withIntermediateDirectories: true)
        let supportName = "SkillsHubUITests-restart-\(fixture.runID.uuidString)"
        var app = launchPlatformRootApp(fixture: fixture, scenario: "restart", appSupportName: supportName)
        openEstablishRootPanel(in: app)
        chooseDirectory(root, in: app)
        XCTAssertTrue(waitForConfiguredRoot(in: app, expectedCount: 1))
        selectNavigation("settings", in: app)
        app.buttons["refresh-default-agent-directories"].click()
        let authorize = app.buttons["authorize-default-agent-directory-claudeCode"]
        XCTAssertTrue(authorize.waitForExistence(timeout: 3))
        authorize.click()
        chooseDirectory(target, in: app)
        selectNavigation("agent-claudeCode", in: app)
        XCTAssertTrue(app.staticTexts["outside-skill"].waitForExistence(timeout: 3))
        let metadataURL = root.appending(path: ".skillshub.json")
        let before = try Data(contentsOf: metadataURL)
        app.terminate()
        activeApp = nil

        app = launchPlatformRootApp(fixture: fixture, scenario: "restart", appSupportName: supportName, expectEmpty: false)
        selectNavigation("agent-claudeCode", in: app)
        XCTAssertTrue(app.staticTexts["outside-skill"].waitForExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: metadataURL), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appending(path: "outside-skill").path))
    }

    @MainActor
    func testSourceUpdatePreviewShowsCompleteScopeAndCancellationPreservesFacts() throws {
        let fixture = try makeFixture()
        try Data("---\nname: review-fixture\ndescription: Updated upstream.\n---\nUpdated.\n".utf8).write(
            to: fixture.source.appending(path: "review-fixture/SKILL.md"),
            options: .atomic
        )
        try Data("shared=true\n".utf8).write(
            to: fixture.source.appending(path: "review-fixture/shared.conf"),
            options: .atomic
        )
        let managed = fixture.root.appending(path: "local/review-fixture", directoryHint: .isDirectory)
        let managedBefore = try treeSnapshot(of: managed)
        let app = try launch(
            fixture: fixture,
            additionalArguments: ["--skillshub-ui-source-update-fixture"]
        )
        let metadataBefore = try Data(contentsOf: fixture.metadata)

        selectNavigation("local-sources", in: app)
        let sourceRow = app.descendants(matching: .any)[Phase1UITestFixture.sourceRowIdentifier]
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 2))
        sourceRow.click()
        app.buttons["check-source-update"].click()
        XCTAssertTrue(app.buttons["preview-source-update"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["source-update-preview"].exists)
        app.buttons["preview-source-update"].click()
        XCTAssertTrue(app.descendants(matching: .any)["source-update-preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Complete Content Changes"].exists)
        XCTAssertTrue(app.staticTexts["Potential Shared Content and Agent Impact"].exists)
        XCTAssertTrue(app.staticTexts["Dependency boundaries are conservative. Every enabled Skill in this source is included."].exists)
        let agentImpact = app.descendants(matching: .any)["source-update-agent-impact"]
        XCTAssertTrue(agentImpact.exists)
        XCTAssertEqual(agentImpact.value as? String, "Claude Code, Codex, Custom Agent")
        XCTAssertTrue(app.buttons["Update Entire Source"].exists)
        app.buttons["Cancel and Keep Current Content"].click()

        XCTAssertEqual(try treeSnapshot(of: managed), managedBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.metadata), metadataBefore)
        app.staticTexts["trash-fixture"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["source-detail"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["check-source-update"].exists)
    }

    @MainActor
    func testConfirmedSourceUpdateShowsComponentResultsAndRecordsTrashDestination() throws {
        let fixture = try makeFixture()
        try Data("---\nname: review-fixture\ndescription: Updated upstream.\n---\nUpdated.\n".utf8).write(
            to: fixture.source.appending(path: "review-fixture/SKILL.md"),
            options: .atomic
        )
        let managed = fixture.root.appending(path: "local/review-fixture", directoryHint: .isDirectory)
        let externalBefore = try treeSnapshot(of: fixture.source)
        let app = try launch(
            fixture: fixture,
            additionalArguments: ["--skillshub-ui-source-update-fixture"]
        )

        selectNavigation("local-sources", in: app)
        let sourceRow = app.descendants(matching: .any)[Phase1UITestFixture.sourceRowIdentifier]
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 2))
        sourceRow.click()
        app.buttons["check-source-update"].click()
        XCTAssertTrue(app.buttons["preview-source-update"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["source-update-preview"].exists)
        app.buttons["preview-source-update"].click()
        XCTAssertTrue(app.buttons["Update Entire Source"].waitForExistence(timeout: 5))
        app.buttons["Update Entire Source"].click()

        XCTAssertTrue(app.staticTexts["Update Applied"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Content: prepared source is active"].exists)
        XCTAssertTrue(app.staticTexts["Metadata and baseline: committed"].exists)
        XCTAssertTrue(app.staticTexts["Old content: moved to Trash"].exists)
        XCTAssertTrue(try String(contentsOf: managed.appending(path: "SKILL.md"), encoding: .utf8).contains("Updated upstream"))
        XCTAssertEqual(try treeSnapshot(of: fixture.source), externalBefore)

        let operationRoot = fixture.root.appending(path: ".skillshub-operations", directoryHint: .isDirectory)
        let recordURL = try XCTUnwrap(
            FileManager.default.enumerator(at: operationRoot, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .first { $0.lastPathComponent == "source-update.json" }
        )
        let recordData = try Data(contentsOf: recordURL)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: recordData) as? [String: Any])
        XCTAssertEqual(record["stage"] as? String, "completed")
        let trashPath = try XCTUnwrap(record["trashPath"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: trashPath).appending(path: "SKILL.md").path))
        let attachment = XCTAttachment(data: recordData, uniformTypeIdentifier: "public.json")
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testSourceUpdateConfirmationAndResultUseSelectedLanguage() throws {
        for (language, confirmation, resultTitle) in [
            ("zh-Hans", "更新整个来源", "更新已应用"),
            ("ja", "ソース全体を更新", "更新を適用済み")
        ] {
            let fixture = try makeFixture()
            try Data("---\nname: review-fixture\ndescription: Updated upstream.\n---\nUpdated.\n".utf8).write(
                to: fixture.source.appending(path: "review-fixture/SKILL.md"), options: .atomic
            )
            let app = try launch(fixture: fixture, language: language,
                                 additionalArguments: ["--skillshub-ui-source-update-fixture"])
            selectNavigation("local-sources", in: app)
            app.descendants(matching: .any)[Phase1UITestFixture.sourceRowIdentifier].click()
            app.buttons["check-source-update"].click()
            app.buttons["preview-source-update"].click()
            let confirm = app.buttons[confirmation]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.click()
            XCTAssertTrue(app.staticTexts[resultTitle].waitForExistence(timeout: 5))
            let managed = fixture.root.appending(path: "local/review-fixture/SKILL.md")
            XCTAssertTrue(try String(contentsOf: managed, encoding: .utf8).contains("Updated upstream"))
            app.terminate()
            try fixture.cleanup()
            activeApp = nil
            activeFixture = nil
        }
    }

    @MainActor
    func testLocalLifecycleActionsRemainAvailableInChineseAndJapanese() throws {
        for (language, enableText, disableText, clearText, clearDetail, removeText, resultText) in [
            ("zh-Hans", "启用", "取消启用", "将清除", "移除已核实的", "移除本地来源", "实际结果"),
            ("ja", "有効にする", "無効にする", "解除予定", "確認済みの", "ローカルソースを削除", "実際の結果")
        ] {
            let fixture = try makeFixture()
            let additionalSource = fixture.runRoot.appending(path: "language-source/candidate-fixture", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: additionalSource, withIntermediateDirectories: true)
            try fixture.sourceSkillData.write(to: additionalSource.appending(path: "SKILL.md"))
            let app = try launch(fixture: fixture, language: language,
                                 additionalArguments: ["--skillshub-ui-agent-overflow-fixture"])
            selectNavigation("local-sources", in: app)
            app.buttons["add-local-source"].click()
            chooseDirectory(additionalSource.deletingLastPathComponent(), in: app)
            XCTAssertTrue(app.buttons["confirm-local-source-import"].waitForExistence(timeout: 3))
            app.buttons["confirm-local-source-import"].click()
            XCTAssertTrue(waitForText("local-source-imported", at: fixture.journal))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appending(path: "local/language-source/candidate-fixture/SKILL.md").path))

            selectNavigation("all-skills", in: app)
            app.descendants(matching: .any)["skill-row-fixture-review-candidate"].click()
            let detail = app.descendants(matching: .any)["skill-detail"]
            for (agent, directory) in [("codex", ".codex"), ("claudeCode", ".claude"), ("custom", ".custom")] {
                let action = app.buttons["relation-action-\(agent)-review-fixture-detail"]
                for _ in 0..<30 where !action.isHittable {
                    if action.frame.midY < detail.frame.midY {
                        detail.swipeDown(velocity: .slow)
                    } else {
                        detail.swipeUp(velocity: .slow)
                    }
                }
                XCTAssertTrue(action.isHittable)
                XCTAssertTrue(action.label.contains(enableText))
                action.click()
                let link = fixture.home.appending(path: "\(directory)/skills/Review Fixture")
                XCTAssertTrue(waitForFile(at: link))
                XCTAssertTrue(action.label.contains(disableText))
                if agent == "codex" {
                    action.click()
                    XCTAssertTrue(waitForMissingFile(at: link))
                    XCTAssertTrue(action.label.contains(enableText))
                    action.click()
                    XCTAssertTrue(waitForFile(at: link))
                }
            }
            let clear = app.buttons["clear-managed-relations"]
            for _ in 0..<25 where !clear.isHittable { detail.swipeUp() }
            XCTAssertTrue(clear.isHittable)
            clear.click()
            let clearPreview = app.descendants(matching: .any)["clear-preview-codex"]
            XCTAssertTrue(clearPreview.waitForExistence(timeout: 2))
            XCTAssertTrue(clearPreview.label.contains(clearText))
            XCTAssertTrue(clearPreview.label.contains(clearDetail))
            app.buttons["confirm-clear-managed-relations"].click()
            for directory in [".codex", ".claude", ".custom"] {
                XCTAssertTrue(waitForMissingFile(at: fixture.home.appending(path: "\(directory)/skills/Review Fixture")))
            }
            app.buttons["done-clear-managed-relations"].click()

            selectNavigation("local-sources", in: app)
            app.staticTexts["trash-fixture"].click()
            app.descendants(matching: .any)["source-more"].click()
            app.menuItems["remove-source"].click()
            XCTAssertTrue(app.staticTexts[removeText].waitForExistence(timeout: 2))
            app.buttons["confirm-remove-source"].click()
            XCTAssertTrue(app.staticTexts[resultText].waitForExistence(timeout: 5))
            XCTAssertTrue(waitForMissingFile(at: fixture.root.appending(path: "local/trash-fixture")))
            app.terminate()
            try fixture.cleanup()
            activeApp = nil
            activeFixture = nil
        }
    }

    @MainActor
    func testDirectLocalSourceRemovalShowsScopeAndRecordsRealTrashDestination() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture)
        let source = fixture.root.appending(path: "local/trash-fixture", directoryHint: .isDirectory)

        selectNavigation("local-sources", in: app)
        let sourceRow = app.staticTexts["trash-fixture"]
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 3))
        sourceRow.click()
        XCTAssertTrue(app.descendants(matching: .any)["source-more"].waitForExistence(timeout: 2))
        app.descendants(matching: .any)["source-more"].click()
        app.menuItems["remove-source"].click()
        XCTAssertTrue(app.staticTexts[source.path].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Trash Fixture"].exists)
        XCTAssertTrue(app.staticTexts["No managed Agent relationships are currently recorded."].exists)
        app.buttons["Cancel"].click()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        app.descendants(matching: .any)["source-more"].click()
        app.menuItems["remove-source"].click()
        app.buttons["confirm-remove-source"].click()
        XCTAssertTrue(app.staticTexts["Actual result"].waitForExistence(timeout: 5))

        let operationRoot = fixture.root.appending(path: ".skillshub-operations", directoryHint: .isDirectory)
        let recordURL = try XCTUnwrap(
            FileManager.default.enumerator(at: operationRoot, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .first { $0.lastPathComponent == "source-removal.json" }
        )
        let recordData = try Data(contentsOf: recordURL)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: recordData) as? [String: Any])
        guard record["stage"] as? String == "completed" else {
            XCTFail(String(decoding: recordData, as: UTF8.self))
            return
        }
        XCTAssertTrue(app.staticTexts["Operation record: completed"].exists)
        XCTAssertTrue(waitForMissingFile(at: source))
        let trashPath = try XCTUnwrap(record["trashPath"] as? String)
        let trashURL = URL(fileURLWithPath: trashPath, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.appending(path: "SKILL.md").path))
        let attachment = XCTAttachment(data: recordData, uniformTypeIdentifier: "public.json")
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testGitHubSourceRemovalUsesWholeRepositoryFlow() throws {
        let fixture = try makeFixture()
        var app = try launch(
            fixture: fixture,
            additionalArguments: ["--skillshub-ui-github-removal-fixture"]
        )
        let repository = fixture.root.appending(
            path: "github/acme/github-removal-fixture",
            directoryHint: .isDirectory
        )

        selectNavigation("github-sources", in: app)
        let sourceRow = app.staticTexts["acme/github-removal-fixture"]
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 3))
        sourceRow.click()
        XCTAssertTrue(app.descendants(matching: .any)["source-more"].waitForExistence(timeout: 2))
        app.descendants(matching: .any)["source-more"].click()
        app.menuItems["remove-source"].click()
        XCTAssertTrue(app.staticTexts["Remove GitHub Source"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts[repository.path].exists)
        app.buttons["Cancel"].click()
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.path))

        app.descendants(matching: .any)["source-more"].click()
        app.menuItems["remove-source"].click()
        app.buttons["confirm-remove-source"].click()
        XCTAssertTrue(app.staticTexts["Operation record: completed"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForMissingFile(at: repository))
        XCTAssertTrue(app.buttons["add-github-source"].waitForExistence(timeout: 2))

        let operations = fixture.root.appending(path: ".skillshub-operations", directoryHint: .isDirectory)
        let recordURL = try XCTUnwrap(
            FileManager.default.enumerator(at: operations, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .first { $0.lastPathComponent == "source-removal.json" }
        )
        let operationID = recordURL.deletingLastPathComponent().lastPathComponent
        let metadataURL = fixture.root.appending(path: ".skillshub.json")
        let metadata = try Data(contentsOf: metadataURL)
        let record = try Data(contentsOf: recordURL)
        app.terminate()

        app = launchPlatformRootApp(fixture: fixture, scenario: "github-removal-recovery")
        openConnectRootPanel(in: app)
        chooseDirectory(fixture.root, in: app)
        selectNavigation("tasks", in: app)
        let task = app.buttons["phase1-task-\(operationID)"]
        XCTAssertTrue(task.waitForExistence(timeout: 3))
        app.buttons["recheck-recovery-facts"].click()
        XCTAssertTrue(task.waitForExistence(timeout: 3))
        task.click()
        XCTAssertTrue(app.staticTexts["Current facts"].exists)
        let recordedLocation = app.descendants(matching: .any)["recovery-component-content"]
        XCTAssertTrue(recordedLocation.waitForExistence(timeout: 2))
        XCTAssertTrue(recordedLocation.label.contains(repository.path))
        app.buttons["task-open-skill-\(operationID)"].click()
        XCTAssertTrue(app.buttons["add-github-source"].waitForExistence(timeout: 2))
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
        XCTAssertEqual(try Data(contentsOf: recordURL), record)
    }

    @MainActor
    func testSidebarBrandIconsRemainReadable() throws {
        for (language, appearance) in [("en", "Light"), ("zh-Hans", "Light"), ("ja", "Light"), ("en", "Dark")] {
            let fixture = try makeFixture()
            let app = try launch(fixture: fixture, language: language, windowWidth: 1040,
                                 additionalArguments: ["--skillshub-ui-fixture-appearance", appearance])
            let sidebar = app.descendants(matching: .any)["phase1-product-sidebar"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 3))
            let divider = app.splitters.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            divider.click(forDuration: 0.2, thenDragTo: divider.withOffset(CGVector(dx: -400, dy: 0)))
            XCTAssertEqual(sidebar.frame.width, 176, accuracy: 2)
            XCTAssertTrue(app.descendants(matching: .any)["nav-agent-codex"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["nav-agent-claudeCode"].exists)
            for destination in ["github-sources", "agent-codex", "agent-claudeCode"] {
                selectNavigation(destination, in: app)
                let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                shot.name = "M002 sidebar \(language) \(appearance) \(destination)"
                shot.lifetime = .keepAlways
                add(shot)
            }
            app.terminate()
            try fixture.cleanup()
            activeFixture = nil
        }
    }

    @MainActor
    func testOperationTaskGroupsAndRecoveryAreReadableInThreeLanguages() throws {
        let samples = [
            ("en", ["Waiting for confirmation", "Running", "Needs attention", "Recently completed"], "Re-observe the current object before preparing a new plan.", "Expanded"),
            ("zh-Hans", ["等待确认", "运行中", "需要处理", "最近完成"], "先重新观察当前对象，再准备新计划。", "已展开"),
            ("ja", ["確認待ち", "進行中", "要確認", "最近の完了"], "新しい計画の前に、現在の対象を再観察してください。", "展開")
        ]
        for (language, groups, nextStep, expanded) in samples {
            let fixture = try makeFixture()
            let app = try launch(fixture: fixture, language: language)
            selectNavigation("settings", in: app)
            let summary = app.staticTexts["operation-summary"]
            XCTAssertTrue(summary.waitForExistence(timeout: 2))
            let expectedSummary = ["en": "Pending operations: 6", "zh-Hans": "待处理操作：6", "ja": "保留中の操作：6"]
            XCTAssertEqual(summary.value as? String, expectedSummary[language])
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "open-operation-")).firstMatch.exists)
            let settings = app.descendants(matching: .any)["settings-workspace"]
            for _ in 0..<3 where !settings.frame.insetBy(dx: 0, dy: 8).contains(summary.frame) {
                settings.swipeUp()
            }
            let settingsShot = XCTAttachment(screenshot: app.screenshot())
            settingsShot.name = "M002 pending summary \(language)"
            settingsShot.lifetime = .keepAlways
            add(settingsShot)
            selectNavigation("tasks", in: app)
            assertTaskGroups(groups, in: app)
            let taskID = "77777777-7777-7777-7777-777777777777"
            let task = app.buttons["phase1-task-\(taskID)"]
            if !task.exists {
                app.descendants(matching: .any)["phase1-task-list"].swipeDown()
            }
            XCTAssertTrue(task.waitForExistence(timeout: 2))
            XCTAssertTrue(task.label.contains(groups[2]))
            XCTAssertTrue(task.label.contains(nextStep))
            task.click()
            let nextStepText = app.staticTexts["task-safe-next-step-\(taskID)"]
            XCTAssertTrue(nextStepText.waitForExistence(timeout: 2))
            XCTAssertEqual(nextStepText.value as? String, nextStep)
            XCTAssertEqual(task.value as? String, expanded)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "M-002 tasks \(language)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            selectNavigation("local-sources", in: app)
            selectNavigation("tasks", in: app)
            XCTAssertTrue(task.exists)
            app.terminate()
            try fixture.cleanup()
            activeFixture = nil
        }
    }

    @MainActor
    func testOperationSummaryWithoutPendingRecords() throws {
        for (language, emptyText, completedText) in [
            ("en", "No pending operations", "Recently completed"),
            ("zh-Hans", "没有待处理操作", "最近完成"),
            ("ja", "保留中の操作はありません", "最近の完了")
        ] {
            let fixture = try makeFixture()
            let app = try launch(fixture: fixture, empty: true, language: language)
            for state in ["empty", "completed"] {
                if state == "completed" {
                    selectNavigation("all-skills", in: app)
                    let root = fixture.runRoot.appending(path: "summary-root", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                    openEstablishRootPanel(in: app)
                    chooseDirectory(root, in: app)
                    XCTAssertTrue(waitForText("root-initialized", at: root.appending(path: ".skillshub.operations.jsonl")))
                }
                selectNavigation("settings", in: app)
                let summary = app.staticTexts["operation-summary"]
                XCTAssertTrue(summary.waitForExistence(timeout: 2))
                XCTAssertEqual(summary.value as? String, emptyText)
                XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "open-operation-")).firstMatch.exists)
                let settings = app.descendants(matching: .any)["settings-workspace"]
                for _ in 0..<3 where !settings.frame.insetBy(dx: 0, dy: 8).contains(summary.frame) {
                    settings.swipeUp()
                }
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "M002 \(state) summary \(language)"
                shot.lifetime = .keepAlways
                add(shot)
                selectNavigation("tasks", in: app)
                if state == "empty" {
                    XCTAssertTrue(app.staticTexts[emptyText].exists)
                } else {
                    assertTaskGroups([completedText], in: app)
                    let task = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "phase1-task-")).firstMatch
                    XCTAssertTrue(task.exists)
                    task.click()
                    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-safe-next-step-")).firstMatch.exists)
                }
            }
            app.terminate()
            try fixture.cleanup()
            activeFixture = nil
        }
    }

    @MainActor
    func testAgentDetailsKeepEveryAgentAccessibleInThreeLanguages() throws {
        for (language, appearance) in [("en", "Light"), ("zh-Hans", "Light"), ("ja", "Light"), ("en", "Dark")] {
            let fixture = try makeFixture()
            let app = try launch(fixture: fixture, language: language, windowWidth: 1040,
                                 additionalArguments: ["--skillshub-ui-agent-overflow-fixture", "--skillshub-ui-fixture-appearance", appearance])
            let row = app.descendants(matching: .any)["skill-row-fixture-review-candidate"]
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            XCTAssertFalse(row.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "relation-action-")).firstMatch.exists)
            row.click()
            let detail = app.descendants(matching: .any)["skill-detail"]
            XCTAssertTrue(detail.waitForExistence(timeout: 2))
            if language == "en" {
                let window = app.windows.firstMatch
                let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
                corner.click(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 0, dy: -500)))
                XCTAssertEqual(app.descendants(matching: .any)["workspace-list-pane"].frame.height, 560, accuracy: 2)
            }
            let lastAction = app.buttons["relation-action-overflow-16-review-fixture-detail"]
            for _ in 0..<20 where !lastAction.isHittable || lastAction.frame.maxY > detail.frame.maxY - 8 {
                detail.swipeUp()
            }
            XCTAssertTrue(lastAction.isHittable)
            XCTAssertLessThanOrEqual(lastAction.frame.maxY, detail.frame.maxY - 8)
            XCTAssertTrue(app.staticTexts["zzzz 非常に長いカスタムAgent名"].exists)
            if language == "en" {
                lastAction.click()
                let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "Disable"), object: lastAction)
                XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 5), .completed)
                let lastAgent = app.descendants(matching: .any)["nav-agent-overflow-16"]
                let sidebar = app.descendants(matching: .any)["phase1-product-sidebar"]
                for _ in 0..<20 where !lastAgent.isHittable { sidebar.swipeUp() }
                XCTAssertTrue(lastAgent.isHittable)
                lastAgent.click()
                XCTAssertTrue(app.descendants(matching: .any)["agent-workspace-search"].isHittable)
            }
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = "All Agent details \(language) \(appearance)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
            try fixture.cleanup()
            activeFixture = nil
        }
    }

    @MainActor
    func testCustomAgentDisplayEditKeepsIdentityDirectoryAndRelations() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture, additionalArguments: ["--skillshub-ui-agent-overflow-fixture"])
        let before = try metadataObject(at: fixture.metadata)

        selectNavigation("settings", in: app)
        let configure = app.buttons["configure-agent-custom"]
        XCTAssertTrue(configure.waitForExistence(timeout: 2))
        configure.click()
        let name = app.textFields["agent-name-field"]
        let monogram = app.textFields["agent-monogram-field"]
        let save = app.buttons["save-agent-display-fields"]
        XCTAssertTrue(name.exists && monogram.exists && save.exists)
        XCTAssertFalse(save.isEnabled)

        monogram.click()
        monogram.typeKey("a", modifierFlags: .command)
        monogram.typeText("ABCDE")
        XCTAssertEqual(monogram.value as? String, "ABCDE")
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(app.staticTexts["Enter 1–4 visible characters for the icon abbreviation."].exists)
        monogram.typeKey("a", modifierFlags: .command)
        monogram.typeText("AAAA")
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("長い Custom Agent Name")
        XCTAssertTrue(save.isEnabled)
        save.click()

        let sidebarAgent = app.descendants(matching: .any)["nav-agent-custom"]
        XCTAssertTrue(sidebarAgent.waitForExistence(timeout: 3))
        XCTAssertTrue(sidebarAgent.label.contains("長い Custom Agent Name"))
        selectNavigation("all-skills", in: app)
        app.descendants(matching: .any)["skill-row-fixture-review-candidate"].click()
        XCTAssertTrue(app.descendants(matching: .any)["relation-detail-custom-review-fixture"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["長い Custom Agent Name"].exists)
        XCTAssertEqual(app.buttons["relation-action-custom-review-fixture-detail"].label,
                       "Enable 長い Custom Agent Name relationship")
        sidebarAgent.click()
        XCTAssertTrue(app.descendants(matching: .any)["agent-workspace-search"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["長い Custom Agent Name"].exists)

        let after = try metadataObject(at: fixture.metadata)
        let oldAgent = try XCTUnwrap((before["agents"] as? [[String: Any]])?.first { ($0["id"] as? String) == "custom" })
        let newAgent = try XCTUnwrap((after["agents"] as? [[String: Any]])?.first { ($0["id"] as? String) == "custom" })
        XCTAssertEqual(newAgent["displayName"] as? String, "長い Custom Agent Name")
        XCTAssertEqual(newAgent["iconMonogram"] as? String, "AAAA")
        XCTAssertEqual(newAgent["skillsDirectory"] as? String, oldAgent["skillsDirectory"] as? String)
        for key in ["enablementIntents", "managedRelationEvidence"] {
            XCTAssertEqual(try metadataFieldData(key, in: after), try metadataFieldData(key, in: before))
        }
    }

    @MainActor
    func testRootOperationOffPageCompletionAndUnknownRecovery() throws {
        let fixture = try makeFixture()
        let root = fixture.runRoot.appending(path: "operation-root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var app = launchPlatformRootApp(fixture: fixture, scenario: "operation")
        openEstablishRootPanel(in: app)
        chooseDirectory(root, in: app)
        selectNavigation("local-sources", in: app)
        let journal = root.appending(path: ".skillshub.operations.jsonl")
        XCTAssertTrue(waitForText("root-initialized", at: journal))
        let operationID = try operationIdentity(inJournal: journal)
        selectNavigation("tasks", in: app)
        assertTaskResult(contains: "Completed", operationID: operationID, in: app)
        app.terminate()

        let completeJournal = try Data(contentsOf: journal)
        let metadata = try Data(contentsOf: root.appending(path: ".skillshub.json"))
        let prefix = completeJournal.split(separator: 0x0A).dropLast().reduce(into: Data()) { $0 += Data($1) + Data([0x0A]) }
        try prefix.write(to: journal)
        app = launchPlatformRootApp(fixture: fixture, scenario: "recovery")
        openConnectRootPanel(in: app)
        chooseDirectory(root, in: app)
        selectNavigation("tasks", in: app)
        assertTaskResult(contains: "Needs attention", operationID: operationID, in: app)
        let recheck = app.buttons["recheck-recovery-facts"]
        XCTAssertTrue(recheck.waitForExistence(timeout: 2))
        recheck.click()
        assertTaskResult(contains: "Needs attention", operationID: operationID, in: app)
        app.buttons["phase1-task-\(operationID)"].click()
        XCTAssertTrue(app.staticTexts["task-planned-writes-\(operationID)"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Retry"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "M-002 Root recovery evidence"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["task-open-skill-\(operationID)"].click()
        XCTAssertTrue(app.buttons["manage-root-settings"].waitForExistence(timeout: 2))
        XCTAssertEqual(try Data(contentsOf: journal), prefix)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: ".skillshub.json")), metadata)
        for (name, bytes) in [("complete-journal.jsonl", completeJournal), ("recovery-prefix.jsonl", prefix), ("metadata.json", metadata)] {
            let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.data")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testCurrentShellDoesNotExposeOutOfScopeWriteEntrypoints() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture)

        for forbidden in ["Add Project", "Archive", "Delete", "Edit Tags", "Check Update", "Export Manifest", "Import Manifest"] {
            XCTAssertFalse(app.buttons[forbidden].exists, "Later-phase write entry \(forbidden) must not be exposed")
        }

        selectNavigation("github-sources", in: app)
        XCTAssertTrue(app.staticTexts["GitHub Sources"].waitForExistence(timeout: 2))
        let metadataBefore = try Data(contentsOf: fixture.metadata)
        app.buttons["add-github-source"].click()
        XCTAssertTrue(app.staticTexts["github-source-import-sheet"].waitForExistence(timeout: 2))
        let input = app.textFields["github-source-input"]
        input.click()
        input.typeText("https://github.com/acme/repository")
        app.buttons["cancel-github-source-import"].click()
        XCTAssertFalse(app.staticTexts["github-source-import-sheet"].exists)
        XCTAssertEqual(try Data(contentsOf: fixture.metadata), metadataBefore)

        app.buttons["add-github-source"].click()
        XCTAssertTrue(app.staticTexts["github-source-import-sheet"].waitForExistence(timeout: 2))
        let retainedInput = app.textFields["github-source-input"]
        XCTAssertEqual(retainedInput.value as? String, "https://github.com/acme/repository")
        retainedInput.click()
        retainedInput.typeKey("a", modifierFlags: .command)
        retainedInput.typeText("https://github.com/acme/repository/tree/main")
        app.buttons["confirm-github-source-import"].click()
        XCTAssertTrue(app.staticTexts["The first version supports repository roots on their default branch only."].waitForExistence(timeout: 2))
        XCTAssertEqual(retainedInput.value as? String, "https://github.com/acme/repository/tree/main")
        XCTAssertEqual(try Data(contentsOf: fixture.metadata), metadataBefore)
        app.buttons["cancel-github-source-import"].click()

        selectNavigation("agent-codex", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["agent-workspace"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Delete"].exists)
        XCTAssertFalse(app.buttons["Repair all"].exists)
    }

    @MainActor
    func testGitHubImportConsumesFixedHTTPThroughTheAppFlow() throws {
        let fixture = try makeFixture()
        let app = try launch(
            fixture: fixture,
            additionalArguments: ["--skillshub-ui-github-import-fixture"]
        )

        selectNavigation("github-sources", in: app)
        app.buttons["add-github-source"].click()
        let input = app.textFields["github-source-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 2))
        input.click()
        input.typeText("https://github.com/fixture-owner/lifecycle")
        app.buttons["confirm-github-source-import"].click()

        let status = app.staticTexts["status-banner"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertEqual(status.value as? String, "Source imported.")
        let repository = fixture.root.appending(path: "github/fixture-owner/lifecycle", directoryHint: .isDirectory)
        XCTAssertEqual(
            try String(contentsOf: repository.appending(path: "shared/config.json"), encoding: .utf8),
            "{\"fixture\":true}\n"
        )
        let requests = try String(contentsOf: fixture.runRoot.appending(path: "github-requests.jsonl"), encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(requests.compactMap { $0["path"] as? String }, [
            "/repos/fixture-owner/lifecycle",
            "/repos/fixture-owner/lifecycle/git/ref/heads/main",
            "/repos/fixture-owner/lifecycle/git/trees/1111111111111111111111111111111111111111",
            "/repos/fixture-owner/lifecycle/tarball/1111111111111111111111111111111111111111"
        ])
        XCTAssertTrue(requests.allSatisfy { ($0["method"] as? String) == "GET" })
        XCTAssertTrue(requests.allSatisfy { ($0["authorization"] as? Bool) == false })
        XCTAssertTrue(app.descendants(matching: .any)["source-detail"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAgentSettingsAndSingleRelationActionProjectCurrentFactsAcrossViews() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture)

        selectNavigation("settings", in: app)
        let configureCodex = app.buttons["configure-agent-codex"]
        XCTAssertTrue(configureCodex.waitForExistence(timeout: 2))
        configureCodex.click()
        let configurationForm = app.buttons["Save name and abbreviation"]
        XCTAssertTrue(configurationForm.waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["agent-name-field"].exists)
        XCTAssertTrue(app.buttons["Save name and abbreviation"].exists)
        XCTAssertFalse(app.buttons["choose-agent-target-codex"].exists)
        XCTAssertTrue(app.buttons["process-agent-directory-blockers-codex"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["agent-configuration-relation-write-boundary"].exists)
        for _ in 0..<10 where !app.buttons["process-agent-directory-blockers-codex"].isHittable {
            let settings = app.descendants(matching: .any)["settings-workspace"]
            if app.buttons["process-agent-directory-blockers-codex"].frame.midY < app.windows.firstMatch.frame.midY {
                settings.swipeDown(velocity: .slow)
            } else {
                settings.swipeUp(velocity: .slow)
            }
        }
        app.buttons["process-agent-directory-blockers-codex"].click()
        XCTAssertTrue(app.descendants(matching: .any)["agent-workspace"].waitForExistence(timeout: 2))
        selectNavigation("settings", in: app)
        XCTAssertTrue(configurationForm.waitForExistence(timeout: 2))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(configurationForm.waitForExistence(timeout: 2))
        app.buttons["Cancel"].click()
        XCTAssertFalse(configurationForm.waitForExistence(timeout: 2))

        selectNavigation("all-skills", in: app)
        let managedRow = app.descendants(matching: .any)["skill-row-fixture-review-candidate"]
        XCTAssertTrue(managedRow.waitForExistence(timeout: 2))
        managedRow.click()
        XCTAssertTrue(app.descendants(matching: .any)["skill-detail"].waitForExistence(timeout: 2))
        let codexAction = app.buttons["relation-action-codex-review-fixture-detail"]
        let claudeAction = app.buttons["relation-action-claudeCode-review-fixture-detail"]
        XCTAssertTrue(codexAction.waitForExistence(timeout: 2))
        XCTAssertEqual(codexAction.label, "Enable Codex relationship")
        XCTAssertTrue(claudeAction.exists)
        XCTAssertEqual(claudeAction.label, "Enable Claude Code relationship")
        codexAction.click()

        let codexLink = fixture.home.appending(path: ".codex/skills/Review Fixture")
        XCTAssertTrue(waitForFile(at: codexLink))
        let codexVerification = app.descendants(matching: .any)[
            "relation-verification-codex-review-fixture"
        ]
        XCTAssertTrue(codexVerification.waitForExistence(timeout: 3))
        XCTAssertEqual(codexVerification.label, "Verification")
        XCTAssertEqual(codexVerification.value as? String, "Verified consistent")
        XCTAssertEqual(claudeAction.label, "Enable Claude Code relationship")

        selectNavigation("agent-codex", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["agent-workspace"].waitForExistence(timeout: 2))
        app.staticTexts["Review Fixture"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["agent-workspace-search"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["agent-ownership-filter"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["agent-attention-filter"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["relation-detail-codex-review-fixture"].exists)
        let recheck = app.buttons["recheck-agent-directory-codex"]
        XCTAssertTrue(recheck.exists)
        recheck.click()
        XCTAssertTrue(app.staticTexts["agent-owned-review"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["codex-review"].exists)
        app.staticTexts["agent-owned-review"].firstMatch.click()
        XCTAssertTrue(app.buttons["Copy into Skills Hub…"].exists)
        app.staticTexts["codex-review"].firstMatch.click()
        let brokenLink = fixture.home.appending(path: ".codex/skills/codex-review")
        let deleteBrokenLink = app.buttons["Delete broken link…"]
        XCTAssertTrue(deleteBrokenLink.waitForExistence(timeout: 2))
        deleteBrokenLink.click()
        let confirmationSheet = app.sheets["alert"]
        let confirmationTitle = app.staticTexts["Delete this link node?"]
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 2))
        let confirmationDetails = confirmationSheet.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH %@", "Agent: Codex")
        ).firstMatch
        XCTAssertTrue(confirmationDetails.waitForExistence(timeout: 2))
        let detailsText = try XCTUnwrap(confirmationDetails.value as? String)
        XCTAssertTrue(detailsText.contains("Original target:"))
        XCTAssertTrue(detailsText.contains("Resolved target:"))
        XCTAssertTrue(detailsText.contains("Only the symbolic-link node will be deleted"))
        confirmationSheet.buttons["Cancel"].click()
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: brokenLink.path))
        deleteBrokenLink.click()
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 2))
        confirmationSheet.buttons["Delete link node"].click()
        XCTAssertTrue(waitForMissingSymbolicLink(at: brokenLink))
    }

    @MainActor
    func testWorkspaceRoundTripsPreserveObjectsFiltersRecoveryAndUnsavedDraft() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture)
        let metadataBefore = try Data(contentsOf: fixture.metadata)

        selectNavigation("local-sources", in: app)
        let sourceRow = app.descendants(matching: .any)[Phase1UITestFixture.sourceRowIdentifier]
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 2))
        sourceRow.click()
        XCTAssertTrue(app.descendants(matching: .any)["source-detail"].waitForExistence(timeout: 2))
        app.buttons["view-source-skills"].click()
        XCTAssertTrue(app.descendants(matching: .any)["skill-library-list"].waitForExistence(timeout: 2))
        app.buttons["return-to-source"].click()
        XCTAssertTrue(app.descendants(matching: .any)["source-detail"].waitForExistence(timeout: 2))
        selectNavigation("github-sources", in: app)
        selectNavigation("local-sources", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["source-detail"].waitForExistence(timeout: 2))

        selectNavigation("agent-codex", in: app)
        let agentSearch = app.descendants(matching: .any)["agent-workspace-search"]
        XCTAssertTrue(agentSearch.waitForExistence(timeout: 2))
        agentSearch.click()
        agentSearch.typeText("review")
        selectNavigation("all-skills", in: app)
        selectNavigation("agent-codex", in: app)
        XCTAssertEqual(agentSearch.value as? String, "review")

        selectNavigation("tasks", in: app)
        let recoveryTask = app.buttons["phase1-task-77777777-7777-7777-7777-777777777777"]
        if !recoveryTask.exists {
            app.descendants(matching: .any)["phase1-task-list"].swipeDown()
        }
        XCTAssertTrue(recoveryTask.waitForExistence(timeout: 2))
        recoveryTask.click()
        XCTAssertEqual(recoveryTask.value as? String, "Expanded")
        selectNavigation("all-skills", in: app)
        selectNavigation("tasks", in: app)
        XCTAssertEqual(recoveryTask.value as? String, "Expanded")

        selectNavigation("settings", in: app)
        app.buttons["configure-agent-codex"].click()
        let name = app.textFields["agent-name-field"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Unsaved Codex")
        selectNavigation("all-skills", in: app)
        XCTAssertTrue(app.staticTexts["Discard unsaved changes?"].waitForExistence(timeout: 2))
        app.sheets.buttons["Stay Here"].click()
        XCTAssertTrue(app.descendants(matching: .any)["settings-workspace"].waitForExistence(timeout: 2))
        XCTAssertEqual(name.value as? String, "Unsaved Codex")
        selectNavigation("all-skills", in: app)
        app.sheets.buttons["Discard Changes"].click()
        XCTAssertTrue(app.descendants(matching: .any)["skill-library-list"].waitForExistence(timeout: 2))

        XCTAssertEqual(try Data(contentsOf: fixture.metadata), metadataBefore)
    }

    @MainActor
    func testNegativeRelationTaskKeepsEvidenceAndRecoversFromMissingObject() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture)

        selectNavigation("tasks", in: app)
        let task = app.buttons["phase1-task-99999999-9999-9999-9999-999999999993"]
        let taskList = app.descendants(matching: .any)["phase1-task-list"]
        for _ in 0..<4 where !task.isHittable {
            taskList.swipeUp()
        }
        XCTAssertTrue(task.waitForExistence(timeout: 3))
        task.click()

        for evidenceText in [
            "Outcome: Unknown",
            "Current conclusion: Currently unverifiable",
            "No verified relationship delta is claimed.",
            "Post-write observation is incomplete and the original Skill is no longer reachable.",
            "Safe next step: Keep this evidence read-only and recover navigation from the current Skills list."
        ] {
            XCTAssertTrue(app.staticTexts[evidenceText].waitForExistence(timeout: 2), "Missing negative Task evidence: \(evidenceText)")
        }
        XCTAssertFalse(app.buttons["Retry all"].exists)
        XCTAssertFalse(app.buttons["Repair"].exists)

        let openSkill = app.buttons["View current Skill"]
        XCTAssertTrue(openSkill.exists)
        let sidebar = app.descendants(matching: .any)["phase1-product-sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2))
        openSkill.click()
        XCTAssertTrue(app.descendants(matching: .any)["skill-library-list"].waitForExistence(timeout: 2))
        let status = app.staticTexts["status-banner"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertTrue(
            "\(status.label) \(String(describing: status.value))".contains("original object is no longer available")
        )
        XCTAssertGreaterThanOrEqual(status.frame.minX, sidebar.frame.maxX)
    }

    @MainActor
    func testRelationTaskRetainsEvidenceOffPageAndDeepLinksToCurrentObjects() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture)

        selectNavigation("all-skills", in: app)
        let managedRow = app.descendants(matching: .any)["skill-row-fixture-review-candidate"]
        XCTAssertTrue(managedRow.waitForExistence(timeout: 2))
        managedRow.click()
        let codexAction = app.buttons["relation-action-codex-review-fixture-detail"]
        XCTAssertTrue(codexAction.waitForExistence(timeout: 2))
        codexAction.click()

        // Leave the initiating Skill immediately; the Task must retain its own
        // immutable action evidence while current Agent facts keep evolving.
        selectNavigation("agent-claudeCode", in: app)
        XCTAssertTrue(waitForFile(at: fixture.home.appending(path: ".codex/skills/Review Fixture")))

        selectNavigation("tasks", in: app)
        let relationTask = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Enable Codex for Review Fixture")
        ).firstMatch
        XCTAssertTrue(relationTask.waitForExistence(timeout: 3))
        XCTAssertTrue(relationTask.label.contains("Completed"))
        XCTAssertTrue(relationTask.label.contains("Verified consistent"))
        XCTAssertTrue(relationTask.label.contains("Created link"))
        relationTask.click()

        for evidenceText in [
            "Target: Codex / Review Fixture",
            "Requested: Enabled",
            "Outcome: Succeeded",
            "Current conclusion: Verified consistent",
            "Actual delta",
            "Evidence limitations"
        ] {
            XCTAssertTrue(app.staticTexts[evidenceText].waitForExistence(timeout: 2), "Missing Task evidence: \(evidenceText)")
        }
        XCTAssertFalse(app.buttons["Retry all"].exists)
        XCTAssertFalse(app.buttons["Repair"].exists)

        let openAgent = app.buttons["View current Codex"]
        XCTAssertTrue(openAgent.waitForExistence(timeout: 2))
        XCTAssertTrue(openAgent.isEnabled)
        openAgent.click()
        XCTAssertTrue(app.descendants(matching: .any)["agent-workspace"].waitForExistence(timeout: 2))
        app.staticTexts["Review Fixture"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["relation-detail-codex-review-fixture"].exists)

        selectNavigation("tasks", in: app)
        let retainedTask = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Enable Codex for Review Fixture")
        ).firstMatch
        XCTAssertTrue(retainedTask.waitForExistence(timeout: 2))
        if retainedTask.value as? String != "Expanded" { retainedTask.click() }
        let openSkill = app.buttons["View current Skill"]
        XCTAssertTrue(openSkill.waitForExistence(timeout: 2))
        XCTAssertTrue(openSkill.isEnabled)
        openSkill.click()
        XCTAssertTrue(app.descendants(matching: .any)["skill-detail"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["relation-detail-codex-review-fixture"].exists)
    }

    @MainActor
    func testDualAgentRelationshipsShareCanonicalSkillAndOneCanBeDisabledIndependently() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture)
        let canonicalSkill = fixture.root
            .appending(path: "local/review-fixture", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let codexLink = fixture.home.appending(path: ".codex/skills/Review Fixture")
        let claudeLink = fixture.home.appending(path: ".claude/skills/Review Fixture")

        selectNavigation("all-skills", in: app)
        let managedRow = app.descendants(matching: .any)["skill-row-fixture-review-candidate"]
        XCTAssertTrue(managedRow.waitForExistence(timeout: 2))
        managedRow.click()
        XCTAssertTrue(app.descendants(matching: .any)["skill-detail"].waitForExistence(timeout: 2))

        let codexAction = app.buttons["relation-action-codex-review-fixture-detail"]
        XCTAssertTrue(codexAction.waitForExistence(timeout: 2))
        XCTAssertEqual(codexAction.label, "Enable Codex relationship")
        codexAction.click()
        XCTAssertTrue(waitForFile(at: codexLink))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeLink.path))

        let claudeAction = app.buttons["relation-action-claudeCode-review-fixture-detail"]
        XCTAssertTrue(claudeAction.waitForExistence(timeout: 3))
        XCTAssertEqual(claudeAction.label, "Enable Claude Code relationship")
        claudeAction.click()
        XCTAssertTrue(waitForFile(at: claudeLink))
        XCTAssertEqual(codexLink.resolvingSymlinksInPath().standardizedFileURL.path, canonicalSkill.path)
        XCTAssertEqual(claudeLink.resolvingSymlinksInPath().standardizedFileURL.path, canonicalSkill.path)

        let localEvidence = try String(
            contentsOf: fixture.root.appending(path: ".skillshub.local.json"),
            encoding: .utf8
        )
        XCTAssertTrue(localEvidence.contains("skillshub.agent-profile.codex.global@1"))
        XCTAssertTrue(localEvidence.contains("skillshub.agent-profile.claude-code.global@1"))

        for (destination, relationIdentifier) in [
            ("agent-codex", "relation-detail-codex-review-fixture"),
            ("agent-claudeCode", "relation-detail-claudeCode-review-fixture")
        ] {
            selectNavigation(destination, in: app)
            app.staticTexts["Review Fixture"].firstMatch.click()
            let relation = app.descendants(matching: .any)[relationIdentifier]
            XCTAssertTrue(relation.waitForExistence(timeout: 2))
            XCTAssertTrue(relation.label.contains("relationship for Review Fixture"))
            let agentID = destination.replacingOccurrences(of: "agent-", with: "")
            let verification = app.descendants(matching: .any)[
                "relation-verification-\(agentID)-review-fixture"
            ]
            XCTAssertTrue(verification.waitForExistence(timeout: 2))
            XCTAssertEqual(verification.label, "Verification")
            XCTAssertEqual(verification.value as? String, "Verified consistent")
        }

        selectNavigation("tasks", in: app)
        for title in ["Enable Codex for Review Fixture", "Enable Claude Code for Review Fixture"] {
            let task = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            XCTAssertTrue(task.waitForExistence(timeout: 2), "Missing relation Task: \(title)")
            XCTAssertTrue(task.label.contains("Completed"))
            XCTAssertTrue(task.label.contains("Verified consistent"))
            XCTAssertTrue(task.isEnabled)
        }

        try FileManager.default.removeItem(at: codexLink)
        selectNavigation("agent-codex", in: app)
        let recheck = app.buttons["recheck-agent-directory-codex"]
        XCTAssertTrue(recheck.waitForExistence(timeout: 2))
        recheck.click()

        let disableCodex = app.buttons["relation-action-codex-review-fixture-detail"]
        XCTAssertTrue(disableCodex.waitForExistence(timeout: 2))
        XCTAssertEqual(disableCodex.label, "Disable Codex relationship")
        let reestablishCodex = app.buttons["relation-action-codex-review-fixture-reestablish"]
        XCTAssertTrue(reestablishCodex.waitForExistence(timeout: 2))
        XCTAssertEqual(reestablishCodex.label, "Re-establish Link Codex relationship")
        reestablishCodex.click()
        XCTAssertTrue(waitForFile(at: codexLink))
        let claudeLinkText = try FileManager.default.destinationOfSymbolicLink(atPath: claudeLink.path)
        disableCodex.click()

        XCTAssertTrue(waitForMissingFile(at: codexLink))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeLink.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: claudeLink.path), claudeLinkText)
        XCTAssertEqual(claudeLink.resolvingSymlinksInPath().standardizedFileURL.path, canonicalSkill.path)
        selectNavigation("all-skills", in: app)
        XCTAssertEqual(
            app.buttons["relation-action-claudeCode-review-fixture-detail"].label,
            "Disable Claude Code relationship"
        )
    }

    @MainActor
    func testClearAllManagedLinksPreviewsScopeAndCancelDoesNotWrite() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture: fixture)
        let codexLink = fixture.home.appending(path: ".codex/skills/Review Fixture")
        let claudeLink = fixture.home.appending(path: ".claude/skills/Review Fixture")

        selectNavigation("all-skills", in: app)
        let managedRow = app.descendants(matching: .any)["skill-row-fixture-review-candidate"]
        XCTAssertTrue(managedRow.waitForExistence(timeout: 2))
        managedRow.click()
        let codexAction = app.buttons["relation-action-codex-review-fixture-detail"]
        let claudeAction = app.buttons["relation-action-claudeCode-review-fixture-detail"]
        XCTAssertTrue(codexAction.waitForExistence(timeout: 2))
        codexAction.click()
        XCTAssertTrue(waitForFile(at: codexLink))
        XCTAssertTrue(claudeAction.waitForExistence(timeout: 2))
        claudeAction.click()
        XCTAssertTrue(waitForFile(at: claudeLink))

        let clear = app.buttons["clear-managed-relations"]
        XCTAssertTrue(clear.waitForExistence(timeout: 2))
        let detail = app.descendants(matching: .any)["skill-detail"]
        for _ in 0..<3 where !clear.isHittable {
            detail.swipeUp()
        }
        XCTAssertTrue(clear.isHittable)
        clear.click()
        XCTAssertTrue(app.descendants(matching: .any)["clear-managed-relations-sheet"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["clear-preview-codex"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["clear-preview-claudeCode"].exists)
        app.buttons["cancel-clear-managed-relations"].click()
        XCTAssertTrue(waitForFile(at: codexLink))
        XCTAssertTrue(waitForFile(at: claudeLink))

        clear.click()
        let confirm = app.buttons["confirm-clear-managed-relations"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.click()
        XCTAssertTrue(waitForMissingFile(at: codexLink))
        XCTAssertTrue(waitForMissingFile(at: claudeLink))
        XCTAssertTrue(app.descendants(matching: .any)["clear-result-codex"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["clear-result-claudeCode"].exists)
        app.buttons["done-clear-managed-relations"].click()
        XCTAssertTrue(app.descendants(matching: .any)["skill-detail"].waitForExistence(timeout: 2))
    }

    private func makeFixture() throws -> Phase1UITestFixture {
        let fixture = try Phase1UITestFixture()
        activeFixture = fixture
        return fixture
    }

    @MainActor
    private func assertTaskGroups(_ groups: [String], in app: XCUIApplication) {
        let taskList = app.descendants(matching: .any)["phase1-task-list"]
        for group in groups {
            let heading = app.staticTexts[group]
            if !heading.exists {
                taskList.swipeUp()
            }
            XCTAssertTrue(heading.waitForExistence(timeout: 2), "Missing task group \(group)")
        }
    }

    @MainActor
    private func selectNavigation(_ identifier: String, in app: XCUIApplication) {
        if identifier == "tasks" {
            selectNavigation("settings", in: app)
        }
        let destination = app.descendants(matching: .any)["nav-\(identifier)"]
        app.activate()
        XCTAssertTrue(destination.waitForExistence(timeout: 2))
        let sidebar = app.descendants(matching: .any)["phase1-product-sidebar"]
        for _ in 0..<3 where identifier != "tasks" && !destination.isHittable && sidebar.exists {
            sidebar.swipeDown()
        }
        if identifier == "tasks" {
            let settings = app.descendants(matching: .any)["settings-workspace"]
            for _ in 0..<3 where !settings.frame.insetBy(dx: 0, dy: 8).contains(destination.frame) {
                settings.swipeUp()
            }
            XCTAssertTrue(settings.frame.insetBy(dx: 0, dy: 8).contains(destination.frame))
        }
        XCTAssertTrue(destination.isHittable)
        destination.click()
    }

    @MainActor
    private func launch(
        fixture: Phase1UITestFixture,
        empty: Bool = false,
        language: String = "en",
        windowWidth: Int? = nil,
        additionalArguments: [String] = []
    ) throws -> XCUIApplication {
        let app = XCUIApplication()
        activeApp = app
        app.launchArguments = [
            "-NSTreatUnknownArgumentsAsOpen", "NO",
            "-ApplePersistenceIgnoreState", "YES"
        ]
            + (empty ? fixture.emptyLaunchArguments : fixture.launchArguments)
            + additionalArguments
            + ["--skillshub-ui-fixture-language", language]
        if let windowWidth {
            app.launchArguments += ["--skillshub-ui-fixture-window-width", String(windowWidth)]
        }
        app.launchEnvironment["AppleLanguages"] = "(en)"
        try fixture.publishFixtureBookmark()
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 4))
        if let windowWidth {
            let predicate = NSPredicate { _, _ in
                abs(app.windows.firstMatch.frame.width - CGFloat(windowWidth)) < 2
            }
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 2), .completed, "window frame: \(app.windows.firstMatch.frame)")
        }
        return app
    }

    @MainActor
    private func launchPlatformRootApp(
        fixture: Phase1UITestFixture,
        scenario: String,
        appSupportName: String? = nil,
        expectEmpty: Bool = true,
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        activeApp = app
        let appSupportName = appSupportName ?? "SkillsHubUITests-platform-\(scenario)-\(UUID().uuidString)"
        app.launchArguments = [
            "-NSTreatUnknownArgumentsAsOpen", "NO",
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "--skillshub-home", fixture.home.path,
            "--skillshub-app-support", appSupportName,
            "--skillshub-ui-fixture-language", "en"
        ] + additionalArguments
        app.launchEnvironment["AppleLanguages"] = "(en)"
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 4))
        if expectEmpty {
            XCTAssertTrue(app.buttons["establish-root-primary"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["connect-root-primary"].exists)
        }
        return app
    }

    @MainActor
    private func openEstablishRootPanel(in app: XCUIApplication) {
        app.buttons["establish-root-primary"].click()
        if !app.sheets.firstMatch.waitForExistence(timeout: 3) {
            app.activate()
            app.buttons["establish-root-primary"].click()
        }
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    private func openConnectRootPanel(in app: XCUIApplication) {
        app.buttons["connect-root-primary"].click()
        if !app.sheets.firstMatch.waitForExistence(timeout: 3) {
            app.activate()
            app.buttons["connect-root-primary"].click()
        }
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    private func chooseDirectory(_ directory: URL, in app: XCUIApplication) {
        let openPanel = app.sheets["open-panel"]
        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.sheets.textFields.firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 2))
        paste(directory.path, into: pathField)
        pathField.typeKey(.return, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(pathField.waitForNonExistence(timeout: 3))

        let chooseButton = openPanel.buttons["OKButton"]
        if chooseButton.waitForExistence(timeout: 2) {
            XCTAssertTrue(chooseButton.isEnabled)
            chooseButton.click()
        }
        XCTAssertTrue(openPanel.waitForNonExistence(timeout: 4))
        app.activate()
    }

    @MainActor
    private func paste(_ text: String, into element: XCUIElement) {
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            if let previousItems, previousItems.isEmpty == false {
                pasteboard.writeObjects(previousItems)
            }
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
        element.typeKey("v", modifierFlags: .command)
    }

    @MainActor
    private func waitForConfiguredRoot(
        in app: XCUIApplication,
        expectedCount: Int
    ) -> Bool {
        let libraryLists = app.descendants(matching: .any).matching(
            identifier: "skill-library-list"
        )
        let predicate = NSPredicate { _, _ in
            libraryLists.allElementsBoundByIndex.count >= expectedCount
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 4) == .completed
    }

    private struct TreeEntry: Equatable {
        var path: String
        var kind: String
        var bytes: Data
    }

    private func treeSnapshot(of root: URL) throws -> [TreeEntry] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            return []
        }
        var entries: [TreeEntry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            if values.isDirectory == true {
                entries.append(TreeEntry(path: relativePath, kind: "directory", bytes: Data()))
            } else if values.isSymbolicLink == true {
                let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                entries.append(TreeEntry(path: relativePath, kind: "symlink", bytes: Data(destination.utf8)))
            } else {
                entries.append(TreeEntry(path: relativePath, kind: "file", bytes: try Data(contentsOf: url)))
            }
        }
        return entries.sorted { lhs, rhs in lhs.path < rhs.path }
    }

    private func waitForFile(at url: URL, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

    private func waitForMissingFile(at url: URL, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if FileManager.default.fileExists(atPath: url.path) == false {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

    private func waitForMissingSymbolicLink(at url: URL, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

    private func waitForText(_ expected: String, at url: URL, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    if try String(contentsOf: url, encoding: .utf8).contains(expected) {
                        return true
                    }
                } catch {
                    XCTFail("Unable to inspect \(url.path): \(error)")
                    return false
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

    private func metadataObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }


    private func metadataFieldData(_ key: String, in metadata: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: metadata[key] ?? [], options: [.sortedKeys])
    }

    private func writeObservedSkill(at directory: URL, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("---\nname: \(name)\ndescription: Runtime observation fixture.\n---\nBody.\n".utf8)
            .write(to: directory.appending(path: "SKILL.md"), options: .atomic)
    }

    private func operationIdentity(inJournal url: URL) throws -> String {
        let lines = try Data(contentsOf: url).split(separator: 0x0A)
        for line in lines.reversed() {
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let identity = object["operationID"] as? String,
                  UUID(uuidString: identity) != nil else { continue }
            return identity.uppercased()
        }
        throw Phase1UITestAssertionError.invalidOperationIdentity(url.path)
    }

    @MainActor
    private func operationIdentity(in confirmation: XCUIElement) throws -> String {
        let projection = (confirmation.value as? String) ?? confirmation.label
        let identity = projection
            .components(
                separatedBy: CharacterSet.alphanumerics
                    .union(CharacterSet(charactersIn: "-"))
                    .inverted
            )
            .first { UUID(uuidString: $0) != nil }
        guard let identity else {
            throw Phase1UITestAssertionError.invalidOperationIdentity(projection)
        }
        return identity.uppercased()
    }

    @MainActor
    private func assertTaskResult(
        contains expected: String,
        operationID: String,
        in app: XCUIApplication
    ) {
        let task = app.buttons["phase1-task-\(operationID)"]
        XCTAssertTrue(task.waitForExistence(timeout: 2))
        let projection = task.label
        XCTAssertTrue(
            projection.contains(operationID) && projection.contains(expected),
            "Unexpected task projection: \(projection)"
        )
    }

    private func stagingDirectoryIsEmpty(in fixture: Phase1UITestFixture) -> Bool {
        let staging = fixture.root.appending(path: ".skillshub-staging", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: staging.path) else {
            return true
        }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty
        } catch {
            XCTFail("Unable to inspect operation staging: \(error)")
            return false
        }
    }
}

private enum Phase1UITestAssertionError: Error {
    case invalidOperationIdentity(String)
}
