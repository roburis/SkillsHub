import Darwin
import Foundation
import Testing
@testable import SkillsHub

struct RelationActionExecutionTests {
    @Test func confirmedBrokenRelativeLinkDeletesOnlyTheNodeAndKeepsMetadata() throws {
        let fixture = try BrokenLinkDeletionFixture(
            rawTarget: "../target-alias",
            intermediateTarget: "missing-target"
        )
        let metadataBefore = try Data(contentsOf: fixture.metadataURL)

        let result = fixture.execute()

        #expect(result.status == .succeeded)
        #expect((try? LinkNodeIdentity.read(at: fixture.linkURL)) == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.resolvedTarget.path) == false)
        #expect(try Data(contentsOf: fixture.metadataURL) == metadataBefore)
    }

    @Test func targetRestoredAfterConfirmationBlocksDeletion() throws {
        let fixture = try BrokenLinkDeletionFixture(rawTarget: "../missing-target")
        try FileManager.default.createDirectory(at: fixture.resolvedTarget, withIntermediateDirectories: false)

        let result = fixture.execute()

        #expect(result.status == .blocked)
        #expect((try? LinkNodeIdentity.read(at: fixture.linkURL)) == fixture.authorization.facts.nodeIdentity)
        #expect(FileManager.default.fileExists(atPath: fixture.resolvedTarget.path))
    }

    @Test func sameTargetReplacementAfterConfirmationIsNotDeleted() throws {
        let fixture = try BrokenLinkDeletionFixture(rawTarget: "../missing-target")
        try FileManager.default.removeItem(at: fixture.linkURL)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.linkURL.path,
            withDestinationPath: fixture.authorization.facts.rawTarget
        )
        let replacement = try LinkNodeIdentity.read(at: fixture.linkURL)

        let result = fixture.execute()

