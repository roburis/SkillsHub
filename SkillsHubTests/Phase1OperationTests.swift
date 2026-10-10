import Foundation
import Testing
@testable import SkillsHub

struct Phase1OperationTests {
    @Test func recordedJSONPreservesEncoderOrderingAndScalarTypes() throws {
        struct Sample: Encodable {
            let initializationFacts = [Int64.min, 0, 1]
            let initialLocalState = ["日本語": true, "a/b": false]
            let initialMetadata = [UInt64.max]
            let fractions = [0.5, -1.25, 1e-20]
            let absent: String? = nil
            let text = "中文 / 日本語\n\"quoted\""
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expected = try encoder.encode(Sample())
        let object = try JSONSerialization.jsonObject(with: expected)
        #expect(try encoder.encode(Phase1RecordedJSON(value: object)) == expected)
    }

    @Test(arguments: [false, true])
    func githubSourceImportPublishesCompleteRepositoryAndLeavesEverySkillDisabled(legacyJournal: Bool) async throws {
        let fixture = try RootInitializationFixture()
        defer { fixture.remove() }
        let initializationPlan = try fixture.plan()
        let initialized = await fixture.coordinator.commit(
            plan: initializationPlan,
            confirmation: fixture.planner.confirmation(for: initializationPlan)
        )
        try #require(initialized.succeeded)
        let originalJournal = try Data(contentsOf: fixture.journal)
        let retainedJournal = legacyJournal ? try historicalInitializationJournal(originalJournal) : originalJournal
        try retainedJournal.write(to: fixture.journal)
        let journal = Phase1OperationJournal(rootURL: fixture.root)
        let recoveredInitialization = try #require(journal.recoverTasks().first)
        #expect(recoveredInitialization.phase == .completed)
        #expect(recoveredInitialization.operationPlan?.id == initializationPlan.id)
        try journal.verifyCompletedPlan(try #require(recoveredInitialization.operationPlan))
        #expect(try Data(contentsOf: fixture.journal) == retainedJournal)
        let stagedDirectory = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("github-stage", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagedDirectory.appendingPathComponent("nested/invalid", isDirectory: true),
            withIntermediateDirectories: true
        )
        try phase1SkillText(name: "Root Skill", description: "Uses shared repository content.").write(
            to: stagedDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try Data("---\nname: []\ndescription: invalid\n---\n".utf8)
            .write(to: stagedDirectory.appendingPathComponent("nested/invalid/SKILL.md"))
        try Data([0, 1, 2, 3]).write(to: stagedDirectory.appendingPathComponent("shared.bin"))
        let sourceID = UUID(uuidString: "22222222-3333-4444-8555-666666666666")!
        let index = LocalSourceIndexer().index(directory: stagedDirectory, sourceID: sourceID, generation: 1)
        let manifest = try ContentManifestBuilder().build(for: stagedDirectory, authorizedRoot: stagedDirectory)
        var source = SkillSource(
            id: sourceID,
            kind: .githubRepository,
            name: "acme/repository",
            urlString: "https://github.com/acme/repository",
            githubRepositoryID: 42,
            ref: "main",
            resolvedVersion: String(repeating: "a", count: 40),
            localPath: stagedDirectory.path,
            sourceMode: .mixed,
            contentFingerprint: index.source.contentFingerprint,
            directoryIdentity: index.source.directoryIdentity,
            lastCheckedAt: index.source.lastCheckedAt
        )
        source.isIndexIncomplete = false
        let result = GitHubIndexResult(
            source: source,
            availableSkills: index.availableSkills,
            issue: nil,
            recoveryActions: [],
            stagedRepository: GitHubStagedRepository(
                directory: stagedDirectory,
                manifest: manifest,
                risks: [],
                externalDependencies: [],
                metrics: GitHubFetchMetrics(
                    archiveByteCount: 1,
                    expandedByteCount: 1,
                    nodeCount: manifest.entries.count,
                    maximumDepth: 2,
                    elapsed: 0,
                    availableDiskByteCount: nil,
                    peakResidentByteCount: 0
                )
            )
        )
        let plan = try fixture.planner.githubSourceImportPlan(
            result: result,
            rootURL: fixture.root,
            snapshot: fixture.store.loadCurrentSnapshot(from: fixture.root)
        )

        let committed = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )
        let snapshot = try #require(committed.snapshot)
        let registered = try #require(snapshot.metadata.sources.first)
        let target = fixture.root.appendingPathComponent("github/acme/repository", isDirectory: true)

        #expect(committed.succeeded)
        #expect(committed.task.kind == .importGitHubSource)
        #expect(registered.kind == .githubRepository)
        #expect(registered.localPath == target.path)
        #expect(registered.ref == "main")
        #expect(registered.resolvedVersion == String(repeating: "a", count: 40))
        #expect(registered.baselineManifest?.digest == manifest.digest)
        #expect(snapshot.metadata.availableSkills.count == 2)
        #expect(snapshot.metadata.installedSkills.map(\.sourceKind) == [.githubRepository, .githubRepository])
        #expect(snapshot.metadata.enablementIntents.isEmpty)
        #expect(try ContentManifestBuilder().build(for: target, authorizedRoot: target).digest == manifest.digest)
        #expect(try Data(contentsOf: fixture.journal).starts(with: retainedJournal))

        let recovered = try #require(
            Phase1OperationJournal(rootURL: fixture.root).recoverTasks().first { $0.id == plan.id }
        )
        #expect(recovered.recoveryEvidence?.sourceKind == .githubRepository)
        #expect(recovered.recoveryEvidence?.components.first { $0.kind == "content" }?.state == .completed)
        #expect(recovered.recoveryEvidence?.components.first { $0.kind == "metadata" }?.state == .completed)
        #expect(recovered.recoveryEvidence?.components.first { $0.kind == "success-baseline" }?.state == .completed)
        #expect(recovered.recoveryEvidence?.components.first { $0.kind == "relationships" }?.state == .completed)
    }

    @Test(arguments: ["retired-field", "current-field"])
    func historicalJournalTamperingStillBlocksWrites(tampering: String) async throws {
        let fixture = try RootInitializationFixture()
        defer { fixture.remove() }
        let plan = try fixture.plan()
        let initialized = await fixture.coordinator.commit(plan: plan, confirmation: fixture.planner.confirmation(for: plan))
        try #require(initialized.succeeded)
        let bytes = try historicalInitializationJournal(Data(contentsOf: fixture.journal), tampering: tampering)
        try bytes.write(to: fixture.journal)
        let journal = Phase1OperationJournal(rootURL: fixture.root)
        #expect(throws: Phase1OperationError.journalUnavailable) {
            try journal.containsSubmission(planID: UUID(), confirmationID: UUID())
        }
        let recovered = try #require(journal.recoverTasks().first)
        #expect(recovered.phase == .needsAttention)
        #expect(recovered.operationPlan?.id == plan.id)
        #expect(try Data(contentsOf: fixture.journal) == bytes)
    }

