import Darwin
import Foundation

nonisolated enum SourceUpdateChangeKind: String, Equatable, Sendable {
    case added
    case modified
    case deleted
}

nonisolated enum SourceUpdateConfirmationKind: Equatable, Sendable {
    case update
    case overwriteLocalChanges
    case replaceUnknownBaseline

    var title: String {
        switch self {
        case .update: "Update Entire Source"
        case .overwriteLocalChanges: "Overwrite Local Changes and Update"
        case .replaceUnknownBaseline: "Confirm Entire Replacement"
        }
    }
}

nonisolated struct SourceUpdateFileChange: Identifiable, Equatable, Sendable {
    var path: String
    var kind: SourceUpdateChangeKind
    var id: String { "\(kind.rawValue)|\(path)" }
}

nonisolated struct SourceUpdateSkillChange: Identifiable, Equatable, Sendable {
    var path: String
    var name: String
    var kind: SourceUpdateChangeKind
    var id: String { "\(kind.rawValue)|\(path)" }
}

nonisolated struct SourceUpdateAgentImpact: Identifiable, Equatable, Sendable {
    var assetID: UUID
    var skillPath: String
    var skillName: String
    var agentIDs: [String]
    var agentNames: [String]
    var id: UUID { assetID }
}

/// A read-only, complete-source confirmation scope. T-005 consumes the same prepared tree.
nonisolated struct SourceUpdatePreview: Identifiable, Equatable {
    var id: UUID
    var source: SkillSource
    var rootIdentity: TargetFileIdentity
    var preparedPath: String?
    var preparedRevision: String?
    var metadataGeneration: UInt64
    var metadataDigest: String
    var currentSourceIdentity: TargetFileIdentity
    var preparedSourceIdentity: TargetFileIdentity
    var currentManifest: ContentManifest
    var preparedManifest: ContentManifest
    var localChanges: [SourceUpdateFileChange]
    var incomingChanges: [SourceUpdateFileChange]
    var skillChanges: [SourceUpdateSkillChange]
    var preparedCandidatePaths: [String]
    var agentImpacts: [SourceUpdateAgentImpact]
    var removedRelationPlans: [ManagedRelationClearPlan]
    var confirmationKind: SourceUpdateConfirmationKind
    var planDigest: String

    var hasIncomingChanges: Bool { !incomingChanges.isEmpty }
    var hasLocalChanges: Bool { !localChanges.isEmpty }
    var hasUnknownBaseline: Bool { source.baselineManifest == nil }
}

nonisolated enum SourceUpdateError: Error, Equatable {
    case invalidSource
    case sourceChangedDuringPreparation
    case preparedSourceIncomplete
    case confirmationChanged
    case writeUnavailable
    case relationshipCleanupIncomplete
    case operationRecordUnavailable
}

nonisolated enum SourceUpdateStage: String, Codable, Equatable, Sendable {
    case confirmed
    case contentSwitched = "content-switched"
    case relationshipsReconciled = "relationships-reconciled"
    case metadataCommitted = "metadata-committed"
    case completed
    case needsAttention = "needs-attention"
}

nonisolated struct SourceUpdateOperationRecord: Codable, Equatable, Sendable {
    var operationID: UUID
    var planDigest: String
    var rootPath: String
    var sourceID: UUID
    var sourceKind: SkillSourceKind?
    var sourcePath: String
    var preparedRevision: String?
    var stage: SourceUpdateStage
    var relationResults: [String: String]
    var relationIDs: [String]?
    var metadataGeneration: UInt64?
    var retainedPath: String?
    var trashPath: String?
    var detail: String
    var updatedAt: Date
}

nonisolated struct SourceUpdateResult: Equatable, Sendable {
    var sourceID: UUID
    var sourceName: String
    var relationResults: [ManagedRelationClearResultItem]
    var contentApplied: Bool
    var metadataCommitted: Bool
    var oldContentMovedToTrash: Bool
    var retainedPath: String?
    var trashPath: String?
    var detail: LocalizedMessage

    var updateSucceeded: Bool { contentApplied && metadataCommitted }
}