        #expect(result.status == .blocked)
        #expect(try LinkNodeIdentity.read(at: fixture.linkURL) == replacement)
        #expect(replacement != fixture.authorization.facts.nodeIdentity)
    }

    @Test func targetChainChangedAfterIsolationRetainsAuthorizedNodeForRecovery() throws {
        let fixture = try BrokenLinkDeletionFixture(
            rawTarget: "../target-alias",
            intermediateTarget: "missing-target"
        )
        let service = AgentLinkService(relationPrimitiveHook: { point, _ in
            if point == .afterIsolation {
                let intermediate = try #require(fixture.intermediateLinkURL)
                try FileManager.default.removeItem(at: intermediate)
                try FileManager.default.createSymbolicLink(
                    atPath: intermediate.path,
                    withDestinationPath: "different-missing-target"
                )
            }
        })

        let result = fixture.execute(linkService: service)

        #expect(result.status == .blocked)
        let retained = try #require(result.retainedPath)
        #expect(try LinkNodeIdentity.read(at: URL(fileURLWithPath: retained)) == fixture.authorization.facts.nodeIdentity)
        #expect((try? LinkNodeIdentity.read(at: fixture.linkURL)) == nil)
    }

    @MainActor
    @Test func clearAllManagedRelationsUsesSingleRelationPathForThreeAgents() async throws {
        let fixture = try makeControllerRelationFixture(agents: [.codex, .claudeCode])
        let customTarget = fixture.root.appendingPathComponent("custom-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: customTarget, withIntermediateDirectories: false)
        try fixture.controller.rememberUserSelectedAccess(to: customTarget)
        let custom = try await fixture.controller.addCustomAgent(
            displayName: "Custom Bench",
            iconMonogram: "CB",
            skillsDirectory: customTarget
        )

        let controlDirectory = fixture.root.appendingPathComponent("local/control", isDirectory: true)
        try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
        try Data("---\nname: Control\ndescription: Protected comparison Skill.\n---\n".utf8)
            .write(to: controlDirectory.appendingPathComponent("SKILL.md"))
        let beforeControlCommit = try SkillsHubMetadataStore().loadCurrentSnapshot(from: fixture.root)
        let afterControlCommit = try SkillsHubMetadataStore().commit(at: fixture.root, expected: beforeControlCommit) { metadata in
            metadata.installedSkills.append(
                InstalledSkill(
                    id: "control",
                    sourceID: nil,
                    name: "Control",
                    description: "Protected comparison Skill.",
                    installedPath: controlDirectory.path,
                    sourceKind: .localDirectory,
                    validation: .valid,
                    purpose: nil,
                    tagIDs: [],
                    installedAt: Date(timeIntervalSince1970: 0)
                )
            )
        }
        fixture.controller.rootSnapshot = afterControlCommit
        fixture.controller.installedSkills = afterControlCommit.metadata.installedSkills

        for agentID in [AgentKind.codex.rawValue, AgentKind.claudeCode.rawValue, custom.id] {
            #expect(try await fixture.controller.setGlobalAgentEnablement(
                agentID: agentID,
                skillID: "writer",
                enabled: true
            ).outcome == .succeeded)
        }
        #expect(try await fixture.controller.setGlobalAgentEnablement(
            agentID: AgentKind.codex.rawValue,
            skillID: "control",
            enabled: true
        ).outcome == .succeeded)

        let writerURL = fixture.root.appendingPathComponent("local/writer/SKILL.md")
        let writerBytes = try Data(contentsOf: writerURL)
        let plan = try fixture.controller.prepareManagedRelationClearPlan(skillID: "writer")
        #expect(plan.items.count == 3)
        #expect(plan.removableItems.count == 3)

        let result = try await fixture.controller.clearAllManagedRelations(using: plan)

        #expect(result.items.count == 3)
        #expect(result.items.allSatisfy { $0.outcome == .succeeded })
        #expect((try? LinkNodeIdentity.read(at: fixture.targets[.codex]!.appendingPathComponent("Writer"))) == nil)
        #expect((try? LinkNodeIdentity.read(at: fixture.targets[.claudeCode]!.appendingPathComponent("Writer"))) == nil)
        #expect((try? LinkNodeIdentity.read(at: customTarget.appendingPathComponent("Writer"))) == nil)
        #expect(try LinkNodeIdentity.read(at: fixture.targets[.codex]!.appendingPathComponent("Control")).kind == S_IFLNK)
        #expect(try Data(contentsOf: writerURL) == writerBytes)

        let metadata = try SkillsHubMetadataStore().loadCurrentSnapshot(from: fixture.root).metadata
        let writer = try #require(metadata.installedSkills.first { $0.id == "writer" })
        #expect(writer.stableLinkName == "Writer")
        #expect(metadata.installedSkills.contains { $0.id == "control" })
        #expect(metadata.enablementIntents.filter { $0.assetID == writer.assetID }.allSatisfy { !$0.isEnabled })
        let control = try #require(metadata.installedSkills.first { $0.id == "control" })
        #expect(metadata.enablementIntents.first { $0.assetID == control.assetID }?.isEnabled == true)
    }

    @MainActor
    @Test func clearAllManagedRelationsRejectsStalePreviewThenReportsBlockedAgent() async throws {
        let fixture = try makeControllerRelationFixture(agents: [.codex, .claudeCode])
        let customTarget = fixture.root.appendingPathComponent("custom-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: customTarget, withIntermediateDirectories: false)
        try fixture.controller.rememberUserSelectedAccess(to: customTarget)
        let custom = try await fixture.controller.addCustomAgent(
            displayName: "Custom Bench",
            iconMonogram: "CB",
            skillsDirectory: customTarget
        )
        for agentID in [AgentKind.codex.rawValue, AgentKind.claudeCode.rawValue, custom.id] {
            _ = try await fixture.controller.setGlobalAgentEnablement(
                agentID: agentID,
                skillID: "writer",
                enabled: true
            )
        }

        let stalePlan = try fixture.controller.prepareManagedRelationClearPlan(skillID: "writer")
        let customLink = customTarget.appendingPathComponent("Writer")
        try FileManager.default.moveItem(at: customLink, to: customLink.appendingPathExtension("managed"))
        try Data("external".utf8).write(to: customLink)

        await #expect(throws: ManagedRelationClearError.planChanged) {
            try await fixture.controller.clearAllManagedRelations(using: stalePlan)
        }
        #expect(try LinkNodeIdentity.read(at: fixture.targets[.codex]!.appendingPathComponent("Writer")).kind == S_IFLNK)
        #expect(try LinkNodeIdentity.read(at: fixture.targets[.claudeCode]!.appendingPathComponent("Writer")).kind == S_IFLNK)

        let currentPlan = try fixture.controller.prepareManagedRelationClearPlan(skillID: "writer")
        #expect(currentPlan.removableItems.count == 2)
        #expect(currentPlan.items.first { $0.relation.agentID == custom.id }?.disposition == .blocked)
        let result = try await fixture.controller.clearAllManagedRelations(using: currentPlan)

        #expect(result.items.filter { $0.outcome == .succeeded }.count == 2)
        #expect(result.items.first { $0.relation.agentID == custom.id }?.outcome == .blocked)
        #expect(try String(contentsOf: customLink, encoding: .utf8) == "external")
        #expect((try? LinkNodeIdentity.read(at: fixture.targets[.codex]!.appendingPathComponent("Writer"))) == nil)
        #expect((try? LinkNodeIdentity.read(at: fixture.targets[.claudeCode]!.appendingPathComponent("Writer"))) == nil)
    }

    @Test(arguments: [RelationActionExecutionFaultPoint.beforeIsolationRecord, .afterIsolationRecord,
                      .afterFilePrimitive, .beforeMetadataCAS, .afterMetadataCAS, .beforeFinalObservation])
    func disableFailureReportsActualPartialResultWithoutReplaying(_ checkpoint: RelationActionExecutionFaultPoint) throws {
        let fixture = try RelationExecutionFixture(node: .managed, intentEnabled: true)
        let authorization = fixture.authorization(desiredEnabled: false)
        let result = fixture.executor(faultHook: RelationTestHook { point in
            if point == checkpoint { throw RelationExecutionTestError.injected }
        }).execute(authorization: authorization, rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") })
        let beforeMove = checkpoint == .beforeIsolationRecord || checkpoint == .afterIsolationRecord
        let committed = checkpoint == .afterMetadataCAS || checkpoint == .beforeFinalObservation
        #expect(result.status == (beforeMove ? .failed : .unknown))
        #expect(try fixture.currentInspection().observation.nodeKind == (beforeMove ? .symbolicLink : .vacant))
        let metadata = try fixture.metadataStore.loadCurrentSnapshot(from: fixture.rootURL)
        #expect(metadata.metadata.enablementIntents.first { $0.agentID == AgentKind.codex.rawValue }?.isEnabled == !committed)
        let identity = try? LinkNodeIdentity.read(at: fixture.linkURL)
        _ = fixture.executor().recover(operationID: authorization.actionID, rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") })
        #expect((try? LinkNodeIdentity.read(at: fixture.linkURL)) == identity)
        #expect(try fixture.metadataStore.loadCurrentSnapshot(from: fixture.rootURL).metadataDigest == metadata.metadataDigest)
    }

    @Test(arguments: [false, true])
    func disableReoccupationNeverReportsSuccess(_ late: Bool) throws {
        let fixture = try RelationExecutionFixture(node: .managed, intentEnabled: true)
        let result = fixture.executor(
            linkService: AgentLinkService(relationPrimitiveHook: { point, _ in
                if !late, point == .afterIsolation { try Data("replacement".utf8).write(to: fixture.linkURL) }
            }), faultHook: RelationTestHook { point in
                if late, point == .beforeFinalObservation { try Data("replacement".utf8).write(to: fixture.linkURL) }
            }).execute(authorization: fixture.authorization(desiredEnabled: false), rootURL: fixture.rootURL,
                currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") })
        #expect(result.status == .unknown)
        #expect(try String(contentsOf: fixture.linkURL, encoding: .utf8) == "replacement")
        #expect(try String(contentsOf: fixture.canonicalURL.appendingPathComponent("SKILL.md"), encoding: .utf8) == "canonical")
    }

    @Test(arguments: [RelationLinkPrimitiveHookPoint.beforeRemovalPreflight, .beforeRemovalPin, .beforeIsolation],
          ["file", "directory", "same-target-link", "fifo"])
    func removalNeverDeletesReplacement(_ checkpoint: RelationLinkPrimitiveHookPoint, _ kind: String) throws {
        let fixture = try RelationExecutionFixture(node: .managed, intentEnabled: true)
        let original = fixture.linkURL.appendingPathExtension("original")
        let identity = try LinkNodeIdentity.read(at: fixture.linkURL)
        #expect(throws: (any Error).self) {
            try fixture.removeCandidate(service: AgentLinkService(relationPrimitiveHook: { point, _ in
                guard point == checkpoint else { return }
                try FileManager.default.moveItem(at: fixture.linkURL, to: original)
                switch kind {
                case "fifo": #expect(Darwin.mkfifo(fixture.linkURL.path, 0o600) == 0)
                case "file": try Data("external".utf8).write(to: fixture.linkURL)
                case "directory":
                    try FileManager.default.createDirectory(at: fixture.linkURL, withIntermediateDirectories: false)
                    try Data("external".utf8).write(to: fixture.linkURL.appendingPathComponent("sentinel"))
                default: try FileManager.default.createSymbolicLink(atPath: fixture.linkURL.path,
                    withDestinationPath: fixture.canonicalURL.path)
                }
            }))
        }
        #expect(try LinkNodeIdentity.read(at: original) == identity)
        switch kind {
        case "fifo": #expect(try LinkNodeIdentity.read(at: fixture.linkURL).kind == S_IFIFO)
        case "file": #expect(try String(contentsOf: fixture.linkURL, encoding: .utf8) == "external")
        case "directory": #expect(try String(contentsOf: fixture.linkURL.appendingPathComponent("sentinel"), encoding: .utf8) == "external")
        default: #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.linkURL.path) == fixture.canonicalURL.path)
        }
    }

    @Test(arguments: [false, true])
    func originalPositionReoccupationIsNeverOverwrittenOrDeleted(_ replacement: Bool) throws {
        let fixture = try RelationExecutionFixture(node: .managed, intentEnabled: true)
        let authorization = fixture.authorization(desiredEnabled: false)
        let outcome = Result {
            try fixture.removeCandidate(authorization: authorization,
                service: AgentLinkService(relationPrimitiveHook: { point, _ in
                    if replacement, point == .beforeIsolation {
                        try FileManager.default.moveItem(at: fixture.linkURL, to: fixture.linkURL.appendingPathExtension("original"))
                        try Data("moved-replacement".utf8).write(to: fixture.linkURL)
                    }
                    if point == .afterIsolation { try Data("new-occupant".utf8).write(to: fixture.linkURL) }
                }))
        }
        #expect(try String(contentsOf: fixture.linkURL, encoding: .utf8) == "new-occupant")
        let record = try RelationActionOperationRecordStore().load(operationID: authorization.actionID, rootURL: fixture.rootURL)
        let isolated = URL(fileURLWithPath: try #require(record.removal).isolationPath)
        if replacement {
            #expect(throws: RelationLinkPrimitiveError.replacementRetained) { try outcome.get() }
            #expect(try String(contentsOf: isolated, encoding: .utf8) == "moved-replacement")
        } else {
            #expect(try outcome.get().contains(.removed(isolated.path)))
        }
        Attachment.record(try JSONEncoder().encode(record), named: "removal-reoccupation-\(replacement).json")
    }

    @Test(arguments: [RelationLinkPrimitiveHookPoint.afterIsolation, .beforeUnlink])
    func isolationReplacementStopsWithoutRestoreOrDelete(_ checkpoint: RelationLinkPrimitiveHookPoint) throws {
        let fixture = try RelationExecutionFixture(node: .managed, intentEnabled: true)
        let authorization = fixture.authorization(desiredEnabled: false)
        #expect(throws: (any Error).self) {
            try fixture.removeCandidate(authorization: authorization,
                service: AgentLinkService(relationPrimitiveHook: { point, isolated in
                    guard point == checkpoint else { return }
                    try FileManager.default.moveItem(at: isolated, to: isolated.appendingPathExtension("original"))
                    try Data("isolation-replacement".utf8).write(to: isolated)
                }))
        }
        let record = try RelationActionOperationRecordStore().load(operationID: authorization.actionID, rootURL: fixture.rootURL)
        let removal = try #require(record.removal)
        let isolated = URL(fileURLWithPath: removal.isolationPath)
        #expect(try String(contentsOf: isolated, encoding: .utf8) == "isolation-replacement")
        #expect(try LinkNodeIdentity.read(at: isolated.appendingPathExtension("original")) == removal.creation.nodeIdentity)
        #expect(try fixture.currentInspection().observation.nodeKind == .vacant)
    }

    @Test(arguments: [RelationLinkPrimitiveHookPoint.beforeIsolation, .afterIsolation, .beforeUnlink],
          ["agent", "isolation", "permissions", "agent-permissions", "record", "metadata"])
    func removalStopsOnDirectoryOrRecordChanges(_ checkpoint: RelationLinkPrimitiveHookPoint, _ change: String) throws {
        let fixture = try RelationExecutionFixture(node: .managed, intentEnabled: true)
        let authorization = fixture.authorization(desiredEnabled: false)
        let operation = fixture.metadataStore.rootLayout(for: fixture.rootURL).operationRecoveryDirectory
            .appendingPathComponent(authorization.actionID.uuidString)
        let isolation = operation.appendingPathComponent("isolation")
        defer {
            _ = Darwin.chmod(isolation.path, 0o700)
            _ = Darwin.chmod(fixture.targetURL.path, 0o700)
        }
        #expect(throws: (any Error).self) {
            try fixture.removeCandidate(authorization: authorization,
                service: AgentLinkService(relationPrimitiveHook: { point, _ in
                    guard point == checkpoint else { return }
                    switch change {
                    case "metadata": try Data("external-json".utf8).write(to: fixture.metadataStore.rootLayout(for: fixture.rootURL).skillshubMetadataFile)
                    case "record": try Data("corrupt".utf8).write(to: operation.appendingPathComponent(RelationActionOperationRecordStore.recordFileName))
                    case "permissions": #expect(Darwin.chmod(isolation.path, 0o500) == 0)
                    case "agent-permissions": #expect(Darwin.chmod(fixture.targetURL.path, 0o500) == 0)
                    default:
                        let directory = change == "agent" ? fixture.targetURL : isolation
                        try FileManager.default.moveItem(at: directory, to: directory.appendingPathExtension("original"))
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    }
                }))
        }
        let name = checkpoint == .beforeIsolation ? "review" : "link"
        let directory: URL
        if checkpoint == .beforeIsolation {
            directory = change == "agent" ? fixture.targetURL.appendingPathExtension("original") : fixture.targetURL
        } else {
            directory = change == "isolation" ? isolation.appendingPathExtension("original") : isolation
        }
        #expect(try LinkNodeIdentity.read(at: directory.appendingPathComponent(name)).kind == S_IFLNK)
        #expect(try String(contentsOf: fixture.canonicalURL.appendingPathComponent("SKILL.md"), encoding: .utf8) == "canonical")
    }

    @Test(arguments: [RelationLinkPrimitiveHookPoint.beforeIsolation, .afterIsolation, .beforeUnlink, .afterUnlink])
    func interruptedRemovalRecoveryOnlyObserves(_ checkpoint: RelationLinkPrimitiveHookPoint) throws {
        let fixture = try RelationExecutionFixture(node: .managed, intentEnabled: true)
        let authorization = fixture.authorization(desiredEnabled: false)
        #expect(throws: RelationExecutionTestError.injected) {
            try fixture.removeCandidate(authorization: authorization,
                service: AgentLinkService(relationPrimitiveHook: { point, _ in
                    if point == checkpoint { throw RelationExecutionTestError.injected }
                }))
        }
        let store = RelationActionOperationRecordStore()
        let record = try store.load(operationID: authorization.actionID, rootURL: fixture.rootURL)
        let removal = try #require(record.removal)
        let isolated = URL(fileURLWithPath: removal.isolationPath)
        let originalIdentity = try? LinkNodeIdentity.read(at: fixture.linkURL)
        let isolatedIdentity = try? LinkNodeIdentity.read(at: isolated)
        let metadata = try fixture.metadataStore.loadCurrentSnapshot(from: fixture.rootURL)
        let recovery = fixture.executor().recover(operationID: authorization.actionID, rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") })
        #expect(recovery.components.contains { $0.kind == .isolationNode && $0.path == isolated.path })
        #expect((try? LinkNodeIdentity.read(at: fixture.linkURL)) == originalIdentity)
        #expect((try? LinkNodeIdentity.read(at: isolated)) == isolatedIdentity)
        #expect(try fixture.metadataStore.loadCurrentSnapshot(from: fixture.rootURL).metadataDigest == metadata.metadataDigest)
        if checkpoint == .beforeIsolation { #expect(originalIdentity == removal.creation.nodeIdentity) }
        if checkpoint == .afterIsolation || checkpoint == .beforeUnlink { #expect(isolatedIdentity == removal.creation.nodeIdentity) }
        if checkpoint == .afterUnlink { #expect(originalIdentity == nil && isolatedIdentity == nil) }
        Attachment.record(try JSONEncoder().encode(try store.load(operationID: authorization.actionID, rootURL: fixture.rootURL)),
            named: "removal-interruption-\(checkpoint).json")
    }

    @Test(arguments: [RelationLinkPrimitiveHookPoint.beforeRestore, .afterRestore])
    func interruptedReplacementRestoreIsNotReplayed(_ checkpoint: RelationLinkPrimitiveHookPoint) throws {
        let fixture = try RelationExecutionFixture(node: .managed, intentEnabled: true)
        let authorization = fixture.authorization(desiredEnabled: false)
        #expect(throws: RelationExecutionTestError.injected) {
            try fixture.removeCandidate(authorization: authorization,
                service: AgentLinkService(relationPrimitiveHook: { point, _ in
                    if point == .beforeIsolation {
                        try FileManager.default.moveItem(at: fixture.linkURL, to: fixture.linkURL.appendingPathExtension("original"))
                        try Data("external".utf8).write(to: fixture.linkURL)
                    }
                    if point == checkpoint { throw RelationExecutionTestError.injected }
                }))
        }
        let record = try RelationActionOperationRecordStore().load(operationID: authorization.actionID, rootURL: fixture.rootURL)
        let isolated = URL(fileURLWithPath: try #require(record.removal).isolationPath)
        let retained = checkpoint == .beforeRestore ? isolated : fixture.linkURL
        let identity = try LinkNodeIdentity.read(at: retained)
        _ = fixture.executor().recover(operationID: authorization.actionID, rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") })
        #expect(try LinkNodeIdentity.read(at: retained) == identity)
        #expect(try String(contentsOf: retained, encoding: .utf8) == "external")
    }

    @Test(arguments: ["occupied-isolation", "agent-permission", "record-enospc"])
    func failedIsolationLeavesOriginalNode(_ failure: String) throws {
        let fixture = try RelationExecutionFixture(node: .managed, intentEnabled: true)
        let authorization = fixture.authorization(desiredEnabled: false)
        let identity = try LinkNodeIdentity.read(at: fixture.linkURL)
        let operation = fixture.metadataStore.rootLayout(for: fixture.rootURL).operationRecoveryDirectory
            .appendingPathComponent(authorization.actionID.uuidString)
        defer { _ = Darwin.chmod(fixture.targetURL.path, 0o700) }
        let expected = failure == "occupied-isolation" ? EEXIST : EACCES
        let result = Result {
            try fixture.removeCandidate(authorization: authorization,
                service: AgentLinkService(relationPrimitiveHook: { point, _ in
                    guard point == .beforeIsolation else { return }
                    if failure == "occupied-isolation" {
                        try Data("occupant".utf8).write(to: operation.appendingPathComponent("isolation/link"))
                    } else if failure == "agent-permission" {
                        #expect(Darwin.chmod(fixture.targetURL.path, 0o500) == 0)
                    }
                }), beforeIsolationRecord: {
                    if failure == "record-enospc" {
                        throw RelationActionOperationRecordError.synchronizationFailed(path: operation.path, errno: ENOSPC)
                    }
                })
        }
        if failure == "record-enospc" {
            #expect(throws: RelationActionOperationRecordError.synchronizationFailed(path: operation.path, errno: ENOSPC)) {
                try result.get()
            }
        } else {
            #expect(throws: RelationLinkPrimitiveError.isolationFailed(expected)) { try result.get() }
        }
        #expect(try LinkNodeIdentity.read(at: fixture.linkURL) == identity)
    }

    @Test(arguments: [RelationLinkPrimitiveHookPoint.afterCreate, .beforePublish, .afterPublish])
    func sameTargetReplacementNeverAcquiresOwnership(_ checkpoint: RelationLinkPrimitiveHookPoint) throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
        let originalMetadata = try fixture.metadataStore.loadCurrentSnapshot(from: fixture.rootURL)
        let authorization = fixture.authorization(desiredEnabled: true)
        let result = fixture.executor(linkService: AgentLinkService(relationPrimitiveHook: { point, url in
            guard point == checkpoint else { return }
            // Keep the original inode alive independently of the primitive's descriptor.
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("original"))
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: fixture.canonicalURL.path)
        })).execute(authorization: authorization, rootURL: fixture.rootURL,
                    currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") })
        #expect(result.status == .unknown)
        #expect(try fixture.metadataStore.loadCurrentSnapshot(from: fixture.rootURL).metadataDigest == originalMetadata.metadataDigest)
        let record = try RelationActionOperationRecordStore().load(operationID: authorization.actionID, rootURL: fixture.rootURL)
        Attachment.record(try JSONEncoder().encode(record), named: "creation-replacement-\(checkpoint).json")
        let creation = try #require(record.creation)
        let replaced = checkpoint == .afterPublish ? fixture.linkURL : URL(fileURLWithPath: creation.stagingPath)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: replaced.path) == fixture.canonicalURL.path)
        #expect(try LinkNodeIdentity.read(at: replaced) != creation.nodeIdentity)
        #expect(try LinkNodeIdentity.read(at: replaced.appendingPathExtension("original")) == creation.nodeIdentity)
        #expect(try fixture.currentInspection().classification == (checkpoint == .afterPublish ? .externalLink : .vacant))
    }

    @Test(arguments: [RelationLinkPrimitiveHookPoint.beforeCreate, .beforePublish], ["file", "directory", "same-target-link"])
    func publicationNeverOverwritesOccupants(_ checkpoint: RelationLinkPrimitiveHookPoint, _ kind: String) throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
        let result = fixture.executor(linkService: AgentLinkService(relationPrimitiveHook: { point, _ in
            guard point == checkpoint else { return }
            switch kind {
            case "file": try Data("external".utf8).write(to: fixture.linkURL)
            case "directory": try FileManager.default.createDirectory(at: fixture.linkURL, withIntermediateDirectories: false)
            default: try FileManager.default.createSymbolicLink(atPath: fixture.linkURL.path, withDestinationPath: fixture.canonicalURL.path)
            }
        })).execute(authorization: fixture.authorization(desiredEnabled: true), rootURL: fixture.rootURL,
                    currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") })
        #expect(result.status == .unknown)
        #expect(try fixture.metadataStore.load(from: fixture.rootURL).managedRelationEvidence.isEmpty)
        switch kind {
        case "file": #expect(try String(contentsOf: fixture.linkURL, encoding: .utf8) == "external")
        case "directory": #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.linkURL.path).isEmpty)
        default: #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.linkURL.path) == fixture.canonicalURL.path)
        }
    }

    @Test(arguments: [RelationLinkPrimitiveHookPoint.beforeCreate, .afterCreate, .beforePublish, .afterPublish])
    func parentReplacementStopsCreationOrPublication(_ checkpoint: RelationLinkPrimitiveHookPoint) throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
        let originalParent = fixture.containerURL.appendingPathComponent("original-agent")
        let result = fixture.executor(linkService: AgentLinkService(relationPrimitiveHook: { point, _ in
            guard point == checkpoint else { return }
            try FileManager.default.moveItem(at: fixture.targetURL, to: originalParent)
            try FileManager.default.createDirectory(at: fixture.targetURL, withIntermediateDirectories: false)
            try Data("replacement".utf8).write(to: fixture.targetURL.appendingPathComponent("sentinel"))
        })).execute(authorization: fixture.authorization(desiredEnabled: true), rootURL: fixture.rootURL,
                    currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") })
        #expect(result.status == (checkpoint == .beforeCreate ? .blocked : .unknown))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.targetURL.path) == ["sentinel"])
        #expect(try fixture.metadataStore.load(from: fixture.rootURL).managedRelationEvidence.isEmpty)
        #expect(FileManager.default.fileExists(atPath: originalParent.path))
    }

    @Test(arguments: [RelationLinkPrimitiveHookPoint.afterCreate, .beforePublish, .afterPublish])
    func interruptedCreationRetainsRecordedSceneAndRecoveryDoesNotReplay(_ checkpoint: RelationLinkPrimitiveHookPoint) throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
        let authorization = fixture.authorization(desiredEnabled: true)
        let result = fixture.executor(linkService: AgentLinkService(relationPrimitiveHook: { point, _ in
            if point == checkpoint { throw RelationExecutionTestError.injected }
        })).execute(authorization: authorization, rootURL: fixture.rootURL,
                    currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") })
        #expect(result.status == .unknown)
        let store = RelationActionOperationRecordStore()
        let record = try store.load(operationID: authorization.actionID, rootURL: fixture.rootURL)
        #expect(try store.unfinishedOperationBlockers(
            agentID: fixture.relation.agentID,
            rootURL: fixture.rootURL
        ) == [UnfinishedAgentOperation(id: authorization.actionID, title: "Unfinished relationship operation")])
        Attachment.record(try JSONEncoder().encode(record), named: "creation-interruption-\(checkpoint).json")
        let creation = try #require(record.creation)
        #expect(record.completedAt == nil)
        let retained = checkpoint == .afterPublish ? fixture.linkURL : URL(fileURLWithPath: creation.stagingPath)
        #expect(try LinkNodeIdentity.read(at: retained) == creation.nodeIdentity)
        let beforeTree = try targetTree(at: fixture.targetURL)
        let beforeMetadata = try fixture.metadataStore.loadCurrentSnapshot(from: fixture.rootURL).metadataDigest
        let recovery = fixture.executor().recover(operationID: authorization.actionID, rootURL: fixture.rootURL,
                                      currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") })
        #expect(recovery.components.first { $0.kind == .preparationNode }?.state
            == (checkpoint == .afterPublish ? .completed : .notCompleted))
        #expect(try targetTree(at: fixture.targetURL) == beforeTree)
        #expect(try fixture.metadataStore.loadCurrentSnapshot(from: fixture.rootURL).metadataDigest == beforeMetadata)
        #expect(try fixture.metadataStore.load(from: fixture.rootURL).managedRelationEvidence.isEmpty)
    }

    @Test func unavailableCreationRecordPreventsPublication() throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
        let authorization = fixture.authorization(desiredEnabled: true)
        let material = fixture.metadataStore.rootLayout(for: fixture.rootURL).operationRecoveryDirectory
            .appendingPathComponent(authorization.actionID.uuidString)
            .appendingPathComponent(RelationActionOperationRecordStore.originalMetadataFileName)
        let result = fixture.executor(linkService: AgentLinkService(relationPrimitiveHook: { point, _ in
            if point == .beforePublish { try Data("damaged".utf8).write(to: material) }
        })).execute(authorization: authorization, rootURL: fixture.rootURL,
                    currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") })
        #expect(result.status == .unknown)
        #expect(try fixture.currentInspection().classification == .vacant)
        #expect(try fixture.metadataStore.load(from: fixture.rootURL).managedRelationEvidence.isEmpty)
        #expect(result.fileEvents.contains { if case .retainedForRecovery = $0 { true } else { false } })
    }

    @Test(arguments: [RelationActionExecutionFaultPoint.beforeMetadataCAS, .beforeFinalObservation])
    func replacementDuringCommitCannotReportSuccessfulEnablement(_ checkpoint: RelationActionExecutionFaultPoint) throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
        let result = fixture.executor(faultHook: RelationTestHook { point in
            guard point == checkpoint else { return }
            try FileManager.default.moveItem(at: fixture.linkURL, to: fixture.linkURL.appendingPathExtension("original"))
            try FileManager.default.createSymbolicLink(atPath: fixture.linkURL.path, withDestinationPath: fixture.canonicalURL.path)
        }).execute(authorization: fixture.authorization(desiredEnabled: true), rootURL: fixture.rootURL,
                   currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") })
        #expect(result.status == .unknown)
        #expect(try fixture.currentInspection().classification == .externalLink)
        if checkpoint == .beforeMetadataCAS {
            #expect(try fixture.metadataStore.load(from: fixture.rootURL).managedRelationEvidence.isEmpty)
        }
    }

    @Test func createReadbackFailureRetainsCreatedNodeAndReportsDelta() throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
        let result = fixture.executor(
            linkService: AgentLinkService(relationPrimitiveHook: { point, _ in
                if case .afterPublish = point { throw RelationExecutionTestError.injected }
            })
        ).execute(
            authorization: fixture.authorization(desiredEnabled: true),
            rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") }
        )
        #expect(result.status == .unknown)
        #expect(result.fileEvents == [.created(fixture.linkURL.path), .retainedForRecovery(fixture.linkURL.path)])
        #expect(result.safeNextStep == "observe-current-relation")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.linkURL.path) == fixture.canonicalURL.path)
        #expect(fixture.quarantineEntries().isEmpty)
    }

    @Test(arguments: [AgentKind.codex, .claudeCode], [true, false])
    func coordinatorReleasesLeaseOnceForRetainedEnablementAndSuccessfulDisable(_ agent: AgentKind, _ desiredEnabled: Bool) async throws {
        let fixture = try RelationExecutionFixture(node: desiredEnabled ? .vacant : .managed, intentEnabled: !desiredEnabled, agent: agent)
        let adapter = RecordingSecurityScopedResourceAccessAdapter()
        let actionID = UUID()
        let qualification = AgentTargetQualification(
            agentID: agent.rawValue, agent: agent, agentDetected: true, profileID: fixture.profileID,
            profileVersion: 1, schemaVersion: 1, scope: .global,
            candidates: [fixture.targetURL], authorizationStatus: .current,
            target: fixture.targetURL, failure: nil
        )
        let access = AgentTargetAccess(
            qualification: qualification,
            lease: try SecurityScopedAccessProvider(adapter: adapter).acquire(
                url: fixture.targetURL, owner: .agentTarget(actionID: actionID, agent: agent)
            )
        )
        let snapshot = try fixture.metadataStore.loadCurrentSnapshot(from: fixture.rootURL)
        let inspection = try fixture.currentInspection()
        let token = try RelationActionTokenBuilder().build(
            actionID: actionID, desiredEnabled: desiredEnabled, relation: fixture.relation,
            rootURL: fixture.rootURL, rootSessionOwner: .rootSession(UUID()), snapshot: snapshot,
            asset: try #require(snapshot.metadata.installedSkills.first), targetAccess: access,
            observation: inspection.observation, ownership: inspection.classification,
            currentIntent: snapshot.metadata.enablementIntents.first { $0.id == fixture.relation.id }
        )
        let executor = fixture.executor(faultHook: RelationTestHook { point in
            if desiredEnabled, point == .beforeMetadataCAS { throw RelationExecutionTestError.injected }
        })
        let result = await RelationActionCoordinator(rootMutationOwner: RootMutationOwner()).coordinate(
            token: token, rootURL: fixture.rootURL, targetAccess: access,
            currentFacts: { token.facts },
            perform: { authorization in
                executor.execute(
                    authorization: authorization, rootURL: fixture.rootURL,
                    currentInstallation: { AgentInstallationEvidence(agent: agent, digest: "fixture-installation") }
                )
            }
        )
        guard case .completed(let execution) = result.outcome else {
            Issue.record("Coordinator did not return the executor result")
            return
        }
        #expect(execution.status == (desiredEnabled ? .unknown : .succeeded))
        #expect(result.leaseRelease == .stopped)
        #expect(adapter.startRecords.count == 1)
        #expect(adapter.startRecords.first?.owner == .agentTarget(actionID: actionID, agent: agent))
        #expect(adapter.stoppedURLs == [fixture.targetURL])
        #expect(access.end(by: actionID) == .alreadyStopped)
        #expect(adapter.stopAttemptCount == 1)
        let finalIntents = try fixture.metadataStore.load(from: fixture.rootURL).enablementIntents
        if desiredEnabled {
            #expect(finalIntents == snapshot.metadata.enablementIntents)
        } else {
            #expect(finalIntents.first { $0.agentID == agent.rawValue }?.isEnabled == false)
        }
        #expect(fixture.quarantineEntries().isEmpty)
    }

    @Test func missingInstallationEvidenceDoesNotBlockAnAuthorizedTarget() throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
        let result = fixture.executor().execute(
            authorization: fixture.authorization(desiredEnabled: true),
            rootURL: fixture.rootURL,
            currentInstallation: { nil }
        )
        #expect(result.status == .succeeded)
        #expect(result.verification?.conclusion == .verifiedConsistent)
    }

    @Test func enableCreatesOneExactLinkAndCommitsOnlyItsIntentAndEvidence() throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
        let otherIntent = try #require(fixture.metadataStore.load(from: fixture.rootURL).enablementIntents.last)

        let result = fixture.executor().execute(
            authorization: fixture.authorization(desiredEnabled: true),
            rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") }
        )

        #expect(result.status == .succeeded)
        #expect(result.metadataDelta == .committed)
        #expect(result.fileEvents.contains(.created(fixture.linkURL.path)))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.linkURL.path) == fixture.canonicalURL.path)
        let metadata = try fixture.metadataStore.load(from: fixture.rootURL)
        #expect(metadata.installedSkills.first?.stableLinkName == "review")
        #expect(metadata.enablementIntents.first { $0.id == fixture.relation.id }?.isEnabled == true)
        #expect(metadata.enablementIntents.first { $0.id == otherIntent.id } == otherIntent)
        let evidence = try #require(metadata.managedRelationEvidence.first { $0.relation == fixture.relation })
        let observedIdentity = try #require(
            RelationOwnershipInspector().inspect(
                linkURL: fixture.linkURL,
                relation: fixture.relation,
                canonicalTargetPath: fixture.canonicalURL.path,
                evidence: evidence
            ).observation.fileIdentity
        )
        #expect(evidence.fileIdentity == observedIdentity)
        let creation = try #require(evidence.creation)
        #expect(creation.linkText == fixture.canonicalURL.path)
        #expect(try creation.nodeIdentity == LinkNodeIdentity.read(at: fixture.linkURL))
        #expect(try creation.parentIdentity == LinkNodeIdentity.read(at: fixture.targetURL))
        let record = try RelationActionOperationRecordStore().load(operationID: creation.operationID, rootURL: fixture.rootURL)
        Attachment.record(try JSONEncoder().encode(record), named: "creation-publication-record.json")
        #expect(record.creation == creation)
        #expect(record.preparationPaths.contains(creation.stagingPath))
        #expect(try FileManager.default.contentsOfDirectory(atPath: URL(fileURLWithPath: creation.stagingPath).deletingLastPathComponent().path).isEmpty)
        let local = try fixture.localStateStore.load(from: fixture.rootURL)
        #expect(local.verificationRecords.first { $0.relation == fixture.relation }?.conclusion == .verifiedConsistent)
        #expect(local.managedRelationEvidence.isEmpty)
        #expect(fixture.quarantineEntries().isEmpty)
    }

    @Test(arguments: [AgentKind.codex, .claudeCode])
    func cancellationFailureBeforePrimitiveDoesNotRewriteLocalState(_ agent: AgentKind) throws {
        let fixture = try RelationExecutionFixture(node: .managed, intentEnabled: true, agent: agent)
        let localFile = fixture.localStateStore.localStateFile(for: fixture.rootURL)
        let localIdentity = try #require(FileManager.default.attributesOfItem(atPath: localFile.path)[.systemFileNumber] as? NSNumber)
        let localBytes = try Data(contentsOf: localFile)
        let result = fixture.executor(faultHook: RelationTestHook { point in
            if point == .beforeFilePrimitive { throw RelationExecutionTestError.injected }
        }).execute(
            authorization: fixture.authorization(desiredEnabled: false), rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: agent, digest: "fixture-installation") }
        )
        #expect(result.status == .failed)
        #expect(result.metadataDelta == .none)
        #expect(result.fileEvents.isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: localFile.path)[.systemFileNumber] as? NSNumber == localIdentity)
        #expect(try Data(contentsOf: localFile) == localBytes)
        #expect(try fixture.currentInspection().classification == .exactManagedLink)
    }

    @Test(arguments: [AgentKind.codex, .claudeCode], [false, true])
    func disableDeletesOnlyManagedNodeAndCommitsItsRelation(_ agent: AgentKind, _ broken: Bool) throws {
        let fixture = try RelationExecutionFixture(node: broken ? .managedBroken : .managed, intentEnabled: true, agent: agent)
        let content = broken ? fixture.containerURL.appendingPathComponent("preserved-target") : fixture.canonicalURL
        let canonicalManifest = try directoryManifest(at: content)
        let authorization = fixture.authorization(desiredEnabled: false)
        let result = fixture.executor().execute(
            authorization: authorization,
            rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: agent, digest: "fixture-installation") }
        )
        #expect(result.status == .succeeded)
        #expect(result.metadataDelta == .committed)
        #expect(result.fileEvents.contains { if case .removed = $0 { true } else { false } })
        #expect(try fixture.currentInspection().observation.nodeKind == .vacant)
        #expect(try directoryManifest(at: content) == canonicalManifest)
        let metadata = try fixture.metadataStore.load(from: fixture.rootURL)
        #expect(metadata.enablementIntents.first { $0.agentID == agent.rawValue }?.isEnabled == false)
        #expect(metadata.managedRelationEvidence.isEmpty)
        let record = try RelationActionOperationRecordStore().load(operationID: authorization.actionID, rootURL: fixture.rootURL)
        #expect(record.removal != nil)
        #expect(record.isolationPaths.count == 1)
        Attachment.record(try JSONEncoder().encode(record), named: "removal-execution-\(agent.rawValue)-\(broken).json")
        let recovery = fixture.executor().recover(operationID: authorization.actionID, rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: agent, digest: "fixture-installation") })
        #expect(recovery.components.allSatisfy { $0.state == .completed })
    }

    @Test func exactEnabledAndExactDisabledStatesReturnNoChangeWithoutMetadataCAS() throws {
        let enabled = try RelationExecutionFixture(node: .managed, intentEnabled: true)
        let enabledIdentity = try #require(enabled.currentInspection().observation.fileIdentity)
        let enabledGeneration = try enabled.metadataStore.loadCurrentSnapshot(from: enabled.rootURL).generation

        let enabledResult = enabled.executor().execute(
            authorization: enabled.authorization(desiredEnabled: true),
            rootURL: enabled.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") }
        )

        #expect(enabledResult.status == .noChange)
        #expect(enabledResult.fileEvents.isEmpty)
        #expect(try enabled.metadataStore.loadCurrentSnapshot(from: enabled.rootURL).generation == enabledGeneration)
        #expect(try enabled.currentInspection().observation.fileIdentity == enabledIdentity)

        let disabled = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
        let disabledGeneration = try disabled.metadataStore.loadCurrentSnapshot(from: disabled.rootURL).generation
        let disabledResult = disabled.executor().execute(
            authorization: disabled.authorization(desiredEnabled: false),
            rootURL: disabled.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") }
        )
        #expect(disabledResult.status == .noChange)
        #expect(disabledResult.fileEvents.isEmpty)
        #expect(try disabled.metadataStore.loadCurrentSnapshot(from: disabled.rootURL).generation == disabledGeneration)
    }

    @Test func disablingMissingSelectedNodeCommitsTheIntent() throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: true)
        let result = fixture.executor().execute(
            authorization: fixture.authorization(desiredEnabled: false),
            rootURL: fixture.rootURL,
            currentInstallation: { nil }
        )

        #expect(result.status == .succeeded)
        #expect(result.fileEvents.isEmpty)
        #expect(try fixture.metadataStore.load(from: fixture.rootURL).enablementIntents.first {
            $0.id == fixture.relation.id
        }?.isEnabled == false)
    }

    @Test(arguments: [
        RelationExecutionFixture.Node.regularFile,
        .externalLink,
        .brokenLink,
        .unownedLink
    ], [AgentKind.codex, .claudeCode])
    fileprivate func conflictingNodesAreBlockedWithZeroProductWrite(node: RelationExecutionFixture.Node, agent: AgentKind) throws {
        for desiredEnabled in [true, false] {
            let fixture = try RelationExecutionFixture(node: node, intentEnabled: false, agent: agent)
            let publicBytes = try Data(contentsOf: fixture.metadataStore.rootLayout(for: fixture.rootURL).skillshubMetadataFile)
            let localBytes = try Data(contentsOf: fixture.localStateStore.localStateFile(for: fixture.rootURL))
            let beforeTree = try targetTree(at: fixture.targetURL)

            let result = fixture.executor().execute(
                authorization: fixture.authorization(desiredEnabled: desiredEnabled),
                rootURL: fixture.rootURL,
                currentInstallation: { AgentInstallationEvidence(agent: agent, digest: "fixture-installation") }
            )

            #expect(result.status == .blocked)
            #expect(result.blockReason == .nodeConflict)
            #expect(result.fileEvents.isEmpty)
            #expect(try Data(contentsOf: fixture.metadataStore.rootLayout(for: fixture.rootURL).skillshubMetadataFile) == publicBytes)
            #expect(try Data(contentsOf: fixture.localStateStore.localStateFile(for: fixture.rootURL)) == localBytes)
            #expect(try targetTree(at: fixture.targetURL) == beforeTree)
        }
    }

    @Test(arguments: [AgentKind.codex, .claudeCode])
    func identityChangeBeforeIsolationIsBlockedAndTheReplacementIsNotDeleted(_ agent: AgentKind) throws {
        let fixture = try RelationExecutionFixture(node: .managed, intentEnabled: true, agent: agent)
        let replacement = fixture.containerURL.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let linkPath = fixture.linkURL.path
        let replacementPath = replacement.path
        let primitiveCalls = RelationInvocationCounter()
        let publicBefore = try Data(contentsOf: fixture.metadataStore.rootLayout(for: fixture.rootURL).skillshubMetadataFile)
        let localBefore = try Data(contentsOf: fixture.localStateStore.localStateFile(for: fixture.rootURL))
        let hook = RelationTestHook { point in
            guard point == .beforeFilePrimitive else { return }
            try FileManager.default.removeItem(atPath: linkPath)
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: replacementPath)
        }

        let result = fixture.executor(
            linkService: AgentLinkService(relationPrimitiveHook: { _, _ in
                primitiveCalls.increment()
            }),
            faultHook: hook
        ).execute(
            authorization: fixture.authorization(desiredEnabled: false),
            rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: agent, digest: "fixture-installation") }
        )

        #expect(primitiveCalls.current == 0, "Cancellation must not move a replacement, even temporarily")
        #expect(result.fileEvents.isEmpty)
        #expect(result.metadataDelta == .none)
        #expect(try Data(contentsOf: fixture.metadataStore.rootLayout(for: fixture.rootURL).skillshubMetadataFile) == publicBefore)
        #expect(try Data(contentsOf: fixture.localStateStore.localStateFile(for: fixture.rootURL)) == localBefore)

        #expect(result.status == .blocked)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkPath) == replacementPath)
        #expect(fixture.quarantineEntries().isEmpty)
        #expect(try fixture.metadataStore.load(from: fixture.rootURL).enablementIntents.first {
            $0.id == fixture.relation.id
        }?.isEnabled == true)
    }

    @Test(arguments: [AgentKind.codex, .claudeCode])
    func staleMetadataCASRetainsNewLinkAndRestoresLocalRelationState(_ agent: AgentKind) throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false, agent: agent)
        let originalLocal = try Data(contentsOf: fixture.localStateStore.localStateFile(for: fixture.rootURL))
        let hook = RelationTestHook { point in
            guard case .beforeMetadataCAS = point else { return }
            let current = try fixture.metadataStore.loadCurrentSnapshot(from: fixture.rootURL)
            _ = try fixture.metadataStore.commit(
                at: fixture.rootURL,
                expected: current
            ) { metadata in
                metadata.tags.append(TagRecord(id: "advance", displayName: "Advance"))
            }
        }

        let result = fixture.executor(faultHook: hook).execute(
            authorization: fixture.authorization(desiredEnabled: true),
            rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: agent, digest: "fixture-installation") }
        )

        #expect(result.status == .unknown)
        #expect(result.fileEvents == [.created(fixture.linkURL.path), .retainedForRecovery(fixture.linkURL.path)])
        #expect(result.metadataDelta == .restored)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.linkURL.path) == fixture.canonicalURL.path)
        #expect(fixture.quarantineEntries().isEmpty)
        let metadata = try fixture.metadataStore.load(from: fixture.rootURL)
        #expect(metadata.tags.map(\.id).contains("advance"))
        #expect(metadata.enablementIntents.first { $0.id == fixture.relation.id }?.isEnabled == false)
        #expect(try Data(contentsOf: fixture.localStateStore.localStateFile(for: fixture.rootURL)) == originalLocal)
    }

    @Test(arguments: [AgentKind.codex, .claudeCode])
    func compensationIdentityLossPreservesReplacementAndReturnsUnknown(_ agent: AgentKind) throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false, agent: agent)
        let primitiveCalls = RelationInvocationCounter()
        let linkURL = fixture.linkURL
        let hook = RelationTestHook { point in
            switch point {
            case .beforeMetadataCAS:
                let current = try fixture.metadataStore.loadCurrentSnapshot(from: fixture.rootURL)
                _ = try fixture.metadataStore.commit(
                    at: fixture.rootURL,
                    expected: current
                ) { metadata in
                    metadata.tags.append(TagRecord(id: "advance", displayName: "Advance"))
                }
            case .beforeCompensation:
                try FileManager.default.removeItem(at: linkURL)
                try Data("external replacement".utf8).write(to: linkURL)
            default:
                break
            }
        }

        let result = fixture.executor(
            linkService: AgentLinkService(relationPrimitiveHook: { point, _ in
                if case .beforeCreate = point { return }
                if case .afterCreate = point { return }
                if case .beforePublish = point { return }
                if case .afterPublish = point { return }
                primitiveCalls.increment()
            }),
            faultHook: hook
        ).execute(
            authorization: fixture.authorization(desiredEnabled: true),
            rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: agent, digest: "fixture-installation") }
        )

        #expect(result.status == .unknown)
        #expect(primitiveCalls.current == 0, "Failed enablement must not move or delete the replacement")
        #expect(result.fileEvents.contains(.created(fixture.linkURL.path)))
        #expect(result.fileEvents.contains(.retainedForRecovery(fixture.linkURL.path)))
        #expect(try String(contentsOf: fixture.linkURL, encoding: .utf8) == "external replacement")
        #expect(fixture.quarantineEntries().isEmpty)
        #expect(result.safeNextStep == "observe-current-relation")
    }

    @Test func precommitFaultsPreserveMetadataAndRetainAnyCreatedLink() throws {
        for faultPoint in [
            RelationActionExecutionFaultPoint.beforeFilePrimitive,
            .afterFilePrimitive,
            .beforeLocalStateCommit
        ] {
            let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
            let publicFile = fixture.metadataStore.rootLayout(for: fixture.rootURL).skillshubMetadataFile
            let localFile = fixture.localStateStore.localStateFile(for: fixture.rootURL)
            let publicBytes = try Data(contentsOf: publicFile)
            let localBytes = try Data(contentsOf: localFile)
            let hook = RelationTestHook { point in
                if point == faultPoint { throw RelationExecutionTestError.injected }
            }

            let result = fixture.executor(faultHook: hook).execute(
                authorization: fixture.authorization(desiredEnabled: true),
                rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") }
            )

            if faultPoint == .beforeFilePrimitive {
                #expect(result.status == .failed)
                #expect(result.fileEvents.isEmpty)
                #expect(try fixture.currentInspection().classification == .vacant)
            } else {
                #expect(result.status == .unknown)
                #expect(result.fileEvents == [.created(fixture.linkURL.path), .retainedForRecovery(fixture.linkURL.path)])
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.linkURL.path) == fixture.canonicalURL.path)
            }
            #expect(try Data(contentsOf: publicFile) == publicBytes)
            #expect(try Data(contentsOf: localFile) == localBytes)
            #expect(fixture.quarantineEntries().isEmpty)
        }
    }

    @Test func postCASFailureIsUnknownWithoutRollingBackCommittedFacts() throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
        let hook = RelationTestHook { point in
            if point == .afterMetadataCAS { throw RelationExecutionTestError.injected }
        }

        let result = fixture.executor(faultHook: hook).execute(
            authorization: fixture.authorization(desiredEnabled: true),
            rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") }
        )

        #expect(result.status == .unknown)
        #expect(result.metadataDelta == .committed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.linkURL.path) == fixture.canonicalURL.path)
        #expect(try fixture.metadataStore.load(from: fixture.rootURL).enablementIntents.first {
            $0.id == fixture.relation.id
        }?.isEnabled == true)
    }

    @Test func recoveryReadsOnlyTheAuthorizedRelationAndPerformsNoWrite() throws {
        let fixture = try RelationExecutionFixture(node: .managed, intentEnabled: true)
        let publicFile = fixture.metadataStore.rootLayout(for: fixture.rootURL).skillshubMetadataFile
        let localFile = fixture.localStateStore.localStateFile(for: fixture.rootURL)
        let publicBytes = try Data(contentsOf: publicFile)
        let localBytes = try Data(contentsOf: localFile)

        let recovery = fixture.executor().recover(
            authorization: fixture.authorization(desiredEnabled: true),
            rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") }
        )

        #expect(recovery.relation == fixture.relation)
        #expect(recovery.observation?.linkPath == fixture.linkURL.path)
        #expect(recovery.verification?.conclusion == .verifiedConsistent)
        #expect(try Data(contentsOf: publicFile) == publicBytes)
        #expect(try Data(contentsOf: localFile) == localBytes)
    }

    @Test(arguments: [
        RelationActionExecutionFaultPoint.beforeOperationRecord,
        .afterOperationRecord,
        .beforeFilePrimitive
    ])
    func interruptionBeforePrimitiveNeverChangesRelationState(_ point: RelationActionExecutionFaultPoint) throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
        let authorization = fixture.authorization(desiredEnabled: true)
        let metadataFile = fixture.metadataStore.rootLayout(for: fixture.rootURL).skillshubMetadataFile
        let localFile = fixture.localStateStore.localStateFile(for: fixture.rootURL)
        let metadataBytes = try Data(contentsOf: metadataFile)
        let localBytes = try Data(contentsOf: localFile)

        let result = fixture.executor(faultHook: RelationTestHook { current in
            if current == point { throw RelationExecutionTestError.injected }
        }).execute(
            authorization: authorization,
            rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") }
        )

        #expect(result.status == .failed)
        #expect(result.fileEvents.isEmpty)
        #expect(try fixture.currentInspection().classification == .vacant)
        #expect(try Data(contentsOf: metadataFile) == metadataBytes)
        #expect(try Data(contentsOf: localFile) == localBytes)
        let operationDirectory = fixture.metadataStore.rootLayout(for: fixture.rootURL)
            .operationRecoveryDirectory.appendingPathComponent(authorization.actionID.uuidString)
        #expect(FileManager.default.fileExists(atPath: operationDirectory.path) == (point != .beforeOperationRecord))
    }

    @Test func existingOperationMaterialBlocksTheActionWithoutOverwritingEvidence() throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
        let authorization = fixture.authorization(desiredEnabled: true)
        let metadataFile = fixture.metadataStore.rootLayout(for: fixture.rootURL).skillshubMetadataFile
        let metadataBytes = try Data(contentsOf: metadataFile)
        let operationDirectory = fixture.metadataStore.rootLayout(for: fixture.rootURL)
            .operationRecoveryDirectory.appendingPathComponent(authorization.actionID.uuidString)
        try FileManager.default.createDirectory(at: operationDirectory, withIntermediateDirectories: true)
        let sentinel = operationDirectory.appendingPathComponent("sentinel")
        let sentinelBytes = Data("owned-by-another-operation".utf8)
        try sentinelBytes.write(to: sentinel)

        let result = fixture.executor().execute(
            authorization: authorization,
            rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") }
        )

        #expect(result.status == .failed)
        #expect(result.fileEvents.isEmpty)
        #expect(try fixture.currentInspection().classification == .vacant)
        #expect(try Data(contentsOf: metadataFile) == metadataBytes)
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
    }

    @Test func interruptedActionRecoversFromDurableMaterialsWithoutReplaying() throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: false)
        let authorization = fixture.authorization(desiredEnabled: true)
        let metadataFile = fixture.metadataStore.rootLayout(for: fixture.rootURL).skillshubMetadataFile
        let localFile = fixture.localStateStore.localStateFile(for: fixture.rootURL)
        let originalMetadata = try Data(contentsOf: metadataFile)
        let result = fixture.executor(faultHook: RelationTestHook { point in
            if point == .afterFilePrimitive { throw RelationExecutionTestError.injected }
        }).execute(
            authorization: authorization,
            rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") }
        )

        #expect(result.status == .unknown)
        let store = RelationActionOperationRecordStore()
        let record = try store.load(operationID: authorization.actionID, rootURL: fixture.rootURL)
        let operationDirectory = fixture.metadataStore.rootLayout(for: fixture.rootURL)
            .operationRecoveryDirectory.appendingPathComponent(authorization.actionID.uuidString)
        #expect(record.originalMetadataDigest == SHA256Digest.hex(originalMetadata))
        #expect(record.retainedPaths.contains(fixture.linkURL.path))
        #expect(record.creation != nil)
        #expect(try Data(contentsOf: operationDirectory.appendingPathComponent(
            RelationActionOperationRecordStore.originalMetadataFileName
        )) == originalMetadata)

        let metadataBeforeRecovery = try Data(contentsOf: metadataFile)
        let localBeforeRecovery = try Data(contentsOf: localFile)
        let linkBeforeRecovery = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.linkURL.path)
        let recovery = fixture.executor().recover(
            operationID: authorization.actionID,
            rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") }
        )

        #expect(recovery.components.first { $0.kind == .metadata }?.state == .notCompleted)
        #expect(recovery.components.first { $0.kind == .linkNode }?.state == .unknown)
        #expect(recovery.components.first { $0.kind == .targetDirectory }?.state == .completed)
        #expect(recovery.components.first { $0.kind == .operationMaterials }?.state == .completed)
        #expect(try Data(contentsOf: metadataFile) == metadataBeforeRecovery)
        #expect(try Data(contentsOf: localFile) == localBeforeRecovery)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.linkURL.path) == linkBeforeRecovery)
        #expect(FileManager.default.fileExists(atPath: operationDirectory.path))
        #expect(try store.load(operationID: authorization.actionID, rootURL: fixture.rootURL)
            .observations.last?.checkpoint == .recoveryObservation)

        try Data("tampered".utf8).write(to: operationDirectory.appendingPathComponent(
            RelationActionOperationRecordStore.originalMetadataFileName
        ))
        let inconsistentRecovery = fixture.executor().recover(
            operationID: authorization.actionID,
            rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") }
        )
        #expect(inconsistentRecovery.components == [
            RelationActionRecoveryComponent(
                kind: .operationMaterials,
                state: .unknown,
                path: operationDirectory.path,
                detail: "operation-record-unavailable"
            )
        ])
        #expect(try Data(contentsOf: metadataFile) == metadataBeforeRecovery)
        #expect(try Data(contentsOf: localFile) == localBeforeRecovery)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.linkURL.path) == linkBeforeRecovery)
    }

    @Test func enablingVacantRelationRepairsAuthoritativeEvidenceEvenWhenIntentIsAlreadyEnabled() throws {
        let fixture = try RelationExecutionFixture(node: .vacant, intentEnabled: true)
        let result = fixture.executor().execute(
            authorization: fixture.authorization(desiredEnabled: true),
            rootURL: fixture.rootURL,
            currentInstallation: { AgentInstallationEvidence(agent: .codex, digest: "fixture-installation") }
        )

        #expect(result.status == .succeeded)
        #expect(result.metadataDelta == .committed)
        let metadata = try fixture.metadataStore.load(from: fixture.rootURL)
        #expect(metadata.managedRelationEvidence.contains { $0.relation == fixture.relation })
        #expect(try fixture.localStateStore.load(from: fixture.rootURL).managedRelationEvidence.isEmpty)
    }
}