    @Test func localSourceImportCopiesTheCompleteTreeAndLeavesEverySkillDisabled() async throws {
        let fixture = try Phase1Fixture()
        defer { fixture.remove() }
        let nested = fixture.source.appendingPathComponent("nested/invalid", isDirectory: true)
        let hidden = fixture.source.appendingPathComponent(".shared", isDirectory: true)
        let empty = fixture.source.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data("shared".utf8).write(to: hidden.appendingPathComponent("config.json"))
        try Data("---\nname: []\ndescription: invalid\n---\n".utf8)
            .write(to: nested.appendingPathComponent("SKILL.md"))

        let original = try ContentManifestBuilder().build(
            for: fixture.source,
            authorizedRoot: fixture.source,
            allowExternalSymbolicLinks: true
        )
        let plan = try fixture.planner.localSourceImportPlan(
            directory: fixture.source,
            rootURL: fixture.root,
            snapshot: fixture.initialSnapshot(),
            sourceID: fixture.sourceID
        )
        let result = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )
        let snapshot = try #require(result.snapshot)
        let source = try #require(snapshot.metadata.sources.first)
        let managed = try ContentManifestBuilder().build(
            for: fixture.managedDirectory,
            authorizedRoot: fixture.managedDirectory,
            allowExternalSymbolicLinks: true
        )

        #expect(result.succeeded)
        #expect(source.localPath == fixture.managedDirectory.path)
        #expect(source.externalLocalPath == fixture.source.path)
        #expect(source.baselineManifest?.digest == original.digest)
        #expect(managed.digest == original.digest)
        #expect(snapshot.metadata.availableSkills.count == 2)
        #expect(snapshot.metadata.installedSkills.count == 2)
        #expect(snapshot.metadata.enablementIntents.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.managedDirectory.appendingPathComponent(".shared/config.json").path))
        #expect(FileManager.default.fileExists(atPath: fixture.managedDirectory.appendingPathComponent("empty").path))

