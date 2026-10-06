import Foundation
import Testing
@testable import SkillsHub

struct SkillValidationTests {
    @Test func incompleteStaticEnumerationCannotPassValidation() throws {
        let skill = try staticFixture()
        defer { try? FileManager.default.removeItem(at: skill) }
        let denied = skill.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        let result = SkillValidator().validate(skillDirectory: skill)
        #expect(result.status == .invalid)
        #expect(!result.canInstall)
    }

    @Test func staticValidationRejectsSpecialNodes() throws {
        let skill = try staticFixture()
        defer { try? FileManager.default.removeItem(at: skill) }
        let fifo = skill.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(SkillValidator().validate(skillDirectory: skill).status == .invalid)
    }

    @Test func staticValidationRecordsBoundedReadsAndZeroExecutions() throws {
        let skill = try staticFixture()
        defer { try? FileManager.default.removeItem(at: skill.deletingLastPathComponent()) }
        let executionLog = skill.deletingLastPathComponent().appendingPathComponent("executions.txt")
        let script = skill.appendingPathComponent("run.sh")
        try "#!/bin/sh\nprintf 'run\\n' >> '\(executionLog.path)'\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try Data([0, 1, 2, 3]).write(to: skill.appendingPathComponent("payload.bin"))
        try Data(#"{"scripts":{"install":"./run.sh","build":"./run.sh","test":"./run.sh"}}"#.utf8)
            .write(to: skill.appendingPathComponent("package.json"))
        let entry = skill.appendingPathComponent("SKILL.md")
        try (String(contentsOf: entry, encoding: .utf8) + "\n[Outside](../outside.md) [Case](RUN.SH) [Script](run.sh)\n")
            .write(to: entry, atomically: true, encoding: .utf8)
        let live = ManifestReadAccess()
        var reads: [String] = []
        func record(_ kind: String, _ url: URL) {
            #expect(url.path == skill.path || url.path.hasPrefix(skill.path + "/"))
            reads.append("\(kind) \(url.path)")
        }
        let access = ManifestReadAccess(
            contentsOfDirectory: { url in record("enumerate", url); return try live.contentsOfDirectory(at: url) },
            resourceValues: { url, keys in record("attributes", url); return try live.resourceValues(at: url, forKeys: keys) },
            dataContents: { url in record("bytes", url); return try live.data(at: url) },
            symlinkDestination: { url in record("readlink", url); return try live.destinationOfSymbolicLink(at: url) }
        )
        let result = SkillValidator(readAccess: access).validate(skillDirectory: skill)
        #expect(result.status == .warning)
        #expect(result.risks.contains { $0.kind == .script })
        #expect(result.risks.contains { $0.kind == .executable && $0.path == "payload.bin" })
        #expect(result.messages.contains { $0.id == "missing-reference-RUN.SH" })
        #expect(!result.messages.contains { $0.id == "missing-reference-run.sh" })
        let executions = (try? String(contentsOf: executionLog, encoding: .utf8)) ?? ""
        #expect(executions.isEmpty)
        Attachment.record(Data(("execution-count=\(executions.split(separator: "\n").count)\n" + reads.joined(separator: "\n")).utf8), named: "static-read-set-and-executions.txt")
    }

    @Test(arguments: [false, true])
    func internalSkillEntrySymlinkRemainsValidAndBindsContent(repeatedAlias: Bool) throws {
        let skill = try staticFixture()
        defer { try? FileManager.default.removeItem(at: skill) }
        let original = skill.appendingPathComponent("entry.md")
        try FileManager.default.moveItem(at: skill.appendingPathComponent("SKILL.md"), to: original)
        if repeatedAlias {
            try FileManager.default.createSymbolicLink(atPath: skill.appendingPathComponent("alias").path, withDestinationPath: ".")
        }
        try FileManager.default.createSymbolicLink(atPath: skill.appendingPathComponent("SKILL.md").path, withDestinationPath: repeatedAlias ? "alias/alias/entry.md" : "entry.md")
        #expect(SkillValidator().validate(skillDirectory: skill).status == .valid)
        let manifest = try ContentManifestBuilder().build(for: skill, authorizedRoot: skill)
        let changed = try String(contentsOf: original, encoding: .utf8) + "Changed"
        let result = SkillValidator().validate(contents: changed, manifest: manifest, skillDirectory: skill)
        #expect(result.messages.contains { $0.id == "content-changed" })
    }

    private func staticFixture() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".tmp/static-validation-tests/\(UUID().uuidString)/review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\nname: Review\ndescription: Reviews static content safely.\n---\nBody\n"
            .write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return directory
    }

