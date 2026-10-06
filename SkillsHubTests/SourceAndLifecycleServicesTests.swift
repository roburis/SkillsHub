import Foundation
import Darwin
import Testing
@testable import SkillsHub

struct SourceAndLifecycleServicesTests {
    @MainActor
    @Test func sourceRemovalRecoveryRechecksFactsWithoutReplaying() async throws {
        let fixture = try sourceRemovalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let trash = fixture.root.appendingPathComponent("test-trash/source", isDirectory: true)
        let service = SourceRemovalService(trashItem: { source in
            try FileManager.default.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: trash)
            return trash
        })
        var record = try service.startRecord(for: fixture.plan, rootURL: fixture.root)
        let controller = SkillsHubLibraryController()
        try await connectInitializedTestRoot(controller, at: fixture.root)

        let pending = try #require(controller.phase1Tasks.first { $0.id == fixture.plan.id })
        #expect(pending.kind == .removeLocalSource)
        #expect(pending.phase == .needsAttention)
        #expect(pending.recoveryEvidence?.components.first { $0.kind == "content" }?.state == .notCompleted)
        #expect(pending.recoveryEvidence?.components.first { $0.kind == "metadata" }?.state == .notCompleted)

        try service.saveRelationResults([], record: &record, rootURL: fixture.root, allCleared: true)
        _ = try await service.removeContentAndRegistration(
            plan: fixture.plan,
            record: &record,
            rootURL: fixture.root,
            metadataStore: fixture.store
        )
        let metadataFile = fixture.store.rootLayout(for: fixture.root).skillshubMetadataFile
        let recordFile = fixture.root.appendingPathComponent(
            ".skillshub-operations/\(fixture.plan.id.uuidString)/source-removal.json"
        )
        let metadataBefore = try Data(contentsOf: metadataFile)
        let recordBefore = try Data(contentsOf: recordFile)

        await controller.recheckRecoveryTasks()