private enum RelationExecutionTestError: Error {
    case injected
}

private final class RelationInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class RelationTestHook: @unchecked Sendable {
    private let body: (RelationActionExecutionFaultPoint) throws -> Void

    init(_ body: @escaping (RelationActionExecutionFaultPoint) throws -> Void) {
        self.body = body
    }

    func run(_ point: RelationActionExecutionFaultPoint) throws {
        try body(point)
    }
}

private final class RelationExecutionFixture: @unchecked Sendable {
    enum Node: Equatable, Sendable {
        case vacant
        case managed
        case managedBroken
        case unownedLink
        case regularFile
        case externalLink
        case brokenLink
    }

    let agent: AgentKind
    let profileID: String
    let containerURL: URL
    let rootURL: URL
    let targetURL: URL
    let canonicalURL: URL
    let linkURL: URL
    let relation: AgentRelationIdentity
    let metadataStore: SkillsHubMetadataStore
    let localStateStore: SkillsHubLocalStateStore
    private let snapshot: RootSnapshot
    private let observation: TargetObservation
    private let ownership: RelationOwnershipClassification
    private let intent: EnablementIntent

    init(node: Node, intentEnabled: Bool, agent: AgentKind = .codex) throws {
        self.agent = agent
        profileID = try #require(AgentCapabilityProfileRegistry.builtIn.profile(for: agent, scope: .global)).profileID
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "skillshub-relation-execution-\(UUID().uuidString)",
            isDirectory: true
        )
        containerURL = container
        rootURL = container.appendingPathComponent("root", isDirectory: true)
        targetURL = container.appendingPathComponent("agent-skills", isDirectory: true)
        canonicalURL = rootURL.appendingPathComponent("local/review", isDirectory: true)
        linkURL = targetURL.appendingPathComponent("review")
        relation = AgentRelationIdentity(assetID: UUID(), agentID: agent.rawValue, scope: .global)
        metadataStore = SkillsHubMetadataStore()
        localStateStore = SkillsHubLocalStateStore()