    @Test func validSkillPassesValidation() throws {
        let skill = try makeSkillDirectory(name: "code-review", skillText: """
        ---
        name: Code Review
        description: Reviews source code for regressions.
        ---
        Use this skill for code review.
        """)

        let result = SkillValidator().validate(skillDirectory: skill)

        #expect(result.status == .valid)
        #expect(result.canInstall)
        #expect(result.canLink)
    }

    @Test func invalidSkillRequiresSkillFileAndFrontmatterFields() throws {
        let missing = try temporaryDirectory()
        #expect(SkillValidator().validate(skillDirectory: missing).status == .invalid)

        let nameless = try makeSkillDirectory(name: "bad", skillText: """
        ---
        description: Missing name.
        ---
        Body
        """)
        let result = SkillValidator().validate(skillDirectory: nameless)
        #expect(result.status == .invalid)
        #expect(result.messages.contains(where: { $0.id == "frontmatter-format" }))
    }

    @Test(arguments: [
        "name: 42\ndescription: Valid description.",
        "name: true\ndescription: Valid description.",
        "name: null\ndescription: Valid description.",
        "name: [Review]\ndescription: Valid description.",
        "name: {value: Review}\ndescription: Valid description.",
        "name: Review\ndescription: 42",
        "name: Review\ndescription: false",
        "name: Review\ndescription: null",
        "name: Review\ndescription: [Text]",
        "name: Review\ndescription: {value: Text}"
    ])
    func frontmatterRequiredFieldsRejectNonStringYAMLNodes(_ yaml: String) throws {
        let skill = try makeSkillDirectory(name: "typed", skillText: "---\n\(yaml)\n---\nBody")

        let result = SkillValidator().validate(skillDirectory: skill)

        #expect(result.status == .invalid)
        #expect(result.messages.map(\.id) == ["frontmatter-format"])
    }

    @Test func frontmatterRequiresNonemptyStringsInATopLevelMapping() throws {
        let invalidDocuments = [
            "name: ''\ndescription: Text",
            "name: '   '\ndescription: Text",
            "name: Review\ndescription: ''",
            "name: Review\ndescription: '   '",
            "- name: Review\n  description: Text",
            "Review",
            "null"
        ]

        for (index, yaml) in invalidDocuments.enumerated() {
            let skill = try makeSkillDirectory(name: "shape-\(index)", skillText: "---\n\(yaml)\n---\nBody")
            #expect(SkillValidator().validate(skillDirectory: skill).messages.map(\.id) == ["frontmatter-format"])
        }
    }

    @Test func frontmatterSeparatesSyntaxFormatAndBudgetErrors() throws {
        let syntax = try makeSkillDirectory(name: "syntax", skillText: "---\nname: [broken\ndescription: Text\n---")
        let duplicate = try makeSkillDirectory(name: "duplicate", skillText: "---\nname: First\nname: Second\ndescription: Text\n---")
        let oversized = try makeSkillDirectory(name: "oversized", skillText: "---\nname: Review\ndescription: \(String(repeating: "x", count: 65 * 1024))\n---")

        #expect(SkillValidator().validate(skillDirectory: syntax).messages.map(\.id) == ["frontmatter-syntax"])
        #expect(SkillValidator().validate(skillDirectory: duplicate).messages.map(\.id) == ["frontmatter-format"])
        #expect(SkillValidator().validate(skillDirectory: oversized).messages.map(\.id) == ["frontmatter-budget"])
        #expect(SkillValidationResult.invalidFrontmatter(.parserCapabilityExceeded).messages.map(\.id) == ["frontmatter-capability"])
    }