        let completed = try #require(controller.phase1Tasks.first { $0.id == fixture.plan.id })
        #expect(completed.phase == .completed)
        #expect(completed.recoveryEvidence?.components.allSatisfy { $0.state == .completed } == true)
        #expect(try Data(contentsOf: metadataFile) == metadataBefore)
        #expect(try Data(contentsOf: recordFile) == recordBefore)
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("SKILL.md").path))
    }

    @Test(arguments: [SkillSourceKind.localDirectory, .githubRepository])
    func wholeSourceRemovalMovesContentThenRemovesActiveMetadata(kind: SkillSourceKind) async throws {
        let fixture = try sourceRemovalFixture(kind: kind)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let trash = fixture.root.appendingPathComponent("test-trash", isDirectory: true)
        let service = SourceRemovalService(trashItem: { source in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let destination = trash.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        })
        var record = try service.startRecord(for: fixture.plan, rootURL: fixture.root)
        try service.saveRelationResults([], record: &record, rootURL: fixture.root, allCleared: true)

        let snapshot = try await service.removeContentAndRegistration(
            plan: fixture.plan,
            record: &record,
            rootURL: fixture.root,
            metadataStore: fixture.store
        )

        #expect(record.stage == .completed)
        #expect(FileManager.default.fileExists(atPath: fixture.source.path) == false)
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("source/SKILL.md").path))
        #expect(snapshot.metadata.sources.isEmpty)
        #expect(snapshot.metadata.installedSkills.isEmpty)
        #expect(snapshot.metadata.availableSkills.isEmpty)
        #expect(try String(contentsOf: fixture.external.appendingPathComponent("marker"), encoding: .utf8) == "external")
    }

    @MainActor
    @Test func githubSourceRemovalPlanUsesTheCompleteRepository() async throws {
        let fixture = try sourceRemovalFixture(kind: .githubRepository)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = SkillsHubLibraryController()
        try await connectInitializedTestRoot(controller, at: fixture.root)

        let plan = try controller.prepareLocalSourceRemoval(sourceID: fixture.plan.source.id)

        #expect(plan.source.kind == .githubRepository)
        #expect(plan.source.localPath == fixture.source.path)
        #expect(plan.skills.map(\.name).sorted() == ["Child", "Source"])
    }

    @Test func sourceRemovalScopeRejectsContainersNestedSkillsAndIncompleteGitHubPaths() throws {
        let root = try temporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid: [(String, SkillSourceKind)] = [
            ("local", .localDirectory),
            ("local/source/nested", .localDirectory),
            ("github", .githubRepository),
            ("github/owner", .githubRepository),
            ("github/owner/repo/nested", .githubRepository)
        ]
        for (path, kind) in invalid {
            let source = SkillSource(kind: kind, name: path, localPath: root.appendingPathComponent(path).path)
            #expect(!SourceRemovalService.isValidScope(source: source, rootURL: root))
        }
    }

    @Test func localSourceRemovalKeepsRegistrationWhenMetadataCommitFailsAfterTrash() async throws {
        let fixture = try sourceRemovalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let trash = fixture.root.appendingPathComponent("test-trash/source", isDirectory: true)
        let service = SourceRemovalService(trashItem: { source in
            try FileManager.default.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: trash)
            return trash
        })
        var record = try service.startRecord(for: fixture.plan, rootURL: fixture.root)
        try service.saveRelationResults([], record: &record, rootURL: fixture.root, allCleared: true)
        let failingStore = SkillsHubMetadataStore(writeCheckpoint: { phase, _ in
            if phase == .encoding { throw SourceRemovalTestError.metadataFailure }
        })

        await #expect(throws: SourceRemovalError.metadataCommitFailed(String(describing: SourceRemovalTestError.metadataFailure))) {
            _ = try await service.removeContentAndRegistration(
                plan: fixture.plan,
                record: &record,
                rootURL: fixture.root,
                metadataStore: failingStore
            )
        }

        #expect(record.stage == .contentTrashed)
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("SKILL.md").path))
        #expect(try fixture.store.loadCurrentSnapshot(from: fixture.root).metadata.sources.count == 1)
        #expect(try fixture.store.loadCurrentSnapshot(from: fixture.root).metadata.installedSkills.count == 2)
    }

    @Test func localSourceRemovalKeepsContentAndRegistrationWhenTrashFails() async throws {
        let fixture = try sourceRemovalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = SourceRemovalService(trashItem: { _ in
            throw SourceRemovalTestError.trashFailure
        })
        var record = try service.startRecord(for: fixture.plan, rootURL: fixture.root)
        try service.saveRelationResults([], record: &record, rootURL: fixture.root, allCleared: true)

        await #expect(throws: SourceRemovalError.trashFailed(String(describing: SourceRemovalTestError.trashFailure))) {
            _ = try await service.removeContentAndRegistration(
                plan: fixture.plan,
                record: &record,
                rootURL: fixture.root,
                metadataStore: fixture.store
            )
        }

        #expect(record.stage == .relationshipsCleared)
        #expect(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("SKILL.md").path))
        #expect(try fixture.store.loadCurrentSnapshot(from: fixture.root).metadata.sources.count == 1)
        #expect(try fixture.store.loadCurrentSnapshot(from: fixture.root).metadata.installedSkills.count == 2)
    }

    @Test func localSourceRemovalRefusesLinkedOperationDirectoryBeforeWriting() throws {
        let fixture = try sourceRemovalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operations = fixture.root.appendingPathComponent(".skillshub-operations", isDirectory: true)
        let external = fixture.root.appendingPathComponent("external-operations", isDirectory: true)
        if FileManager.default.fileExists(atPath: operations.path) {
            try FileManager.default.removeItem(at: operations)
        }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: operations, withDestinationURL: external)

        #expect(throws: SourceRemovalError.recordUnavailable) {
            _ = try SourceRemovalService().startRecord(for: fixture.plan, rootURL: fixture.root)
        }
        #expect(FileManager.default.fileExists(atPath: external.appendingPathComponent(fixture.plan.id.uuidString).path) == false)
    }

    @Test(arguments: ["local/source", "github/owner/repo"])
    func wholeSourceExchangePreservesBothTreesAndMetadata(sourcePath: String) async throws {
        let fixture = try SourceExchangeFixture(sourcePath: sourcePath)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exchange = SourceDirectoryExchange()
        let record = fixture.record
        let result = try await exchange.execute(confirmed: record, rootURL: fixture.root)
        guard case .performed(let observation) = result else {
            Issue.record("Expected exclusive Root qualification")
            return
        }
        #expect(observation.current == .prepared)
        #expect(observation.retained == .original)
        #expect(observation.metadataUnchanged)
        #expect(observation.materialsVerified)
        #expect(try fixture.manifest(fixture.source).entries == record.prepared.manifest.entries)
        #expect(try fixture.manifest(fixture.prepared).entries == record.current.manifest.entries)
        #expect(try LinkNodeIdentity.read(at: fixture.source) == record.prepared.identity)
        #expect(try LinkNodeIdentity.read(at: fixture.prepared) == record.current.identity)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(".skillshub.json")) == record.originalMetadata)
        #expect(try exchange.loadRecord(operationID: record.operationID, rootURL: fixture.root) == record)
        let saved = record.operationDirectory.appendingPathComponent("source-exchange-observation.json")
        #expect(try JSONDecoder().decode(SourceDirectoryExchangeObservation.self, from: Data(contentsOf: saved)) == observation)
        Attachment.record(try JSONEncoder().encode(record), named: "source-exchange-input.json")
        Attachment.record(try JSONEncoder().encode(observation), named: "source-exchange-result.json")
        let space = try FileManager.default.attributesOfFileSystem(forPath: fixture.root.path)
        Attachment.record(Data("\(ProcessInfo.processInfo.operatingSystemVersionString)\n\(space)".utf8), named: "source-exchange-platform.txt")
    }

    @Test(arguments: SourceDirectoryExchangeCheckpoint.allCases)
    func interruptedExchangeOnlyObservesActualTrees(point: SourceDirectoryExchangeCheckpoint) async throws {
        let fixture = try SourceExchangeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exchange = SourceDirectoryExchange(checkpoint: { reached in
            if reached == point { throw CancellationError() }
        })
        await #expect(throws: CancellationError.self) {
            try await exchange.execute(confirmed: fixture.record, rootURL: fixture.root)
        }
        let swapped = [.afterExchange, .beforeReadback, .afterReadback, .afterObservationRecord].contains(point)
        let restarted = SourceDirectoryExchange()
        let observation = restarted.observe(fixture.record, rootURL: fixture.root)
        #expect(observation.current == (swapped ? .prepared : .original))
        #expect(observation.retained == (swapped ? .original : .prepared))
        #expect(observation.metadataUnchanged)
        #expect(observation.materialsVerified == (point != .beforeRecord))
        #expect(try fixture.manifest(fixture.source).digest == (swapped ? fixture.record.prepared : fixture.record.current).manifest.digest)
        #expect(restarted.observe(fixture.record, rootURL: fixture.root) == observation)
        Attachment.record(try JSONEncoder().encode(observation), named: "interruption-\(point).json")
    }

    @Test(arguments: ["old-content", "new-content", "same-content-new-node", "source-parent", "operation-parent", "metadata", "record"])
    func changedConfirmationStopsBeforeDirectoryExchange(change: String) async throws {
        let fixture = try SourceExchangeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exchange = SourceDirectoryExchange(checkpoint: { point in
            guard point == .beforeExchange else { return }
            let fm = FileManager.default
            switch change {
            case "old-content", "new-content":
                let target = change == "old-content" ? fixture.source : fixture.prepared
                try Data("later edit".utf8).write(to: target.appendingPathComponent(".hidden"))
            case "same-content-new-node":
                try fm.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("original"))
                try fm.copyItem(at: fixture.root.appendingPathComponent("original"), to: fixture.source)
            case "source-parent", "operation-parent":
                let parent = change == "source-parent" ? fixture.source.deletingLastPathComponent() : fixture.record.operationDirectory
                try fm.moveItem(at: parent, to: fixture.root.appendingPathComponent("retained-parent"))
                try fm.createDirectory(at: parent, withIntermediateDirectories: false)
            case "metadata":
                try Data("external JSON".utf8).write(to: fixture.root.appendingPathComponent(".skillshub.json"))
            default:
                try Data("{}".utf8).write(to: fixture.record.recordURL)
            }
        })
        do {
            _ = try await exchange.execute(confirmed: fixture.record, rootURL: fixture.root)
            Issue.record("Changed confirmation must not exchange directories")
        } catch {
            #expect(error is SourceDirectoryExchangeError || change == "record")
        }
        let oldURL = change == "source-parent" ? fixture.root.appendingPathComponent("retained-parent/source") : fixture.source
        let newURL = change == "operation-parent" ? fixture.root.appendingPathComponent("retained-parent/prepared") : fixture.prepared
        #expect(try String(contentsOf: oldURL.appendingPathComponent("version"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: newURL.appendingPathComponent("version"), encoding: .utf8) == "new")
    }

    @Test(arguments: ["old-content", "new-content", "source-parent", "metadata", "record"],
          [SourceDirectoryExchangeCheckpoint.afterExchange, .afterReadback])
    func postExchangeChangesRemainInPlaceWithoutRollback(change: String, boundary: SourceDirectoryExchangeCheckpoint) async throws {
        let fixture = try SourceExchangeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exchange = SourceDirectoryExchange(checkpoint: { point in
            guard point == boundary else { return }
            switch change {
            case "old-content", "new-content":
                let target = change == "old-content" ? fixture.prepared : fixture.source
                try Data("later edit".utf8).write(to: target.appendingPathComponent(".hidden"))
            case "source-parent":
                let parent = fixture.source.deletingLastPathComponent()
                try FileManager.default.moveItem(at: parent, to: fixture.root.appendingPathComponent("retained-parent"))
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            case "metadata":
                try Data("external JSON".utf8).write(to: fixture.root.appendingPathComponent(".skillshub.json"))
            default:
                try Data("{}".utf8).write(to: fixture.record.recordURL)
            }
        })
        await #expect(throws: SourceDirectoryExchangeError.factsChanged) {
            try await exchange.execute(confirmed: fixture.record, rootURL: fixture.root)
        }
        let source = change == "source-parent" ? fixture.root.appendingPathComponent("retained-parent/source") : fixture.source
        let restarted = SourceDirectoryExchange()
        let before = restarted.observe(fixture.record, rootURL: fixture.root)
        #expect(try String(contentsOf: source.appendingPathComponent("version"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: fixture.prepared.appendingPathComponent("version"), encoding: .utf8) == "old")
        #expect(restarted.observe(fixture.record, rootURL: fixture.root) == before)
        if change == "metadata" { #expect(before.metadataUnchanged == false) }
        if change == "record" { #expect(before.materialsVerified == false) }
        if change == "source-parent" {
            #expect(before.current == .unknown)
            #expect(before.retained == .original)
            #expect(before.metadataUnchanged)
            #expect(before.materialsVerified)
            #expect(try restarted.loadRecord(operationID: fixture.record.operationID, rootURL: fixture.root) == fixture.record)
        }
    }

    @Test(arguments: [false, true])
    func lastWindowReplacementIsRetainedAndNeverReportedAsSuccess(link: Bool) async throws {
        let fixture = try SourceExchangeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = fixture.root.appendingPathComponent("external")
        try Data("external bytes".utf8).write(to: external)
        let original = fixture.root.appendingPathComponent("moved-original")
        let exchange = SourceDirectoryExchange(checkpoint: { point in
            guard point == .beforePrimitive else { return }
            try FileManager.default.moveItem(at: fixture.source, to: original)
            if link {
                try FileManager.default.createSymbolicLink(at: fixture.source, withDestinationURL: external)
            } else {
                try Data("replacement".utf8).write(to: fixture.source)
            }
        })
        do {
            _ = try await exchange.execute(confirmed: fixture.record, rootURL: fixture.root)
            Issue.record("A last-window replacement cannot be reported as a successful exchange")
        } catch let error as SourceDirectoryExchangeError {
            // NOFOLLOW may reject a final symlink; otherwise the swapped replacement is retained.
            if case .filesystem(_, let code) = error { #expect(link && code == ELOOP) }
            else { #expect(error == .factsChanged) }
        }
        #expect(try fixture.manifest(original).digest == fixture.record.current.manifest.digest)
        #expect(try String(contentsOf: external, encoding: .utf8) == "external bytes")
        let retained = (try LinkNodeIdentity.read(at: fixture.prepared)).kind == S_IFDIR ? fixture.source : fixture.prepared
        if link { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: retained.path) == external.path) }
        else { #expect(try String(contentsOf: retained, encoding: .utf8) == "replacement") }
        let observation = SourceDirectoryExchange().observe(fixture.record, rootURL: fixture.root)
        #expect(observation.current == .unknown || observation.retained == .unknown)
        #expect(observation.metadataUnchanged)
    }

    @Test(arguments: ["local", "github", "github/owner", ".skillshub-operations", "local/source/nested"])
    func directoryExchangeRejectsContainersAndNestedSources(path: String) throws {
        let fixture = try SourceExchangeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(throws: SourceDirectoryExchangeError.invalidScope) {
            try SourceDirectoryExchange().prepare(rootURL: fixture.root,
                                                 sourceURL: fixture.root.appendingPathComponent(path),
                                                 operationID: fixture.record.operationID)
        }
    }

    @Test func recoveryRecordCannotExpandAuthorizedScope() throws {
        let fixture = try SourceExchangeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.record)) as? [String: Any])
        var current = try #require(payload["current"] as? [String: Any])
        current["path"] = fixture.root.path + "/github/../.."
        payload["current"] = current
        let bytes = try JSONSerialization.data(withJSONObject: payload)
        try bytes.write(to: fixture.record.recordURL)
        let corrupt = try JSONDecoder().decode(SourceDirectoryExchangeRecord.self, from: bytes)
        #expect(throws: SourceDirectoryExchangeError.materialsChanged) {
            try SourceDirectoryExchange().loadRecord(operationID: corrupt.operationID, rootURL: fixture.root)
        }
        let result = SourceDirectoryExchange().observe(corrupt, rootURL: fixture.root)
        #expect(result.current == .unknown)
        #expect(result.retained == .unknown)
        #expect(result.metadataUnchanged == false)
        #expect(result.materialsVerified == false)
    }

    @Test func directoryExchangeRejectsReplayAndLostParentPermission() async throws {
        let fixture = try SourceExchangeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let parent = fixture.source.deletingLastPathComponent()
        defer { _ = Darwin.chmod(parent.path, 0o700) }
        let exchange = SourceDirectoryExchange(checkpoint: { point in
            if point == .beforeExchange { _ = Darwin.chmod(parent.path, 0o500) }
        })
        await #expect(throws: SourceDirectoryExchangeError.filesystem(path: parent.path, errno: EACCES)) {
            try await exchange.execute(confirmed: fixture.record, rootURL: fixture.root)
        }
        #expect(try fixture.manifest(fixture.source).digest == fixture.record.current.manifest.digest)
        _ = Darwin.chmod(parent.path, 0o700)
        await #expect(throws: SourceDirectoryExchangeError.filesystem(path: fixture.record.recordURL.path, errno: EEXIST)) {
            try await SourceDirectoryExchange().execute(confirmed: fixture.record, rootURL: fixture.root)
        }
        #expect(try fixture.manifest(fixture.prepared).digest == fixture.record.prepared.manifest.digest)
    }

    @Test(arguments: [ENOTSUP, ENOSPC])
    func directoryExchangeStopsOnPrimitiveFailure(code: Int32) async throws {
        let fixture = try SourceExchangeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let failure = SourceDirectoryExchangeError.filesystem(path: fixture.source.path, errno: code)
        let exchange = SourceDirectoryExchange(checkpoint: { point in
            if point == .beforeExchange { throw failure }
        })
        await #expect(throws: failure) { try await exchange.execute(confirmed: fixture.record, rootURL: fixture.root) }
        let observation = SourceDirectoryExchange().observe(fixture.record, rootURL: fixture.root)
        #expect(observation.current == .original)
        #expect(observation.retained == .prepared)
        #expect(observation.materialsVerified)
        #expect(observation.metadataUnchanged)
    }

    @Test func rootCandidateFileLinkDoesNotBecomeBlockedDirectoryCandidate() throws {
        let source = try temporaryDirectory()
        try writeSkill(source, name: "Review", description: "Reviews local files.")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("entry-link").path, withDestinationPath: "SKILL.md")
        let result = LocalSourceIndexer().index(directory: source)
        #expect(result.isPlannable)
        #expect(result.availableSkills.map(\.skillPath) == ["."])
        #expect(result.observations.first { $0.relativePath == "entry-link" }?.reason == .symbolicLinkSkipped)
    }

    @Test func invalidYAMLCandidateRemainsVisibleAndBlocked() throws {
        let source = try temporaryDirectory()
        let skill = source.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: [broken\ndescription: Text\n---".write(
            to: skill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let result = LocalSourceIndexer().index(directory: source, sourceID: UUID())

        let candidate = try #require(result.availableSkills.first { $0.skillPath == "broken" })
        #expect(candidate.checkStatus == .blocked)
        #expect(candidate.validation.messages.map(\.id) == ["frontmatter-syntax"])
        #expect(result.observations.first { $0.relativePath == "broken" }?.status == .blocked)
        #expect(result.isPlannable)
    }

    @Test func localSourceIndexerStaysInsideSelectedFolderLayouts() throws {
        let fixture = try sourceDiscoveryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        try writeSkill(source, name: "Root Skill", description: "Root local skill.")
        let child = source.appendingPathComponent("review", isDirectory: true)
        try writeSkill(child, name: "Review Skill", description: "Child local skill.")
        let agentSkill = source.appendingPathComponent(".agents/skills/write", isDirectory: true)
        try writeSkill(agentSkill, name: "Write Skill", description: "Agent layout skill.")
        let hiddenDeepSkill = source.appendingPathComponent(".hidden/one/two/review", isDirectory: true)
        try writeSkill(hiddenDeepSkill, name: "Review Skill", description: "Hidden deep skill with the same display name.")
        let outside = fixture.appendingPathComponent("outside", isDirectory: true)
        try writeSkill(outside, name: "Outside Skill", description: "Must not be indexed.")
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("linked-outside", isDirectory: true), withDestinationURL: outside)
        let sourceID = UUID()

        let live = SourceTraversalAccess()
        var enumerated: [URL] = []
        var reads: [String] = []
        let traversal = SourceTraversalAccess(
            contentsOfDirectory: { url in
                enumerated.append(url)
                reads.append("enumerate \(url.path)")
                return try live.contentsOfDirectory(at: url)
            },
            resourceValues: { url, keys in
                reads.append("attributes \(url.path)")
                #expect(url.path == source.path || url.path.hasPrefix(source.path + "/"))
                return try live.resourceValues(at: url, forKeys: keys)
            },
            symlinkDestination: { url in
                reads.append("readlink \(url.path)")
                return try live.destinationOfSymbolicLink(at: url)
            }
        )
        let result = LocalSourceIndexer(traversal: traversal).index(directory: source, sourceID: sourceID)

        #expect(enumerated.allSatisfy { $0.path == source.path || $0.path.hasPrefix(source.path + "/") })
        #expect(enumerated.contains(source.appendingPathComponent(".agents", isDirectory: true)))
        #expect(enumerated.contains(source.appendingPathComponent(".agents/skills/write", isDirectory: true)))
        Attachment.record(Data(reads.joined(separator: "\n").utf8), named: "discovery-read-set.txt")

        #expect(result.source.id == sourceID)
        #expect(result.source.kind == .localDirectory)
        #expect(result.source.localPath == source.path)
        #expect(Set(result.availableSkills.map(\.skillPath)) == Set([
            ".", ".agents/skills/write", ".hidden/one/two/review", "review"
        ]))
        #expect(Set(result.availableSkills.map(\.candidateID)).count == 4)
        #expect(result.availableSkills.map(\.sourceID).allSatisfy { $0 == sourceID })
        #expect(!result.availableSkills.map(\.id).contains("outside-skill"))
        #expect(!result.availableSkills.map(\.skillPath).contains("linked-outside"))
        #expect(result.observations.first(where: { $0.relativePath == "linked-outside" })?.status == .warning)
        #expect(result.source.registrationState == .registered)
        #expect(result.isPlannable)
    }

    @Test func localSourceIndexerDistinguishesEmptySourceFromIncompleteScan() throws {
        let source = try temporaryDirectory()
        try Data("notes".utf8).write(to: source.appendingPathComponent("notes.txt"))
        try Data(skillText(name: "Wrong Case", description: "The entry spelling is not exact.").utf8)
            .write(to: source.appendingPathComponent("skill.md"))

        let result = LocalSourceIndexer().index(directory: source, sourceID: UUID())

        #expect(result.availableSkills.isEmpty)
        #expect(result.observations.isEmpty)
        #expect(result.source.isIndexIncomplete == false)
        #expect(result.source.indexStatusReason == "noSkillFound")
        #expect(result.isPlannable == false)
    }

    @Test func localSourceObservationDoesNotProbeReferencesOutsideSelectedSource() throws {
        let fixture = try sourceDiscoveryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        try writeSkill(source, name: "Source", description: "Checks only authorized content.")
        let entry = source.appendingPathComponent("SKILL.md")
        try (String(contentsOf: entry, encoding: .utf8) + "\n[Outside](../outside.md)\n")
            .write(to: entry, atomically: true, encoding: .utf8)
        let fileManager = ReferenceProbeFileManager()
        fileManager.outsidePath = fixture.appendingPathComponent("outside.md").path

        _ = LocalSourceIndexer(fileManager: fileManager).index(directory: source)

        Attachment.record(Data(fileManager.probes.joined(separator: "\n").utf8), named: "reference-read-set.txt")
        #expect(fileManager.probes.isEmpty)
    }

    @Test func localSourceIndexerReportsRootAttributeFailureAsUnreadable() throws {
        let source = try temporaryDirectory()
        let traversal = SourceTraversalAccess(
            resourceValues: { _, _ in throw SourceTraversalTestError.denied }
        )

        let result = LocalSourceIndexer(traversal: traversal).index(directory: source, sourceID: UUID())

        let observation = try #require(result.observations.first)
        #expect(observation.status == .unreadable)
        #expect(observation.reason == .attributesUnreadable)
    }

    @Test func localSourceIndexerDoesNotReadAttributesBeyondAuthorizedSource() throws {
        let source = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let link = source.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let live = SourceTraversalAccess()
        var outsideAttributesWereRead = false
        let traversal = SourceTraversalAccess(resourceValues: { url, keys in
            if url.standardizedFileURL.path == outside.standardizedFileURL.path {
                outsideAttributesWereRead = true
            }
            return try live.resourceValues(at: url, forKeys: keys)
        })

        let result = LocalSourceIndexer(traversal: traversal).index(directory: source, sourceID: UUID())

        let observation = try #require(result.observations.first { $0.relativePath == "escape" })
        #expect(observation.status == .warning)
        #expect(observation.reason == .symlinkEscapesSource)
        #expect(outsideAttributesWereRead == false)
    }

    @Test func localSourceIndexerMakesRootEnumerationFailureUnplannable() throws {
        let source = try temporaryDirectory()
        let observedAt = Date(timeIntervalSince1970: 42)
        let live = SourceTraversalAccess()
        let traversal = SourceTraversalAccess(contentsOfDirectory: { url in
            if url.standardizedFileURL == source.standardizedFileURL {
                throw SourceTraversalTestError.denied
            }
            return try live.contentsOfDirectory(at: url)
        })

        let result = LocalSourceIndexer(traversal: traversal, now: { observedAt })
            .index(directory: source, sourceID: UUID())

        let root = try #require(result.observations.first)
        #expect(root.relativePath == ".")
        #expect(root.status == .unreadable)
        #expect(root.reason == .enumerationFailed)
        #expect(root.observedAt == observedAt)
        #expect(root.fingerprint.isEmpty == false)
        #expect(result.isPlannable == false)
        #expect(result.availableSkills.isEmpty)
    }

    @Test func sourceRegistrationPlannerRejectsUnplannableRootObservation() throws {
        let root = try temporaryDirectory()
        let missingSource = root.appendingPathComponent("missing-source", isDirectory: true)
        let metadata = SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path))
        let snapshot = RootSnapshot(metadata: metadata, generation: 0, metadataDigest: "metadata")

        #expect(throws: Phase1OperationError.candidateUnavailable) {
            _ = try Phase1OperationPlanner().sourceRegistrationPlan(
                directory: missingSource,
                snapshot: snapshot,
                sourceID: UUID()
            )
        }
    }

    @Test func sourceRegistrationPlannerRejectsACompletelyScannedEmptySource() throws {
        let fixture = try sourceDiscoveryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("root", isDirectory: true)
        let source = fixture.appendingPathComponent("empty-source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let snapshot = RootSnapshot(
            metadata: SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)),
            generation: 0,
            metadataDigest: "metadata"
        )

        #expect(throws: Phase1OperationError.candidateUnavailable) {
            _ = try Phase1OperationPlanner().sourceRegistrationPlan(
                directory: source,
                snapshot: snapshot,
                sourceID: UUID()
            )
        }
    }

    @Test func localSourceIndexerMakesNestedEnumerationFailureIncomplete() throws {
        let source = try temporaryDirectory()
        let nested = source.appendingPathComponent("nested/deeper", isDirectory: true)
        try writeSkill(nested, name: "Review", description: "Reviews nested skills safely.")
        let live = SourceTraversalAccess()
        let traversal = SourceTraversalAccess(contentsOfDirectory: { url in
            if url.standardizedFileURL == source.appendingPathComponent("nested").standardizedFileURL {
                throw SourceTraversalTestError.denied
            }
            return try live.contentsOfDirectory(at: url)
        })

        let result = LocalSourceIndexer(traversal: traversal).index(directory: source, sourceID: UUID())

        let unreadable = try #require(result.observations.first { $0.relativePath == "nested" })
        #expect(unreadable.status == .unreadable)
        #expect(unreadable.reason == .enumerationFailed)
        #expect(result.isPlannable == false)
    }

    @Test func localSourceIndexerPreservesChildAttributeFailureAndUniqueObservations() throws {
        let source = try temporaryDirectory()
        let child = source.appendingPathComponent("review", isDirectory: true)
        try writeSkill(child, name: "Review", description: "Reviews local skills safely.")
        let live = SourceTraversalAccess()
        let traversal = SourceTraversalAccess(resourceValues: { url, keys in
            if url.standardizedFileURL == child.standardizedFileURL {
                throw SourceTraversalTestError.denied
            }
            return try live.resourceValues(at: url, forKeys: keys)
        })

        let result = LocalSourceIndexer(traversal: traversal).index(directory: source, sourceID: UUID())

        let failedChild = try #require(result.observations.first { $0.relativePath == "review" })
        #expect(failedChild.status == .unreadable)
        #expect(failedChild.reason == .attributesUnreadable)
        #expect(Set(result.observations.map(\.id)).count == result.observations.count)
        #expect(result.isPlannable == false)
    }

    @Test func localSourceIndexerKeepsSameRelativeCandidateDistinctAcrossSourcesAndInvalidatesDrift() throws {
        let firstSource = try temporaryDirectory()
        let secondSource = try temporaryDirectory()
        let firstSkill = firstSource.appendingPathComponent("review", isDirectory: true)
        let secondSkill = secondSource.appendingPathComponent("review", isDirectory: true)
        try writeSkill(firstSkill, name: "Review", description: "Reviews local skills safely.")
        try writeSkill(secondSkill, name: "Review", description: "Reviews local skills safely.")
        let firstID = UUID()
        let secondID = UUID()

        let before = LocalSourceIndexer().index(directory: firstSource, sourceID: firstID)
        let other = LocalSourceIndexer().index(directory: secondSource, sourceID: secondID)
        let firstCandidate = try #require(before.observations.first { $0.relativePath == "review" })
        let otherCandidate = try #require(other.observations.first { $0.relativePath == "review" })
        #expect(firstCandidate.candidateID != otherCandidate.candidateID)

        try writeSkill(firstSkill, name: "Review", description: "Changed source facts.")
        let after = LocalSourceIndexer().index(directory: firstSource, sourceID: firstID)
        #expect(before.source.contentFingerprint != after.source.contentFingerprint)
        #expect(before.availableSkills.first?.manifestDigest != after.availableSkills.first?.manifestDigest)
    }

    @Test func localSourceCandidateAssociationFollowsSourceAndRelativePosition() throws {
        let source = try temporaryDirectory()
        let original = source.appendingPathComponent("review", isDirectory: true)
        try writeSkill(original, name: "Review", description: "Original display name.")
        let sourceID = UUID()

        let before = LocalSourceIndexer().index(directory: source, sourceID: sourceID)
        let beforeID = try #require(before.observations.first { $0.relativePath == "review" }?.candidateID)
        try writeSkill(original, name: "Renamed Review", description: "Renamed at the same relative position.")
        let renamed = LocalSourceIndexer().index(directory: source, sourceID: sourceID)
        #expect(renamed.observations.first { $0.relativePath == "review" }?.candidateID == beforeID)

        let moved = source.appendingPathComponent("group/review", isDirectory: true)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)
        let afterMove = LocalSourceIndexer().index(directory: source, sourceID: sourceID)
        #expect(afterMove.observations.contains { $0.relativePath == "review" } == false)
        #expect(afterMove.observations.first { $0.relativePath == "group/review" }?.candidateID != beforeID)
    }

    @Test(arguments: [".agents", ".agents/skills"])
    func localSourceIndexerDoesNotTraverseSymlinkedDiscoveryParents(linkPath: String) throws {
        let fixture = try sourceDiscoveryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        let outside = fixture.appendingPathComponent("outside")
        let link = source.appendingPathComponent(linkPath)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeSkill(outside.appendingPathComponent("skills/review"), name: "Review", description: "Outside the source.")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: linkPath == ".agents" ? outside : outside.appendingPathComponent("skills")
        )
        let live = SourceTraversalAccess()
        var readsThroughLink: [String] = []
        let traversal = SourceTraversalAccess(
            contentsOfDirectory: { url in
                if url.path == link.path || url.path.hasPrefix(link.path + "/") { readsThroughLink.append(url.path) }
                return try live.contentsOfDirectory(at: url)
            },
            resourceValues: { url, keys in
                if url.path.hasPrefix(link.path + "/") { readsThroughLink.append(url.path) }
                return try live.resourceValues(at: url, forKeys: keys)
            }
        )

        let result = LocalSourceIndexer(traversal: traversal).index(directory: source)

        #expect(readsThroughLink.isEmpty)
        #expect(result.availableSkills.isEmpty)
        #expect(result.observations.contains { $0.reason == .symlinkEscapesSource })
    }

    @Test func localSourceFingerprintDetectsSameContentDirectoryReplacement() throws {
        let fixture = try sourceDiscoveryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        try writeSkill(source, name: "Review", description: "Stable content.")
        let sourceID = UUID()
        let indexer = LocalSourceIndexer()
        let before = indexer.index(directory: source, sourceID: sourceID)
        #expect(indexer.index(directory: source, sourceID: sourceID).source.contentFingerprint == before.source.contentFingerprint)
        try FileManager.default.moveItem(at: source, to: fixture.appendingPathComponent("original"))
        try writeSkill(source, name: "Review", description: "Stable content.")

        let after = indexer.index(directory: source, sourceID: sourceID)

        #expect(after.source.contentFingerprint != before.source.contentFingerprint)
        #expect(after.availableSkills.first?.manifestDigest == before.availableSkills.first?.manifestDigest)
    }

    @Test(arguments: [".", "local"])
    func localSourceRegistrationRejectsRootStorage(relativePath: String) throws {
        let fixture = try sourceDiscoveryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("local"), withIntermediateDirectories: true)
        let snapshot = RootSnapshot(
            metadata: SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)),
            generation: 0, metadataDigest: "metadata"
        )

        #expect(throws: Phase1OperationError.candidateUnavailable) {
            _ = try Phase1OperationPlanner().sourceRegistrationPlan(
                directory: root.appendingPathComponent(relativePath), snapshot: snapshot
            )
        }
    }

    private func sourceDiscoveryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".tmp/source-discovery-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func localSourceIndexerDoesNotDiscoverCandidatesThroughDirectoryAliases() throws {
        let fixture = try sourceDiscoveryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        let nested = source.appendingPathComponent("group/nested")
        let alias = source.appendingPathComponent("alias")
        try writeSkill(nested, name: "Nested", description: "Beyond discovery depth.")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        let live = SourceTraversalAccess()
        var followedAlias = false
        let traversal = SourceTraversalAccess(resourceValues: { url, keys in
            if url.path.hasPrefix(alias.path + "/") { followedAlias = true }
            return try live.resourceValues(at: url, forKeys: keys)
        })

        let result = LocalSourceIndexer(traversal: traversal).index(directory: source)

        #expect(followedAlias == false)
        #expect(result.availableSkills.map(\.skillPath) == ["group/nested"])
        #expect(result.observations.first { $0.relativePath == "alias" }?.status == .warning)
    }

    @Test(arguments: ["inside", "outside", "broken", "cycle"])
    func localSourceIndexerRestrictsLinkedSkillEntryToTheSelectedSource(mode: String) throws {
        let fixture = try sourceDiscoveryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        let skill = source.appendingPathComponent("candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        let entry = skill.appendingPathComponent("SKILL.md")
        var outsidePath: String?
        switch mode {
        case "inside":
            try Data(skillText(name: "Linked", description: "Linked entry inside the selected source.").utf8)
                .write(to: source.appendingPathComponent("shared.md"))
            try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: "../shared.md")
        case "outside":
            let outside = fixture.appendingPathComponent("outside.md")
            try Data(skillText(name: "Outside", description: "Must not be read through discovery.").utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: outside)
            outsidePath = outside.path
        case "broken":
            try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: "../missing.md")
        default:
            try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: "other")
            try FileManager.default.createSymbolicLink(
                atPath: skill.appendingPathComponent("other").path, withDestinationPath: "SKILL.md"
            )
        }

        let live = ManifestReadAccess()
        var reads: [String] = []
        let readAccess = ManifestReadAccess(dataContents: { url in
            reads.append(url.path)
            #expect(url.path != outsidePath)
            return try live.data(at: url)
        })
        let result = LocalSourceIndexer(readAccess: readAccess).index(directory: source, sourceID: UUID())
        let candidate = try #require(result.availableSkills.first { $0.skillPath == "candidate" })

        Attachment.record(Data(reads.joined(separator: "\n").utf8), named: "linked-entry-read-set-\(mode).txt")
        #expect(result.isPlannable)
        #expect(candidate.checkStatus == (mode == "inside" ? .warning : .blocked))
        #expect(mode != "inside" || candidate.validation.risks.contains { $0.id == "linked-skill-entry" })
    }

    @Test(arguments: ["budget", "cancel"])
    func localSourceIndexerReportsBoundedAndCancelledScansAsIncomplete(mode: String) throws {
        let source = try temporaryDirectory()
        try writeSkill(source.appendingPathComponent("one/two", isDirectory: true), name: "Review", description: "Nested candidate.")
        var cancellationChecks = 0
        let indexer = LocalSourceIndexer(
            maximumVisitedNodeCount: mode == "budget" ? 1 : 100_000,
            isCancelled: {
                cancellationChecks += 1
                return mode == "cancel" && cancellationChecks > 1
            }
        )

        let result = indexer.index(directory: source, sourceID: UUID())
        let expected: LocalSourceObservationReason = mode == "budget" ? .traversalBudgetExceeded : .scanCancelled

        #expect(result.source.isIndexIncomplete)
        #expect(result.source.indexStatusReason == expected.rawValue)
        #expect(result.observations.contains { $0.reason == expected })
        #expect(result.isPlannable == false)
    }

    @Test func localSourceIndexerRejectsSourceReplacementDuringDiscovery() throws {
        let fixture = try sourceDiscoveryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        try writeSkill(source, name: "Original", description: "Original source identity.")
        let live = SourceTraversalAccess()
        var replaced = false
        let traversal = SourceTraversalAccess(contentsOfDirectory: { url in
            let children = try live.contentsOfDirectory(at: url)
            if url.standardizedFileURL == source.standardizedFileURL, !replaced {
                replaced = true
                try FileManager.default.moveItem(at: source, to: fixture.appendingPathComponent("old-source"))
                try writeSkill(source, name: "Replacement", description: "Replacement source identity.")
            }
            return children
        })

        let result = LocalSourceIndexer(traversal: traversal).index(directory: source, sourceID: UUID())

        #expect(result.source.isIndexIncomplete)
        #expect(result.observations.contains { $0.reason == .sourceChanged })
        #expect(result.isPlannable == false)
    }

    @Test func contentManifestBuilderRejectsEnumerationThatStopsEarly() throws {
        let candidate = try temporaryDirectory()
        let nested = candidate.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("complete".utf8).write(to: nested.appendingPathComponent("entry.txt"))
        let live = ManifestReadAccess()
        let observedNested = try #require(
            live.contentsOfDirectory(at: candidate).first { $0.lastPathComponent == nested.lastPathComponent }
        )
        let readAccess = ManifestReadAccess(contentsOfDirectory: { url in
            if url.lastPathComponent == nested.lastPathComponent {
                throw SourceTraversalTestError.denied
            }
            return try live.contentsOfDirectory(at: url)
        })

        #expect(throws: ContentManifestFailure.readFailed(
            path: observedNested.path,
            stage: .enumeration
        )) {
            _ = try ContentManifestBuilder(readAccess: readAccess).build(
                for: candidate,
                authorizedRoot: candidate
            )
        }
    }

    @Test func contentManifestBuilderReportsAttributeAndContentReadStages() throws {
        let candidate = try temporaryDirectory()
        let file = candidate.appendingPathComponent("entry.txt")
        try Data("complete".utf8).write(to: file)
        let live = ManifestReadAccess()
        let observedFile = try #require(
            live.contentsOfDirectory(at: candidate).first { $0.lastPathComponent == file.lastPathComponent }
        )
        let attributesDenied = ManifestReadAccess(resourceValues: { url, keys in
            if url.lastPathComponent == file.lastPathComponent {
                throw SourceTraversalTestError.denied
            }
            return try live.resourceValues(at: url, forKeys: keys)
        })

        #expect(throws: ContentManifestFailure.readFailed(
            path: observedFile.path,
            stage: .attributes
        )) {
            _ = try ContentManifestBuilder(readAccess: attributesDenied).build(
                for: candidate,
                authorizedRoot: candidate
            )
        }

        let contentDenied = ManifestReadAccess(dataContents: { url in
            if url.lastPathComponent == file.lastPathComponent {
                throw SourceTraversalTestError.denied
            }
            return try live.data(at: url)
        })

        #expect(throws: ContentManifestFailure.readFailed(
            path: observedFile.path,
            stage: .content
        )) {
            _ = try ContentManifestBuilder(readAccess: contentDenied).build(
                for: candidate,
                authorizedRoot: candidate
            )
        }
    }

    @Test func contentManifestBuilderRejectsUnknownNodesAndCaseInsensitiveConflicts() throws {
        let candidate = try temporaryDirectory()
        let fifo = candidate.appendingPathComponent("events.pipe")
        #expect(mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0)
        let observedFIFO = try #require(
            ManifestReadAccess().contentsOfDirectory(at: candidate).first { $0.lastPathComponent == fifo.lastPathComponent }
        )

        #expect(throws: ContentManifestFailure.unsupportedNode(path: observedFIFO.path)) {
            _ = try ContentManifestBuilder().build(for: candidate, authorizedRoot: candidate)
        }

        let first = candidate.appendingPathComponent("README.md")
        let second = candidate.appendingPathComponent("readme.md")
        let live = ManifestReadAccess()
        let conflicting = ManifestReadAccess(contentsOfDirectory: { url in
            if url.standardizedFileURL.path == candidate.standardizedFileURL.path {
                return [first, second]
            }
            return try live.contentsOfDirectory(at: url)
        })

        #expect(throws: ContentManifestFailure.caseInsensitiveConflict(
            directoryPath: candidate.path,
            names: ["README.md", "readme.md"]
        )) {
            _ = try ContentManifestBuilder(readAccess: conflicting).build(
                for: candidate,
                authorizedRoot: candidate
            )
        }
    }

    @Test func contentManifestBuilderRejectsSymbolicLinkOutsideAuthorizedRoot() throws {
        let candidate = try temporaryDirectory()
        let outside = try temporaryDirectory().appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let link = candidate.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let observedLink = try #require(
            ManifestReadAccess().contentsOfDirectory(at: candidate).first { $0.lastPathComponent == link.lastPathComponent }
        )

        #expect(throws: FileAccessFailure.symlinkEscapesRoot(path: observedLink.path)) {
            _ = try ContentManifestBuilder().build(for: candidate, authorizedRoot: candidate)
        }
    }

    @Test func completeSourceBaselineRecordsExternalSymbolicLinkWithoutReadingItsTarget() throws {
        let candidate = try temporaryDirectory()
        let outside = try temporaryDirectory().appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let link = candidate.appendingPathComponent("shared-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let manifest = try ContentManifestBuilder().build(
            for: candidate,
            authorizedRoot: candidate,
            allowExternalSymbolicLinks: true
        )

        let entry = try #require(manifest.entries.first { $0.relativePath == "shared-link" })
        #expect(entry.kind == .symbolicLink)
        #expect(entry.symbolicLinkTarget == outside.path)
        #expect(entry.byteDigest == nil)
    }

    @Test func contentManifestBuilderValidatesTheSameSymbolicLinkTargetItRecords() throws {
        let candidate = try temporaryDirectory()
        let safeFile = candidate.appendingPathComponent("safe.txt")
        try Data("safe".utf8).write(to: safeFile)
        let link = candidate.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "safe.txt")
        let outside = try temporaryDirectory().appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let live = ManifestReadAccess()
        let observedLink = try #require(
            live.contentsOfDirectory(at: candidate).first { $0.lastPathComponent == link.lastPathComponent }
        )
        let readAccess = ManifestReadAccess(symlinkDestination: { url in
            if url.lastPathComponent == link.lastPathComponent {
                return outside.path
            }
            return try live.destinationOfSymbolicLink(at: url)
        })

        #expect(throws: FileAccessFailure.symlinkEscapesRoot(path: observedLink.path)) {
            _ = try ContentManifestBuilder(readAccess: readAccess).build(
                for: candidate,
                authorizedRoot: candidate
            )
        }
    }

    @Test func contentManifestBuilderReturnsCanonicalCompleteNodeSetAndDigest() throws {
        let candidate = try temporaryDirectory()
        let file = candidate.appendingPathComponent("data.txt")
        let link = candidate.appendingPathComponent("data-link")
        let bytes = Data("complete".utf8)
        try bytes.write(to: file)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "data.txt")

        let manifest = try ContentManifestBuilder().build(for: candidate, authorizedRoot: candidate)
        let byteDigest = SHA256Digest.hex(bytes)
        let expectedEntries = [
            ContentManifestEntry(
                relativePath: ".",
                kind: .directory,
                byteDigest: nil,
                symbolicLinkTarget: nil,
                isExecutable: false,
                byteCount: 0
            ),
            ContentManifestEntry(
                relativePath: "data-link",
                kind: .symbolicLink,
                byteDigest: nil,
                symbolicLinkTarget: "data.txt",
                isExecutable: false,
                byteCount: 0
            ),
            ContentManifestEntry(
                relativePath: "data.txt",
                kind: .file,
                byteDigest: byteDigest,
                symbolicLinkTarget: nil,
                isExecutable: false,
                byteCount: Int64(bytes.count)
            )
        ]
        let digestEncoder = JSONEncoder()
        digestEncoder.outputFormatting = [.sortedKeys]
        let expectedPayload = try digestEncoder.encode(expectedEntries)

        #expect(manifest.entries == expectedEntries)
        #expect(manifest.fileCount == 1)
        #expect(manifest.totalByteCount == Int64(bytes.count))
        #expect(manifest.digest == SHA256Digest.hex(expectedPayload))
    }

    @Test func contentManifestDigestDoesNotCollideOnPathsContainingDelimiters() throws {
        let unambiguous = try temporaryDirectory()
        // A path literally containing the former "|" delimiter and an embedded newline.
        try Data("first".utf8).write(to: unambiguous.appendingPathComponent("a|b\nc.txt"))
        try Data("second".utf8).write(to: unambiguous.appendingPathComponent("d.txt"))

        let colliding = try temporaryDirectory()
        // Same bytes, but a naive "|"/newline join could concatenate to the identical payload.
        try Data("first".utf8).write(to: colliding.appendingPathComponent("a|b.txt"))
        try Data("second".utf8).write(to: colliding.appendingPathComponent("c\nd.txt"))

        let builder = ContentManifestBuilder()
        let first = try builder.build(for: unambiguous, authorizedRoot: unambiguous)
        let second = try builder.build(for: colliding, authorizedRoot: colliding)

        #expect(first.digest != second.digest)
    }

    @Test func contentManifestIncludesPackageContentsAndDetectsTheirChanges() throws {
        let candidate = try sourceDiscoveryDirectory()
        defer { try? FileManager.default.removeItem(at: candidate) }
        let package = candidate.appendingPathComponent("Tool.app/Contents")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("payload")
        try Data("before".utf8).write(to: file)
        try Data("normalized".utf8).write(to: package.appendingPathComponent("e\u{301}.txt"))
        let builder = ContentManifestBuilder()
        let before = try builder.build(for: candidate, authorizedRoot: candidate)
        #expect(before.entries.contains { $0.relativePath == "Tool.app/Contents/payload" })
        #expect(before.entries.contains { $0.relativePath == "Tool.app/Contents/é.txt" })
        #expect(try builder.build(for: candidate, authorizedRoot: candidate).digest == before.digest)

        try Data("after".utf8).write(to: file)
        #expect(try builder.build(for: candidate, authorizedRoot: candidate).digest != before.digest)
    }

    @Test func contentManifestResolvesParentLinksThroughReadAccess() throws {
        let fixture = try sourceDiscoveryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        let candidate = source.appendingPathComponent("candidate")
        let outside = fixture.appendingPathComponent("outside")
        for directory in [candidate, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let alias = source.appendingPathComponent("alias")
        let link = candidate.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../alias/payload")
        let live = ManifestReadAccess()
        var links: [URL] = []
        let access = ManifestReadAccess(
            resourceValues: { url, keys in
                #expect(url.path == source.path || url.path.hasPrefix(source.path + "/"))
                return try live.resourceValues(at: url, forKeys: keys)
            },
            symlinkDestination: { url in
                links.append(url)
                return try live.destinationOfSymbolicLink(at: url)
            }
        )
        #expect(throws: FileAccessFailure.symlinkEscapesRoot(path: link.path)) {
            try ContentManifestBuilder(readAccess: access).build(for: candidate, authorizedRoot: source)
        }
        #expect(links.contains(alias))
        Attachment.record(Data(links.map(\.path).joined(separator: "\n").utf8), named: "parent-symlink-read-set.txt")
    }

    @Test(arguments: [false, true])
    func sourceStaticReadFailureAndDriftRemainDistinct(denyRead: Bool) throws {
        let source = try sourceDiscoveryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        try writeSkill(source, name: "Review", description: "Checks the current static content.")
        let live = ManifestReadAccess()
        var entryReads = 0
        let access = ManifestReadAccess(dataContents: { url in
            if url.lastPathComponent == "SKILL.md" {
                entryReads += 1
                if entryReads == 2 {
                    if denyRead { throw CocoaError(.fileReadNoPermission) }
                    return try live.data(at: url) + Data("Changed".utf8)
                }
            }
            return try live.data(at: url)
        })
        let result = LocalSourceIndexer(readAccess: access).index(directory: source)
        let observation = try #require(result.observations.first { $0.relativePath == "." })
        let candidate = try #require(result.availableSkills.first { $0.skillPath == "." })
        #expect(observation.status == (denyRead ? .unreadable : .blocked))
        #expect(candidate.checkStatus == observation.status)
        #expect(entryReads == 2)
    }

    @Test func managedCopyPlannerRejectsManifestReadFailure() throws {
        let sourceRoot = try temporaryDirectory()
        let candidateURL = sourceRoot.appendingPathComponent("review", isDirectory: true)
        try writeSkill(candidateURL, name: "Review", description: "Reviews local skills safely.")
        let indexed = LocalSourceIndexer().index(directory: sourceRoot, sourceID: UUID())
        let source = indexed.source
        let candidate = try #require(indexed.availableSkills.first)
        let skillFile = candidateURL.appendingPathComponent("SKILL.md")
        let live = ManifestReadAccess()
        let observedSkillFile = try #require(
            live.contentsOfDirectory(at: candidateURL).first { $0.lastPathComponent == skillFile.lastPathComponent }
        )
        let contentDenied = ManifestReadAccess(dataContents: { url in
            if url.lastPathComponent == skillFile.lastPathComponent {
                throw SourceTraversalTestError.denied
            }
            return try live.data(at: url)
        })
        let root = try temporaryDirectory()
        let snapshot = RootSnapshot(
            metadata: SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)),
            generation: 0,
            metadataDigest: "metadata"
        )

        #expect(throws: ContentManifestFailure.readFailed(
            path: observedSkillFile.path,
            stage: .content
        )) {
            _ = try Phase1OperationPlanner(
                manifestBuilder: ContentManifestBuilder(readAccess: contentDenied)
            ).managedCopyPlan(
                candidate: candidate,
                source: source,
                rootURL: root,
                snapshot: snapshot
            )
        }

        try Data("drift".utf8).write(to: candidateURL.appendingPathComponent("changed.txt"))
        #expect(throws: Phase1OperationError.sourceChanged) {
            _ = try Phase1OperationPlanner().managedCopyPlan(
                candidate: candidate,
                source: source,
                rootURL: root,
                snapshot: snapshot
            )
        }
    }

    @Test func userHomeResolverPrefersLoginHomeOverSandboxContainerHome() {
        let sandboxHome = URL(fileURLWithPath: "/Users/test/Library/Containers/me.ledar.SkillsHub/Data", isDirectory: true)
        let loginHome = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resolver = UserHomeDirectoryResolver()

        let resolved = resolver.homeDirectory(
            environment: ["HOME": sandboxHome.path],
            fileManagerHomeDirectory: sandboxHome,
            posixHomeDirectory: loginHome
        )

        #expect(resolved.path == "/Users/test")
    }

    @Test func userHomeResolverStripsSandboxContainerWhenPOSIXHomeIsUnavailable() {
        let sandboxHome = URL(fileURLWithPath: "/Users/test/Library/Containers/me.ledar.SkillsHub/Data", isDirectory: true)
        let resolver = UserHomeDirectoryResolver()

        let resolved = resolver.homeDirectory(
            environment: ["HOME": sandboxHome.path],
            fileManagerHomeDirectory: sandboxHome,
            posixHomeDirectory: nil
        )

        #expect(resolved.path == "/Users/test")
    }

    @Test func agentLinkResolverCoversBuiltInGlobalPaths() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resolver = AgentPathResolver()
        #expect(resolver.globalSkillsDirectory(for: .claudeCode, environment: [:], homeDirectory: home).path == "/Users/test/.claude/skills")
        #expect(resolver.globalSkillsDirectory(for: .claudeCode, environment: ["CLAUDE_CONFIG_DIR": "/configured/claude"], homeDirectory: home).path == "/configured/claude/skills")
        #expect(resolver.globalSkillsDirectory(for: .codex, environment: ["CODEX_HOME": "/tmp/codex"], homeDirectory: home).path == "/tmp/codex/skills")
        #expect(resolver.globalSkillsDirectory(for: .codex, environment: [:], homeDirectory: home).path == "/Users/test/.codex/skills")
    }

    @Test func sourceUpdatePreviewUsesThreeCompleteManifestsAndIncludesEveryEnabledAgent() {
        let sourceID = UUID()
        let assetID = UUID()
        let currentIdentity = TargetFileIdentity(volumeNumber: 1, fileNumber: 2)
        let preparedIdentity = TargetFileIdentity(volumeNumber: 1, fileNumber: 3)
        let baseline = manifest([
            manifestEntry("SKILL.md", digest: "a", bytes: 4),
            manifestEntry("tool", digest: "tool", bytes: 4)
        ], digest: "baseline")
        let current = manifest([
            manifestEntry("SKILL.md", digest: "b", bytes: 4),
            manifestEntry("tool", digest: "tool", executable: true, bytes: 4),
            ContentManifestEntry(relativePath: "alias", kind: .symbolicLink, byteDigest: nil, symbolicLinkTarget: "tool", isExecutable: false, byteCount: 0)
        ], digest: "current")
        let prepared = manifest([
            manifestEntry("SKILL.md", digest: "c", bytes: 4),
            manifestEntry("nested/SKILL.md", digest: "new", bytes: 8)
        ], digest: "prepared")
        let source = SkillSource(
            id: sourceID,
            kind: .githubRepository,
            name: "acme/skills",
            localPath: "/root/github/acme/skills",
            baselineManifest: baseline
        )
        let installed = InstalledSkill(
            id: "review",
            sourceID: sourceID,
            name: "Review",
            description: "Reviews changes.",
            installedPath: "/root/github/acme/skills",
            sourceKind: .githubRepository,
            validation: .valid,
            purpose: nil,
            tagIDs: [],
            installedAt: .distantPast,
            assetID: assetID
        )
        let oldCandidate = AvailableSkill(
            id: "review", sourceID: sourceID, skillPath: ".", name: "Review",
            description: "Old", validation: .valid, candidateID: "review", manifestDigest: "b"
        )
        let newCandidate = AvailableSkill(
            id: "review", sourceID: sourceID, skillPath: ".", name: "Renamed",
            description: "New", validation: .valid, candidateID: "review", manifestDigest: "c"
        )
        let addedCandidate = AvailableSkill(
            id: "new", sourceID: sourceID, skillPath: "nested", name: "New",
            description: "Added", validation: .valid, candidateID: "new", manifestDigest: "new"
        )

        let preview = SourceUpdateService().preview(
            id: UUID(),
            source: source,
            currentSourceIdentity: currentIdentity,
            currentManifest: current,
            preparedPath: "/staging/prepared",
            preparedSourceIdentity: preparedIdentity,
            preparedRevision: String(repeating: "c", count: 40),
            preparedManifest: prepared,
            currentCandidates: [oldCandidate],
            preparedCandidates: [newCandidate, addedCandidate],
            installedSkills: [installed],
            enablementIntents: [
                EnablementIntent(assetID: assetID, agentID: AgentKind.codex.rawValue, scope: .global, isEnabled: true, generation: 1),
                EnablementIntent(assetID: assetID, agentID: AgentKind.claudeCode.rawValue, scope: .global, isEnabled: true, generation: 1),
                EnablementIntent(assetID: assetID, agentID: "custom", scope: .global, isEnabled: true, generation: 1)
            ],
            agents: [.builtIn(.codex), .builtIn(.claudeCode), AgentConfigurationRecord(id: "custom", agent: nil, displayName: "My Agent")],
            metadataGeneration: 4,
            metadataDigest: "metadata"
        )

        #expect(preview.confirmationKind == .overwriteLocalChanges)
        #expect(preview.localChanges.map(\.path) == ["SKILL.md", "alias", "tool"])
        #expect(preview.incomingChanges.map(\.path) == ["SKILL.md", "alias", "nested/SKILL.md", "tool"])
        #expect(preview.skillChanges.map(\.path) == [".", "nested"])
        #expect(preview.skillChanges.map(\.kind) == [.modified, .added])
        #expect(preview.agentImpacts.first?.assetID == assetID)
        #expect(preview.agentImpacts.first?.agentIDs == ["claudeCode", "codex", "custom"])
        #expect(preview.agentImpacts.first?.agentNames == ["Claude Code", "Codex", "My Agent"])
        #expect(preview.currentSourceIdentity == currentIdentity)
        #expect(preview.preparedSourceIdentity == preparedIdentity)
        #expect(preview.currentManifest == current)
        #expect(preview.source.baselineManifest == baseline)
    }

    @Test func sourceUpdatePreviewKeepsUnknownBaselineDistinctFromNoLocalChanges() {
        let content = manifest([manifestEntry("SKILL.md", digest: "same", bytes: 4)], digest: "same")
        let source = SkillSource(kind: .localDirectory, name: "Unknown baseline", localPath: "/root/local/unknown")
        let identity = TargetFileIdentity(volumeNumber: 1, fileNumber: 2)
        let preview = SourceUpdateService().preview(
            id: UUID(), source: source, currentSourceIdentity: identity, currentManifest: content,
            preparedPath: "/staging/prepared", preparedSourceIdentity: identity,
            preparedRevision: nil, preparedManifest: content, currentCandidates: [], preparedCandidates: [],
            installedSkills: [], enablementIntents: [], agents: [], metadataGeneration: 1, metadataDigest: "metadata"
        )

        #expect(preview.hasUnknownBaseline)
        #expect(preview.confirmationKind == .replaceUnknownBaseline)
        #expect(preview.localChanges.isEmpty)
        #expect(!preview.hasIncomingChanges)
    }

    @MainActor
    @Test func localSourceUpdatePreparationIsStableCancelableAndReadOnly() async throws {
        let root = try temporaryDirectory().resolvingSymlinksInPath()
        let external = try temporaryDirectory().resolvingSymlinksInPath()
        let appSupport = try temporaryDirectory().resolvingSymlinksInPath()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
            try? FileManager.default.removeItem(at: appSupport)
        }
        let managed = root.appendingPathComponent("local/source", isDirectory: true)
        try writeSkill(managed, name: "Managed", description: "Initial")
        try writeSkill(external, name: "Managed", description: "Initial")
        let builder = ContentManifestBuilder()
        let baseline = try builder.build(for: managed, authorizedRoot: managed)
        try writeSkill(managed, name: "Managed", description: "Local edit")
        try writeSkill(external, name: "Managed", description: "Upstream edit")
        let managedBefore = try builder.build(for: managed, authorizedRoot: managed)
        let externalBefore = try builder.build(for: external, authorizedRoot: external)
        let identity = try LinkNodeIdentity.read(at: managed).file
        let source = SkillSource(
            kind: .localDirectory,
            name: "Source",
            localPath: managed.path,
            externalLocalPath: external.path,
            directoryIdentity: identity,
            baselineManifest: baseline
        )
        let index = LocalSourceIndexer().index(directory: managed, sourceID: source.id)
        let store = SkillsHubMetadataStore()
        try store.save(
            SkillsHubMetadata(
                rootConfig: RootConfig(rootPath: root.path),
                sources: [source],
                availableSkills: index.availableSkills
            ),
            to: root
        )
        let controller = SkillsHubLibraryController(
            appSupportURL: appSupport,
            securityScopedAccessProvider: SecurityScopedAccessProvider(
                adapter: RecordingSecurityScopedResourceAccessAdapter()
            )
        )
        try await connectInitializedTestRoot(controller, at: root)
        let metadataURL = store.rootLayout(for: root).skillshubMetadataFile
        let metadataBefore = try Data(contentsOf: metadataURL)

        try await controller.prepareSourceUpdate(sourceID: source.id)

        let preview = try #require(controller.sourceUpdatePreview)
        #expect(preview.confirmationKind == .overwriteLocalChanges)
        #expect(preview.hasIncomingChanges)
        #expect(try builder.build(for: managed, authorizedRoot: managed).digest == managedBefore.digest)
        #expect(try builder.build(for: external, authorizedRoot: external).digest == externalBefore.digest)
        #expect(try Data(contentsOf: metadataURL) == metadataBefore)
        let preparedPath = try #require(preview.preparedPath)
        #expect(FileManager.default.fileExists(atPath: preparedPath))

        controller.cancelSourceUpdatePreview(preview)

        #expect(controller.sourceUpdatePreview == nil)
        #expect(!FileManager.default.fileExists(atPath: preparedPath))
        #expect(controller.sources.first?.baselineManifest?.digest == baseline.digest)
        #expect(try Data(contentsOf: metadataURL) == metadataBefore)
    }

    @MainActor
    @Test func updateCheckReportsPartialFailureWithoutPresentingOrApplyingPreview() async throws {
        let fixture = try sourceUpdateFixture()
        defer { fixture.remove() }
        let controller = SkillsHubLibraryController(appSupportURL: fixture.appSupport,
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: RecordingSecurityScopedResourceAccessAdapter()))
        try await connectInitializedTestRoot(controller, at: fixture.root)
        controller.language = .english
        let metadata = fixture.store.rootLayout(for: fixture.root).skillshubMetadataFile
        let before = try Data(contentsOf: metadata)
        let builder = ContentManifestBuilder()
        let content = try builder.build(for: fixture.managed, authorizedRoot: fixture.managed)
        let unknownSource = UUID()
        await controller.checkSourceUpdates([fixture.sourceID, unknownSource])
        #expect(controller.sourceUpdatePreview == nil)
        #expect(controller.sourceUpdateChecks[fixture.sourceID] == true)
        #expect(controller.sourceUpdateFailures[unknownSource] != nil)
        #expect(controller.checkingSourceIDs.isEmpty)
        let summary = try #require(controller.updateCheckSummary)
        #expect(controller.localized(summary) == "Checked 2 sources: 1 updates, 1 failures.")
        controller.language = .chinese
        #expect(controller.localized(summary) == "已检查 2 个来源：1 个有更新，1 个失败。")
        controller.language = .japanese
        #expect(controller.localized(summary) == "2 件のソースを確認：更新 1 件、失敗 1 件。")
        #expect(try Data(contentsOf: metadata) == before)
        #expect(try builder.build(for: fixture.managed, authorizedRoot: fixture.managed).digest == content.digest)
        let staging = fixture.appSupport.appendingPathComponent("SourceUpdateStaging")
        let remaining = try FileManager.default.fileExists(atPath: staging.path) ? FileManager.default.contentsOfDirectory(atPath: staging.path) : []
        #expect(remaining.isEmpty)
    }

    @MainActor
    @Test func singleSourceRecheckDoesNotInspectOtherSourcesOrWriteMetadata() async throws {
        let fixture = try sourceUpdateFixture()
        defer { fixture.remove() }
        let controller = SkillsHubLibraryController(appSupportURL: fixture.appSupport,
            securityScopedAccessProvider: SecurityScopedAccessProvider(adapter: RecordingSecurityScopedResourceAccessAdapter()))
        try await connectInitializedTestRoot(controller, at: fixture.root)
        var unrelated = try #require(controller.installedSkills.first)
        unrelated.id = "unrelated"
        unrelated.assetID = UUID()
        unrelated.sourceID = UUID()
        unrelated.installedPath = fixture.root.appendingPathComponent("nonexistent-other-source").path
        controller.installedSkills.append(unrelated)
        let before = try Data(contentsOf: fixture.store.rootLayout(for: fixture.root).skillshubMetadataFile)
        let added = fixture.managed.appendingPathComponent("newly-discovered", isDirectory: true)
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: false)
        try Data("---\nname: Newly Discovered\ndescription: Source recheck fixture.\n---\n".utf8).write(to: added.appendingPathComponent("SKILL.md"))
        try await controller.recheckSource(fixture.sourceID)
        #expect(controller.availableSkills.contains { $0.sourceID == fixture.sourceID && $0.skillPath == "newly-discovered" })
        #expect(controller.installedSkills.first { $0.id == unrelated.id } == unrelated)
        #expect(controller.sourceRecheckResults[fixture.sourceID] != nil)
        #expect(controller.sourceRecheckResults[unrelated.sourceID!] == nil)
        #expect(controller.recheckingSourceIDs.isEmpty)
        #expect(try Data(contentsOf: fixture.store.rootLayout(for: fixture.root).skillshubMetadataFile) == before)
    }

    @MainActor
    @Test func confirmedSourceUpdateSwitchesWholeTreePreservesIdentityAndCommitsBaseline() async throws {
        let fixture = try sourceUpdateFixture()
        defer { fixture.remove() }
        let service = SourceUpdateService(trashItem: { retained in
            try FileManager.default.createDirectory(at: fixture.trash, withIntermediateDirectories: true)
            let destination = fixture.trash.appendingPathComponent("old", isDirectory: true)
            try FileManager.default.moveItem(at: retained, to: destination)
            return destination
        })
        let controller = SkillsHubLibraryController(
            sourceUpdateService: service,
            appSupportURL: fixture.appSupport,
            securityScopedAccessProvider: SecurityScopedAccessProvider(
                adapter: RecordingSecurityScopedResourceAccessAdapter()
            )
        )
        try await connectInitializedTestRoot(controller, at: fixture.root)

        try await controller.prepareSourceUpdate(sourceID: fixture.sourceID)
        let preview = try #require(controller.sourceUpdatePreview)
        let before = try fixture.store.loadCurrentSnapshot(from: fixture.root)
        #expect(before.generation == preview.metadataGeneration)
        #expect(before.metadataDigest == preview.metadataDigest)
        #expect(before.metadata.sources.first { $0.id == fixture.sourceID } == preview.source)
        #expect(try LinkNodeIdentity.read(at: fixture.root).file == preview.rootIdentity)
        #expect(try LinkNodeIdentity.read(at: fixture.managed).file == preview.currentSourceIdentity)
        let prepared = URL(fileURLWithPath: try #require(preview.preparedPath))
        #expect(try LinkNodeIdentity.read(at: prepared).file == preview.preparedSourceIdentity)
        let builder = ContentManifestBuilder()
        #expect(try builder.build(for: fixture.managed, authorizedRoot: fixture.managed, allowExternalSymbolicLinks: true).digest == preview.currentManifest.digest)
        #expect(try builder.build(for: prepared, authorizedRoot: prepared, allowExternalSymbolicLinks: true).digest == preview.preparedManifest.digest)
        #expect(controller.sourceUpdatePreview == preview)
        let result: SourceUpdateResult
        do {
            result = try await controller.applySourceUpdate(using: preview)
        } catch {
            Issue.record("Source update unexpectedly failed: \(error)")
            return
        }

        let snapshot = try fixture.store.loadCurrentSnapshot(from: fixture.root)
        let updatedSource = try #require(snapshot.metadata.sources.first { $0.id == fixture.sourceID })
        let preserved = try #require(snapshot.metadata.installedSkills.first { $0.installedPath == fixture.managed.path })
        #expect(result.updateSucceeded)
        #expect(result.oldContentMovedToTrash)
        #expect(updatedSource.baselineManifest?.digest == preview.preparedManifest.digest)
        #expect(preserved.assetID == fixture.assetID)
        #expect(preserved.stableLinkName == "Stable")
        #expect(snapshot.metadata.enablementIntents.first?.assetID == fixture.assetID)
        #expect(snapshot.metadata.installedSkills.count == 2)
        #expect(try String(contentsOf: fixture.managed.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("Upstream"))
        #expect(try String(contentsOf: fixture.trash.appendingPathComponent("old/SKILL.md"), encoding: .utf8).contains("Old"))
        #expect(try service.loadRecord(operationID: preview.id, rootURL: fixture.root).stage == .completed)
    }

    @MainActor
    @Test func changedFactsInvalidateSourceUpdateBeforeExchange() async throws {
        let fixture = try sourceUpdateFixture()
        defer { fixture.remove() }
        let controller = SkillsHubLibraryController(
            sourceUpdateService: SourceUpdateService(trashItem: { _ in throw SourceRemovalTestError.trashFailure }),
            appSupportURL: fixture.appSupport,
            securityScopedAccessProvider: SecurityScopedAccessProvider(
                adapter: RecordingSecurityScopedResourceAccessAdapter()
            )
        )
        try await connectInitializedTestRoot(controller, at: fixture.root)
        try await controller.prepareSourceUpdate(sourceID: fixture.sourceID)
        let preview = try #require(controller.sourceUpdatePreview)
        try writeSkill(fixture.managed, name: "Stable", description: "Changed after confirmation")

        await #expect(throws: SourceUpdateError.confirmationChanged) {
            _ = try await controller.applySourceUpdate(using: preview)
        }

        #expect(try fixture.store.loadCurrentSnapshot(from: fixture.root).metadata.sources.first?.baselineManifest?.digest == fixture.baseline.digest)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".skillshub-operations/\(preview.id.uuidString)").path))
    }

    @MainActor
    @Test func trashFailureKeepsSuccessfulUpdateAndRecoveryMaterialDistinct() async throws {
        let fixture = try sourceUpdateFixture()
        defer { fixture.remove() }
        let service = SourceUpdateService(trashItem: { _ in throw SourceRemovalTestError.trashFailure })
        let controller = SkillsHubLibraryController(
            sourceUpdateService: service,
            appSupportURL: fixture.appSupport,
            securityScopedAccessProvider: SecurityScopedAccessProvider(
                adapter: RecordingSecurityScopedResourceAccessAdapter()
            )
        )
        try await connectInitializedTestRoot(controller, at: fixture.root)
        try await controller.prepareSourceUpdate(sourceID: fixture.sourceID)
        let preview = try #require(controller.sourceUpdatePreview)

        let result = try await controller.applySourceUpdate(using: preview)
        let record = try service.loadRecord(operationID: preview.id, rootURL: fixture.root)

        #expect(result.updateSucceeded)
        #expect(!result.oldContentMovedToTrash)
        #expect(record.stage == .needsAttention)
        #expect(record.metadataGeneration != nil)
        #expect(record.retainedPath.map(FileManager.default.fileExists(atPath:)) == true)
        #expect(try fixture.store.loadCurrentSnapshot(from: fixture.root).metadata.sources.first?.baselineManifest?.digest == preview.preparedManifest.digest)
    }

    @MainActor
    @Test func metadataFailureKeepsSwitchedTreesAndDoesNotAdvanceBaseline() async throws {
        let fixture = try sourceUpdateFixture()
        defer { fixture.remove() }
        let store = SkillsHubMetadataStore(writeCheckpoint: { phase, _ in
            if phase == .encoding { throw SourceRemovalTestError.metadataFailure }
        })
        let service = SourceUpdateService(trashItem: { _ in throw SourceRemovalTestError.trashFailure })
        let controller = SkillsHubLibraryController(
            metadataStore: store,
            sourceUpdateService: service,
            appSupportURL: fixture.appSupport,
            securityScopedAccessProvider: SecurityScopedAccessProvider(
                adapter: RecordingSecurityScopedResourceAccessAdapter()
            )
        )
        try await connectInitializedTestRoot(controller, at: fixture.root)
        try await controller.prepareSourceUpdate(sourceID: fixture.sourceID)
        let preview = try #require(controller.sourceUpdatePreview)

        let result = try await controller.applySourceUpdate(using: preview)
        let record = try service.loadRecord(operationID: preview.id, rootURL: fixture.root)

        #expect(result.contentApplied)
        #expect(!result.metadataCommitted)
        #expect(record.stage == .needsAttention)
        #expect(record.retainedPath.map(FileManager.default.fileExists(atPath:)) == true)
        #expect(try fixture.store.loadCurrentSnapshot(from: fixture.root).metadata.sources.first?.baselineManifest?.digest == fixture.baseline.digest)

        let metadataFile = fixture.store.rootLayout(for: fixture.root).skillshubMetadataFile
        let recordFile = fixture.root.appendingPathComponent(
            ".skillshub-operations/\(preview.id.uuidString)/source-update.json"
        )
        let metadataBeforeRecheck = try Data(contentsOf: metadataFile)
        let recordBeforeRecheck = try Data(contentsOf: recordFile)
        let restarted = SkillsHubLibraryController(appSupportURL: fixture.appSupport)
        try await connectInitializedTestRoot(restarted, at: fixture.root)
        await restarted.recheckRecoveryTasks()

        let recovered = try #require(restarted.phase1Tasks.first { $0.id == preview.id })
        #expect(recovered.kind == .updateSource)
        #expect(recovered.recoveryEvidence?.components.first { $0.kind == "content" }?.state == .completed)
        #expect(recovered.recoveryEvidence?.components.first { $0.kind == "metadata" }?.state == .notCompleted)
        #expect(recovered.recoveryEvidence?.components.first { $0.kind == "success-baseline" }?.state == .notCompleted)
        #expect(recovered.recoveryEvidence?.components.first { $0.kind == "old-content-disposal" }?.state == .notCompleted)
        #expect(try Data(contentsOf: metadataFile) == metadataBeforeRecheck)
        #expect(try Data(contentsOf: recordFile) == recordBeforeRecheck)
    }

}