        try FileManager.default.createDirectory(at: canonicalURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        try Data("canonical".utf8).write(to: canonicalURL.appendingPathComponent("SKILL.md"))

        let external = container.appendingPathComponent("external", isDirectory: true)
        var creation: LinkCreationEvidence?
        switch node {
        case .vacant:
            break
        case .managed, .managedBroken:
            creation = try AgentLinkService().createManagedLink(
                at: linkURL, linkText: canonicalURL.path, operationID: UUID(),
                expectedParentIdentity: LinkNodeIdentity.read(at: targetURL),
                recordPreparation: { _ in }, recordCreation: { _ in }, onCreated: { _ in }
            ).creation
            if node == .managedBroken {
                try FileManager.default.moveItem(at: canonicalURL, to: container.appendingPathComponent("preserved-target"))
            }
        case .unownedLink:
            try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: canonicalURL.path)
        case .regularFile:
            try Data("occupied".utf8).write(to: linkURL)
        case .externalLink:
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: external.path)
        case .brokenLink:
            try FileManager.default.createSymbolicLink(
                atPath: linkURL.path,
                withDestinationPath: container.appendingPathComponent("missing").path
            )
        }

        intent = EnablementIntent(
            assetID: relation.assetID,
            agentID: relation.agentID,
            scope: relation.scope,
            isEnabled: intentEnabled,
            generation: 4
        )
        let otherIntent = EnablementIntent(
            assetID: relation.assetID,
            agentID: (agent == .codex ? AgentKind.claudeCode : .codex).rawValue,
            scope: .global,
            isEnabled: false,
            generation: 4
        )
        let asset = InstalledSkill(
            id: "review",
            sourceID: nil,
            name: "Review",
            description: "Reviews changes.",
            installedPath: canonicalURL.path,
            sourceKind: .localDirectory,
            validation: .valid,
            purpose: nil,
            tagIDs: [],
            installedAt: Date(timeIntervalSince1970: 100),
            assetID: relation.assetID,
            canonicalPathComponent: "review",
            currentRevision: "revision-v1",
            manifestDigest: "manifest-v1",
            managedGeneration: 4,
            stableLinkName: "review"
        )
        try metadataStore.save(
            SkillsHubMetadata(
                generation: 4,
                rootConfig: RootConfig(rootPath: rootURL.path),
                installedSkills: [asset],
                enablementIntents: [intent, otherIntent]
            ),
            to: rootURL
        )

        let inspector = RelationOwnershipInspector(now: { Date(timeIntervalSince1970: 100) })
        let initial = try inspector.inspect(
            linkURL: linkURL,
            relation: relation,
            canonicalTargetPath: canonicalURL.path,
            evidence: nil
        )
        let evidence: ManagedRelationEvidence?
        if node == .managed || node == .managedBroken {
            evidence = ManagedRelationEvidence(
                relation: relation,
                linkPath: linkURL.path,
                canonicalTargetPath: canonicalURL.path,
                profileID: profileID,
                profileVersion: 1,
                createdAtGeneration: intent.generation,
                fileIdentity: try #require(initial.observation.fileIdentity),
                createdAt: Date(timeIntervalSince1970: 90),
                creation: creation
            )
        } else {
            evidence = nil
        }
        let current = try inspector.inspect(
            linkURL: linkURL,
            relation: relation,
            canonicalTargetPath: canonicalURL.path,
            evidence: evidence
        )
        observation = current.observation
        ownership = current.classification
        try localStateStore.save(
            SkillsHubLocalState(
                ignoredFindingFingerprints: ["sentinel"],
                targetObservations: [current.observation]
            ),
            to: rootURL
        )
        if let evidence {
            let currentSnapshot = try metadataStore.loadCurrentSnapshot(from: rootURL)
            _ = try metadataStore.commit(at: rootURL, expected: currentSnapshot) { metadata in
                metadata.managedRelationEvidence = [evidence]
            }
        }
        snapshot = try metadataStore.loadCurrentSnapshot(from: rootURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: containerURL)
    }

    func authorization(desiredEnabled: Bool) -> RelationActionAuthorization {
        let qualification = AgentTargetQualification(
            agentID: agent.rawValue,
            agent: agent,
            agentDetected: true,
            profileID: profileID,
            profileVersion: 1,
            schemaVersion: 1,
            scope: .global,
            candidates: [targetURL],
            authorizationStatus: .current,
            target: targetURL,
            failure: nil
        )
        let facts = try! RelationActionTokenBuilder().facts(
            relation: relation,
            rootURL: rootURL,
            rootSessionOwner: .rootSession(UUID()),
            snapshot: snapshot,
            asset: snapshot.metadata.installedSkills[0],
            qualification: qualification,
            observation: observation,
            ownership: ownership,
            currentIntent: intent
        )
        let builder = RelationActionTokenBuilder()
        let actionID = UUID()
        let factsDigest = builder.digest(of: facts)
        return RelationActionAuthorization(
            actionID: actionID,
            relation: relation,
            desiredEnabled: desiredEnabled,
            facts: facts,
            factsDigest: factsDigest,
            tokenDigest: builder.tokenDigest(
                actionID: actionID,
                desiredEnabled: desiredEnabled,
                factsDigest: factsDigest,
                targetLeaseOwnerIdentity: "agent-target:\(agent.rawValue):\(actionID.uuidString)"
            )
        )
    }

    func executor(
        linkService: AgentLinkService? = nil,
        faultHook: RelationTestHook? = nil
    ) -> RelationActionExecutor {
        RelationActionExecutor(
            metadataStore: metadataStore,
            localStateStore: localStateStore,
            linkService: linkService ?? AgentLinkService(),
            now: { Date(timeIntervalSince1970: 200) },
            faultHook: faultHook.map { hook in
                { point in try hook.run(point) }
            }
        )
    }

    func currentInspection() throws -> RelationOwnershipInspection {
        let metadata = try metadataStore.load(from: rootURL)
        return try RelationOwnershipInspector().inspect(
            linkURL: linkURL,
            relation: relation,
            canonicalTargetPath: canonicalURL.path,
            evidence: metadata.managedRelationEvidence.first { $0.relation == relation }
        )
    }

    // Primitive fault matrix shares the production record seam, without committing enablement.
    func removeCandidate(
        authorization suppliedAuthorization: RelationActionAuthorization? = nil,
        service: AgentLinkService = AgentLinkService(),
        beforeIsolationRecord: (() throws -> Void)? = nil
    ) throws -> [RelationActionFileEvent] {
        let authorization = suppliedAuthorization ?? authorization(desiredEnabled: false)
        let layout = metadataStore.rootLayout(for: rootURL)
        let lock = try RootProcessWriteLock.acquire(at: layout.writeLockFile).get()
        defer { lock.release() }
        let snapshot = try metadataStore.loadCurrentSnapshot(from: rootURL)
        let store = RelationActionOperationRecordStore()
        var record = try store.prepare(authorization: authorization, snapshot: snapshot, rootURL: rootURL)
        var events: [RelationActionFileEvent] = []
        let executor = executor(linkService: service, faultHook: RelationTestHook { point in
            if point == .beforeIsolationRecord { try beforeIsolationRecord?() }
        })
        try executor.removeManagedNode(authorization: authorization, record: &record, rootURL: rootURL,
            onEvent: { events.append($0) })
        return events
    }

    func quarantineEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: targetURL.path)) ?? [])
            .filter { $0.hasPrefix(".skillshub-action-") }
            .sorted()
    }
}