    @Test func frontmatterBudgetsBoundDepthNodesAndAliases() throws {
        let oversizedMalformed = "---\n[\(String(repeating: "x", count: 65 * 1024))\n---"
        #expect(throws: SkillFrontmatterError.inputBudgetExceeded) {
            _ = try SkillFrontmatterParser().parse(oversizedMalformed)
        }

        var depthBudget = SkillFrontmatterBudget()
        depthBudget.maxDepth = 2
        let deepParser = SkillFrontmatterParser(budget: depthBudget)
        #expect(throws: SkillFrontmatterError.depthBudgetExceeded) {
            _ = try deepParser.parse("---\nname: Review\ndescription: Text\nextension:\n  nested: true\n---")
        }

        var nodeBudget = SkillFrontmatterBudget()
        nodeBudget.maxNodes = 4
        let smallParser = SkillFrontmatterParser(budget: nodeBudget)
        #expect(throws: SkillFrontmatterError.nodeBudgetExceeded) {
            _ = try smallParser.parse("---\nname: Review\ndescription: Text\n---")
        }

        var aliasBudget = SkillFrontmatterBudget()
        aliasBudget.maxAliases = 1
        let aliasParser = SkillFrontmatterParser(budget: aliasBudget)
        #expect(throws: SkillFrontmatterError.aliasBudgetExceeded) {
            _ = try aliasParser.parse("---\nname: Review\ndescription: Text\nextension: &shared {enabled: true}\nfirst: *shared\nsecond: *shared\n---")
        }

        #expect(throws: SkillFrontmatterError.invalidSyntax) {
            _ = try SkillFrontmatterParser().parse("---\nname: Review\ndescription: Text\nextension: &loop [*loop]\n---")
        }
    }

    @Test func warningsCoverMetadataReferencesScriptsExecutablesAndLargeAssets() throws {
        let skill = try makeSkillDirectory(name: "review", skillText: """
        ---
        name: Review
        description: Short
        ---
        See [missing](missing.md), [outside](../shared.md), and [site](https://example.com).
        """)
        let scripts = skill.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let executable = skill.appendingPathComponent("run.sh")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let largeAsset = skill.appendingPathComponent("large.bin")
        try Data(repeating: 0, count: 32).write(to: largeAsset)

        var validator = SkillValidator()
        validator.largeAssetThreshold = 8
        let result = validator.validate(skillDirectory: skill, sourceMetadataPresent: false)

        #expect(result.status == .warning)
        #expect(result.messages.contains(where: { $0.id == "description-length" }))
        #expect(result.messages.contains(where: { $0.id == "missing-source-metadata" }))
        #expect(result.messages.contains(where: { $0.id.hasPrefix("missing-reference") }))
        #expect(result.risks.contains(where: { $0.kind == .script }))
        #expect(result.risks.contains(where: { $0.kind == .executable }))
        #expect(result.risks.contains(where: { $0.kind == .externalURL }))
        #expect(result.risks.contains(where: { $0.kind == .largeAsset }))
        #expect(result.risks.contains(where: { $0.kind == .crossDirectoryReference }))
    }

    @Test func duplicateNormalizedSkillIDIsInvalid() throws {
        let skill = try makeSkillDirectory(name: "Code Review", skillText: """
        ---
        name: Code Review
        description: Reviews source code for regressions.
        ---
        Body
        """)

        let result = SkillValidator().validate(skillDirectory: skill, knownSkillIDs: ["code-review"])

        #expect(result.status == .invalid)
        #expect(result.messages.contains(where: { $0.id == "skill-id-conflict" }))
    }

    @Test func brokenSymlinkSkillIsInvalidWithoutCrashing() throws {
        let root = try temporaryDirectory()
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        let broken = skillsRoot.appendingPathComponent("broken-link")
        try FileManager.default.createSymbolicLink(atPath: broken.path, withDestinationPath: root.appendingPathComponent("missing-skill").path)

        let result = SkillValidator().validate(skillDirectory: broken, rootDirectory: root)

        #expect(result.status == .invalid)
        #expect(result.messages.contains(where: { $0.id.hasPrefix("broken-symlink") }))
    }

    @Test func externalLinkedSkillIsBlockedWithoutReadingTarget() throws {
        let root = try temporaryDirectory()
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        let outside = try makeSkillDirectory(name: "external", skillText: """
        ---
        name: External
        description: Keeps an explicitly linked local skill visible.
        ---
        Body.
        """)
        let linked = skillsRoot.appendingPathComponent("external")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)

        var contentReads: [URL] = []
        let access = ManifestReadAccess(dataContents: { url in
            contentReads.append(url)
            return try Data(contentsOf: url)
        })
        let result = SkillValidator(readAccess: access).validate(skillDirectory: linked, rootDirectory: root)

        #expect(result.status == .invalid)
        #expect(!result.canInstall)
        #expect(contentReads.isEmpty)
        #expect(result.risks.contains(where: { $0.kind == .symlink && $0.id.hasPrefix("symlink-escape") }))
    }

    @Test func internalSymlinkEscapeIsInvalidAndDoesNotHideReferencedRisks() throws {
        let root = try temporaryDirectory()
        let skill = root.appendingPathComponent("skills/review", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try """
        ---
        name: Review
        description: Reviews symlink escape behavior.
        ---
        See [external](outside-link.md).
        """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let outside = try temporaryDirectory().appendingPathComponent("outside-link.md")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: skill.appendingPathComponent("outside-link.md"), withDestinationURL: outside)

        let result = SkillValidator().validate(skillDirectory: skill, rootDirectory: root)

        #expect(result.status == .invalid)
        #expect(result.messages.contains(where: { $0.id.hasPrefix("symlink-escape") }))
        #expect(result.risks.contains(where: { $0.kind == .symlink }))
    }

    @Test func symlinkCycleIsInvalidWithoutInfiniteRecursion() throws {
        let root = try temporaryDirectory()
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        let first = skillsRoot.appendingPathComponent("cycle-a")
        let second = skillsRoot.appendingPathComponent("cycle-b")
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: second)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: first)

        let result = SkillValidator().validate(skillDirectory: first, rootDirectory: root)

        #expect(result.status == .invalid)
        #expect(result.messages.contains(where: { $0.id.hasPrefix("symlink-cycle") }))
    }

    @Test func frontmatterParserAcceptsCommentsQuotesAndBlockDescription() throws {
        let skill = try makeSkillDirectory(name: "quoted", skillText: """
        ---
        # comment
        name: "Quoted: Skill"
        description: >
          Reviews source code
          for regressions.
        ---
        Body
        """)

        let result = SkillValidator().validate(skillDirectory: skill)

        #expect(result.status == .warning)
        #expect(result.messages.contains(where: { $0.id == "name-directory-mismatch" }))
        #expect(!result.messages.contains(where: { $0.id.hasPrefix("frontmatter-") }))
    }

    @Test func frontmatterParserAcceptsNestedExtensionsAndSingleDocumentOnly() throws {
        let valid = try makeSkillDirectory(name: "nested", skillText: """
        ---
        name: Nested
        description: |
          Reviews nested YAML
          without flattening values.
        metadata:
          tags: [swift, review]
          options:
            enabled: true
        ---
        Body
        """)
        let multiple = try makeSkillDirectory(name: "multiple", skillText: """
        ---
        name: First
        description: First document.
        ...
        name: Second
        description: Second document.
        ---
        """)

        #expect(SkillValidator().validate(skillDirectory: valid).status == .valid)
        #expect(SkillValidator().validate(skillDirectory: multiple).messages.map(\.id) == ["frontmatter-syntax"])
    }

}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
func connectInitializedTestRoot(
    _ controller: SkillsHubLibraryController,
    at root: URL
) async throws {
    let normalizedRoot = root.standardizedFileURL
    let store = SkillsHubMetadataStore()
    let metadataFile = store.rootLayout(for: normalizedRoot).skillshubMetadataFile
    if FileManager.default.fileExists(atPath: metadataFile.path) == false {
        try store.save(
            SkillsHubMetadata(rootConfig: RootConfig(rootPath: normalizedRoot.path)),
            to: normalizedRoot
        )
    }
    try await controller.connectExistingRoot(normalizedRoot)
    await controller.waitForPendingRechecks()
    await controller.waitForPresentationObservation()
}

func makeSkillDirectory(name: String, skillText: String) throws -> URL {
    let directory = try temporaryDirectory().appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try skillText.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    return directory
}