private struct SourceRemovalFixture {
    var root: URL
    var source: URL
    var external: URL
    var store: SkillsHubMetadataStore
    var plan: SourceRemovalPlan
}

private func sourceRemovalFixture(kind: SkillSourceKind = .localDirectory) throws -> SourceRemovalFixture {
    let root = try temporaryDirectory().resolvingSymlinksInPath()
    let source = root.appendingPathComponent(
        kind == .githubRepository ? "github/acme/source" : "local/source",
        isDirectory: true
    )
    let external = root.appendingPathComponent("external", isDirectory: true)
    try writeSkill(source, name: "Source", description: "Whole source removal fixture.")
    let child = source.appendingPathComponent("child", isDirectory: true)
    try writeSkill(child, name: "Child", description: "Second skill in the same source.")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try Data("external".utf8).write(to: external.appendingPathComponent("marker"))
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    let identity = TargetFileIdentity(
        volumeNumber: try #require((attributes[.systemNumber] as? NSNumber)?.uint64Value),
        fileNumber: try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    )
    let sourceID = UUID()
    let managedSource = SkillSource(
        id: sourceID,
        kind: kind,
        name: "Source",
        urlString: kind == .githubRepository ? "https://github.com/acme/source" : nil,
        localPath: source.path,
        externalLocalPath: kind == .localDirectory ? external.path : nil,
        directoryIdentity: identity
    )
    let asset = InstalledSkill(
        id: "source-skill",
        sourceID: sourceID,
        name: "Source",
        description: "Whole source removal fixture.",
        installedPath: source.path,
        sourceKind: kind,
        validation: .valid,
        purpose: nil,
        tagIDs: [],
        installedAt: Date(timeIntervalSince1970: 0)
    )
    let childAsset = InstalledSkill(
        id: "child-skill",
        sourceID: sourceID,
        name: "Child",
        description: "Second skill in the same source.",
        installedPath: child.path,
        sourceKind: kind,
        validation: .valid,
        purpose: nil,
        tagIDs: [],
        installedAt: Date(timeIntervalSince1970: 0)
    )
    let candidate = AvailableSkill(
        id: "source-skill",
        sourceID: sourceID,
        skillPath: ".",
        name: "Source",
        description: "Whole source removal fixture.",
        validation: .valid,
        candidateID: "candidate-source",
        manifestDigest: nil
    )
    let childCandidate = AvailableSkill(
        id: "child-skill",
        sourceID: sourceID,
        skillPath: "child",
        name: "Child",
        description: "Second skill in the same source.",
        validation: .valid,
        candidateID: "candidate-child",
        manifestDigest: nil
    )
    let store = SkillsHubMetadataStore()
    try store.save(SkillsHubMetadata(
        rootConfig: RootConfig(rootPath: root.path),
        sources: [managedSource],
        availableSkills: [candidate, childCandidate],
        installedSkills: [asset, childAsset]
    ), to: root)
    let snapshot = try store.loadCurrentSnapshot(from: root)
    let contentDigest = try ContentManifestBuilder().build(
        for: source,
        authorizedRoot: source,
        allowExternalSymbolicLinks: true
    ).digest
    let plan = SourceRemovalPlan(
        id: UUID(),
        rootPath: root.path,
        source: managedSource,
        sourceIdentity: identity,
        contentDigest: contentDigest,
        metadataGeneration: snapshot.generation,
        metadataDigest: snapshot.metadataDigest,
        skills: [asset, childAsset].map {
            SourceRemovalSkill(assetID: $0.assetID, skillID: $0.id, name: $0.name, installedPath: $0.installedPath)
        },
        relationPlans: [],
        planDigest: "fixture-plan"
    )
    return SourceRemovalFixture(root: root, source: source, external: external, store: store, plan: plan)
}