        try Data("later external edit".utf8).write(to: fixture.source.appendingPathComponent("later.txt"))
        #expect(!FileManager.default.fileExists(atPath: fixture.managedDirectory.appendingPathComponent("later.txt").path))
    }

    @Test func localSourceImportRejectsOccupiedTargetWithoutMerging() throws {
        let fixture = try Phase1Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.managedDirectory, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: fixture.managedDirectory.appendingPathComponent("foreign.txt"))

        #expect(throws: Phase1OperationError.targetConflict(fixture.managedDirectory.path)) {
            try fixture.planner.localSourceImportPlan(
                directory: fixture.source,
                rootURL: fixture.root,
                snapshot: fixture.initialSnapshot(),
                sourceID: fixture.sourceID
            )
        }
        #expect(try String(contentsOf: fixture.managedDirectory.appendingPathComponent("foreign.txt"), encoding: .utf8) == "preserve")
        #expect(try fixture.initialSnapshot().generation == 0)
    }

    @Test func localSourceImportKeepsAnAllInvalidSourceVisibleAndDisabled() async throws {
        let fixture = try Phase1Fixture()
        defer { fixture.remove() }
        try Data("---\nname: []\ndescription: invalid\n---\n".utf8).write(to: fixture.sourceSkillFile)
        let plan = try fixture.planner.localSourceImportPlan(
            directory: fixture.source,
            rootURL: fixture.root,
            snapshot: fixture.initialSnapshot(),
            sourceID: fixture.sourceID
        )

        let result = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )
        let snapshot = try #require(result.snapshot)

        #expect(result.succeeded)
        #expect(snapshot.metadata.availableSkills.map(\.checkStatus) == [.blocked])
        #expect(snapshot.metadata.installedSkills.count == 1)
        #expect(snapshot.metadata.enablementIntents.isEmpty)
    }

    @Test func localSourceImportStopsOnSourceDriftBeforePublishing() async throws {
        let fixture = try Phase1Fixture()
        defer { fixture.remove() }
        let plan = try fixture.planner.localSourceImportPlan(
            directory: fixture.source,
            rootURL: fixture.root,
            snapshot: fixture.initialSnapshot(),
            sourceID: fixture.sourceID
        )
        try Data("changed".utf8).write(to: fixture.source.appendingPathComponent("after-plan.txt"))

        let result = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )

        #expect(!result.succeeded)
        #expect(!FileManager.default.fileExists(atPath: fixture.managedDirectory.path))
        #expect(try fixture.initialSnapshot().generation == 0)
    }

    @Test func localSourceImportMetadataFailureRemovesOnlyItsPublishedCopy() async throws {
        let fixture = try Phase1Fixture(fault: .metadataCommitBeforeCAS)
        defer { fixture.remove() }
        let sourceBefore = try Data(contentsOf: fixture.sourceSkillFile)
        let plan = try fixture.planner.localSourceImportPlan(
            directory: fixture.source,
            rootURL: fixture.root,
            snapshot: fixture.initialSnapshot(),
            sourceID: fixture.sourceID
        )

        let result = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )

        #expect(!result.succeeded)
        #expect(!FileManager.default.fileExists(atPath: fixture.managedDirectory.path))
        #expect(try Data(contentsOf: fixture.sourceSkillFile) == sourceBefore)
        #expect(try fixture.initialSnapshot().generation == 0)
    }

    @Test func localSourceImportStagingFailureLeavesSourceAndMetadataUnchanged() async throws {
        let fixture = try Phase1Fixture(fault: .afterStagingCopy)
        defer { fixture.remove() }
        let sourceBefore = try ContentManifestBuilder().build(
            for: fixture.source,
            authorizedRoot: fixture.source
        )
        let plan = try fixture.planner.localSourceImportPlan(
            directory: fixture.source,
            rootURL: fixture.root,
            snapshot: fixture.initialSnapshot(),
            sourceID: fixture.sourceID
        )

        let result = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )

        #expect(!result.succeeded)
        #expect(!FileManager.default.fileExists(atPath: fixture.managedDirectory.path))
        #expect(try fixture.initialSnapshot().generation == 0)
        #expect(try ContentManifestBuilder().build(
            for: fixture.source,
            authorizedRoot: fixture.source
        ).digest == sourceBefore.digest)
    }

    @Test func localSourceImportPreservesCommittedFactsWhenFinalRecordingFails() async throws {
        let fixture = try Phase1Fixture(fault: .afterMetadataCommit)
        defer { fixture.remove() }
        let plan = try fixture.planner.localSourceImportPlan(
            directory: fixture.source,
            rootURL: fixture.root,
            snapshot: fixture.initialSnapshot(),
            sourceID: fixture.sourceID
        )

        let result = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )
        let snapshot = try fixture.store.loadCurrentSnapshot(from: fixture.root)

        #expect(!result.succeeded)
        #expect(result.task.phase == .needsAttention)
        #expect(FileManager.default.fileExists(atPath: fixture.managedDirectory.path))
        #expect(snapshot.generation == 1)
        #expect(snapshot.metadata.sources.first?.baselineManifest?.digest == plan.sourceManifest?.digest)
    }

    @Test(arguments: ["success", "source-drift", "copy", "rename", "compensation", "target-race"])
    func sourceImportFilesystemMatrixPreservesBoundaries(failure: String) async throws {
        let files = SourceImportFileProbe(failure: failure)
        let fixture = try Phase1Fixture(fault: failure == "compensation" ? .metadataCommitBeforeCAS : nil, fileManager: files)
        defer { fixture.remove() }
        files.target = fixture.managedDirectory
        let resources = fixture.source.appendingPathComponent("Tool.app/Contents")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: resources.appendingPathComponent("payload.bin"))
        try FileManager.default.createSymbolicLink(atPath: resources.appendingPathComponent("entry-link").path, withDestinationPath: "../../SKILL.md")
        let builder = ContentManifestBuilder()
        let original = try builder.build(for: fixture.source, authorizedRoot: fixture.source)

        let execution = try await fixture.executeSourceImport()
        let current = try fixture.store.loadCurrentSnapshot(from: fixture.root)
        let after = try builder.build(for: fixture.source, authorizedRoot: fixture.source)
        #expect(files.copyCount == 1)
        #expect(execution.result.succeeded == (failure == "success"))
        if failure == "success" {
            #expect(files.renameCount == 1)
            #expect(files.publishedInodeBefore == files.publishedInodeAfter)
            #expect(files.publishedInodeBefore != nil)
            let published = try builder.build(for: fixture.managedDirectory, authorizedRoot: fixture.managedDirectory)
            #expect(published.entries == original.entries)
            #expect(current.metadata.installedSkills.count == 1)
            #expect(current.metadata.installedSkills.first?.canonicalPathComponent == "review")
        } else {
            #expect(current.metadata.installedSkills.isEmpty)
            #expect(try fixture.metadataBytes() == execution.metadataBefore)
            #expect(execution.result.task.phase == .needsAttention)
            if failure == "compensation" {
                #expect(FileManager.default.fileExists(atPath: fixture.managedSkillFile.path))
                #expect(execution.result.task.result.template == "Recovery needs attention. Diagnostic (original): %@")
                #expect(!execution.result.task.result.arguments.isEmpty)
            } else if failure == "target-race" || failure == "rename" {
                #expect(try String(contentsOf: fixture.managedDirectory.appendingPathComponent("foreign.txt"), encoding: .utf8) == "preserve")
            } else {
                #expect(!FileManager.default.fileExists(atPath: fixture.managedDirectory.path))
            }
        }
        if failure == "copy" || failure == "rename" {
            #expect(files.nativeErrorCode != nil)
        }
        if failure == "copy" {
            #expect(try String(contentsOf: fixture.stagingDirectory(for: execution.plan).appendingPathComponent("source/partial"), encoding: .utf8) == "partial")
        }
        if failure == "source-drift" {
            #expect(files.renameCount == 0)
            #expect(try Data(contentsOf: fixture.sourceSkillFile) == execution.sourceBefore + Data("External change".utf8))
        } else {
            #expect(after.entries == original.entries)
        }
        Attachment.record(try JSONEncoder().encode(original), named: "source-manifest-before.json")
        Attachment.record(try JSONEncoder().encode(after), named: "source-manifest-after.json")
        Attachment.record("case=\(failure), copy=\(files.copyCount), rename=\(files.renameCount), native-error=\(String(describing: files.nativeErrorCode)), inode-before=\(String(describing: files.publishedInodeBefore)), inode-after=\(String(describing: files.publishedInodeAfter))", named: "copy-rename-evidence.txt")
    }

    @Test func sourceImportRejectsReplacedDirectoryBeforeEnumeration() async throws {
        let fixture = try Phase1Fixture()
        defer { fixture.remove() }
        let plan = try fixture.planner.localSourceImportPlan(
            directory: fixture.source, rootURL: fixture.root, snapshot: fixture.initialSnapshot(), sourceID: fixture.sourceID
        )
        let oldSource = fixture.source.appendingPathExtension("old")
        try FileManager.default.moveItem(at: fixture.source, to: oldSource)
        try FileManager.default.copyItem(at: oldSource, to: fixture.source)
        let fileManager = SourceEnumerationProbe()
        fileManager.source = fixture.source
        let coordinator = Phase1OperationCoordinator(metadataStore: fixture.store, fileManager: fileManager)

        let result = await coordinator.commit(plan: plan, confirmation: fixture.planner.confirmation(for: plan))

        #expect(!result.succeeded)
        #expect(result.task.result == "The source or current facts changed. Re-check before continuing.")
        #expect(fileManager.sourceEnumerations == 0)
        #expect(try fixture.initialSnapshot().metadata.sources.isEmpty)
    }

    @Test func unreadableJournalProducesVisibleRecoveryEvidence() throws {
        let fixture = try Phase1Fixture()
        defer { fixture.remove() }
        try FileManager.default.createSymbolicLink(at: fixture.journal, withDestinationURL: fixture.sourceSkillFile)
        let tasks = try Phase1OperationJournal(rootURL: fixture.root).recoverTasks()
        #expect(tasks.count == 1)
        #expect(tasks.first?.phase == .needsAttention)
    }

    @Test(arguments: [Phase1OperationKind.registerLocalSource, .publishManagedCopy])
    func retiredPlansRemainReadableButCannotExecute(kind: Phase1OperationKind) async throws {
        let fixture = try Phase1Fixture()
        defer { fixture.remove() }
        var plan = try fixture.planner.localSourceImportPlan(
            directory: fixture.source, rootURL: fixture.root, snapshot: fixture.initialSnapshot()
        )
        plan.kind = kind
        plan.compensationPaths = nil
        plan.planDigest = try plan.computedDigest()
        let journal = Phase1OperationJournal(rootURL: fixture.root)
        try journal.append(Phase1JournalRecord(
            operationID: plan.id, kind: kind, operationPlan: plan, sequence: 1,
            planDigest: plan.planDigest, event: .plan, phase: .waitingConfirmation,
            objectID: fixture.source.path, result: "immutable-plan", occurredAt: plan.createdAt
        ))
        let journalBefore = try Data(contentsOf: fixture.journal)
        let metadataBefore = try fixture.metadataBytes()
        let recovered = try #require(journal.recoverTasks().first)
        #expect(recovered.kind == kind.taskKind)
        #expect(try recovered.operationPlan?.computedDigest() == plan.planDigest)
        #expect(recovered.phase == .needsAttention)

        let result = await fixture.coordinator.commit(
            plan: plan, confirmation: fixture.planner.confirmation(for: plan)
        )
        #expect(result.succeeded == false)
        #expect(result.task.phase == .needsAttention)
        #expect(try Data(contentsOf: fixture.journal) == journalBefore)
        #expect(try fixture.metadataBytes() == metadataBefore)
        #expect(FileManager.default.fileExists(atPath: fixture.managedDirectory.path) == false)
    }

    @Test func sourceImportMetadataFailureStopsBeforeTheCommit() async throws {
        let fixture = try Phase1Fixture(fault: .metadataCommitBeforeCAS)
        defer { fixture.remove() }
        let initial = try fixture.initialSnapshot()
        let plan = try fixture.planner.localSourceImportPlan(
            directory: fixture.source, rootURL: fixture.root,
            snapshot: initial,
            sourceID: fixture.sourceID
        )
        let metadataBefore = try fixture.metadataBytes()

        let result = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )
        let records = try fixture.journalRecords(operationID: plan.id)

        #expect(result.succeeded == false)
        #expect(result.task.phase == .needsAttention)
        #expect(try fixture.metadataBytes() == metadataBefore)
        #expect(try fixture.store.loadCurrentSnapshot(from: fixture.root).metadata.sources.isEmpty)
        #expect(records.map(\.result) == ["immutable-plan", "source-import-authorized", "staging-copy", "staging-verified", "target-publish", "target-published", "metadata-cas", "published-target-removed", "staging-removed"])
        #expect(records.contains { $0.event == .final } == false)

        let journalBeforeReplay = try Data(contentsOf: fixture.journal)
        let restarted = Phase1OperationCoordinator(metadataStore: fixture.store)
        let replay = await restarted.commit(plan: plan, confirmation: fixture.planner.confirmation(for: plan))
        #expect(replay.succeeded == false)
        #expect(replay.task.result == "The confirmation is no longer valid. Review a new preview.")
        #expect(try Data(contentsOf: fixture.journal) == journalBeforeReplay)
        #expect(try fixture.metadataBytes() == metadataBefore)
    }

    @Test func staleImportPlanDoesNotCommitSourceMetadata() async throws {
        let fixture = try Phase1Fixture()
        defer { fixture.remove() }
        let initial = try fixture.initialSnapshot()
        let plan = try fixture.planner.localSourceImportPlan(
            directory: fixture.source, rootURL: fixture.root,
            snapshot: initial,
            sourceID: fixture.sourceID
        )

        let newer = try fixture.store.commit(
            at: fixture.root,
            expected: initial
        ) { metadata in
            metadata.tags.append(TagRecord(id: "newer", displayName: "Newer"))
        }
        let metadataAfterNewerCommit = try fixture.metadataBytes()
        let result = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )

        #expect(!result.succeeded)
        #expect(result.task.phase == .needsAttention)
        #expect(try fixture.metadataBytes() == metadataAfterNewerCommit)
        #expect(newer.metadata.sources.isEmpty)
        #expect(try fixture.store.loadCurrentSnapshot(from: fixture.root).metadata.sources.isEmpty)
    }

    @Test func mutatedPlanCannotConsumeConfirmationOrCreateJournal() async throws {
        let fixture = try Phase1Fixture()
        defer { fixture.remove() }
        let original = try fixture.planner.localSourceImportPlan(
            directory: fixture.source, rootURL: fixture.root,
            snapshot: fixture.initialSnapshot(),
            sourceID: fixture.sourceID
        )
        let confirmation = fixture.planner.confirmation(for: original)
        var mutated = original
        mutated.expectedWrites.append("outside-plan")
        let metadataBefore = try fixture.metadataBytes()

        let result = await fixture.coordinator.commit(plan: mutated, confirmation: confirmation)

        #expect(!result.succeeded)
        #expect(try fixture.metadataBytes() == metadataBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test(arguments: ["directory", "file", "symlink", "broken-symlink", "case"])
    func targetConflictPreservesExistingTargetSourceAndMetadata(node: String) async throws {
        let fixture = try Phase1Fixture()
        defer { fixture.remove() }
        let plan = try fixture.planner.localSourceImportPlan(directory: fixture.source, rootURL: fixture.root, snapshot: fixture.initialSnapshot(), sourceID: fixture.sourceID)
        let target = node == "case" ? fixture.managedDirectory.deletingLastPathComponent().appendingPathComponent("REVIEW") : fixture.managedDirectory
        let sentinel = fixture.root.deletingLastPathComponent().appendingPathComponent("unplanned.txt")
        try Data("keep".utf8).write(to: sentinel)
        switch node {
        case "directory":
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: target.appendingPathComponent("keep.txt"))
        case "symlink", "broken-symlink":
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: node == "symlink" ? sentinel : sentinel.appendingPathExtension("missing"))
        default:
            try Data("keep".utf8).write(to: target)
        }
        let targetBefore = try FileManager.default.attributesOfItem(atPath: target.path)
        let sourceBefore = try Data(contentsOf: fixture.sourceSkillFile)
        let metadataBefore = try fixture.metadataBytes()
        let journalBefore = try? Data(contentsOf: fixture.journal)
        let localBefore = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).sorted()

        let result = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )

        #expect(!result.succeeded)
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        #expect(try Data(contentsOf: fixture.sourceSkillFile) == sourceBefore)
        #expect(try fixture.metadataBytes() == metadataBefore)
        #expect((try? Data(contentsOf: fixture.journal)) == journalBefore)
        #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber == targetBefore[.systemFileNumber] as? NSNumber)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).sorted() == localBefore)
        if node == "symlink" || node == "broken-symlink" {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == (node == "symlink" ? sentinel.path : sentinel.appendingPathExtension("missing").path))
        } else {
            #expect(try Data(contentsOf: node == "directory" ? target.appendingPathComponent("keep.txt") : target) == Data("keep".utf8))
        }
        #expect(try fixture.store.loadCurrentSnapshot(from: fixture.root).metadata.installedSkills.isEmpty)
        Attachment.record("node=\(node), inode=\(String(describing: targetBefore[.systemFileNumber])), local=\(localBefore), source/metadata/journal/unplanned unchanged", named: "target-conflict-evidence.txt")
    }

    @Test func sourceChangeInvalidatesPlanBeforeJournalOrDomainWrites() async throws {
        let fixture = try Phase1Fixture()
        defer { fixture.remove() }
        let initial = try fixture.initialSnapshot()
        let plan = try fixture.planner.localSourceImportPlan(
            directory: fixture.source, rootURL: fixture.root,
            snapshot: initial,
            sourceID: fixture.sourceID
        )
        let metadataBefore = try fixture.metadataBytes()
        try phase1SkillText(name: "Review", description: "Changed after planning.").write(
            to: fixture.sourceSkillFile,
            atomically: true,
            encoding: .utf8
        )

        let result = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )

        #expect(!result.succeeded)
        #expect(try fixture.metadataBytes() == metadataBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test func metadataFailureAfterPublishRunsBoundedCompensation() async throws {
        let fixture = try Phase1Fixture(fault: .metadataCommitBeforeCAS)
        defer { fixture.remove() }
        let execution = try await fixture.executeSourceImport()
        let current = try fixture.store.loadCurrentSnapshot(from: fixture.root)
        let recovered = try Phase1OperationJournal(rootURL: fixture.root).recoverTasks()

        #expect(execution.result.succeeded == false)
        #expect(FileManager.default.fileExists(atPath: fixture.managedDirectory.path) == false)
        #expect(current.metadata.installedSkills.isEmpty)
        #expect(try Data(contentsOf: fixture.sourceSkillFile) == execution.sourceBefore)
        #expect(recovered.contains { $0.result.contains("No verified local-source import delta") })
    }

    @Test func stagingCopyFailureStopsBeforePublishAndCleansOperationStaging() async throws {
        let fixture = try Phase1Fixture(fault: .afterStagingCopy)
        defer { fixture.remove() }
        let execution = try await fixture.executeSourceImport()
        let records = try fixture.journalRecords(operationID: execution.plan.id)

        #expect(execution.result.succeeded == false)
        #expect(execution.result.task.phase == .needsAttention)
        #expect(FileManager.default.fileExists(atPath: fixture.managedDirectory.path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.stagingDirectory(for: execution.plan).path) == false)
        #expect(try fixture.store.loadCurrentSnapshot(from: fixture.root).metadata.installedSkills.isEmpty)
        #expect(try Data(contentsOf: fixture.sourceSkillFile) == execution.sourceBefore)
        #expect(records.contains { $0.result == "target-published" } == false)
        #expect(records.contains { $0.result == "metadata-committed" } == false)
    }

    @Test func targetPublishFailureStopsBeforeRenameAndPreservesSourceAndMetadata() async throws {
        let fixture = try Phase1Fixture(fault: .beforeTargetPublish)
        defer { fixture.remove() }
        let execution = try await fixture.executeSourceImport()
        let records = try fixture.journalRecords(operationID: execution.plan.id)

        #expect(execution.result.succeeded == false)
        #expect(execution.result.task.phase == .needsAttention)
        #expect(FileManager.default.fileExists(atPath: fixture.managedDirectory.path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.stagingDirectory(for: execution.plan).path) == false)
        #expect(try fixture.metadataBytes() == execution.metadataBefore)
        #expect(try Data(contentsOf: fixture.sourceSkillFile) == execution.sourceBefore)
        #expect(records.contains { $0.result == "target-published" } == false)
        #expect(records.contains { $0.result == "metadata-committed" } == false)
    }

    @Test func interruptionAfterMetadataCommitRemainsNeedsAttentionWithoutReplay() async throws {
        let fixture = try Phase1Fixture(fault: .afterMetadataCommit)
        defer { fixture.remove() }
        let execution = try await fixture.executeSourceImport()
        let current = try fixture.store.loadCurrentSnapshot(from: fixture.root)
        let recovered = try Phase1OperationJournal(rootURL: fixture.root).recoverTasks()

        #expect(execution.result.succeeded == false)
        #expect(execution.result.task.phase == .needsAttention)
        #expect(current.metadata.installedSkills.count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.managedSkillFile.path))
        #expect(try Data(contentsOf: fixture.sourceSkillFile) == execution.sourceBefore)
        #expect(recovered.contains {
            $0.id == execution.plan.id
                && $0.phase == .needsAttention
                && $0.result.contains("consistent")
                && $0.result.contains("re-observe")
        })
    }

    @Test func journalCorruptionNeedsAttention() async throws {
        let fixture = try Phase1Fixture()
        defer { fixture.remove() }
        let plan = try fixture.planner.localSourceImportPlan(
            directory: fixture.source, rootURL: fixture.root,
            snapshot: fixture.initialSnapshot(),
            sourceID: fixture.sourceID
        )
        let registration = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )
        try #require(registration.succeeded)

        let handle = try FileHandle(forWritingTo: fixture.journal)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.synchronize()

        let recovered = try Phase1OperationJournal(rootURL: fixture.root).recoverTasks()
        #expect(recovered.first?.phase == .needsAttention)
        #expect(recovered.first?.result.contains("corrupted") == true)
    }

    @Test(arguments: ["sequence-gap", "digest", "missing-plan", "unknown-tail", "missing-step", "foreign-root"])
    func invalidJournalCannotReportCompletionOrAdmitNewWrites(corruption: String) async throws {
        let fixture = try Phase1Fixture()
        defer { fixture.remove() }
        let execution = try await fixture.executeSourceImport()
        var records = try fixture.journalRecords(operationID: execution.plan.id)
        switch corruption {
        case "sequence-gap": records.remove(at: 2)
        case "digest": records[0].planDigest = "changed"
        case "missing-plan": records[0].operationPlan = nil
        case "missing-step":
            records.remove(at: 2)
            for index in records.indices { records[index].sequence = index + 1 }
        case "foreign-root":
            var plan = try #require(records[0].operationPlan)
            plan.rootPath = fixture.source.path
            plan.planDigest = try plan.computedDigest()
            records[0].operationPlan = plan
            for index in records.indices { records[index].planDigest = plan.planDigest }
        default: break
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var bytes = try records.reduce(into: Data()) { $0 += try encoder.encode($1) + Data([0x0A]) }
        if corruption == "unknown-tail" { bytes += Data("{\"unknown-version\":9}\n".utf8) }
        try bytes.write(to: fixture.journal)

        let recovered = try Phase1OperationJournal(rootURL: fixture.root).recoverTasks()
        #expect(recovered.allSatisfy { $0.phase == .needsAttention })
        let anotherSource = fixture.source.deletingLastPathComponent().appendingPathComponent("another")
        try FileManager.default.copyItem(at: fixture.source, to: anotherSource)
        let plan = try fixture.planner.localSourceImportPlan(directory: anotherSource, rootURL: fixture.root, snapshot: fixture.initialSnapshot())
        let before = try fixture.metadataBytes()
        let result = await fixture.coordinator.commit(plan: plan, confirmation: fixture.planner.confirmation(for: plan))
        #expect(result.succeeded == false)
        #expect(try Data(contentsOf: fixture.journal) == bytes)
        #expect(try fixture.metadataBytes() == before)
    }

    @Test(arguments: ["metadata-committed", "target-replaced"])
    func compensationPreservesReferencedOrExternallyReplacedTargets(failure: String) async throws {
        let fixture = try Phase1Fixture(metadataCheckpoint: { phase, file in
            if failure == "metadata-committed", phase == .readback {
                throw Phase1OperationError.injectedFailure(failure)
            }
            if failure == "target-replaced", phase == .encoding {
                let target = file.deletingLastPathComponent().appendingPathComponent("local/review")
                let retained = target.deletingLastPathComponent().appendingPathComponent("retained-original")
                try FileManager.default.moveItem(at: target, to: retained)
                try FileManager.default.copyItem(at: retained, to: target)
                throw Phase1OperationError.injectedFailure(failure)
            }
        })
        defer { fixture.remove() }
        let execution = try await fixture.executeSourceImport()
        #expect(execution.result.succeeded == false)
        #expect(execution.result.task.phase == .needsAttention)
        #expect(try Data(contentsOf: fixture.managedSkillFile) == execution.sourceBefore)
        #expect(try Data(contentsOf: fixture.sourceSkillFile) == execution.sourceBefore)
        let snapshot = try fixture.initialSnapshot()
        #expect(snapshot.metadata.installedSkills.count == (failure == "metadata-committed" ? 1 : 0))
    }

    @Test func stagingSymlinkCannotRedirectOperationWrites() async throws {
        let fixture = try Phase1Fixture()
        defer { fixture.remove() }
        let external = fixture.root.deletingLastPathComponent().appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: fixture.store.rootLayout(for: fixture.root).operationRecoveryDirectory, withDestinationURL: external)
        let execution = try await fixture.executeSourceImport()
        #expect(execution.result.succeeded == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.journal.path) == false)
        #expect(try fixture.initialSnapshot().metadata.installedSkills.isEmpty)
    }

    @Test(arguments: ["staging-copy", "target-publish", "metadata-cas"], [Phase1JournalEventKind.stepStarted, .stepResult])
    func journalFailureAtEachCopyStepStopsAndPreservesTheSource(step: String, event: Phase1JournalEventKind) async throws {
        let results = ["staging-copy": "staging-verified", "target-publish": "target-published", "metadata-cas": "metadata-committed"]
        let fixture = try Phase1Fixture(fault: .journal(event, event == .stepResult ? #require(results[step]) : step))
        defer { fixture.remove() }
        let execution = try await fixture.executeSourceImport()
        #expect(execution.result.succeeded == false)
        #expect(execution.result.task.phase == .needsAttention)
        #expect(try Data(contentsOf: fixture.sourceSkillFile) == execution.sourceBefore)
        let records = try fixture.journalRecords(operationID: execution.plan.id)
        #expect(records.contains { $0.event == .final && $0.phase == .completed } == false)
        let before = try Data(contentsOf: fixture.journal)
        _ = try Phase1OperationJournal(rootURL: fixture.root).recoverTasks()
        #expect(try Data(contentsOf: fixture.journal) == before)
    }
}

struct RootInitializationOperationTests {
    @Test func planIsImmutableAndLeavesTheSelectedDirectoryUntouched() throws {
        let fixture = try RootInitializationFixture()
        defer { fixture.remove() }
        let before = try fixture.treeSnapshot()

        let plan = try fixture.planner.rootInitializationPlan(
            facts: RootInspectionFacts(url: fixture.root)
        )

        #expect(plan.kind == .initializeRoot)
        #expect(plan.rootPath == fixture.root.standardizedFileURL.path)
        #expect(plan.expectedGeneration == 0)
        #expect(plan.metadataDigest == "absent")
        #expect(plan.source == nil)
        #expect(plan.initialMetadata?.schemaVersion == SkillsHubMetadata.currentSchemaVersion)
        #expect(plan.initialMetadata?.generation == 0)
        #expect(plan.initialMetadata?.rootConfig.rootPath == fixture.root.standardizedFileURL.path)
        #expect(plan.initialLocalState == SkillsHubLocalState())
        #expect(plan.initializationFacts?.rootPath == fixture.root.standardizedFileURL.path)
        let payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        #expect(payload["compensationPaths"] as? [String] == [])
        #expect(
            Set(plan.expectedWrites) == Set([
                "local/",
                "github/",
                ".skillshub.json",
                ".skillshub.lock",
                ".skillshub.local.json",
                ".skillshub.operations.jsonl"
            ])
        )
        #expect(plan.steps.count == 6)
        #expect(plan.excludedActions.contains("No existing Root content is modified, moved, or removed"))
        #expect(try plan.computedDigest() == plan.planDigest)
        #expect(try fixture.treeSnapshot() == before)

        #expect(FileManager.default.fileExists(atPath: fixture.journal.path) == false)
    }

    @Test func explicitAuthorizationCreatesExactlyThePlannedRootAndVerifiesGenerationZero() async throws {
        let fixture = try RootInitializationFixture()
        defer { fixture.remove() }
        let sentinelBefore = try Data(contentsOf: fixture.sentinel)
        let plan = try fixture.plan()
        let confirmation = fixture.planner.confirmation(for: plan)

        let result = await fixture.coordinator.commit(plan: plan, confirmation: confirmation)
        #expect(result.succeeded)
        let snapshot = try #require(result.snapshot)
        let localState = try SkillsHubLocalStateStore().load(from: fixture.root)
        let tasks = try Phase1OperationJournal(rootURL: fixture.root).recoverTasks()

        #expect(result.task.kind == .initializeRoot)
        #expect(result.task.phase == .completed)
        #expect(snapshot.metadata == plan.initialMetadata)
        #expect(snapshot.generation == 0)
        #expect(snapshot.metadata.schemaVersion == SkillsHubMetadata.currentSchemaVersion)
        #expect(localState == plan.initialLocalState)
        #expect(try Data(contentsOf: fixture.sentinel) == sentinelBefore)
        #expect(
            Set(try fixture.relativeTreePaths()) == Set([
                ".skillshub.json",
                ".skillshub.lock",
                ".skillshub.local.json",
                ".skillshub.operations.jsonl",
                "github/",
                "local/",
                "sentinel.txt"
            ])
        )
        #expect(tasks.count == 1)
        #expect(tasks.first?.kind == .initializeRoot)
        #expect(tasks.first?.phase == .completed)
        #expect(tasks.first?.planDigest == plan.planDigest)
    }

    @Test func existingCompliantLocalContentIsDiscoveredAndPreserved() async throws {
        let fixture = try RootInitializationFixture()
        defer { fixture.remove() }
        let existingSkill = fixture.root.appendingPathComponent("local/existing/SKILL.md")
        try FileManager.default.createDirectory(
            at: existingSkill.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try phase1SkillText(name: "Existing", description: "Already managed content.").write(
            to: existingSkill,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("github"),
            withIntermediateDirectories: false
        )
        let existingBytes = try Data(contentsOf: existingSkill)
        let plan = try fixture.plan()

        #expect(Set(plan.expectedWrites).contains("local/") == false)
        #expect(Set(plan.expectedWrites).contains("github/") == false)
        #expect(plan.initialMetadata?.sources.isEmpty == true)
        #expect(plan.initialMetadata?.availableSkills.isEmpty == true)
        #expect(plan.initialMetadata?.installedSkills.count == 1)

        let result = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )

        #expect(result.succeeded)
        #expect(result.snapshot?.metadata.installedSkills.first?.installedPath == existingSkill.deletingLastPathComponent().path)
        #expect(result.snapshot?.metadata.installedSkills.first?.sourceKind == .manualFilesystem)
        #expect(result.snapshot?.metadata.installedSkills.first?.sourceID == nil)
        #expect(try Data(contentsOf: existingSkill) == existingBytes)
    }

    @Test func driftConflictAndMutatedPlanAreRejectedBeforeTheFirstBusinessWrite() async throws {
        let driftFixture = try RootInitializationFixture()
        defer { driftFixture.remove() }
        let driftPlan = try driftFixture.plan()
        let external = driftFixture.root.appendingPathComponent("appeared-after-planning.txt")
        try Data("external".utf8).write(to: external)
        let afterExternalDrift = try driftFixture.treeSnapshot()

        let driftResult = await driftFixture.coordinator.commit(
            plan: driftPlan,
            confirmation: driftFixture.planner.confirmation(for: driftPlan)
        )

        #expect(driftResult.succeeded == false)
        #expect(try driftFixture.treeSnapshot() == afterExternalDrift)
        #expect(FileManager.default.fileExists(atPath: driftFixture.journal.path) == false)

        let conflictFixture = try RootInitializationFixture()
        defer { conflictFixture.remove() }
        try Data("occupied".utf8).write(to: conflictFixture.root.appendingPathComponent("local"))
        let conflictTree = try conflictFixture.treeSnapshot()
        #expect(throws: Phase1OperationError.self) {
            _ = try conflictFixture.plan()
        }
        #expect(try conflictFixture.treeSnapshot() == conflictTree)

        let mutationFixture = try RootInitializationFixture()
        defer { mutationFixture.remove() }
        let original = try mutationFixture.plan()
        let confirmation = mutationFixture.planner.confirmation(for: original)
        var mutated = original
        mutated.expectedWrites.append("outside-plan")
        let beforeMutationCommit = try mutationFixture.treeSnapshot()

        let mutationResult = await mutationFixture.coordinator.commit(
            plan: mutated,
            confirmation: confirmation
        )

        #expect(mutationResult.succeeded == false)
        #expect(try mutationFixture.treeSnapshot() == beforeMutationCommit)
        #expect(FileManager.default.fileExists(atPath: mutationFixture.journal.path) == false)
    }

    @Test func initializationCannotSucceedWhenItsJournalLosesTheConfirmedPlan() async throws {
        let fixture = try RootInitializationFixture()
        defer { fixture.remove() }
        let plan = try fixture.plan()
        let coordinator = Phase1OperationCoordinator(
            metadataStore: fixture.store,
            fileManager: TruncatedInitializationJournalFileManager()
        )

        let result = await coordinator.commit(plan: plan, confirmation: fixture.planner.confirmation(for: plan))

        #expect(result.succeeded == false)
        #expect(result.snapshot == nil)
        #expect(result.task.phase == .needsAttention)
        #expect(try fixture.store.loadCurrentSnapshot(from: fixture.root).metadata == plan.initialMetadata)
        #expect(try Phase1OperationJournal(rootURL: fixture.root).recoverTasks().allSatisfy { $0.phase == .needsAttention })
    }

    @Test(arguments: ["root-layout", "initial-metadata", "initial-local-state"], [Phase1JournalEventKind.stepStarted, .stepResult])
    func rootJournalFailureAtEachStepNeverActivatesOrReplays(step: String, event: Phase1JournalEventKind) async throws {
        let resultName = step == "root-layout" ? "root-layout-created" : step + "-committed"
        let fixture = try RootInitializationFixture(fault: .journal(event, event == .stepResult ? resultName : step))
        defer { fixture.remove() }
        let plan = try fixture.plan()
        let result = await fixture.coordinator.commit(plan: plan, confirmation: fixture.planner.confirmation(for: plan))
        #expect(result.succeeded == false)
        #expect(result.snapshot == nil)
        let before = try fixture.treeSnapshot()
        _ = try Phase1OperationJournal(rootURL: fixture.root).recoverTasks()
        #expect(try fixture.treeSnapshot() == before)
    }

    @Test func authorizationReplayDoesNotChangeAnEstablishedRoot() async throws {
        let fixture = try RootInitializationFixture()
        defer { fixture.remove() }
        let plan = try fixture.plan()
        let confirmation = fixture.planner.confirmation(for: plan)
        let first = await fixture.coordinator.commit(plan: plan, confirmation: confirmation)
        guard first.succeeded else {
            Issue.record("Root initialization failed before replay: \(first.task.result)")
            return
        }
        let afterFirst = try fixture.treeSnapshot()

        let replay = await fixture.coordinator.commit(plan: plan, confirmation: confirmation)

        #expect(replay.succeeded == false)
        #expect(replay.task.phase == .needsAttention)
        #expect(try fixture.treeSnapshot() == afterFirst)
    }

    @Test func firstLayoutFailureStopsLaterWritesAndRecoveryNeverReplaysIt() async throws {
        let fixture = try RootInitializationFixture(fault: .afterRootLayoutDirectory)
        defer { fixture.remove() }
        let plan = try fixture.plan()

        let result = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )
        let recovered = try Phase1OperationJournal(rootURL: fixture.root).recoverTasks()
        let afterFailure = try fixture.treeSnapshot()

        #expect(result.succeeded == false)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("local").path))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("github").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.metadata.path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.localState.path) == false)
        #expect(recovered.first?.phase == .needsAttention)
        #expect(recovered.first?.result.contains("will not be replayed automatically") == true)

        let retry = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )
        #expect(retry.succeeded == false)
        #expect(try fixture.treeSnapshot() == afterFailure)
    }

    @Test func interruptionAfterMetadataUsesCurrentFactsAndRemainsNeedsAttention() async throws {
        let fixture = try RootInitializationFixture(fault: .afterRootMetadataCommit)
        defer { fixture.remove() }
        let plan = try fixture.plan()

        let result = await fixture.coordinator.commit(
            plan: plan,
            confirmation: fixture.planner.confirmation(for: plan)
        )
        let snapshot = try fixture.store.loadCurrentSnapshot(from: fixture.root)
        let recovered = try Phase1OperationJournal(rootURL: fixture.root).recoverTasks()

        #expect(result.succeeded == false)
        #expect(snapshot.metadata == plan.initialMetadata)
        #expect(FileManager.default.fileExists(atPath: fixture.localState.path) == false)
        #expect(recovered.first?.phase == .needsAttention)
        #expect(recovered.first?.result.contains("metadata") == true)
        #expect(recovered.first?.result.contains("will not be replayed automatically") == true)
    }
}

