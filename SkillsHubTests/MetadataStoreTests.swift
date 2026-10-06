import Darwin
import Foundation
import Testing
@testable import SkillsHub

struct MetadataStoreTests {
    @Test(arguments: ["missing", "json", "version", "field", "type", "reference", "root"])
    func connectionCreatesCurrentMetadataAndPreservesContent(defect: String) throws {
        let root = try temporaryDirectory()
        let store = SkillsHubMetadataStore()
        let metadata = SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path))
        try store.save(metadata, to: root)
        let file = store.rootLayout(for: root).skillshubMetadataFile
        let marker = root.appendingPathComponent("local/content.txt")
        try Data("keep".utf8).write(to: marker)
        let link = root.appendingPathComponent("content-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: marker)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        switch defect {
        case "missing": try FileManager.default.removeItem(at: file)
        case "json": try Data("{".utf8).write(to: file)
        default:
            switch defect {
            case "version": json["schemaVersion"] = -1
            case "field": json.removeValue(forKey: "logicalRevision")
            case "type": json["agents"] = "invalid"
            case "reference":
                json["enablementIntents"] = [["assetID": UUID().uuidString, "agentID": "codex", "scope": "global", "isEnabled": true, "generation": 0]]
            case "root": json["rootConfig"] = ["rootPath": "/different-root"]
            default: Issue.record("Unexpected defect")
            }
            try JSONSerialization.data(withJSONObject: json).write(to: file)
        }
        let snapshot = try store.loadOrCreateSnapshot(from: root)
        #expect(snapshot.metadata.rootConfig.id != metadata.rootConfig.id)
        #expect(snapshot.metadata.schemaVersion == SkillsHubMetadata.currentSchemaVersion)
        #expect(snapshot.metadata.agents == AgentConfigurationRecord.phase1BuiltIns)
        #expect(snapshot.metadata.enablementIntents.isEmpty)
        #expect(snapshot == (try store.loadCurrentSnapshot(from: root)))
        let bytes = try Data(contentsOf: file)
        #expect(try store.loadOrCreateSnapshot(from: root) == snapshot)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == marker.path)
    }

    @Test(arguments: ["directory", "symlink", "unreadable", "concurrent", "writeFailure"])
    func rebuildingMetadataPreservesAccessAndWriteFailures(failure: String) throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent(".skillshub.json")
        let bytes = Data("invalid JSON".utf8)
        try bytes.write(to: file)
        var target: URL?
        switch failure {
        case "directory":
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        case "symlink":
            target = root.appendingPathComponent("target")
            try bytes.write(to: #require(target))
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: #require(target))
        case "unreadable":
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        default: break
        }
        defer { if failure == "unreadable" { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) } }
        let store = SkillsHubMetadataStore(writeCheckpoint: { phase, _ in
            if failure == "concurrent", phase == .replacement {
                try Data("external edit".utf8).write(to: file, options: .atomic)
            }
            if failure == "writeFailure", phase == .staging {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        })
        #expect(throws: (any Error).self) { _ = try store.loadOrCreateSnapshot(from: root) }
        if failure == "concurrent" {
            #expect(try Data(contentsOf: file) == Data("external edit".utf8))
        } else if failure == "writeFailure" {
            #expect(try Data(contentsOf: file) == bytes)
        } else if let target {
            #expect(try Data(contentsOf: target) == bytes)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == target.path)
        }
    }
    @Test func metadataStoreWritesOnlyRootLongTermStateToRoot() throws {
        let root = try temporaryDirectory()
        let appSupport = try temporaryDirectory()
        let store = SkillsHubMetadataStore()
        let metadata = SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path, appSupportPath: appSupport.path))

        try store.ensureAppContainerLayout(at: appSupport)
        try store.save(metadata, to: root)

        let rootEntries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(Set(rootEntries) == [".skillshub.json", ".skillshub.lock", "github", "local"])
        #expect(!rootEntries.contains("Cache"))
        #expect(!rootEntries.contains("Indexes"))
        #expect(!rootEntries.contains("Logs"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("local").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("github").path))

        let containerEntries = try FileManager.default.contentsOfDirectory(atPath: appSupport.path)
        #expect(containerEntries.contains("Cache"))
        #expect(containerEntries.contains("Indexes"))
        #expect(containerEntries.contains("Logs"))

        let loaded = try store.load(from: root)
        #expect(loaded.rootConfig.rootPath == root.path)
    }

    @Test func rootLayoutKeepsLongTermStateSeparateFromNpxSkillsState() throws {
        let root = URL(fileURLWithPath: "/Users/example/ai-projects/skills-hub")
        let layout = SkillsHubMetadataStore().rootLayout(for: root)

        #expect(layout.localDirectory.path == "/Users/example/ai-projects/skills-hub/local")
        #expect(layout.githubDirectory.path == "/Users/example/ai-projects/skills-hub/github")
        #expect(layout.skillsDirectory.path == "/Users/example/ai-projects/skills-hub/local")
        #expect(layout.installedEntryURL(for: "review").path == "/Users/example/ai-projects/skills-hub/local/review")
        #expect(layout.skillshubMetadataFile.path == "/Users/example/ai-projects/skills-hub/.skillshub.json")
        #expect(layout.writeLockFile.path == "/Users/example/ai-projects/skills-hub/.skillshub.lock")
        #expect(layout.operationRecoveryDirectory.path == "/Users/example/ai-projects/skills-hub/.skillshub-operations")
    }

    @Test func rootLayoutCreatesSourceContainersIdempotently() throws {
        let root = try temporaryDirectory()

        try SkillsHubMetadataStore().ensureRootLayout(at: root)

        let rootEntries = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(rootEntries.contains("local"))
        #expect(rootEntries.contains("github"))
        #expect(!rootEntries.contains("unrelated"))

        try SkillsHubMetadataStore().ensureRootLayout(at: root)
    }

    @Test func currentSchemaRoundTripsCanonicalIntentWithoutPublishingLocalRelationEvidence() throws {
        let root = try temporaryDirectory()
        let store = SkillsHubMetadataStore()
        let relation = canonicalRelation()
        let intent = EnablementIntent(
            assetID: relation.assetID,
            agentID: relation.agentID,
            scope: relation.scope,
            isEnabled: true,
            generation: 7
        )
        let metadata = SkillsHubMetadata(
            logicalRevision: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            generation: 7,
            rootConfig: canonicalRootConfig(path: root.path),
            installedSkills: [canonicalInstalledSkill(relation: relation)],
            enablementIntents: [intent]
        )

        try store.save(metadata, to: root)
        let loaded = try store.load(from: root)
        let file = store.rootLayout(for: root).skillshubMetadataFile
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])

        #expect(loaded == metadata)
        #expect(object["enablementIntents"] != nil)
        #expect(object["targetObservations"] == nil)
        #expect(object["managedRelationEvidence"] == nil)
        #expect(object["verificationRecords"] == nil)
    }

    @Test func legacyCreationEvidenceIsIgnoredWithoutRebuildingManagementRecords() throws {
        let root = try temporaryDirectory()
        let store = SkillsHubMetadataStore()
        let relation = canonicalRelation()
        let metadata = SkillsHubMetadata(
            generation: 7, rootConfig: canonicalRootConfig(path: root.path),
            installedSkills: [canonicalInstalledSkill(relation: relation)],
            enablementIntents: [EnablementIntent(assetID: relation.assetID, agentID: relation.agentID,
                scope: .global, isEnabled: true, generation: 7)]
        )
        try store.save(metadata, to: root)
        let file = store.rootLayout(for: root).skillshubMetadataFile
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        legacy["managedRelationEvidence"] = ["obsolete-creation-record"]
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let snapshot = try store.loadCurrentSnapshot(from: root)
        #expect(snapshot.metadata == metadata)
        let committed = try store.commit(at: root, expected: snapshot) { _ in }
        #expect(committed.metadata.enablementIntents == metadata.enablementIntents)
        #expect(committed.metadata.installedSkills == metadata.installedSkills)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(saved["managedRelationEvidence"] == nil)
    }

    @Test func localStateRoundTripsObservationAndVerificationWithoutChangingPublicIntent() throws {
        let root = try temporaryDirectory()
        let metadataStore = SkillsHubMetadataStore()
        let localStore = SkillsHubLocalStateStore()
        let relation = canonicalRelation()
        let identity = TargetFileIdentity(volumeNumber: 11, fileNumber: 29)
        let intent = EnablementIntent(
            assetID: relation.assetID,
            agentID: relation.agentID,
            scope: relation.scope,
            isEnabled: true,
            generation: 4
        )
        let observation = TargetObservation(
            relation: relation,
            linkPath: "/agent/review",
            nodeKind: .symbolicLink,
            linkText: "/root/local/review",
            resolvedTargetPath: "/root/local/review",
            fileIdentity: identity,
            isReadable: true,
            isWritable: true,
            observedAt: Date(timeIntervalSince1970: 123),
            limitation: nil
        )
        let bindings = canonicalBindings(intent: intent, observation: observation)
        let verification = VerificationRecord(
            relation: relation,
            conclusion: .verifiedConsistent,
            bindings: bindings,
            factsDigest: bindings.digest,
            observedAt: observation.observedAt,
            limitations: [],
            safeNextStep: "none"
        )
        let localState = SkillsHubLocalState(
            targetObservations: [observation],
            verificationRecords: [verification]
        )
        let metadata = SkillsHubMetadata(
            generation: 4,
            rootConfig: canonicalRootConfig(path: root.path),
            installedSkills: [canonicalInstalledSkill(relation: relation)],
            enablementIntents: [intent]
        )

        try metadataStore.save(metadata, to: root)
        let publicBytes = try Data(contentsOf: metadataStore.rootLayout(for: root).skillshubMetadataFile)
        try localStore.save(localState, to: root)

        #expect(try localStore.load(from: root) == localState)
        #expect(try metadataStore.load(from: root).enablementIntents == [intent])
        #expect(try Data(contentsOf: metadataStore.rootLayout(for: root).skillshubMetadataFile) == publicBytes)
    }

    @Test func staleMetadataCASDoesNotPublishIntentOrMutateLocalRelationState() throws {
        let root = try temporaryDirectory()
        let metadataStore = SkillsHubMetadataStore()
        let localStore = SkillsHubLocalStateStore()
        let relation = canonicalRelation()
        let initial = SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path))
        let localState = SkillsHubLocalState()
        try metadataStore.save(initial, to: root)
        try localStore.save(localState, to: root)
        let snapshot = try metadataStore.loadCurrentSnapshot(from: root)
        _ = try metadataStore.commit(
            at: root,
            expected: snapshot
        ) { metadata in
            metadata.tags.append(TagRecord(id: "advance", displayName: "Advance"))
        }
        let publicBytes = try Data(contentsOf: metadataStore.rootLayout(for: root).skillshubMetadataFile)
        let localBytes = try Data(contentsOf: localStore.localStateFile(for: root))

        #expect(throws: MetadataCommitError.staleGeneration(expected: 0, actual: 1)) {
            _ = try metadataStore.commit(
                at: root,
                expected: snapshot
            ) { metadata in
                metadata.enablementIntents = [
                    EnablementIntent(
                        assetID: relation.assetID,
                        agentID: relation.agentID,
                        scope: relation.scope,
                        isEnabled: true,
                        generation: 1
                    )
                ]
            }
        }

        #expect(try Data(contentsOf: metadataStore.rootLayout(for: root).skillshubMetadataFile) == publicBytes)
        #expect(try Data(contentsOf: localStore.localStateFile(for: root)) == localBytes)
        #expect(try metadataStore.load(from: root).enablementIntents.isEmpty)
    }

    @Test func localStateWriteFailureCannotPublishOrChangePublicIntent() throws {
        let root = try temporaryDirectory()
        let metadataStore = SkillsHubMetadataStore()
        let localStore = SkillsHubLocalStateStore()
        let relation = canonicalRelation()
        let intent = EnablementIntent(
            assetID: relation.assetID,
            agentID: relation.agentID,
            scope: relation.scope,
            isEnabled: false,
            generation: 3
        )
        let metadata = SkillsHubMetadata(
            generation: 3,
            rootConfig: canonicalRootConfig(path: root.path),
            installedSkills: [canonicalInstalledSkill(relation: relation)],
            enablementIntents: [intent]
        )
        try metadataStore.save(metadata, to: root)
        let publicFile = metadataStore.rootLayout(for: root).skillshubMetadataFile
        let publicBytes = try Data(contentsOf: publicFile)
        try FileManager.default.createDirectory(
            at: localStore.localStateFile(for: root),
            withIntermediateDirectories: false
        )

        #expect(throws: (any Error).self) {
            try localStore.save(SkillsHubLocalState(), to: root)
        }
        #expect(try Data(contentsOf: publicFile) == publicBytes)
        #expect(try metadataStore.load(from: root).enablementIntents == [intent])
    }

    @Test(arguments: [UInt64(0), UInt64.max])
    func metadataCommitUsesGenerationAndDigestCAS(generation: UInt64) throws {
        let root = try temporaryDirectory()
        let store = SkillsHubMetadataStore()
        try store.save(SkillsHubMetadata(generation: generation, rootConfig: RootConfig(rootPath: root.path)), to: root)
        let initial = try store.loadCurrentSnapshot(from: root)
        if generation == UInt64.max {
            #expect(throws: MetadataCommitError.generationExhausted) {
                _ = try store.commit(at: root, expected: initial) { _ in }
            }
            #expect(try store.loadCurrentSnapshot(from: root) == initial)
            return
        }

        let committed = try store.commit(
            at: root,
            expected: initial
        ) { metadata in
            metadata.tags.append(TagRecord(id: "review", displayName: "Review"))
        }
        let bytesAfterCommit = try Data(contentsOf: store.rootLayout(for: root).skillshubMetadataFile)

        #expect(committed.generation == initial.generation + 1)
        #expect(committed.metadata.tags.map(\.id) == ["review"])
        #expect(throws: MetadataCommitError.expectedSnapshotRequired) {
            try store.save(initial.metadata, to: root)
        }
        #expect(throws: MetadataCommitError.staleGeneration(expected: 0, actual: 1)) {
            _ = try store.commit(
                at: root,
                expected: initial
            ) { metadata in
                metadata.tags.append(TagRecord(id: "stale", displayName: "Stale"))
            }
        }
        #expect(try Data(contentsOf: store.rootLayout(for: root).skillshubMetadataFile) == bytesAfterCommit)
    }

    @Test(arguments: ["logicalRevision", "generation", "candidateID", "assetID", "duplicateAsset", "missingSource"])
    func currentFormatRejectsMissingIdentityAndInvalidReferences(defect: String) throws {
        let root = try metadataTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillsHubMetadataStore()
        let source = SkillSource(kind: .localDirectory, name: "Source", localPath: "/source")
        let metadata = SkillsHubMetadata(
            rootConfig: RootConfig(rootPath: root.path),
            sources: [source],
            availableSkills: [AvailableSkill(id: "review", sourceID: source.id, skillPath: "review", name: "Review", description: "Review.", validation: .valid)],
            installedSkills: [canonicalInstalledSkill(relation: canonicalRelation())]
        )
        try store.save(metadata, to: root)
        let file = store.rootLayout(for: root).skillshubMetadataFile
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var assets = try #require(object["installedSkills"] as? [[String: Any]])
        switch defect {
        case "logicalRevision", "generation": object.removeValue(forKey: defect)
        case "candidateID":
            var candidates = try #require(object["availableSkills"] as? [[String: Any]])
            candidates[0].removeValue(forKey: "candidateID")
            object["availableSkills"] = candidates
        case "assetID": assets[0].removeValue(forKey: "assetID")
        case "duplicateAsset": assets.append(assets[0])
        case "missingSource": assets[0]["sourceID"] = UUID().uuidString
        default: Issue.record("Unknown schema defect.")
        }
        object["installedSkills"] = assets
        let invalidBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try invalidBytes.write(to: file)

        do {
            _ = try store.loadCurrentSnapshot(from: root)
            Issue.record("Invalid metadata must not publish a snapshot: \(defect)")
        } catch is DecodingError {
            #expect(["logicalRevision", "generation", "candidateID", "assetID"].contains(defect))
        } catch MetadataCommitError.writeVerificationFailed {
            #expect(["duplicateAsset", "missingSource"].contains(defect))
        }
        #expect(try Data(contentsOf: file) == invalidBytes)
    }

    @Test(arguments: [false, true])
    func metadataCASPreservesExternalEditsBeforeAndDuringMutation(editDuringMutation: Bool) throws {
        let root = try metadataTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillsHubMetadataStore()
        try store.save(SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)), to: root)
        let snapshot = try store.loadCurrentSnapshot(from: root)
        let file = store.rootLayout(for: root).skillshubMetadataFile
        // Whitespace changes the byte digest while keeping generation and JSON semantics intact.
        var externalBytes = try Data(contentsOf: file)
        externalBytes.append(Data("\n ".utf8))
        if editDuringMutation == false { try externalBytes.write(to: file) }

        #expect(throws: MetadataCommitError.staleDigest) {
            _ = try store.commit(
                at: root,
                expected: snapshot
            ) { metadata in
                if editDuringMutation { try externalBytes.write(to: file) }
                metadata.tags.append(TagRecord(id: "local", displayName: "Local"))
            }
        }
        #expect(try Data(contentsOf: file) == externalBytes)
    }

    /// Each unexplainable mapping must produce its own blocking reason naming the
    /// object, and none of them may be silently repaired, merged or renumbered.

    @Test(arguments: MetadataWritePhase.allCases)
    func metadataWriteFaultsPreserveOriginalBytesOrExplicitRecovery(phase: MetadataWritePhase) throws {
        let root = try metadataTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillsHubMetadataStore()
        try store.save(SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)), to: root)
        let snapshot = try store.loadCurrentSnapshot(from: root)
        let file = store.rootLayout(for: root).skillshubMetadataFile
        let original = try Data(contentsOf: file)
        let fault = NSError(domain: "MetadataWriteTest", code: 1)
        let failingStore = SkillsHubMetadataStore { checkpoint, url in
            if checkpoint == .staging {
                #expect(try Data(contentsOf: file) == original)
                Attachment.record(try Data(contentsOf: url), named: "staging.json")
            }
            if checkpoint == phase {
                switch checkpoint {
                case .encoding, .publishedFileSync, .readback:
                    #expect(url == file)
                case .stagingDirectorySync, .publishedDirectorySync:
                    #expect(url == file.deletingLastPathComponent())
                case .staging, .stagingFileSync, .replacement, .displacedOriginal:
                    #expect(url.deletingLastPathComponent() == file.deletingLastPathComponent())
                    #expect(url.lastPathComponent.hasSuffix(".staging"))
                }
                throw fault
            }
        }
        var published = snapshot
        do {
            published = try failingStore.commit(at: root, expected: snapshot) {
                $0.tags = [TagRecord(id: "new", displayName: "New")]
            }
            Issue.record("Injected write failure must not publish a snapshot.")
        } catch MetadataCommitError.recoveryRequired(let path, let backupPath, _, let reason) {
            #expect([
                .displacedOriginal,
                .publishedFileSync,
                .publishedDirectorySync,
                .readback
            ].contains(phase))
            #expect(path == file.path)
            #expect(reason.contains("MetadataWriteTest"))
            let backup = URL(fileURLWithPath: try #require(backupPath))
            #expect(try Data(contentsOf: backup) == original)
            Attachment.record(try Data(contentsOf: backup), named: "recovery-original.json")
        } catch {
            #expect(error as NSError == fault)
            #expect([
                .encoding,
                .staging,
                .stagingFileSync,
                .stagingDirectorySync,
                .replacement
            ].contains(phase))
            #expect(try Data(contentsOf: file) == original)
        }
        #expect(published == snapshot)
        Attachment.record(original, named: "before.json")
        Attachment.record(try Data(contentsOf: file), named: "after.json")
    }

    @Test func metadataCommitRejectsSameBytesInAReplacementNode() throws {
        let root = try metadataTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillsHubMetadataStore()
        try store.save(SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)), to: root)
        let snapshot = try store.loadCurrentSnapshot(from: root)
        let file = store.rootLayout(for: root).skillshubMetadataFile
        let original = try Data(contentsOf: file)

        try FileManager.default.removeItem(at: file)
        try original.write(to: file, options: [.withoutOverwriting])

        #expect(throws: MetadataCommitError.metadataIdentityChanged) {
            _ = try store.commit(at: root, expected: snapshot) {
                $0.tags.append(TagRecord(id: "must-not-publish", displayName: "Must not publish"))
            }
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func metadataCommitRequiresTheCrossProcessWriteQualification() throws {
        let root = try metadataTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillsHubMetadataStore()
        try store.save(SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)), to: root)
        let snapshot = try store.loadCurrentSnapshot(from: root)
        let file = store.rootLayout(for: root).skillshubMetadataFile
        let original = try Data(contentsOf: file)
        let holder = try #require(try? RootProcessWriteLock.acquire(
            at: store.rootLayout(for: root).writeLockFile
        ).get())
        defer { holder.release() }

        #expect(throws: RootWriteUnavailableReason.heldByAnotherProcess) {
            _ = try store.commit(at: root, expected: snapshot) {
                $0.tags.append(TagRecord(id: "must-not-publish", displayName: "Must not publish"))
            }
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func metadataCommitKeepsExternalPostPublishEditAndDisplacedOriginal() throws {
        let root = try metadataTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let initialStore = SkillsHubMetadataStore()
        try initialStore.save(SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)), to: root)
        let snapshot = try initialStore.loadCurrentSnapshot(from: root)
        let file = initialStore.rootLayout(for: root).skillshubMetadataFile
        let original = try Data(contentsOf: file)
        let external = Data("{\"external\":true}".utf8)
        let racingStore = SkillsHubMetadataStore { phase, _ in
            if phase == .displacedOriginal {
                try external.write(to: file)
            }
        }

        do {
            _ = try racingStore.commit(at: root, expected: snapshot) {
                $0.tags.append(TagRecord(id: "candidate", displayName: "Candidate"))
            }
            Issue.record("A post-publish external edit must not be reported as success.")
        } catch MetadataCommitError.recoveryRequired(let metadataPath, let backupPath, _, _) {
            #expect(metadataPath == file.path)
            let backupPath = try #require(backupPath)
            #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == original)
        }
        #expect(try Data(contentsOf: file) == external)
    }

    @Test func initialMetadataPublishNeverOverwritesAConcurrentOccupant() throws {
        let root = try metadataTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = SkillsHubMetadataStore().rootLayout(for: root).skillshubMetadataFile
        let external = Data("external occupant".utf8)
        let store = SkillsHubMetadataStore { phase, _ in
            if phase == .replacement {
                try external.write(to: file, options: [.withoutOverwriting])
            }
        }
        try store.ensureRootLayout(at: root)

        #expect(throws: Phase1OperationError.targetConflict(file.path)) {
            _ = try store.writeInitialMetadata(
                SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)),
                to: root
            )
        }
        #expect(try Data(contentsOf: file) == external)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
            $0.hasSuffix(".staging")
        } == false)
    }

    @Test func metadataCommitStopsWhenItsParentDirectoryIsReplaced() throws {
        let root = try metadataTestDirectory()
        let movedRoot = root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-moved")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: movedRoot)
        }
        let initialStore = SkillsHubMetadataStore()
        try initialStore.save(SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)), to: root)
        let snapshot = try initialStore.loadCurrentSnapshot(from: root)
        let originalFile = initialStore.rootLayout(for: root).skillshubMetadataFile
        let original = try Data(contentsOf: originalFile)
        let replacement = Data("replacement parent".utf8)
        let racingStore = SkillsHubMetadataStore { phase, _ in
            guard phase == .replacement else { return }
            try FileManager.default.moveItem(at: root, to: movedRoot)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try replacement.write(to: originalFile)
        }

        #expect(throws: MetadataCommitError.metadataParentIdentityChanged) {
            _ = try racingStore.commit(at: root, expected: snapshot) {
                $0.tags.append(TagRecord(id: "must-not-publish", displayName: "Must not publish"))
            }
        }
        #expect(try Data(contentsOf: originalFile) == replacement)
        #expect(try Data(contentsOf: movedRoot.appendingPathComponent(".skillshub.json")) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: movedRoot.path).contains {
            $0.hasSuffix(".staging")
        })
    }

    @Test func strictReadReportsInvalidVersionWithoutWriting() throws {
        let root = try temporaryDirectory()
        let store = SkillsHubMetadataStore()
        try store.save(
            SkillsHubMetadata(rootConfig: RootConfig(rootPath: root.path)),
            to: root
        )
        let file = store.rootLayout(for: root).skillshubMetadataFile
        var input = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        input["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: [.atomic])
        let originalData = try Data(contentsOf: file)

        var didThrow = false
        do {
            _ = try store.load(from: root)
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(try Data(contentsOf: file) == originalData)
    }

    @Test func currentFormatRoundTripsIdentityGenerationStableNameAndIntents() throws {
        let root = try temporaryDirectory()
        let store = SkillsHubMetadataStore()
        let relation = canonicalRelation()
        let source = SkillSource(
            kind: .localDirectory,
            name: "Source",
            localPath: "/source",
            baselineManifest: canonicalBaselineManifest()
        )
        var asset = canonicalInstalledSkill(relation: relation)
        asset.sourceID = source.id
        asset.stableLinkName = "review-link"
        let candidate = AvailableSkill(
            id: "review", sourceID: source.id, skillPath: "review",
            name: "Review", description: "Review.", validation: .valid
        )
        asset.candidateID = candidate.candidateID
        let intent = EnablementIntent(
            assetID: relation.assetID, agentID: relation.agentID,
            scope: relation.scope, isEnabled: true, generation: 7
        )
        let metadata = SkillsHubMetadata(
            logicalRevision: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            generation: 7,
            rootConfig: canonicalRootConfig(path: root.path),
            sources: [source],
            availableSkills: [candidate],
            installedSkills: [asset],
            enablementIntents: [intent])

        try store.save(metadata, to: root)
        let loaded = try store.load(from: root)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.rootLayout(for: root).skillshubMetadataFile)) as? [String: Any]
        )

        #expect(loaded == metadata)
        #expect(loaded.schemaVersion == 4)
        #expect(loaded.logicalRevision == metadata.logicalRevision)
        #expect(loaded.generation == 7)
        #expect(loaded.installedSkills.first?.stableLinkName == "review-link")
        #expect(loaded.enablementIntents == [intent])
        #expect(loaded.sources.first?.baselineManifest == canonicalBaselineManifest())
        #expect(object["schemaVersion"] as? Int == 4)
    }

    @Test(arguments: ["illegalStableName", "escapingBaselinePath", "absoluteBaselinePath"])
    func currentFormatRejectsUnprovenIdentityReferencesAndOutOfBoundsPaths(defect: String) throws {
        let root = try metadataTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillsHubMetadataStore()
        let relation = canonicalRelation()
        var source = SkillSource(kind: .localDirectory, name: "Source", localPath: "/source")
        var asset = canonicalInstalledSkill(relation: relation)
        asset.sourceID = source.id
        switch defect {
        case "illegalStableName":
            asset.stableLinkName = "../escape"
        case "escapingBaselinePath":
            source.baselineManifest = canonicalBaselineManifest(relativePath: "nested/../../escape")
        case "absoluteBaselinePath":
            source.baselineManifest = canonicalBaselineManifest(relativePath: "/etc/passwd")
        default:
            Issue.record("Unknown metadata defect.")
        }
        let metadata = SkillsHubMetadata(
            generation: 1,
            rootConfig: canonicalRootConfig(path: root.path),
            sources: [source],
            installedSkills: [asset])
        let file = store.rootLayout(for: root).skillshubMetadataFile
        try store.ensureRootLayout(at: root)
        try metadataBytes(metadata).write(to: file, options: [.atomic])
        let invalidBytes = try Data(contentsOf: file)

        #expect(throws: MetadataCommitError.writeVerificationFailed) {
            _ = try store.loadCurrentSnapshot(from: root)
        }
        #expect(try Data(contentsOf: file) == invalidBytes)
        Attachment.record(invalidBytes, named: "metadata-\(defect).json")
    }

    @MainActor
    @Test func newRootDiscoversOnlySourceContainers() async throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("local/review"), withIntermediateDirectories: true)
        try skillText(name: "Review", description: "Visible local skill.").write(
            to: root.appendingPathComponent("local/review/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("unrelated/local/review"), withIntermediateDirectories: true)
        try skillText(name: "Unrelated Review", description: "Unrelated directory.").write(
            to: root.appendingPathComponent("unrelated/local/review/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let controller = SkillsHubLibraryController()
        try await connectInitializedTestRoot(controller, at: root)
        await controller.waitForPendingRechecks()

        // local/ direct content is discovered and registered on connect (REQ-003/REQ-014),
        // but never enabled; unrelated/ is outside the source containers and
        // must stay ignored.
        #expect(controller.installedSkills.map(\.id) == ["review"])
        #expect(controller.installedSkills.allSatisfy { $0.sourceKind == .manualFilesystem })
        #expect(controller.installedSkills.allSatisfy { $0.sourceID == nil })
        let review = try #require(controller.installedSkills.first)
        #expect(review.installedPath.contains("/local/review"))
        #expect(!review.installedPath.contains("unrelated"))
    }
}

private func metadataTestDirectory() throws -> URL {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".tmp/metadata-tests/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func metadataBytes(_ metadata: SkillsHubMetadata) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(metadata)
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

private func canonicalRelation() -> AgentRelationIdentity {
    AgentRelationIdentity(
        assetID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        agentID: AgentKind.codex.rawValue,
        scope: .global
    )
}

private func canonicalRootConfig(path: String) -> RootConfig {
    RootConfig(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        rootPath: path,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
}

private func canonicalInstalledSkill(relation: AgentRelationIdentity) -> InstalledSkill {
    InstalledSkill(
        id: "review",
        sourceID: nil,
        name: "Review",
        description: "Reviews changes.",
        installedPath: "/root/local/review",
        sourceKind: .localDirectory,
        validation: .valid,
        purpose: nil,
        tagIDs: [],
        installedAt: Date(timeIntervalSince1970: 100),
        assetID: relation.assetID,
        canonicalPathComponent: "review",
        currentRevision: "revision-v1",
        manifestDigest: "manifest-v1",
        managedGeneration: 4
    )
}

private func canonicalBaselineManifest(relativePath: String = "SKILL.md") -> ContentManifest {
    let entry = ContentManifestEntry(
        relativePath: relativePath,
        kind: .file,
        byteDigest: "digest-v1",
        symbolicLinkTarget: nil,
        isExecutable: false,
        byteCount: 12
    )
    return ContentManifest(
        entries: [entry],
        fileCount: 1,
        totalByteCount: 12,
        digest: "manifest-digest-v1",
        observedAt: Date(timeIntervalSince1970: 130)
    )
}

private func canonicalBindings(
    intent: EnablementIntent,
    observation: TargetObservation
) -> RelationVerificationBindings {
    RelationVerificationBindings(
        rootGeneration: 4,
        assetRevision: "revision-v1",
        manifestDigest: "manifest-v1",
        canonicalPath: "/root/local/review",
        canonicalPathFingerprint: "canonical-v1",
        profileID: "skillshub.agent-profile.codex.global",
        profileVersion: 1,
        profileSchemaVersion: 1,
        profileIsValid: true,
        agentExists: true,
        globalTargetPath: "/agent",
        authorizationFingerprint: "authorization-v1",
        targetIsAuthorized: true,
        isReadable: true,
        isWritable: true,
        linkPath: observation.linkPath,
        nodeKind: observation.nodeKind,
        nodeFingerprint: observation.fileIdentity?.fingerprint,
        linkText: observation.linkText,
        resolvedTargetPath: observation.resolvedTargetPath,
        observationDigest: observation.digest,
        enablementIntent: intent
    )
}