private enum SourceRemovalTestError: Error {
    case metadataFailure
    case trashFailure
}

private struct SourceUpdateFixture {
    let root: URL
    let managed: URL
    let external: URL
    let appSupport: URL
    let trash: URL
    let store: SkillsHubMetadataStore
    let sourceID: UUID
    let assetID: UUID
    let baseline: ContentManifest

    func remove() {
        for url in [root, external, appSupport, trash] { try? FileManager.default.removeItem(at: url) }
    }
}

private func sourceUpdateFixture() throws -> SourceUpdateFixture {
    let root = try temporaryDirectory().resolvingSymlinksInPath()
    let external = try temporaryDirectory().resolvingSymlinksInPath()
    let appSupport = try temporaryDirectory().resolvingSymlinksInPath()
    let trash = try temporaryDirectory().resolvingSymlinksInPath()
    let managed = root.appendingPathComponent("local/source", isDirectory: true)
    try writeSkill(managed, name: "Stable", description: "Old")
    try writeSkill(external, name: "Stable", description: "Upstream")
    try writeSkill(external.appendingPathComponent("added", isDirectory: true), name: "Added", description: "New")
    let sourceID = UUID()
    let assetID = UUID()
    let builder = ContentManifestBuilder()
    let baseline = try builder.build(for: managed, authorizedRoot: managed)
    let source = SkillSource(
        id: sourceID,
        kind: .localDirectory,
        name: "Source",
        localPath: managed.path,
        externalLocalPath: external.path,
        directoryIdentity: try LinkNodeIdentity.read(at: managed).file,
        baselineManifest: baseline
    )
    let candidate = try #require(LocalSourceIndexer().index(directory: managed, sourceID: sourceID).availableSkills.first)
    let installed = InstalledSkill(
        id: candidate.candidateID,
        sourceID: sourceID,
        name: candidate.name,
        description: candidate.description,
        installedPath: managed.path,
        sourceKind: .localDirectory,
        validation: candidate.validation,
        purpose: nil,
        tagIDs: [],
        installedAt: .distantPast,
        assetID: assetID,
        candidateID: candidate.candidateID,
        canonicalPathComponent: "source",
        currentRevision: candidate.manifestDigest,
        manifestDigest: candidate.manifestDigest,
        stableLinkName: "Stable"
    )
    let store = SkillsHubMetadataStore()
    try store.save(
        SkillsHubMetadata(
            rootConfig: RootConfig(rootPath: root.path),
            sources: [source],
            availableSkills: [candidate],
            installedSkills: [installed],
            enablementIntents: [
                EnablementIntent(
                    assetID: assetID,
                    agentID: AgentKind.codex.rawValue,
                    scope: .global,
                    isEnabled: true,
                    generation: 0
                )
            ]
        ),
        to: root
    )
    return SourceUpdateFixture(
        root: root,
        managed: managed,
        external: external,
        appSupport: appSupport,
        trash: trash,
        store: store,
        sourceID: sourceID,
        assetID: assetID,
        baseline: baseline
    )
}