private final class BrokenLinkDeletionFixture: @unchecked Sendable {
    let containerURL: URL
    let rootURL: URL
    let agentDirectory: URL
    let linkURL: URL
    let resolvedTarget: URL
    let intermediateLinkURL: URL?
    let metadataURL: URL
    let authorization: BrokenLinkDeletionAuthorization

    init(rawTarget: String, intermediateTarget: String? = nil) throws {
        containerURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("broken-link-deletion-\(UUID().uuidString)", isDirectory: true)
        rootURL = containerURL.appendingPathComponent("root", isDirectory: true)
        agentDirectory = rootURL.appendingPathComponent("agent", isDirectory: true)
        linkURL = agentDirectory.appendingPathComponent("review")
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: rawTarget)
        let firstTarget = (rawTarget.hasPrefix("/")
            ? URL(fileURLWithPath: rawTarget)
            : agentDirectory.appendingPathComponent(rawTarget)).standardizedFileURL
        if let intermediateTarget {
            intermediateLinkURL = firstTarget
            try FileManager.default.createSymbolicLink(
                atPath: firstTarget.path,
                withDestinationPath: intermediateTarget
            )
            resolvedTarget = firstTarget.deletingLastPathComponent()
                .appendingPathComponent(intermediateTarget).standardizedFileURL
        } else {
            intermediateLinkURL = nil
            resolvedTarget = firstTarget
        }

