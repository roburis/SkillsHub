import Foundation
import Testing
@testable import SkillsHub

@MainActor
struct AgentDirectoryAuditTests {
    @Test func installationResolutionChecksLinksBeforeParentComponents() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".tmp/agent-installation-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("good")
        try Data("controlled sample".utf8).write(to: file)
        let entry = root.appendingPathComponent("bin/agent")
        let candidate = AgentInstallationDetector.Candidate(entry: entry, root: root)
        try fm.createSymbolicLink(atPath: entry.path, withDestinationPath: "../good")
        #expect(try AgentInstallationDetector.resolve(candidate) == file)
        try fm.removeItem(at: entry)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("bridge").path, withDestinationPath: "/outside/nested")
        try fm.createSymbolicLink(atPath: entry.path, withDestinationPath: "../bridge/../good")
        #expect(throws: (any Error).self) { try AgentInstallationDetector.resolve(candidate) }
    }

    @Test(arguments: ["absent", "directory", "script", "wrongPublisher", "broken", "cycle", "escape", "unreadable"])
    func staticInstallationRejectsUnsupportedArtifacts(_ sample: String) throws {
        // Use a project-local path: macOS's /var test-temp alias is itself a
        // symlink, which correctly fails the detector's installation-root guard.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".tmp/agent-installation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = root.appendingPathComponent("codex")
        switch sample {
        case "unreadable":
            try Data("controlled unreadable sample".utf8).write(to: entry)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: entry.path)
            #expect(FileManager.default.isReadableFile(atPath: entry.path) == false)
        case "directory":
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        case "script":
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: entry)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        case "wrongPublisher":
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: entry)
        case "broken":
            try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: root.appendingPathComponent("missing"))
        case "cycle":
            try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: entry)
        case "escape":
            try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        default: break
        }
        let detector = AgentInstallationDetector(candidates: { _, _ in [.init(entry: entry, root: root)] }, desktopCandidates: { _, _ in [] })
        #expect(detector.detect(agent: .codex, home: root) == (sample == "absent" ? .absent : .unverifiable))
        if sample == "unreadable" {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: entry.path)
            #expect(FileManager.default.isReadableFile(atPath: entry.path))
        }
    }

    @Test(arguments: ["absent", "cli", "desktop", "both", "unknown"])
    func installationClassifiesBoundedSignedChannels(_ sample: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".tmp/agent-classification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("codex")
        let app = root.appendingPathComponent("Codex.app", isDirectory: true)
        if sample == "cli" || sample == "both" || sample == "unknown" {
            try Data("fixture".utf8).write(to: cli)
        }
        if sample == "desktop" || sample == "both" {
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        }
        let detector = AgentInstallationDetector(
            candidates: { _, _ in [.init(entry: cli, root: root)] },
            desktopCandidates: { _, _ in [app] },
            verifyCLI: { _, _ in
                if sample == "unknown" { throw CocoaError(.fileReadNoPermission) }
                return ["verified-cli"]
            },
            verifyDesktop: { _, _ in ["verified-desktop"] }
        )
        let expected: AgentInstallationCategory = switch sample {
        case "cli": .cli
        case "desktop": .desktop
        case "both": .both
        case "unknown": .unverifiable
        default: .absent
        }
        #expect(detector.detect(agent: .codex, home: root).category == expected)
    }

    @Test func unsignedDesktopBundleCannotBecomeInstallationEvidence() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".tmp/agent-unsigned-desktop-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Codex.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = AgentInstallationDetector(candidates: { _, _ in [] }, desktopCandidates: { _, _ in [app] })
        #expect(detector.detect(agent: .codex, home: root) == .unverifiable)
    }

    @Test(arguments: [AgentInstallationCategory.absent, .unverifiable, .cli, .desktop, .both])
    func builtInSidebarAdmissionKeepsConfiguration(_ category: AgentInstallationCategory) {
        let detection = AgentDetectionSnapshot(
            agentID: AgentKind.codex.rawValue, agent: .codex, displayName: "Codex",
            markerPath: "/fixture/.codex", skillsDirectory: "/fixture/.codex/skills",
            detected: [.cli, .desktop, .both].contains(category), skillsDirectoryExists: true,
            entryCount: 0, readable: true, writable: true, isCustom: false,
            installationCategory: category
        )
        let descriptors = InstalledAgentDescriptorBuilder().build(
            detections: [detection], configurations: AgentConfigurationRecord.phase1BuiltIns,
            links: []
        ).descriptors
        let codex = descriptors.first { $0.id == AgentKind.codex.rawValue }
        #expect(descriptors.count == 2)
        #expect(codex?.isVisibleOnCards == true)
        #expect(codex?.isVisibleInSidebar == [.cli, .desktop, .both].contains(category))
        #expect(descriptors.first { $0.id == AgentKind.claudeCode.rawValue }?.isVisibleInSidebar == false)
    }

    @Test(arguments: [AgentKind.codex, .claudeCode])
    func skillsDirectoryAloneDoesNotProveInstallation(_ agent: AgentKind) throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let target = AgentPathResolver().globalSkillsDirectory(for: agent, environment: [:], homeDirectory: home)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let result = AgentDirectoryAuditService(installationPresence: { _, _ in .absent }).lightScan(
            rootURL: root, homeDirectory: home, overrides: [:], localState: SkillsHubLocalState()
        )
        let detection = try #require(result.detections.first { $0.agent == agent })
        #expect(detection.skillsDirectoryExists)
        #expect(detection.detected == false)
        #expect(detection.installationCategory == .absent)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func builtInAgentDetectionUsesFakeHomeAndDoesNotCreateMissingSkillsDirectories() throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".random-agent/skills"), withIntermediateDirectories: true)

        let service = AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation)
        let result = service.lightScan(rootURL: root, homeDirectory: home, overrides: [:], localState: SkillsHubLocalState())

        let codex = try #require(result.detections.first { $0.agent == .codex })
        #expect(codex.detected)
        #expect(!codex.skillsDirectoryExists)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/skills").path))
        #expect(result.findings.first?.type == .missingSkillsDirectory)

        let cursor = try #require(result.detections.first { $0.agent == .cursor })
        #expect(!cursor.detected)
        #expect(!result.findings.contains { $0.agent == .cursor })
        #expect(!result.detections.contains { $0.agentID == "random-agent" || $0.displayName == "Random Agent" })
    }

    @Test func lightScanCreatesPendingAuditWithoutReadingSkillFiles() throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let codexSkills = home.appendingPathComponent(".codex/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: codexSkills.appendingPathComponent("review", isDirectory: true), withIntermediateDirectories: true)
        try localSkillText(name: "Review", description: "Reviews code safely.").write(
            to: codexSkills.appendingPathComponent("review/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let result = AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation).lightScan(rootURL: root, homeDirectory: home, overrides: [:], localState: SkillsHubLocalState())

        let finding = try #require(result.findings.first { $0.type == .pendingAudit })
        #expect(finding.agent == .codex)
        #expect(finding.skillFileHash == nil)
        #expect(!finding.evidence.contains { $0.contains("SKILL.md hash") })
    }

    @Test func lightScanSurfacesPermissionDeniedBeforePendingAudit() throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let codexSkills = home.appendingPathComponent(".codex/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: codexSkills.appendingPathComponent("review", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: codexSkills.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexSkills.path)
        }

        let result = AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation).lightScan(rootURL: root, homeDirectory: home, overrides: [:], localState: SkillsHubLocalState())

        let finding = try #require(result.findings.first { $0.type == .permissionDenied })
        #expect(finding.agent == .codex)
        #expect(finding.recommendedAction == .viewPermissionGuidance)
        #expect(finding.evidence.contains { $0.contains("Readable: false") || $0.contains("Writable: false") })
        #expect(!result.findings.contains { $0.type == .pendingAudit && $0.agent == .codex })
    }

    @Test func fullAuditClassifiesFirstLevelEntriesAndSortsSeverity() throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let codexSkills = home.appendingPathComponent(".codex/skills", isDirectory: true)
        let local = codexSkills.appendingPathComponent("local-skill", isDirectory: true)
        let noSkill = codexSkills.appendingPathComponent("local-no-skill-md", isDirectory: true)
        let externalRoot = try temporaryDirectory().appendingPathComponent("external-skill", isDirectory: true)
        let externalLink = codexSkills.appendingPathComponent("external-link")
        let brokenLink = codexSkills.appendingPathComponent("broken-link")
        let hidden = codexSkills.appendingPathComponent(".hidden-entry", isDirectory: true)
        let invalid = codexSkills.appendingPathComponent("invalid.txt")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: noSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: invalid)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        try localSkillText(name: "Local Skill", description: "Local agent skill.").write(to: local.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try localSkillText(name: "External Skill", description: "External agent skill.").write(to: externalRoot.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: externalLink, withDestinationURL: externalRoot)
        try FileManager.default.createSymbolicLink(atPath: brokenLink.path, withDestinationPath: "/missing/path")

        let installed = InstalledSkill(
            id: "local-skill",
            sourceID: nil,
            name: "Local Skill",
            description: "Local agent skill.",
            installedPath: root.appendingPathComponent("local-skill", isDirectory: true).path,
            sourceKind: .manualFilesystem,
            validation: .valid,
            purpose: nil,
            tagIDs: [],
            installedAt: Date()
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("local-skill", isDirectory: true), withIntermediateDirectories: true)
        try localSkillText(name: "Local Skill", description: "Local agent skill.").write(to: root.appendingPathComponent("local-skill/SKILL.md"), atomically: true, encoding: .utf8)

        let result = try AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation).fullAudit(
            agentID: AgentKind.codex.rawValue,
            rootURL: root,
            homeDirectory: home,
            overrides: [:],
            localState: SkillsHubLocalState(),
            installedSkills: [installed]
        )

        #expect(result.findings.contains { $0.type == .duplicateWithHub && $0.entryName == "local-skill" })
        #expect(!result.findings.contains { $0.entryName == "local-no-skill-md" || $0.entryName == ".hidden-entry" })
        #expect(result.findings.contains { $0.type == .externalSymlinkNotManaged && $0.entryName == "external-link" })
        let actualNames = Set(try FileManager.default.contentsOfDirectory(atPath: codexSkills.path))
        #expect(Set(result.findings.map(\.entryName)) == actualNames.subtracting(["local-no-skill-md", ".hidden-entry"]))
        let broken = try #require(result.findings.first { $0.type == .brokenSymlink && $0.entryName == "broken-link" })
        #expect(broken.symlinkTarget == "/missing/path")
        #expect(broken.targetPath == "/missing/path")
        #expect(result.findings.map(\.severity.sortRank) == result.findings.map(\.severity.sortRank).sorted())
    }

    @Test func fullAuditDoesNotTreatEnumerationFailureAsEmptyDirectory() throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let target = home.appendingPathComponent(".codex/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let service = AgentDirectoryAuditService(fileManager: FailingAgentDirectoryFileManager(target: target), installationPresence: fixtureAgentInstallation)
        let light = service.lightScan(rootURL: root, homeDirectory: home, overrides: [:], localState: SkillsHubLocalState())
        #expect(light.detections.first { $0.agent == .codex }?.entryCount == 0)
        #expect(light.detections.first { $0.agent == .codex }?.readable == false)
        #expect(light.findings.contains { $0.agent == .codex && $0.type == .directoryEnumerationFailed })
        #expect(throws: (any Error).self) {
            try service.fullAudit(agentID: AgentKind.codex.rawValue, rootURL: root, homeDirectory: home, overrides: [:], localState: SkillsHubLocalState(), installedSkills: [])
        }
        try FileManager.default.removeItem(at: target)
        #expect(throws: AgentTargetAccessError.qualificationFailed(.targetMissing)) {
            try AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation).fullAudit(
                agentID: AgentKind.codex.rawValue, rootURL: root, homeDirectory: home,
                overrides: [:], localState: SkillsHubLocalState(), installedSkills: []
            )
        }
    }

    @Test func fullAuditIncludesAgentsSkillsBrokenSymlinks() throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let agentsSkills = home.appendingPathComponent(".agents/skills", isDirectory: true)
        let brokenLink = agentsSkills.appendingPathComponent("stale-agent-skill")
        try FileManager.default.createDirectory(at: agentsSkills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: brokenLink.path, withDestinationPath: "/missing/stale-agent-skill")

        let result = try AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation).fullAudit(
            agentID: nil,
            rootURL: root,
            homeDirectory: home,
            overrides: [:],
            localState: SkillsHubLocalState(),
            installedSkills: []
        )

        let finding = try #require(result.findings.first { $0.agentID == "agents" && $0.entryName == "stale-agent-skill" })
        #expect(finding.agent == nil)
        #expect(finding.agentDisplayName == "Agents")
        #expect(finding.type == .brokenSymlink)
        #expect(finding.entryKind == .brokenSymlink)
        #expect(finding.symlinkTarget == "/missing/stale-agent-skill")
        #expect(finding.targetPath == "/missing/stale-agent-skill")
        #expect(finding.recommendedAction == .deleteBrokenLink)
    }

    @Test func linkIntoManagedRootWithoutCreationEvidenceRemainsExternal() throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let codexSkills = home.appendingPathComponent(".codex/skills", isDirectory: true)
        let managed = root.appendingPathComponent("local/review", isDirectory: true)
        let link = codexSkills.appendingPathComponent("review")
        try FileManager.default.createDirectory(at: codexSkills, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try localSkillText(name: "Review", description: "Reviews code safely.")
            .write(to: managed.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: managed)

        let result = try AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation).fullAudit(
            agentID: AgentKind.codex.rawValue,
            rootURL: root,
            homeDirectory: home,
            overrides: [:],
            localState: SkillsHubLocalState(),
            installedSkills: [installedSkill(id: "review", name: "Review", path: managed)]
        )

        let finding = try #require(result.findings.first { $0.entryName == "review" })
        #expect(finding.type == .externalSymlinkNotManaged)
        #expect(finding.entryKind == .externalSymlink)
        #expect(finding.skillFileHash != nil)
        #expect(finding.evidence.contains { $0.contains("SKILL.md hash") })
    }

    @Test(arguments: [".system", "nested", "case-entry", "external-empty", "invalid", "unreadable", "entry-inside", "entry-escape", "external-file", "managed-missing"])
    func directEntryIdentityPreservesProblemsAndLeavesNodesUnchanged(_ sample: String) throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: root)
        }
        let target = home.appendingPathComponent(".codex/skills", isDirectory: true)
        let directory = root.appendingPathComponent("sample", isDirectory: true)
        let entry = target.appendingPathComponent(sample)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = Data(localSkillText(name: "Sample", description: "Direct entry.").utf8)
        let file = directory.appendingPathComponent("SKILL.md")
        var state = SkillsHubLocalState()
        if sample == "external-file" {
            try bytes.write(to: file)
            try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: file)
        } else if sample == "external-empty" {
            try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: directory)
        } else {
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
            let skillFile = entry.appendingPathComponent("SKILL.md")
            if sample == "nested" {
                try FileManager.default.createDirectory(at: entry.appendingPathComponent("child"), withIntermediateDirectories: true)
                try bytes.write(to: entry.appendingPathComponent("child/SKILL.md"))
            } else if sample == "invalid" {
                try Data("invalid frontmatter".utf8).write(to: skillFile)
            } else if sample == "case-entry" {
                try bytes.write(to: entry.appendingPathComponent("skill.md"))
            } else if sample == "entry-inside" {
                try bytes.write(to: entry.appendingPathComponent("entry.md"))
                try FileManager.default.createSymbolicLink(atPath: skillFile.path, withDestinationPath: "entry.md")
            } else if sample == "unreadable" {
                try bytes.write(to: skillFile)
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: skillFile.path)
            } else if sample == "entry-escape" {
                try bytes.write(to: file)
                try FileManager.default.createSymbolicLink(at: skillFile, withDestinationURL: file)
            } else if sample == "managed-missing" {
                state.activeAgentLinks = [AgentManagedLinkRecord(agentID: "codex", agent: .codex, alias: sample,
                    linkPath: entry.path, targetPath: directory.path, hubSkillID: sample,
                    hubRelativePath: "sample", rootAtCreation: root.path)]
            }
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: entry.appendingPathComponent("SKILL.md").path) }
        let before = try FileManager.default.contentsOfDirectory(atPath: target.path)
        let result = try AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation).fullAudit(
            agentID: "codex", rootURL: root, homeDirectory: home, overrides: [:], localState: state, installedSkills: [])
        if [".system", "nested", "case-entry", "external-empty"].contains(sample) {
            #expect(result.findings.isEmpty)
        } else if sample == "entry-inside" {
            #expect(result.findings.first?.type == .localDirectoryNotManaged)
        } else {
            #expect(result.findings.contains { $0.entryName == sample && $0.type == .invalidEntry })
            #expect(!result.findings.contains { $0.type == .localDirectoryNotManaged || $0.type == .externalSymlinkNotManaged })
            if sample == "unreadable" {
                #expect(!result.findings.flatMap(\.evidence).contains("Missing SKILL.md"))
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == before)
        if sample == "entry-escape" || sample == "external-file" {
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func sameDisplayNameHubSkillsRemainDistinctCandidates() throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let codexSkills = home.appendingPathComponent(".codex/skills", isDirectory: true)
        let local = codexSkills.appendingPathComponent("shared-review", isDirectory: true)
        let firstHub = root.appendingPathComponent("local/shared-review-a", isDirectory: true)
        let secondHub = root.appendingPathComponent("local/shared-review-b", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: firstHub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondHub, withIntermediateDirectories: true)
        try localSkillText(name: "Shared Review", description: "Local agent skill.")
            .write(to: local.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let result = try AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation).fullAudit(
            agentID: AgentKind.codex.rawValue,
            rootURL: root,
            homeDirectory: home,
            overrides: [:],
            localState: SkillsHubLocalState(),
            installedSkills: [
                installedSkill(id: "shared-review-a", name: "Shared Review", path: firstHub),
                installedSkill(id: "shared-review-b", name: "Shared Review", path: secondHub)
            ]
        )

        let finding = try #require(result.findings.first { $0.type == .duplicateWithHub && $0.entryName == "shared-review" })
        #expect(Set(finding.matchCandidates.map(\.hubSkillID)) == ["shared-review-a", "shared-review-b"])
        #expect(Set(finding.matchCandidates.map(\.hubRelativePath)) == ["local/shared-review-a", "local/shared-review-b"])
    }

    @Test func ignoredFindingExpiresWhenFingerprintChanges() throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let codexSkills = home.appendingPathComponent(".codex/skills", isDirectory: true)
        let local = codexSkills.appendingPathComponent("review", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try localSkillText(name: "Review", description: "Reviews code safely.").write(to: local.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let service = AgentDirectoryAuditService(installationPresence: fixtureAgentInstallation)
        let first = try service.fullAudit(agentID: AgentKind.codex.rawValue, rootURL: root, homeDirectory: home, overrides: [:], localState: SkillsHubLocalState(), installedSkills: [])
        let ignoredID = try #require(first.findings.first?.id)
        try localSkillText(name: "Review Changed", description: "Reviews code safely.").write(to: local.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let second = try service.fullAudit(
            agentID: AgentKind.codex.rawValue,
            rootURL: root,
            homeDirectory: home,
            overrides: [:],
            localState: SkillsHubLocalState(ignoredFindingFingerprints: [ignoredID]),
            installedSkills: []
        )

        #expect(second.findings.first?.id != ignoredID)
        #expect(second.findings.first?.ignored == false)
    }

    @Test func installedAgentDescriptorsMergeDetectedAgentsCapabilitiesAndOrphans() throws {
        let detections = [
            AgentDetectionSnapshot(
                agentID: AgentKind.codex.rawValue,
                agent: .codex,
                displayName: "Codex",
                markerPath: "/tmp/codex",
                skillsDirectory: "/tmp/codex/skills",
                detected: true,
                skillsDirectoryExists: true,
                entryCount: 0,
                readable: true,
                writable: true,
                isCustom: false
            ),
            AgentDetectionSnapshot(
                agentID: "custom-valid",
                agent: nil,
                displayName: "Custom Valid",
                markerPath: "/tmp/custom",
                skillsDirectory: "/tmp/custom/skills",
                detected: true,
                skillsDirectoryExists: true,
                entryCount: 0,
                readable: true,
                writable: true,
                isCustom: true
            ),
            AgentDetectionSnapshot(
                agentID: "custom-invalid",
                agent: nil,
                displayName: "Custom Invalid",
                markerPath: "relative",
                skillsDirectory: "relative/skills",
                detected: true,
                skillsDirectoryExists: false,
                entryCount: 0,
                readable: false,
                writable: false,
                isCustom: true
            ),
            AgentDetectionSnapshot(
                agentID: "custom-missing",
                agent: nil,
                displayName: "Custom Missing",
                markerPath: "/tmp/missing",
                skillsDirectory: "/tmp/missing/skills",
                detected: true,
                skillsDirectoryExists: false,
                entryCount: 0,
                readable: false,
                writable: false,
                isCustom: true
            ),
            AgentDetectionSnapshot(
                agentID: "custom-readonly",
                agent: nil,
                displayName: "Custom Readonly",
                markerPath: "/tmp/readonly",
                skillsDirectory: "/tmp/readonly/skills",
                detected: true,
                skillsDirectoryExists: true,
                entryCount: 0,
                readable: true,
                writable: false,
                isCustom: true
            ),
            AgentDetectionSnapshot(
                agentID: AgentKind.claudeCode.rawValue,
                agent: .claudeCode,
                displayName: "Claude Code",
                markerPath: "/tmp/claude",
                skillsDirectory: "/tmp/claude/skills",
                detected: false,
                skillsDirectoryExists: false,
                entryCount: 0,
                readable: false,
                writable: false,
                isCustom: false
            )
        ]
        let customAgents = [
            CustomAgentRecord(id: "custom-valid", displayName: "Custom Valid", skillsDirectory: "/tmp/custom/skills", createdAt: .distantPast),
            CustomAgentRecord(id: "custom-invalid", displayName: "Custom Invalid", skillsDirectory: "relative/skills", createdAt: .distantPast),
            CustomAgentRecord(id: "custom-missing", displayName: "Custom Missing", skillsDirectory: "/tmp/missing/skills", createdAt: .distantPast),
            CustomAgentRecord(id: "custom-readonly", displayName: "Custom Readonly", skillsDirectory: "/tmp/readonly/skills", createdAt: .distantPast)
        ]
        let orphanLink = AgentLinkRecord(
            agentID: "custom-orphan",
            scope: .global,
            skillID: "review",
            linkPath: "/tmp/orphan/review",
            targetPath: "/tmp/root/review"
        )

        let result = InstalledAgentDescriptorBuilder().build(
            detections: detections,
            configurations: AgentConfigurationRecord.phase1BuiltIns + customAgents.map {
                AgentConfigurationRecord(
                    id: $0.id,
                    agent: nil,
                    displayName: $0.displayName,
                    iconMonogram: "AI",
                    skillsDirectory: $0.skillsDirectory
                )
            },
            links: [orphanLink]
        )

        #expect(Set(result.descriptors.map(\.id)) == Set(["codex", "claudeCode", "custom-valid", "custom-invalid", "custom-missing", "custom-readonly", "custom-orphan"]))
        #expect(result.descriptors.map(\.displayName) == ["Claude Code", "Codex", "Custom Invalid", "Custom Missing", "Custom Readonly", "Custom Valid", "custom-orphan"])
        #expect(result.descriptors.first { $0.id == "claudeCode" }?.isVisibleOnCards == true)
        let builtIn = try #require(result.descriptors.first { $0.id == "codex" })
        #expect(builtIn.globalCapability.isAvailable)
        let custom = try #require(result.descriptors.first { $0.id == "custom-valid" })
        #expect(custom.globalCapability.isAvailable)
        #expect(custom.isVisibleInSidebar)
        let invalid = try #require(result.descriptors.first { $0.id == "custom-invalid" })
        #expect(invalid.globalCapability == .unavailable(.invalidSkillsDirectory))
        let missing = try #require(result.descriptors.first { $0.id == "custom-missing" })
        #expect(missing.globalCapability == .unavailable(.missingSkillsDirectory))
        let readOnly = try #require(result.descriptors.first { $0.id == "custom-readonly" })
        #expect(readOnly.globalCapability == .unavailable(.notWritable))
        let orphan = try #require(result.descriptors.first { $0.id == "custom-orphan" })
        #expect(orphan.isUnresolved)
        #expect(!orphan.isVisibleOnCards)
        #expect(result.issues.map(\.agentID) == ["custom-orphan"])
    }

    @Test func builtInAgentsRemainConfigurableWithoutInstallationEvidence() async throws {
        let root = try temporaryDirectory()
        let controller = SkillsHubLibraryController(agentAuditService: AgentDirectoryAuditService(installationPresence: { _, _ in .absent }), agentEnvironment: [:])
        try await connectInitializedTestRoot(controller, at: root)

        #expect(controller.visibleInstalledAgentDescriptors.map(\.id) == ["claudeCode", "codex"])
        #expect(controller.visibleInstalledAgentDescriptors.allSatisfy { $0.isDetected == false })
        #expect(controller.sidebarAgentDescriptors.isEmpty)
    }

    @Test func agentDirectoryChangesOnlyAfterOldRelationsAreClear() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex])
        let oldDirectory = try #require(fixture.targets[.codex])
        let newDirectory = try temporaryDirectory()
        try fixture.controller.rememberUserSelectedAccess(to: newDirectory)

        #expect(fixture.controller.agentDirectoryChangeBlockers(agentID: AgentKind.codex.rawValue).isEmpty)
        try await fixture.controller.saveAgentDirectory(
            agentID: AgentKind.codex.rawValue,
            newDirectory: newDirectory
        )

        let saved = try #require(fixture.controller.rootSnapshot?.metadata.agents.first { $0.id == AgentKind.codex.rawValue })
        #expect(saved.skillsDirectory == newDirectory.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: oldDirectory.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: newDirectory.path).isEmpty)

        let result = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
            enabled: true
        )
        #expect(result.outcome == .succeeded)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: newDirectory.appendingPathComponent("Writer").path)
            == fixture.root.appendingPathComponent("local/writer").path)
        #expect(!FileManager.default.fileExists(atPath: oldDirectory.appendingPathComponent("Writer").path))
    }

    @Test func enabledSelectionWithMissingNodeStillBlocksAgentDirectoryChange() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex])
        let oldDirectory = try #require(fixture.targets[.codex])
        _ = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
            enabled: true
        )
        try FileManager.default.removeItem(at: oldDirectory.appendingPathComponent("Writer"))
        let newDirectory = try temporaryDirectory()
        try fixture.controller.rememberUserSelectedAccess(to: newDirectory)

        let blockers = fixture.controller.agentDirectoryChangeBlockers(agentID: AgentKind.codex.rawValue)
        #expect(blockers.contains { $0.kind == .enabledSelection && $0.skillID == "writer" })
        try await fixture.controller.saveAgentDisplayFields(
            agentID: AgentKind.codex.rawValue,
            displayName: "Codex Personal",
            iconMonogram: nil
        )
        #expect(fixture.controller.rootSnapshot?.metadata.agents.first {
            $0.id == AgentKind.codex.rawValue
        }?.displayName == "Codex Personal")
        await #expect(throws: SkillsHubLibraryFailure.invalidSource(
            "Please resolve the listed Agent relationships or operations before changing the directory."
        )) {
            try await fixture.controller.saveAgentDirectory(
                agentID: AgentKind.codex.rawValue,
                newDirectory: newDirectory
            )
        }
        let saved = try #require(fixture.controller.rootSnapshot?.metadata.agents.first { $0.id == AgentKind.codex.rawValue })
        #expect(saved.skillsDirectory == nil)
        #expect(fixture.controller.resolvedAgentSkillsDirectory(for: .codex) == oldDirectory)

        _ = try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            assetID: fixture.assetID,
            enabled: false
        )
        try await fixture.controller.auditAgentDirectory(agentID: AgentKind.codex.rawValue)
        #expect(fixture.controller.agentDirectoryChangeBlockers(agentID: AgentKind.codex.rawValue).isEmpty)
        try await fixture.controller.saveAgentDirectory(
            agentID: AgentKind.codex.rawValue,
            newDirectory: newDirectory
        )
        #expect(fixture.controller.rootSnapshot?.metadata.agents.first {
            $0.id == AgentKind.codex.rawValue
        }?.skillsDirectory == newDirectory.path)
    }

    @Test func verifiedExternalObjectDoesNotBlockAgentDirectoryChange() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex])
        let oldDirectory = try #require(fixture.targets[.codex])
        try FileManager.default.createDirectory(
            at: oldDirectory.appendingPathComponent("external-owned", isDirectory: true),
            withIntermediateDirectories: false
        )
        try localSkillText(name: "External", description: "External skill.").write(
            to: oldDirectory.appendingPathComponent("external-owned/SKILL.md"), atomically: true, encoding: .utf8)
        try await fixture.controller.auditAgentDirectory(agentID: AgentKind.codex.rawValue)

        let blockers = fixture.controller.agentDirectoryChangeBlockers(agentID: AgentKind.codex.rawValue)
        #expect(blockers.isEmpty)
        #expect(fixture.controller.agentFindings.contains {
            $0.agentID == AgentKind.codex.rawValue && $0.type == .localDirectoryNotManaged
        })
    }

    @Test func directoryChangeReauditsOldTargetImmediatelyBeforeSaving() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [.codex])
        let oldDirectory = try #require(fixture.targets[.codex])
        let newDirectory = try temporaryDirectory()
        try fixture.controller.rememberUserSelectedAccess(to: newDirectory)
        #expect(fixture.controller.agentDirectoryChangeBlockers(agentID: AgentKind.codex.rawValue).isEmpty)

        try Data("not a skill".utf8).write(to: oldDirectory.appendingPathComponent("unexpected.txt"))

        await #expect(throws: SkillsHubLibraryFailure.invalidSource(
            "Please resolve the listed Agent relationships or operations before changing the directory."
        )) {
            try await fixture.controller.saveAgentDirectory(
                agentID: AgentKind.codex.rawValue,
                newDirectory: newDirectory
            )
        }
        #expect(fixture.controller.rootSnapshot?.metadata.agents.first {
            $0.id == AgentKind.codex.rawValue
        }?.skillsDirectory == nil)
    }

    @Test func customAgentDirectoryUsesTheSameChangePreflight() async throws {
        let fixture = try await makeControllerRelationFixture(agents: [])
        let oldDirectory = try temporaryDirectory()
        let newDirectory = try temporaryDirectory()
        try fixture.controller.rememberUserSelectedAccess(to: oldDirectory)
        try fixture.controller.rememberUserSelectedAccess(to: newDirectory)
        let customAgent = try await fixture.controller.addCustomAgent(
            displayName: "Personal Agent",
            iconMonogram: "PA",
            skillsDirectory: oldDirectory
        )

        try await fixture.controller.saveAgentDirectory(agentID: customAgent.id, newDirectory: newDirectory)

        #expect(fixture.controller.rootSnapshot?.metadata.agents.first {
            $0.id == customAgent.id
        }?.skillsDirectory == newDirectory.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: oldDirectory.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: newDirectory.path).isEmpty)
    }
}