private struct SourceExchangeFixture: Sendable {
    let root: URL
    let source: URL
    let prepared: URL
    let record: SourceDirectoryExchangeRecord

    init(sourcePath: String = "local/source") throws {
        root = try temporaryDirectory().resolvingSymlinksInPath()
        source = root.appendingPathComponent(sourcePath)
        let operationID = UUID()
        prepared = root.appendingPathComponent(".skillshub-operations/\(operationID.uuidString)/prepared")
        for (url, version) in [(source, "old"), (prepared, "new")] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("\(version)/empty"), withIntermediateDirectories: true)
            try Data(version.utf8).write(to: url.appendingPathComponent("version"))
            try Data("hidden-\(version)".utf8).write(to: url.appendingPathComponent(".hidden"))
            let executable = url.appendingPathComponent("\(version)/tool")
            try Data("never execute \(version)".utf8).write(to: executable)
            guard Darwin.chmod(executable.path, 0o755) == 0 else { throw SourceTraversalTestError.denied }
            try FileManager.default.createSymbolicLink(atPath: url.appendingPathComponent("link").path, withDestinationPath: "./\(version)/tool")
        }
        try SkillsHubMetadataStore().save(SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)), to: root)
        record = try SourceDirectoryExchange().prepare(rootURL: root, sourceURL: source, operationID: operationID)
    }

    func manifest(_ url: URL) throws -> ContentManifest {
        try ContentManifestBuilder().build(for: url, authorizedRoot: url)
    }
}