// Adds no mutable state to FileManager; only the test-owned Root journal is changed.
private final class TruncatedInitializationJournalFileManager: FileManager, @unchecked Sendable {
    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        if url.lastPathComponent == "github" {
            try Data().write(to: url.deletingLastPathComponent().appendingPathComponent(".skillshub.operations.jsonl"))
        }
    }
}

private struct RootInitializationFixture {
    let fixtureRoot: URL
    let root: URL
    let sentinel: URL
    let store: SkillsHubMetadataStore
    let planner: Phase1OperationPlanner
    let coordinator: Phase1OperationCoordinator

    init(fault: Phase1OperationFaultInjection? = nil) throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        fixtureRoot = repositoryRoot
            .appendingPathComponent(".tmp/phase1-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = fixtureRoot.appendingPathComponent("root", isDirectory: true)
        sentinel = root.appendingPathComponent("sentinel.txt")
        store = SkillsHubMetadataStore()
        planner = Phase1OperationPlanner()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: sentinel)
        coordinator = Phase1OperationCoordinator(metadataStore: store, faultInjection: fault)
    }

    var journal: URL { store.rootLayout(for: root).operationJournalFile }
    var metadata: URL { store.rootLayout(for: root).skillshubMetadataFile }
    var localState: URL { SkillsHubLocalStateStore().localStateFile(for: root) }

    func plan() throws -> Phase1OperationPlan {
        try planner.rootInitializationPlan(facts: RootInspectionFacts(url: root))
    }

    func relativeTreePaths() throws -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in false }
            )
        )
        return try enumerator.compactMap { element -> String? in
            guard let url = element as? URL else { return nil }
            let values = try url.resourceValues(forKeys: Set(keys))
            let relative = String(url.path.dropFirst(root.path.count + 1))
            return values.isDirectory == true && values.isSymbolicLink != true ? relative + "/" : relative
        }.sorted()
    }

    func treeSnapshot() throws -> [String: String] {
        var snapshot: [String: String] = [:]
        for relative in try relativeTreePaths() {
            let normalized = relative.hasSuffix("/") ? String(relative.dropLast()) : relative
            let url = root.appendingPathComponent(normalized)
            if relative.hasSuffix("/") {
                snapshot[relative] = "directory"
            } else {
                snapshot[relative] = SHA256Digest.hex(try Data(contentsOf: url))
            }
        }
        return snapshot
    }

    func remove() {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }
}