        let metadataStore = SkillsHubMetadataStore()
        try metadataStore.save(
            SkillsHubMetadata(generation: 1, rootConfig: RootConfig(rootPath: rootURL.path)),
            to: rootURL
        )
        metadataURL = metadataStore.rootLayout(for: rootURL).skillshubMetadataFile
        let actionID = UUID()
        let qualification = AgentTargetQualification(
            agentID: AgentKind.codex.rawValue,
            agent: .codex,
            agentDetected: true,
            profileID: "skillshub.agent-profile.codex.global",
            profileVersion: 1,
            schemaVersion: 1,
            scope: .global,
            candidates: [agentDirectory],
            authorizationStatus: .current,
            target: agentDirectory,
            failure: nil
        )
        let facts = try BrokenLinkDeletionInspector().facts(
            rootURL: rootURL,
            rootSessionOwner: .rootSession(UUID()),
            agentID: AgentKind.codex.rawValue,
            agentDisplayName: "Codex",
            qualification: qualification,
            linkURL: linkURL
        )
        authorization = BrokenLinkDeletionAuthorization(
            kind: .confirmedBrokenLink,
            actionID: actionID,
            facts: facts,
            factsDigest: BrokenLinkDeletionTokenBuilder().digest(of: facts)
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: containerURL)
    }

    func execute(linkService: AgentLinkService = AgentLinkService()) -> BrokenLinkDeletionExecutionResult {
        RelationActionExecutor(
            metadataStore: SkillsHubMetadataStore(),
            localStateStore: SkillsHubLocalStateStore(),
            linkService: linkService
        ).executeBrokenLinkDeletion(authorization: authorization, rootURL: rootURL)
    }
}

private func directoryManifest(at directory: URL) throws -> [String: Data] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    return try Dictionary(uniqueKeysWithValues: names.map { name in
        (name, try Data(contentsOf: directory.appendingPathComponent(name)))
    })
}

private func targetTree(at directory: URL) throws -> [String: String] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    return Dictionary(uniqueKeysWithValues: names.map { name in
        let path = directory.appendingPathComponent(name).path
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            return (name, "link:\(destination)")
        }
        return (name, "node")
    })
}