private final class MockHTTPDataClient: HTTPDataClient {
    struct Response {
        var data: Data
        var statusCode: Int
        var headers: [String: String]
    }

    var requests: [URLRequest] = []
    private var responses: [Response] = []

    func enqueue(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        responses.append(Response(data: data, statusCode: statusCode, headers: headers))
    }

    func data(for request: URLRequest, maximumByteCount: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.removeFirst()
        guard response.data.count <= maximumByteCount else {
            throw GitHubAPIClientFailure.repositoryTooLarge
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: response.headers
        )!
        return (response.data, httpResponse)
    }
}

private final class ReferenceProbeFileManager: FileManager, @unchecked Sendable {
    var outsidePath = ""
    var probes: [String] = []

    override func fileExists(atPath path: String) -> Bool {
        if URL(fileURLWithPath: path).standardizedFileURL.path == outsidePath {
            probes.append(path)
            return false
        }
        return super.fileExists(atPath: path)
    }
}

private enum SourceTraversalTestError: Error {
    case denied
}

private func writeSkill(_ directory: URL, name: String, description: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
    ---
    name: \(name)
    description: \(description)
    ---
    Body.
    """.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
}

private func manifestEntry(
    _ path: String,
    digest: String,
    executable: Bool = false,
    bytes: Int64
) -> ContentManifestEntry {
    ContentManifestEntry(
        relativePath: path,
        kind: .file,
        byteDigest: digest,
        symbolicLinkTarget: nil,
        isExecutable: executable,
        byteCount: bytes
    )
}

private func manifest(_ entries: [ContentManifestEntry], digest: String) -> ContentManifest {
    ContentManifest(
        entries: entries,
        fileCount: entries.count(where: { $0.kind == .file }),
        totalByteCount: entries.reduce(0) { $0 + $1.byteCount },
        digest: digest,
        observedAt: Date(timeIntervalSince1970: 0)
    )
}

private func installedSkill(id: String, sourceKind: SkillSourceKind, path: String) -> InstalledSkill {
    InstalledSkill(
        id: id,
        sourceID: nil,
        name: id,
        description: "A test skill.",
        installedPath: path,
        sourceKind: sourceKind,
        validation: .valid,
        purpose: nil,
        tagIDs: [],
        installedAt: Date(timeIntervalSince1970: 0)
    )
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

private func tarData(entries: [String: String]) -> Data {
    var data = Data()
    for (path, contents) in entries {
        let body = Data(contents.utf8)
        data.append(tarHeader(path: path, size: body.count, typeFlag: UInt8(ascii: "0")))
        data.append(body)
        let padding = (512 - (body.count % 512)) % 512
        data.append(Data(repeating: 0, count: padding))
    }
    data.append(Data(repeating: 0, count: 1024))
    return data
}

private func tarHeader(path: String, size: Int, typeFlag: UInt8) -> Data {
    var header = [UInt8](repeating: 0, count: 512)
    write(path, to: &header, offset: 0, length: 100)
    write(String(format: "%011o", size), to: &header, offset: 124, length: 12)
    header[156] = typeFlag
    write("ustar", to: &header, offset: 257, length: 6)
    return Data(header)
}

private func write(_ text: String, to header: inout [UInt8], offset: Int, length: Int) {
    let bytes = Array(text.utf8.prefix(length))
    for (index, byte) in bytes.enumerated() {
        header[offset + index] = byte
    }
}
