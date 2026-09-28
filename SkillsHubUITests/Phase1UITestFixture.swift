import AppKit
import Foundation

struct Phase1UITestFixture {
    static let candidateRowIdentifier = "skill-row-fixture-publish-candidate"
    static let sourceRowIdentifier = "source-row-11111111-1111-1111-1111-111111111111"

    let runID: UUID
    let runRoot: URL
    let root: URL
    let source: URL
    let home: URL
    let sourceCandidate: URL
    let managedCandidate: URL
    let metadata: URL
    let journal: URL
    let sourceSkillData: Data
    let interprocessBookmark: String
    let pasteboardName: String
    let fixtureAccessURL: URL?

    init(
        runID: UUID = UUID(),
        fileManager: FileManager = .default
    ) throws {
        let fixtureParents = [
            fileManager.temporaryDirectory
                .appending(path: "SkillsHubUITests/.tmp/phase1-ui-tests", directoryHint: .isDirectory),
            URL(fileURLWithPath: "/private/tmp/SkillsHubUITests/.tmp/phase1-ui-tests", isDirectory: true),
        ].map(\.standardizedFileURL)
        guard let fixtureParent = fixtureParents.first(where: { parent in
            fileManager.fileExists(
                atPath: parent.deletingLastPathComponent().appending(path: "fixture-bridge").path
            )
        }) else {
            throw Phase1UITestFixtureError.missingBridgeDescriptor
        }
        let descriptor = fixtureParent.deletingLastPathComponent()
            .appending(path: "fixture-bridge")
        let descriptorData: Data
        do {
            descriptorData = try Data(contentsOf: descriptor)
        } catch {
            throw Phase1UITestFixtureError.missingBridgeDescriptor
        }
        guard descriptorData.last == 0x0A,
              let descriptorText = String(data: descriptorData.dropLast(), encoding: .utf8) else {
            throw Phase1UITestFixtureError.invalidBridgeDescriptor
        }
        let descriptorLines = descriptorText.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard descriptorLines.count == 2,
              descriptorLines[0].isEmpty == false,
              descriptorLines[1].isEmpty == false else {
            throw Phase1UITestFixtureError.invalidBridgeDescriptor
        }
        let fixtureParentValue = String(descriptorLines[0])
        let interprocessBookmark = String(descriptorLines[1])
        let bridgedFixtureParent = URL(
            fileURLWithPath: fixtureParentValue,
            isDirectory: true
        ).standardizedFileURL
        guard bridgedFixtureParent == fixtureParent else {
            throw Phase1UITestFixtureError.invalidBridgePath(bridgedFixtureParent.path)
        }
        let fixtureAccessURL: URL?
        if fixtureParent == fixtureParents[1] {
            guard let bookmarkData = Data(base64Encoded: interprocessBookmark) else {
                throw Phase1UITestFixtureError.invalidBridgeDescriptor
            }
            var bookmarkIsStale = false
            let authorizedParent = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutImplicitStartAccessing],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            ).standardizedFileURL
            guard authorizedParent == fixtureParent,
                  authorizedParent.startAccessingSecurityScopedResource() else {
                throw Phase1UITestFixtureError.invalidBridgeDescriptor
            }
            fixtureAccessURL = authorizedParent
        } else {
            fixtureAccessURL = nil
        }
        var initializationSucceeded = false
        defer {
            if !initializationSucceeded {
                fixtureAccessURL?.stopAccessingSecurityScopedResource()
            }
        }
        let runRoot = bridgedFixtureParent
            .appending(path: runID.uuidString, directoryHint: .isDirectory)
        let root = runRoot.appending(path: "root", directoryHint: .isDirectory)
        let source = runRoot.appending(path: "source", directoryHint: .isDirectory)
        let home = runRoot.appending(path: "home", directoryHint: .isDirectory)
        let sourceCandidate = source.appending(path: "candidate-fixture", directoryHint: .isDirectory)
        let managedCandidate = root.appending(path: "local/source/candidate-fixture", directoryHint: .isDirectory)
        let sourceSkillData = Data(Self.candidateSkillText.utf8)

        guard !fileManager.fileExists(atPath: runRoot.path) else {
            throw Phase1UITestFixtureError.runAlreadyExists(runRoot.path)
        }

        self.runID = runID
        self.runRoot = runRoot
        self.root = root
        self.source = source
        self.home = home
        self.sourceCandidate = sourceCandidate
        self.managedCandidate = managedCandidate
        self.metadata = root.appending(path: ".skillshub.json")
        self.journal = root.appending(path: ".skillshub.operations.jsonl")
        try fileManager.createDirectory(at: sourceCandidate, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: source.appending(path: "review-fixture", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: root.appending(path: "local/review-fixture", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: root.appending(path: "local/trash-fixture", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: root.appending(path: "github/acme/github-removal-fixture", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: root.appending(
                path: "local/roles-skills/workflows/product-development/platforms/apple/workflow-apple-feature-delivery",
                directoryHint: .isDirectory
            ),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: home.appending(path: ".codex/skills", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: home.appending(path: ".claude/skills", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: home.appending(path: ".codex/skills/agent-owned-review", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: runRoot.appending(path: "project", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        try sourceSkillData.write(to: sourceCandidate.appending(path: "SKILL.md"), options: .atomic)
        try Data(Self.reviewSkillText.utf8).write(
            to: source.appending(path: "review-fixture/SKILL.md"),
            options: .atomic
        )
        try Data(Self.reviewSkillText.utf8).write(
            to: root.appending(path: "local/review-fixture/SKILL.md"),
            options: .atomic
        )
        try Data(Self.trashSkillText.utf8).write(
            to: root.appending(path: "local/trash-fixture/SKILL.md"),
            options: .atomic
        )
        try Data(Self.trashSkillText.utf8).write(
            to: root.appending(path: "github/acme/github-removal-fixture/SKILL.md"),
            options: .atomic
        )
        try Data(Self.rolesSkillText.utf8).write(
            to: root.appending(path: "local/roles-skills/SKILL.md"),
            options: .atomic
        )
        try Data(Self.workflowSkillText.utf8).write(
            to: root.appending(
                path: "local/roles-skills/workflows/product-development/platforms/apple/workflow-apple-feature-delivery/SKILL.md"
            ),
            options: .atomic
        )
        try Data(Self.agentOwnedSkillText.utf8).write(
            to: home.appending(path: ".codex/skills/agent-owned-review/SKILL.md"),
            options: .atomic
        )
        try fileManager.createSymbolicLink(
            atPath: home.appending(path: ".codex/skills/roles-skills").path,
            withDestinationPath: root.appending(path: "local/roles-skills", directoryHint: .isDirectory).path
        )
        try fileManager.createSymbolicLink(
            atPath: home.appending(path: ".codex/skills/codex-review").path,
            withDestinationPath: runRoot.appending(path: "missing-codex-review").path
        )

        self.sourceSkillData = sourceSkillData
        self.interprocessBookmark = interprocessBookmark
        self.pasteboardName = "me.ledar.SkillsHub.phase1-fixture.\(runID.uuidString)"
        self.fixtureAccessURL = fixtureAccessURL
        initializationSucceeded = true
    }

    var launchArguments: [String] {
        var arguments = [
            "--skillshub-ui-fixture",
            "--skillshub-ui-fixture-run-id", runID.uuidString,
            "--skillshub-ui-fixture-run-root", runRoot.path,
            "--skillshub-ui-fixture-root", root.path,
            "--skillshub-ui-fixture-source", source.path,
            "--skillshub-ui-fixture-home", home.path,
            "--skillshub-ui-fixture-pasteboard", pasteboardName
        ]
        return arguments
    }

    var emptyLaunchArguments: [String] {
        var arguments = launchArguments
        arguments[0] = "--skillshub-ui-empty-fixture"
        return arguments
    }

    var expectedLocalSourceImportWritePaths: Set<String> {
        [
            root.appending(path: ".skillshub-operations", directoryHint: .isDirectory).path,
            root.appending(path: "local/source", directoryHint: .isDirectory).path,
            metadata.path,
            journal.path
        ]
    }

    func publishFixtureBookmark() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        pasteboard.clearContents()
        guard pasteboard.setString(interprocessBookmark, forType: .string) else {
            throw Phase1UITestFixtureError.bookmarkPublishFailed
        }
    }

    func cleanup(fileManager: FileManager = .default) throws {
        defer { fixtureAccessURL?.stopAccessingSecurityScopedResource() }
        NSPasteboard(name: NSPasteboard.Name(pasteboardName)).clearContents()
        let fixtureParent = runRoot.deletingLastPathComponent().standardizedFileURL
        guard runRoot.lastPathComponent == runID.uuidString,
              fixtureParent.lastPathComponent == "phase1-ui-tests",
              fixtureParent.deletingLastPathComponent().lastPathComponent == ".tmp" else {
            throw Phase1UITestFixtureError.invalidCleanupTarget(runRoot.path)
        }
        if fileManager.fileExists(atPath: runRoot.path) {
            try fileManager.removeItem(at: runRoot)
        }
    }

    private static let candidateSkillText = """
    ---
    name: Candidate Fixture
    description: A valid local candidate in a fixture source.
    ---
    Body.
    """

    private static let reviewSkillText = """
    ---
    name: Review Fixture
    description: Reviews code changes from a fixture source.
    ---
    Body.
    """

    private static let rolesSkillText = """
    ---
    name: roles-skills
    description: Routes agents to role and workflow skill packs.
    ---
    Body.
    """

    private static let trashSkillText = """
    ---
    name: Trash Fixture
    description: Isolated direct source used only for Trash acceptance.
    ---
    Body.
    """

    private static let workflowSkillText = """
    ---
    name: workflow-apple-feature-delivery
    description: Delivers Apple feature changes.
    ---
    Body.
    """

    private static let agentOwnedSkillText = """
    ---
    name: agent-owned-review
    description: A Codex-owned fixture entry that SkillsHub keeps read-only.
    ---
    Body.
    """
}

enum Phase1UITestFixtureError: Error, Equatable {
    case missingBridgeDescriptor
    case invalidBridgeDescriptor
    case invalidBridgePath(String)
    case runAlreadyExists(String)
    case invalidCleanupTarget(String)
    case bookmarkPublishFailed
}