nonisolated final class SourceUpdateService: @unchecked Sendable {
    private let fileManager: FileManager
    private let exchange: SourceDirectoryExchange
    private let trashItem: (URL) throws -> URL

    init(
        fileManager: FileManager = .default,
        exchange: SourceDirectoryExchange = SourceDirectoryExchange(),
        trashItem: ((URL) throws -> URL)? = nil
    ) {
        self.fileManager = fileManager
        self.exchange = exchange
        self.trashItem = trashItem ?? { url in
            var resultingURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
            guard let resultingURL else { throw SourceUpdateError.operationRecordUnavailable }
            return resultingURL as URL
        }
    }

    func preview(
        id: UUID,
        source: SkillSource,
        rootIdentity: TargetFileIdentity? = nil,
        currentSourceIdentity: TargetFileIdentity,
        currentManifest: ContentManifest,
        preparedPath: String,
        preparedSourceIdentity: TargetFileIdentity,
        preparedRevision: String?,
        preparedManifest: ContentManifest,
        currentCandidates: [AvailableSkill],
        preparedCandidates: [AvailableSkill],
        installedSkills: [InstalledSkill],
        enablementIntents: [EnablementIntent],
        agents: [AgentConfigurationRecord],
        removedRelationPlans: [ManagedRelationClearPlan] = [],
        metadataGeneration: UInt64,
        metadataDigest: String
    ) -> SourceUpdatePreview {
        let localChanges = source.baselineManifest.map { changes(from: $0, to: currentManifest) } ?? []
        let incomingChanges = changes(from: currentManifest, to: preparedManifest)
        let skillChanges = candidateChanges(from: currentCandidates, to: preparedCandidates)
        let impacts = enabledImpacts(
            source: source,
            installedSkills: installedSkills,
            enablementIntents: enablementIntents,
            agents: agents
        )
        let confirmationKind: SourceUpdateConfirmationKind = if source.baselineManifest == nil {
            .replaceUnknownBaseline
        } else if !localChanges.isEmpty {
            .overwriteLocalChanges
        } else {
            .update
        }
        let facts = [
            id.uuidString,
            source.id.uuidString,
            currentSourceIdentity.fingerprint,
            preparedSourceIdentity.fingerprint,
            source.baselineManifest?.digest ?? "unknown-baseline",
            currentManifest.digest,
            preparedManifest.digest,
            preparedRevision ?? "local-source",
            String(metadataGeneration),
            metadataDigest,
            preparedCandidates.map(\.skillPath).sorted().joined(separator: "\n"),
            impacts.flatMap { impact in impact.agentIDs.map { "\(impact.assetID)|\($0)" } }.joined(separator: "\n"),
            removedRelationPlans.flatMap { plan in
                plan.items.map {
                    "\(plan.assetID)|\($0.relation.id)|\($0.disposition.rawValue)|\($0.linkPath)"
                }
            }.sorted().joined(separator: "\n")
        ].joined(separator: "\n")
        return SourceUpdatePreview(
            id: id,
            source: source,
            rootIdentity: rootIdentity ?? currentSourceIdentity,
            preparedPath: preparedPath,
            preparedRevision: preparedRevision,
            metadataGeneration: metadataGeneration,
            metadataDigest: metadataDigest,
            currentSourceIdentity: currentSourceIdentity,
            preparedSourceIdentity: preparedSourceIdentity,
            currentManifest: currentManifest,
            preparedManifest: preparedManifest,
            localChanges: localChanges,
            incomingChanges: incomingChanges,
            skillChanges: skillChanges,
            preparedCandidatePaths: preparedCandidates.map(\.skillPath).sorted(),
            agentImpacts: impacts,
            removedRelationPlans: removedRelationPlans,
            confirmationKind: confirmationKind,
            planDigest: SHA256Digest.hex(Data(facts.utf8))
        )
    }

    func prepareExchange(
        preview: SourceUpdatePreview,
        rootURL: URL
    ) async throws -> (SourceDirectoryExchangeRecord, SourceUpdateOperationRecord) {
        guard let preparedPath = preview.preparedPath,
              let sourcePath = preview.source.localPath else { throw SourceUpdateError.invalidSource }
        let root = rootURL.standardizedFileURL
        let operation = root.appendingPathComponent(".skillshub-operations/\(preview.id.uuidString)", isDirectory: true)
        let prepared = operation.appendingPathComponent("prepared", isDirectory: true)
        guard !fileManager.fileExists(atPath: operation.path) else {
            throw SourceUpdateError.operationRecordUnavailable
        }
        do {
            try await RootMutationOwner.shared.perform(at: root) {
                let operations = operation.deletingLastPathComponent()
                if !self.fileManager.fileExists(atPath: operations.path) {
                    try self.fileManager.createDirectory(at: operations, withIntermediateDirectories: false)
                }
                guard (try? LinkNodeIdentity.read(at: operations).kind) == S_IFDIR else {
                    throw SourceUpdateError.operationRecordUnavailable
                }
                try self.fileManager.createDirectory(at: operation, withIntermediateDirectories: false)
                try self.fileManager.copyItem(
                    at: URL(fileURLWithPath: preparedPath, isDirectory: true),
                    to: prepared
                )
                let manifest = try ContentManifestBuilder(fileManager: self.fileManager).build(
                    for: prepared,
                    authorizedRoot: prepared,
                    allowExternalSymbolicLinks: true
                )
                guard manifest.entries == preview.preparedManifest.entries,
                      manifest.digest == preview.preparedManifest.digest else {
                    throw SourceUpdateError.sourceChangedDuringPreparation
                }
            }
            let exchangeRecord = try exchange.prepare(
                rootURL: root,
                sourceURL: URL(fileURLWithPath: sourcePath, isDirectory: true),
                operationID: preview.id
            )
            guard exchangeRecord.current.identity.file == preview.currentSourceIdentity,
                  exchangeRecord.current.manifest.entries == preview.currentManifest.entries,
                  exchangeRecord.current.manifest.digest == preview.currentManifest.digest,
                  SHA256Digest.hex(exchangeRecord.originalMetadata) == preview.metadataDigest else {
                throw SourceUpdateError.confirmationChanged
            }
            let record = SourceUpdateOperationRecord(
                operationID: preview.id,
                planDigest: preview.planDigest,
                rootPath: root.path,
                sourceID: preview.source.id,
                sourceKind: preview.source.kind,
                sourcePath: sourcePath,
                preparedRevision: preview.preparedRevision,
                stage: .confirmed,
                relationResults: [:],
                relationIDs: preview.removedRelationPlans.flatMap { $0.items.map(\.relation.id) }.sorted(),
                metadataGeneration: nil,
                retainedPath: nil,
                trashPath: nil,
                detail: "Source update confirmed; managed content is unchanged.",
                updatedAt: Date()
            )
            try save(record, rootURL: root, requireExisting: false)
            return (exchangeRecord, record)
        } catch {
            try? fileManager.removeItem(at: operation)
            throw error
        }
    }

    func executeExchange(
        _ exchangeRecord: SourceDirectoryExchangeRecord,
        rootURL: URL
    ) async throws -> SourceDirectoryExchangeObservation {
        switch try await exchange.execute(confirmed: exchangeRecord, rootURL: rootURL) {
        case .performed(let observation): return observation
        case .writeUnavailable: throw SourceUpdateError.writeUnavailable
        }
    }

    func observeExchange(
        _ exchangeRecord: SourceDirectoryExchangeRecord,
        rootURL: URL
    ) -> SourceDirectoryExchangeObservation {
        exchange.observe(exchangeRecord, rootURL: rootURL)
    }

    func saveProgress(
        _ record: SourceUpdateOperationRecord,
        rootURL: URL
    ) throws {
        try save(record, rootURL: rootURL, requireExisting: true)
    }

    func moveRetainedContentToTrash(
        exchangeRecord: SourceDirectoryExchangeRecord,
        record: inout SourceUpdateOperationRecord,
        rootURL: URL
    ) throws {
        let retained = URL(fileURLWithPath: exchangeRecord.prepared.path, isDirectory: true)
        record.retainedPath = retained.path
        let destination = try trashItem(retained).standardizedFileURL
        record.trashPath = destination.path
        guard !fileManager.fileExists(atPath: retained.path),
              (try? LinkNodeIdentity.read(at: destination)) == exchangeRecord.current.identity else {
            throw SourceUpdateError.operationRecordUnavailable
        }
        record.stage = .completed
        record.detail = "Source content, relationships, metadata, baseline, and retained old content were verified."
        record.updatedAt = Date()
        try save(record, rootURL: rootURL, requireExisting: true)
    }

    func loadRecord(operationID: UUID, rootURL: URL) throws -> SourceUpdateOperationRecord {
        let operations = rootURL.standardizedFileURL.appendingPathComponent(".skillshub-operations", isDirectory: true)
        let directory = operations.appendingPathComponent(operationID.uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("source-update.json")
        guard (try? LinkNodeIdentity.read(at: operations).kind) == S_IFDIR,
              (try? LinkNodeIdentity.read(at: directory).kind) == S_IFDIR,
              (try? LinkNodeIdentity.read(at: file).kind) == S_IFREG else {
            throw SourceUpdateError.operationRecordUnavailable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(SourceUpdateOperationRecord.self, from: Data(contentsOf: file))
        guard record.operationID == operationID, record.rootPath == rootURL.standardizedFileURL.path else {
            throw SourceUpdateError.operationRecordUnavailable
        }
        return record
    }

    func recoveryOperationIDs(rootURL: URL) throws -> [UUID] {
        let operations = rootURL.standardizedFileURL.appendingPathComponent(".skillshub-operations", isDirectory: true)
        guard fileManager.fileExists(atPath: operations.path) else { return [] }
        guard (try? LinkNodeIdentity.read(at: operations).kind) == S_IFDIR else {
            throw SourceUpdateError.operationRecordUnavailable
        }
        return try fileManager.contentsOfDirectory(at: operations, includingPropertiesForKeys: nil).compactMap { entry in
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  let entryKind = try? LinkNodeIdentity.read(at: entry).kind else { return nil }
            guard entryKind == S_IFDIR else { return id }
            guard (try? LinkNodeIdentity.read(at: entry.appendingPathComponent("source-update.json"))) != nil else { return nil }
            return id
        }.sorted { $0.uuidString < $1.uuidString }
    }

    private func save(
        _ record: SourceUpdateOperationRecord,
        rootURL: URL,
        requireExisting: Bool
    ) throws {
        let directory = rootURL.standardizedFileURL.appendingPathComponent(
            ".skillshub-operations/\(record.operationID.uuidString)", isDirectory: true
        )
        let file = directory.appendingPathComponent("source-update.json")
        guard (try? LinkNodeIdentity.read(at: directory).kind) == S_IFDIR,
              !requireExisting || (try? LinkNodeIdentity.read(at: file).kind) == S_IFREG else {
            throw SourceUpdateError.operationRecordUnavailable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: file, options: .atomic)
        guard try Data(contentsOf: file) == data else { throw SourceUpdateError.operationRecordUnavailable }
        try synchronize(file, directory: false)
        try synchronize(directory, directory: true)
    }

    private func synchronize(_ url: URL, directory: Bool) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | (directory ? O_DIRECTORY : 0)) } ?? -1
        }
        guard descriptor >= 0 else { throw SourceUpdateError.operationRecordUnavailable }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw SourceUpdateError.operationRecordUnavailable }
    }

    func changes(from old: ContentManifest, to new: ContentManifest) -> [SourceUpdateFileChange] {
        let oldEntries = Dictionary(uniqueKeysWithValues: old.entries.map { ($0.relativePath, $0) })
        let newEntries = Dictionary(uniqueKeysWithValues: new.entries.map { ($0.relativePath, $0) })
        return Set(oldEntries.keys).union(newEntries.keys).compactMap { path in
            switch (oldEntries[path], newEntries[path]) {
            case (nil, .some): SourceUpdateFileChange(path: path, kind: .added)
            case (.some, nil): SourceUpdateFileChange(path: path, kind: .deleted)
            case let (.some(old), .some(new)) where old != new:
                SourceUpdateFileChange(path: path, kind: .modified)
            default: nil
            }
        }.sorted { ($0.path, $0.kind.rawValue) < ($1.path, $1.kind.rawValue) }
    }

    private func candidateChanges(
        from old: [AvailableSkill],
        to new: [AvailableSkill]
    ) -> [SourceUpdateSkillChange] {
        let oldByPath = Dictionary(uniqueKeysWithValues: old.map { ($0.skillPath, $0) })
        let newByPath = Dictionary(uniqueKeysWithValues: new.map { ($0.skillPath, $0) })
        return Set(oldByPath.keys).union(newByPath.keys).compactMap { path in
            switch (oldByPath[path], newByPath[path]) {
            case let (nil, .some(candidate)):
                SourceUpdateSkillChange(path: path, name: candidate.name, kind: .added)
            case let (.some(candidate), nil):
                SourceUpdateSkillChange(path: path, name: candidate.name, kind: .deleted)
            case let (.some(old), .some(new)) where old.name != new.name
                || old.description != new.description
                || old.validation != new.validation
                || old.manifestDigest != new.manifestDigest:
                SourceUpdateSkillChange(path: path, name: new.name, kind: .modified)
            default: nil
            }
        }.sorted { ($0.path, $0.kind.rawValue) < ($1.path, $1.kind.rawValue) }
    }

    private func enabledImpacts(
        source: SkillSource,
        installedSkills: [InstalledSkill],
        enablementIntents: [EnablementIntent],
        agents: [AgentConfigurationRecord]
    ) -> [SourceUpdateAgentImpact] {
        let enabledByAsset = Dictionary(grouping: enablementIntents.filter(\.isEnabled), by: \.assetID)
        let agentNames = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.displayName) })
        let sourceRoot = source.localPath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
        return installedSkills.compactMap { skill -> SourceUpdateAgentImpact? in
            guard skill.sourceID == source.id,
                  let intents = enabledByAsset[skill.assetID],
                  !intents.isEmpty else { return nil }
            let path = URL(fileURLWithPath: skill.installedPath, isDirectory: true).standardizedFileURL.path
            let relativePath = sourceRoot.flatMap { root in
                path == root ? "." : path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
            } ?? skill.canonicalPathComponent
            return SourceUpdateAgentImpact(
                assetID: skill.assetID,
                skillPath: relativePath,
                skillName: skill.name,
                agentIDs: intents.map(\.agentID).sorted(),
                agentNames: intents.map { agentNames[$0.agentID] ?? $0.agentID }.sorted()
            )
        }.sorted { $0.skillPath.localizedStandardCompare($1.skillPath) == .orderedAscending }
    }
}