private func installedSkill(id: String, name: String, path: URL) -> InstalledSkill {
    InstalledSkill(
        id: id,
        sourceID: nil,
        name: name,
        description: "Fixture skill.",
        installedPath: path.path,
        sourceKind: .manualFilesystem,
        validation: .valid,
        purpose: nil,
        tagIDs: [],
        installedAt: Date()
    )
}

private func localSkillText(name: String, description: String) -> String {
    """
    ---
    name: \(name)
    description: \(description)
    ---
    Body.
    """
}

// Directory-audit and consumer tests inject a signed-installation fact independently
// of production detection. Only their isolated fake home controls this fixture.
nonisolated func fixtureAgentInstallation(_ agent: AgentKind, _ home: URL) -> AgentInstallationResult {
    let target = AgentPathResolver().globalSkillsDirectory(for: agent, environment: [:], homeDirectory: home)
    guard FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) else { return .absent }
    return .present(AgentInstallationEvidence(agent: agent, digest: "fixture-installation-\(agent.rawValue)"))
}

private final class FailingAgentDirectoryFileManager: FileManager, @unchecked Sendable {
    let target: URL

    init(target: URL) { self.target = target }

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: DirectoryEnumerationOptions = []) throws -> [URL] {
        if url.standardizedFileURL == target.standardizedFileURL {
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