private final class SourceEnumerationProbe: FileManager, @unchecked Sendable {
    var source = URL(fileURLWithPath: "/dev/null")
    var sourceEnumerations = 0

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        if url.standardizedFileURL == source.standardizedFileURL { sourceEnumerations += 1 }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

private final class SourceImportFileProbe: FileManager, @unchecked Sendable {
    let failure: String
    var target = URL(fileURLWithPath: "/dev/null")
    var copyCount = 0
    var renameCount = 0
    var nativeErrorCode: Int?
    var publishedInodeBefore: UInt64?
    var publishedInodeAfter: UInt64?

    init(failure: String) { self.failure = failure; super.init() }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        copyCount += 1
        if failure == "copy" {
            try super.createDirectory(at: dstURL, withIntermediateDirectories: true)
            try Data("partial".utf8).write(to: dstURL.appendingPathComponent("partial"))
        }
        do { try super.copyItem(at: srcURL, to: dstURL) }
        catch { nativeErrorCode = (error as NSError).code; throw error }
        if failure == "source-drift" {
            let entry = srcURL.appendingPathComponent("SKILL.md")
            try (Data(contentsOf: entry) + Data("External change".utf8)).write(to: entry)
        }
        if failure == "target-race" {
            try super.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("preserve".utf8).write(to: target.appendingPathComponent("foreign.txt"))
        }
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        renameCount += 1
        if failure == "rename" {
            try super.createDirectory(at: dstURL, withIntermediateDirectories: true)
            try Data("preserve".utf8).write(to: dstURL.appendingPathComponent("foreign.txt"))
        }
        publishedInodeBefore = (try super.attributesOfItem(atPath: srcURL.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        do { try super.moveItem(at: srcURL, to: dstURL) }
        catch { nativeErrorCode = (error as NSError).code; throw error }
        publishedInodeAfter = (try super.attributesOfItem(atPath: dstURL.path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    override func removeItem(at URL: URL) throws {
        if failure == "compensation" && URL == target { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }
}

private struct Phase1Fixture {
    let root: URL
    let source: URL
    let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let assetID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-addd-eeeeeeeeeeee")!
    let store: SkillsHubMetadataStore
    let planner: Phase1OperationPlanner
    let coordinator: Phase1OperationCoordinator

    init(fault: Phase1OperationFaultInjection? = nil, metadataCheckpoint: (@Sendable (MetadataWritePhase, URL) throws -> Void)? = nil, fileManager: FileManager = .default) throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureRoot = repositoryRoot
            .appendingPathComponent(".tmp/phase1-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = fixtureRoot.appendingPathComponent("root", isDirectory: true)
        let source = fixtureRoot.appendingPathComponent("source/review", isDirectory: true)
        let store = SkillsHubMetadataStore()
        let planner = Phase1OperationPlanner()
        self.root = root
        self.source = source
        self.store = store
        self.planner = planner
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try phase1SkillText(name: "Review", description: "Reviews local changes.").write(
            to: source.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try store.save(SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)), to: root)
        coordinator = Phase1OperationCoordinator(metadataStore: SkillsHubMetadataStore(writeCheckpoint: metadataCheckpoint), fileManager: fileManager, faultInjection: fault)
    }

    var sourceSkillFile: URL { source.appendingPathComponent("SKILL.md") }
    var managedDirectory: URL { root.appendingPathComponent("local/review", isDirectory: true) }
    var managedSkillFile: URL { managedDirectory.appendingPathComponent("SKILL.md") }
    var journal: URL { store.rootLayout(for: root).operationJournalFile }

    func stagingDirectory(for plan: Phase1OperationPlan) -> URL {
        store.rootLayout(for: root).operationRecoveryDirectory
            .appendingPathComponent(plan.id.uuidString, isDirectory: true)
    }

    func initialSnapshot() throws -> RootSnapshot {
        try store.loadCurrentSnapshot(from: root)
    }

    func metadataBytes() throws -> Data {
        try Data(contentsOf: store.rootLayout(for: root).skillshubMetadataFile)
    }

    func executeSourceImport() async throws -> (
        plan: Phase1OperationPlan,
        result: Phase1OperationResult,
        sourceBefore: Data,
        metadataBefore: Data
    ) {
        let plan = try planner.localSourceImportPlan(directory: source, rootURL: root, snapshot: initialSnapshot(), sourceID: sourceID)
        let sourceBefore = try Data(contentsOf: sourceSkillFile)
        let metadataBefore = try metadataBytes()
        let treeBefore = FileManager.default.subpaths(atPath: root.path)?.sorted() ?? []
        let result = await coordinator.commit(
            plan: plan,
            confirmation: planner.confirmation(for: plan)
        )
        Attachment.record(metadataBefore, named: "metadata-before.json")
        Attachment.record(try metadataBytes(), named: "metadata-after.json")
        if FileManager.default.fileExists(atPath: journal.path) {
            Attachment.record(try Data(contentsOf: journal), named: "operation-journal.jsonl")
        }
        Attachment.record(sourceBefore, named: "source-before.md")
        Attachment.record(try Data(contentsOf: sourceSkillFile), named: "source-after.md")
        Attachment.record(treeBefore.joined(separator: "\n"), named: "root-before.txt")
        Attachment.record((FileManager.default.subpaths(atPath: root.path)?.sorted() ?? []).joined(separator: "\n"), named: "root-after.txt")
        return (plan, result, sourceBefore, metadataBefore)
    }

    func journalRecords(operationID: UUID) throws -> [Phase1JournalRecord] {
        let data = try Data(contentsOf: journal)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: 0x0A)
            .map { try decoder.decode(Phase1JournalRecord.self, from: Data($0)) }
            .filter { $0.operationID == operationID }
            .sorted { $0.sequence < $1.sequence }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

private func phase1SkillText(name: String, description: String) -> String {
    """
    ---
    name: \(name)
    description: \(description)
    ---
    Body.
    """
}

private func historicalInitializationJournal(_ data: Data, tampering: String? = nil) throws -> Data {
    var records = try data.split(separator: 0x0A).map {
        try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
    }
    var plan = try #require(records[0]["operationPlan"] as? [String: Any])
    var state = try #require(plan["initialLocalState"] as? [String: Any])
    state["managedRelationEvidence"] = [] as [String]
    plan["initialLocalState"] = state
    plan["planDigest"] = ""
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = SHA256Digest.hex(try encoder.encode(Phase1RecordedJSON(value: plan)))
    plan["planDigest"] = digest
    if tampering == "retired-field" {
        state["managedRelationEvidence"] = ["changed"]
        plan["initialLocalState"] = state
    } else if tampering == "current-field" {
        plan["expectedGeneration"] = 42
    }
    records[0]["operationPlan"] = plan
    for index in records.indices { records[index]["planDigest"] = digest }
    return try records.reduce(into: Data()) {
        $0 += try JSONSerialization.data(withJSONObject: $1, options: [.sortedKeys]) + Data([0x0A])
    }
}
