import Darwin
import Foundation

extension SkillsHubLibraryController {
    var githubSourcesForPresentation: [SkillSource] {
        sources.filter { $0.kind == .githubRepository }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var localSourcesForPresentation: [SkillSource] {
        localSourcesForInspection.filter { source in
            guard let observedLocalSourceNames, let path = source.localPath else { return true }
            return observedLocalSourceNames.contains(URL(fileURLWithPath: path).lastPathComponent)
        }
    }

    // Missing sources still provide context for retained skills and recovery records.
    var localSourcesForInspection: [SkillSource] {
        localSourcesInspectionSnapshot
    }

    func makeLocalSourcesForInspection() -> [SkillSource] {
        guard let rootURL else { return sources.filter { $0.kind == .localDirectory } }
        let registered = sources.filter { $0.kind == .localDirectory }
        let registeredPaths = Set(registered.compactMap { $0.localPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
        let localPath = rootURL.standardizedFileURL.path + "/local"
        var rootPrefixes = [localPath]
        if let resolvedRootPath {
            rootPrefixes.append(resolvedRootPath + "/local")
        }
        let manualPaths = Set(installedSkills.compactMap { skill -> String? in
            guard skill.sourceID == nil,
                  skill.sourceKind == .manualFilesystem || skill.sourceKind == .localDirectory else { return nil }
            // Resolve only the existing Root alias, never a replaced/missing descendant.
            guard let prefix = rootPrefixes.first(where: { skill.installedPath.hasPrefix($0 + "/") }) else { return nil }
            let relative = skill.installedPath.dropFirst(prefix.count + 1)
            guard let first = relative.split(separator: "/").first else { return nil }
            return localPath + "/" + String(first)
        }).subtracting(registeredPaths)
        let manual = manualPaths.sorted().map { path in
            SkillSource(
                id: StableIdentity.uuid(namespace: "root-local-source", value: path),
                kind: .manualFilesystem,
                name: URL(fileURLWithPath: path).lastPathComponent,
                localPath: path
            )
        }
        return (registered + manual).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func prepareLocalSourceRemoval(
        sourceID: UUID,
        operationID: UUID = UUID()
    ) throws -> SourceRemovalPlan {
        guard let rootURL, let snapshot = rootSnapshot,
              let source = sources.first(where: { $0.id == sourceID })
                ?? localSourcesForPresentation.first(where: { $0.id == sourceID }),
              let path = source.localPath else {
            throw SourceRemovalError.invalidScope
        }
        let sourceURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard SourceRemovalService.isValidScope(source: source, rootURL: rootURL) else {
            throw SourceRemovalError.invalidScope
        }
        let identity = try sourceDirectoryIdentity(sourceURL)
        let contentDigest = try ContentManifestBuilder(fileManager: fileManager).build(
            for: sourceURL,
            authorizedRoot: sourceURL,
            allowExternalSymbolicLinks: true
        ).digest
        let assets = snapshot.metadata.installedSkills.filter { skill in
            if source.kind == .manualFilesystem {
                let installed = URL(fileURLWithPath: skill.installedPath, isDirectory: true).standardizedFileURL.path
                return skill.sourceID == nil && skill.sourceKind == .manualFilesystem
                    && (installed == sourceURL.path || installed.hasPrefix(sourceURL.path + "/"))
            }
            return skill.sourceID == source.id
        }.sorted { $0.assetID.uuidString < $1.assetID.uuidString }
        guard assets.isEmpty == false else { throw SourceRemovalError.invalidScope }
        let relationPlans = try assets.map { try prepareManagedRelationClearPlan(assetID: $0.assetID) }
        let skills = assets.map {
            SourceRemovalSkill(assetID: $0.assetID, skillID: $0.id, name: $0.name, installedPath: $0.installedPath)
        }
        let relationFacts = relationPlans.flatMap { plan in
            plan.items.map { "\($0.relation.id)|\($0.disposition.rawValue)|\($0.linkPath)" }
        }.sorted().joined(separator: "\n")
        let skillFacts = skills.map { "\($0.assetID.uuidString)|\($0.skillID)|\($0.installedPath)" }
            .sorted().joined(separator: "\n")
        let digest = SHA256Digest.hex(Data([
            operationID.uuidString,
            rootURL.standardizedFileURL.path,
            source.id.uuidString,
            sourceURL.path,
            identity.fingerprint,
            contentDigest,
            snapshot.metadataDigest,
            skillFacts,
            relationFacts
        ].joined(separator: "\n").utf8))
        return SourceRemovalPlan(
            id: operationID,
            rootPath: rootURL.standardizedFileURL.path,
            source: source,
            sourceIdentity: identity,
            contentDigest: contentDigest,
            metadataGeneration: snapshot.generation,
            metadataDigest: snapshot.metadataDigest,
            skills: skills,
            relationPlans: relationPlans,
            planDigest: digest
        )
    }

    func removeLocalSource(using confirmedPlan: SourceRemovalPlan) async throws -> SourceRemovalResult {
        guard let rootURL else { throw SkillsHubLibraryFailure.missingRoot }
        guard try prepareLocalSourceRemoval(
            sourceID: confirmedPlan.source.id,
            operationID: confirmedPlan.id
        ) == confirmedPlan else {
            throw SourceRemovalError.planChanged
        }
        var record = try await RootMutationOwner.shared.perform(at: rootURL) {
            try self.sourceRemovalService.startRecord(for: confirmedPlan, rootURL: rootURL)
        }
        var relationResults: [ManagedRelationClearResultItem] = []
        var allCleared = true
        for confirmedRelations in confirmedPlan.relationPlans {
            do {
                let current = try prepareManagedRelationClearPlan(assetID: confirmedRelations.assetID)
                guard sameRemovalScope(current, confirmedRelations) else {
                    allCleared = false
                    relationResults.append(contentsOf: confirmedRelations.items.map {
                        ManagedRelationClearResultItem(
                            relation: $0.relation,
                            agentDisplayName: $0.agentDisplayName,
                            outcome: .stale,
                            detail: "Relationship facts changed after source removal was confirmed."
                        )
                    })
                    continue
                }
                let result = try await clearAllManagedRelations(using: current)
                relationResults.append(contentsOf: result.items)
                allCleared = allCleared && result.items.allSatisfy {
                    $0.outcome == .succeeded || $0.outcome == .noChange
                }
            } catch {
                allCleared = false
                relationResults.append(contentsOf: confirmedRelations.items.map {
                    ManagedRelationClearResultItem(
                        relation: $0.relation,
                        agentDisplayName: $0.agentDisplayName,
                        outcome: .failed,
                        detail: errorPresentation(for: error)
                    )
                })
            }
        }
        var updatedRecord = record
        try await RootMutationOwner.shared.perform(at: rootURL) {
            try self.sourceRemovalService.saveRelationResults(
                relationResults,
                record: &updatedRecord,
                rootURL: rootURL,
                allCleared: allCleared
            )
        }
        record = updatedRecord
        guard allCleared else {
            return SourceRemovalResult(
                sourceID: confirmedPlan.source.id,
                sourceName: confirmedPlan.source.name,
                relationResults: relationResults,
                contentMovedToTrash: false,
                trashPath: nil,
                metadataRemoved: false,
                operationRecordCompleted: false,
                detail: "Required relationship cleanup is incomplete. The source content and registration were retained."
            )
        }
        do {
            let snapshot = try await sourceRemovalService.removeContentAndRegistration(
                plan: confirmedPlan,
                record: &record,
                rootURL: rootURL,
                metadataStore: metadataStore
            )
            applySourceRemovalSnapshot(snapshot)
            setStatus("Removed the complete source %@.", confirmedPlan.source.name)
            errorMessage = nil
            return SourceRemovalResult(
                sourceID: confirmedPlan.source.id,
                sourceName: confirmedPlan.source.name,
                relationResults: relationResults,
                contentMovedToTrash: true,
                trashPath: record.trashPath,
                metadataRemoved: true,
                operationRecordCompleted: true,
                detail: "Managed relationships were cleared, the complete source was moved to Trash, and active metadata was removed."
            )
        } catch {
            let assetIDs = Set(confirmedPlan.skills.map(\.assetID))
            var metadataRemoved = false
            if let observed = try? metadataStore.loadCurrentSnapshot(from: rootURL) {
                applySourceRemovalSnapshot(observed)
                metadataRemoved = observed.metadata.sources.contains { $0.id == confirmedPlan.source.id } == false
                    && observed.metadata.installedSkills.contains { assetIDs.contains($0.assetID) } == false
            }
            let contentMoved = (record.stage == .contentTrashed || record.stage == .completed)
                && (record.trashPath.map { fileManager.fileExists(atPath: $0) } ?? false)
            return SourceRemovalResult(
                sourceID: confirmedPlan.source.id,
                sourceName: confirmedPlan.source.name,
                relationResults: relationResults,
                contentMovedToTrash: contentMoved,
                trashPath: record.trashPath,
                metadataRemoved: metadataRemoved,
                operationRecordCompleted: record.stage == .completed,
                detail: errorPresentation(for: error)
            )
        }
    }

    func addLocalSource(from directory: URL) async {
        await importLocalSource(from: directory)
    }

    func prepareSourceUpdate(sourceID: UUID, presentPreview: Bool = true) async throws {
        guard let snapshot = rootSnapshot,
              let source = snapshot.metadata.sources.first(where: { $0.id == sourceID }),
              source.kind == .localDirectory || source.kind == .githubRepository,
              let managedPath = source.localPath else {
            throw SourceUpdateError.invalidSource
        }
        discardSourceUpdatePreview(sourceUpdatePreview)
        sourceUpdatePreview = nil
        sourceUpdateResult = nil
        sourceUpdateFailures[sourceID] = nil

        let managedURL = URL(fileURLWithPath: managedPath, isDirectory: true).standardizedFileURL
        let currentSourceIdentity = try sourceDirectoryIdentity(managedURL)
        let manifestBuilder = ContentManifestBuilder(fileManager: fileManager)
        let currentManifest = try manifestBuilder.build(
            for: managedURL,
            authorizedRoot: managedURL,
            allowExternalSymbolicLinks: true
        )
        let currentIndex = LocalSourceIndexer(fileManager: fileManager).index(directory: managedURL, sourceID: source.id)
        guard currentIndex.isPlannable else { throw SourceUpdateError.invalidSource }

        let prepared: (path: URL, identity: TargetFileIdentity, manifest: ContentManifest, revision: String?, candidates: [AvailableSkill])
        switch source.kind {
        case .localDirectory:
            guard let externalPath = source.externalLocalPath else { throw SourceUpdateError.invalidSource }
            let externalURL = URL(fileURLWithPath: externalPath, isDirectory: true).standardizedFileURL
            let operationRoot = appSupportURL
                .appendingPathComponent("SourceUpdateStaging", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let lease = try acquireSecurityScopedAccess(
                to: externalURL,
                owner: .source(source.id),
                resolvingPersistedBookmark: true
            )
            let result: Result<(URL, ContentManifest, [AvailableSkill]), Error>
            do {
                let identityBefore = try sourceDirectoryIdentity(externalURL)
                let before = try manifestBuilder.build(
                    for: externalURL,
                    authorizedRoot: externalURL,
                    allowExternalSymbolicLinks: true
                )
                let preparedURL = operationRoot.appendingPathComponent("prepared", isDirectory: true)
                try fileManager.createDirectory(at: operationRoot, withIntermediateDirectories: true)
                try fileManager.copyItem(at: externalURL, to: preparedURL)
                let after = try manifestBuilder.build(
                    for: externalURL,
                    authorizedRoot: externalURL,
                    allowExternalSymbolicLinks: true
                )
                guard identityBefore == (try sourceDirectoryIdentity(externalURL)), before.digest == after.digest else {
                    try? fileManager.removeItem(at: operationRoot)
                    throw SourceUpdateError.sourceChangedDuringPreparation
                }
                let preparedManifest = try manifestBuilder.build(
                    for: preparedURL,
                    authorizedRoot: preparedURL,
                    allowExternalSymbolicLinks: true
                )
                guard preparedManifest.digest == before.digest else {
                    try? fileManager.removeItem(at: operationRoot)
                    throw SourceUpdateError.sourceChangedDuringPreparation
                }
                let index = LocalSourceIndexer(fileManager: fileManager).index(directory: preparedURL, sourceID: source.id)
                guard index.isPlannable else {
                    try? fileManager.removeItem(at: operationRoot)
                    throw SourceUpdateError.preparedSourceIncomplete
                }
                result = .success((preparedURL, preparedManifest, index.availableSkills))
            } catch {
                try? fileManager.removeItem(at: operationRoot)
                result = .failure(error)
            }
            try endSecurityScopedAccessLease(lease)
            let value = try result.get()
            prepared = (value.0, try sourceDirectoryIdentity(value.0), value.1, nil, value.2)
        case .githubRepository:
            guard let rawURL = source.urlString else { throw SourceUpdateError.invalidSource }
            let result = try await indexGitHubSource(
                rawURL: rawURL,
                trackedBranch: source.ref,
                repositoryID: source.githubRepositoryID,
                sourceID: source.id
            )
            guard result.issue == nil, let staged = result.stagedRepository else {
                if let issue = result.issue { throw issue }
                throw SourceUpdateError.preparedSourceIncomplete
            }
            prepared = (
                staged.directory,
                try sourceDirectoryIdentity(staged.directory),
                staged.manifest,
                result.source.resolvedVersion,
                result.availableSkills
            )
        default:
            throw SourceUpdateError.invalidSource
        }

        var retainedForPreview = false
        defer { if !retainedForPreview { discardPreparedSource(at: prepared.path.path) } }
        guard rootSnapshot?.generation == snapshot.generation,
              rootSnapshot?.metadata.rootConfig.rootPath == snapshot.metadata.rootConfig.rootPath else {
            throw SourceUpdateError.sourceChangedDuringPreparation
        }
        let preparedPaths = Set(prepared.candidates.map(\.skillPath))
        let removedRelationPlans = try snapshot.metadata.installedSkills.compactMap { skill -> ManagedRelationClearPlan? in
            guard skill.sourceID == source.id,
                  let relativePath = sourceRelativePath(for: skill, sourcePath: managedURL.path),
                  !preparedPaths.contains(relativePath) else { return nil }
            return try prepareManagedRelationClearPlan(assetID: skill.assetID)
        }
        var preview = sourceUpdateService.preview(
            id: UUID(),
            source: source,
            rootIdentity: try sourceDirectoryIdentity(rootURL ?? managedURL),
            currentSourceIdentity: currentSourceIdentity,
            currentManifest: currentManifest,
            preparedPath: prepared.path.path,
            preparedSourceIdentity: prepared.identity,
            preparedRevision: prepared.revision,
            preparedManifest: prepared.manifest,
            currentCandidates: currentIndex.availableSkills,
            preparedCandidates: prepared.candidates,
            installedSkills: snapshot.metadata.installedSkills,
            enablementIntents: snapshot.metadata.enablementIntents,
            agents: snapshot.metadata.agents,
            removedRelationPlans: removedRelationPlans,
            metadataGeneration: snapshot.generation,
            metadataDigest: snapshot.metadataDigest
        )
        if !preview.hasIncomingChanges {
            discardSourceUpdatePreview(preview)
            preview.preparedPath = nil
        }
        sourceUpdateChecks[sourceID] = preview.hasIncomingChanges
        sourceUpdateCheckDates[sourceID] = Date()
        if !presentPreview {
            discardSourceUpdatePreview(preview)
            return
        }
        retainedForPreview = true
        sourceUpdatePreview = preview
        setStatus(preview.hasIncomingChanges
            ? "Prepared a complete source update preview. Managed content is unchanged."
            : "No source update was found. Managed content and its success baseline are unchanged.")
        errorMessage = nil
    }

    /// Checks the captured page scope; never presents a confirmation or applies content.
    func checkSourceUpdates(_ sourceIDs: [UUID]) async {
        guard checkingSourceIDs.isEmpty, sourceUpdatePreview == nil, !sourceIDs.isEmpty else { return }
        checkingSourceIDs = Set(sourceIDs)
        defer { checkingSourceIDs.removeAll() }
        updateCheckSummary = "Checking updates…"
        let checkedRoot = rootURL
        var updates = 0
        var failures = 0
        for id in sourceIDs {
            guard rootURL == checkedRoot else { updateCheckSummary = nil; return }
            do {
                try await prepareSourceUpdate(sourceID: id, presentPreview: false)
                if sourceUpdateChecks[id] == true { updates += 1 }
            } catch {
                guard rootURL == checkedRoot else { updateCheckSummary = nil; return }
                failures += 1
                recordSourceUpdateFailure(sourceID: id, error: error)
            }
        }
        updateCheckSummary = LocalizedMessage(
            "Checked %@ sources: %@ updates, %@ failures.",
            arguments: [String(sourceIDs.count), String(updates), String(failures)]
        )
    }

    func cancelSourceUpdatePreview(_ preview: SourceUpdatePreview) {
        guard sourceUpdatePreview?.id == preview.id else { return }
        discardSourceUpdatePreview(preview)
        if sourceUpdatePreview?.id == preview.id { sourceUpdatePreview = nil }
        sourceUpdateResult = nil
        setStatus("Cancelled the source update and kept the current managed content, relationships, and baseline.")
    }

    func sourceHasPreparedUpdate(_ sourceID: UUID) -> Bool {
        sourceUpdateChecks[sourceID] == true || (sourceUpdatePreview?.source.id == sourceID && sourceUpdatePreview?.hasIncomingChanges == true)
    }

    func recordSourceUpdateFailure(sourceID: UUID, error: Error) {
        sourceUpdateFailures[sourceID] = errorPresentation(for: error)
        sourceUpdateChecks[sourceID] = nil
        sourceUpdateCheckDates[sourceID] = Date()
    }

    func invalidateSourceUpdatePreviews() {
        sourceUpdateChecks.removeAll()
        sourceUpdateCheckDates.removeAll()
        discardSourceUpdatePreview(sourceUpdatePreview)
        sourceUpdatePreview = nil
        sourceUpdateResult = nil
        sourceUpdateFocusPath = nil
    }

    func applySourceUpdate(using preview: SourceUpdatePreview) async throws -> SourceUpdateResult {
        guard sourceUpdatePreview == preview, preview.hasIncomingChanges,
              let rootURL else { throw SourceUpdateError.confirmationChanged }
        try validateSourceUpdateConfirmation(preview, rootURL: rootURL)
        let (exchangeRecord, initialRecord) = try await sourceUpdateService.prepareExchange(
            preview: preview,
            rootURL: rootURL
        )
        discardSourceUpdatePreview(preview)
        var record = initialRecord
        var relationResults: [ManagedRelationClearResultItem] = []
        do {
            let observation = try await sourceUpdateService.executeExchange(exchangeRecord, rootURL: rootURL)
            guard observation.current == .prepared, observation.retained == .original else {
                throw SourceUpdateError.operationRecordUnavailable
            }
            record.stage = .contentSwitched
            record.retainedPath = exchangeRecord.prepared.path
            record.detail = "The complete prepared source is active; the original tree is retained."
            record.updatedAt = Date()
            try sourceUpdateService.saveProgress(record, rootURL: rootURL)
        } catch {
            let observation = sourceUpdateService.observeExchange(exchangeRecord, rootURL: rootURL)
            record.stage = .needsAttention
            record.retainedPath = observation.retained == .original ? exchangeRecord.prepared.path : nil
            record.detail = "Directory exchange needs attention: \(error)"
            record.updatedAt = Date()
            try? sourceUpdateService.saveProgress(record, rootURL: rootURL)
            let result = sourceUpdateResult(
                preview: preview, record: record, relationResults: [],
                contentApplied: observation.current == .prepared
            )
            sourceUpdateResult = result
            return result
        }

        var relationshipsComplete = true
        for confirmedPlan in preview.removedRelationPlans {
            do {
                let current = try prepareManagedRelationClearPlan(assetID: confirmedPlan.assetID)
                guard sameRemovalScope(current, confirmedPlan) else { throw SourceUpdateError.confirmationChanged }
                let result = try await clearAllManagedRelations(using: current)
                relationResults.append(contentsOf: result.items)
                relationshipsComplete = relationshipsComplete && result.items.allSatisfy {
                    $0.outcome == .succeeded || $0.outcome == .noChange
                }
            } catch {
                relationshipsComplete = false
                relationResults.append(contentsOf: confirmedPlan.items.map {
                    ManagedRelationClearResultItem(
                        relation: $0.relation,
                        agentDisplayName: $0.agentDisplayName,
                        outcome: .failed,
                        detail: errorPresentation(for: error)
                    )
                })
            }
        }
        for result in relationResults {
            record.relationResults[result.relation.id] = "\(result.outcome.rawValue): \(localization.localized(result.detail, language: .english))"
        }
        record.stage = relationshipsComplete ? .relationshipsReconciled : .needsAttention
        record.detail = relationshipsComplete
            ? "Required relationships were reconciled; metadata commit is pending."
            : "Required relationship cleanup is incomplete; the success baseline was not advanced."
        record.updatedAt = Date()
        try sourceUpdateService.saveProgress(record, rootURL: rootURL)
        guard relationshipsComplete else {
            let result = sourceUpdateResult(
                preview: preview, record: record, relationResults: relationResults, contentApplied: true
            )
            sourceUpdateResult = result
            return result
        }

        do {
            let snapshot = try await commitSourceUpdate(preview, rootURL: rootURL)
            applySourceRemovalSnapshot(snapshot)
            record.stage = .metadataCommitted
            record.metadataGeneration = snapshot.generation
            record.detail = "Content, relationships, metadata, revision, and success baseline were verified."
            record.updatedAt = Date()
            try sourceUpdateService.saveProgress(record, rootURL: rootURL)
        } catch {
            record.stage = .needsAttention
            record.detail = "Metadata commit failed after content exchange: \(error)"
            record.updatedAt = Date()
            try? sourceUpdateService.saveProgress(record, rootURL: rootURL)
            let result = sourceUpdateResult(
                preview: preview, record: record, relationResults: relationResults, contentApplied: true
            )
            sourceUpdateResult = result
            return result
        }

        do {
            try sourceUpdateService.moveRetainedContentToTrash(
                exchangeRecord: exchangeRecord,
                record: &record,
                rootURL: rootURL
            )
        } catch {
            record.stage = .needsAttention
            record.retainedPath = exchangeRecord.prepared.path
            record.detail = "The update succeeded, but retained old content could not be moved to Trash: \(error)"
            record.updatedAt = Date()
            try? sourceUpdateService.saveProgress(record, rootURL: rootURL)
        }
        let result = sourceUpdateResult(
            preview: preview, record: record, relationResults: relationResults, contentApplied: true
        )
        sourceUpdateResult = result
        setStatus(result.oldContentMovedToTrash
            ? "Updated the complete source %@."
            : "Updated the complete source %@; retained old content needs attention.", preview.source.name)
        return result
    }

    private func validateSourceUpdateConfirmation(_ preview: SourceUpdatePreview, rootURL: URL) throws {
        let snapshot = try metadataStore.loadCurrentSnapshot(from: rootURL)
        guard snapshot.generation == preview.metadataGeneration,
              snapshot.metadataDigest == preview.metadataDigest,
              snapshot.metadata.sources.first(where: { $0.id == preview.source.id }) == preview.source,
              let sourcePath = preview.source.localPath,
              let preparedPath = preview.preparedPath else {
            throw SourceUpdateError.confirmationChanged
        }
        let currentURL = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let preparedURL = URL(fileURLWithPath: preparedPath, isDirectory: true)
        let builder = ContentManifestBuilder(fileManager: fileManager)
        guard try sourceDirectoryIdentity(rootURL) == preview.rootIdentity,
              try sourceDirectoryIdentity(currentURL) == preview.currentSourceIdentity,
              try sourceDirectoryIdentity(preparedURL) == preview.preparedSourceIdentity,
              sameSourceUpdateManifest(
                try builder.build(for: currentURL, authorizedRoot: currentURL, allowExternalSymbolicLinks: true),
                preview.currentManifest
              ),
              sameSourceUpdateManifest(
                try builder.build(for: preparedURL, authorizedRoot: preparedURL, allowExternalSymbolicLinks: true),
                preview.preparedManifest
              ) else {
            throw SourceUpdateError.confirmationChanged
        }
        for confirmedPlan in preview.removedRelationPlans {
            guard try prepareManagedRelationClearPlan(assetID: confirmedPlan.assetID) == confirmedPlan else {
                throw SourceUpdateError.confirmationChanged
            }
        }
    }

    private func commitSourceUpdate(_ preview: SourceUpdatePreview, rootURL: URL) async throws -> RootSnapshot {
        try await RootMutationOwner.shared.perform(at: rootURL) {
            let current = try self.metadataStore.loadCurrentSnapshot(from: rootURL)
            let sourceURL = URL(fileURLWithPath: preview.source.localPath ?? "", isDirectory: true)
            let manifest = try ContentManifestBuilder(fileManager: self.fileManager).build(
                for: sourceURL,
                authorizedRoot: sourceURL,
                allowExternalSymbolicLinks: true
            )
            let index = LocalSourceIndexer(fileManager: self.fileManager).index(
                directory: sourceURL,
                sourceID: preview.source.id,
                generation: current.generation + 1
            )
            guard self.sameSourceUpdateManifest(manifest, preview.preparedManifest), index.isPlannable,
                  Set(index.availableSkills.map(\.skillPath)) == Set(preview.preparedCandidatePaths) else {
                throw SourceUpdateError.confirmationChanged
            }
            let removedAssetIDs = Set(preview.removedRelationPlans.map(\.assetID))
            guard current.metadata.enablementIntents.allSatisfy({ !removedAssetIDs.contains($0.assetID) }) else {
                throw SourceUpdateError.relationshipCleanupIncomplete
            }
            return try self.metadataStore.commit(at: rootURL, expected: current) { metadata in
                guard let sourceIndex = metadata.sources.firstIndex(where: { $0.id == preview.source.id }),
                      metadata.sources[sourceIndex] == preview.source else {
                    throw SourceUpdateError.confirmationChanged
                }
                let oldSkills = metadata.installedSkills.filter { $0.sourceID == preview.source.id }
                let oldByPath = Dictionary(uniqueKeysWithValues: oldSkills.compactMap { skill in
                    self.sourceRelativePath(for: skill, sourcePath: sourceURL.path).map { ($0, skill) }
                })
                let installed = index.availableSkills.map { candidate -> InstalledSkill in
                    let skillURL = candidate.skillPath == "."
                        ? sourceURL
                        : sourceURL.appendingPathComponent(candidate.skillPath, isDirectory: true)
                    if var existing = oldByPath[candidate.skillPath] {
                        existing.name = candidate.name
                        existing.description = candidate.description
                        existing.installedPath = skillURL.path
                        existing.validation = candidate.validation
                        existing.candidateID = candidate.candidateID
                        existing.currentRevision = candidate.manifestDigest
                        existing.manifestDigest = candidate.manifestDigest
                        existing.managedGeneration = current.generation + 1
                        return existing
                    }
                    return InstalledSkill(
                        id: candidate.candidateID,
                        sourceID: preview.source.id,
                        name: candidate.name,
                        description: candidate.description,
                        installedPath: skillURL.path,
                        sourceKind: preview.source.kind,
                        validation: candidate.validation,
                        purpose: nil,
                        tagIDs: [],
                        installedAt: Date(),
                        assetID: StableIdentity.assetID(
                            candidateID: candidate.candidateID,
                            canonicalPathComponent: skillURL.lastPathComponent
                        ),
                        candidateID: candidate.candidateID,
                        canonicalPathComponent: skillURL.lastPathComponent,
                        currentRevision: candidate.manifestDigest,
                        manifestDigest: candidate.manifestDigest,
                        managedGeneration: current.generation + 1
                    )
                }
                var source = metadata.sources[sourceIndex]
                source.resolvedVersion = preview.preparedRevision ?? source.resolvedVersion
                source.contentFingerprint = index.source.contentFingerprint
                source.directoryIdentity = try self.sourceDirectoryIdentity(sourceURL)
                source.lastCheckedAt = index.source.lastCheckedAt
                source.registrationState = .registered
                source.isIndexIncomplete = false
                source.indexStatusReason = nil
                source.baselineManifest = manifest
                metadata.sources[sourceIndex] = source
                metadata.availableSkills.removeAll { $0.sourceID == source.id }
                metadata.availableSkills.append(contentsOf: index.availableSkills)
                metadata.installedSkills.removeAll { $0.sourceID == source.id }
                metadata.installedSkills.append(contentsOf: installed)
                let removedSkillIDs = Set(oldSkills.filter { removedAssetIDs.contains($0.assetID) }.map(\.id))
                for id in removedSkillIDs {
                    metadata.purposeMetadata[id] = nil
                    metadata.validationCache[id] = nil
                }
            }
        }
    }

    private func sourceUpdateResult(
        preview: SourceUpdatePreview,
        record: SourceUpdateOperationRecord,
        relationResults: [ManagedRelationClearResultItem],
        contentApplied: Bool
    ) -> SourceUpdateResult {
        SourceUpdateResult(
            sourceID: preview.source.id,
            sourceName: preview.source.name,
            relationResults: relationResults,
            contentApplied: contentApplied,
            metadataCommitted: record.metadataGeneration != nil,
            oldContentMovedToTrash: record.stage == .completed,
            retainedPath: record.retainedPath,
            trashPath: record.trashPath,
            detail: LocalizedMessage("Operation record (original): %@", arguments: [record.detail])
        )
    }

    private func sameSourceUpdateManifest(_ lhs: ContentManifest, _ rhs: ContentManifest) -> Bool {
        lhs.entries == rhs.entries && lhs.digest == rhs.digest
    }

    private func sourceRelativePath(for skill: InstalledSkill, sourcePath: String) -> String? {
        let path = URL(fileURLWithPath: skill.installedPath, isDirectory: true).standardizedFileURL.path
        if path == sourcePath { return "." }
        guard path.hasPrefix(sourcePath + "/") else { return nil }
        return String(path.dropFirst(sourcePath.count + 1))
    }

    private func discardSourceUpdatePreview(_ preview: SourceUpdatePreview?) {
        guard let path = preview?.preparedPath else { return }
        discardPreparedSource(at: path)
    }

    private func discardPreparedSource(at path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let allowedRoots = ["SourceUpdateStaging", "GitHubStaging"].map {
            appSupportURL.appendingPathComponent($0, isDirectory: true).standardizedFileURL.path
        }
        guard allowedRoots.contains(where: { url.path.hasPrefix($0 + "/") }) else { return }
        try? fileManager.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
            try? fileManager.removeItem(at: parent)
        }
    }

    /// Re-observe only this source and its existing relationships; never advance its baseline.
    func recheckSource(_ sourceID: UUID) async throws {
        guard let rootURL, let source = (localSourcesForPresentation + githubSourcesForPresentation).first(where: { $0.id == sourceID }),
              let path = source.localPath else { throw SourceUpdateError.invalidSource }
        guard recheckingSourceIDs.insert(sourceID).inserted else { return }
        defer { recheckingSourceIDs.remove(sourceID) }
        let sessionID = rootSessionLease?.id
        let expected = rootSnapshot
        let inputSkills = installedSkills
        let inputSources = sources
        let lease = try rootSessionLease.map {
            try securityScopedAccessProvider.acquire(url: $0.url, owner: .inspection(UUID()))
        }
        defer { if let lease { _ = lease.end(by: lease.owner) } }
        let selectedSkills = inputSkills.filter {
            $0.sourceID == sourceID || (source.kind == .manualFilesystem && sourceRelativePath(for: $0, sourcePath: path) != nil)
        }
        let result = try await Self.readSourceForRecheck(source: source, root: rootURL,
            skills: selectedSkills, fileManager: fileManager)
        guard !Task.isCancelled, self.rootURL == rootURL, rootSessionLease?.id == sessionID,
              rootSnapshot == expected, installedSkills == inputSkills, sources == inputSources else {
            throw CancellationError()
        }
        let index = result.index
        if !index.source.isIndexIncomplete, let expected {
            guard try await registerDiscoveredLocalSkills([], rootURL: rootURL, expected: expected, sourceID: sourceID) else {
                throw CancellationError()
            }
        }
        guard !Task.isCancelled, self.rootURL == rootURL, rootSessionLease?.id == sessionID,
              sources == inputSources else { throw CancellationError() }
        let observedSkills = Dictionary(result.skills.map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first })
        let assets = Set(observedSkills.keys)
        installedSkills = installedSkills.map { skill in
            guard var observed = observedSkills[skill.assetID] else { return skill }
            // Keep an association filled by the single writer while updating content facts.
            observed.candidateID = skill.candidateID
            observed.canonicalPathComponent = skill.canonicalPathComponent
            return observed
        }
        // Preserve identities of surviving rows; an incomplete scan cannot prove removal.
        let previous = availableSkills.filter { $0.sourceID == sourceID }
        var observed = index.availableSkills.map { candidate in
            var candidate = candidate
            if let old = previous.first(where: { $0.skillPath == candidate.skillPath }) {
                candidate.id = old.id
                candidate.candidateID = old.candidateID
                candidate.generatedAtGeneration = old.generatedAtGeneration
            }
            return candidate
        }
        if index.source.isIndexIncomplete {
            observed += previous.filter { old in !observed.contains { $0.skillPath == old.skillPath } }.map { old in
                var unavailable = old
                unavailable.checkStatus = .unreadable
                unavailable.validation.messages = [ValidationMessage(id: "source-check-incomplete", severity: .warning,
                    message: index.source.indexStatusReason ?? "Source check is incomplete.")]
                return unavailable
            }
        }
        availableSkills = availableSkills.filter { $0.sourceID != sourceID } + observed
        await refreshRelationObservations(for: agentDetections, assetIDs: assets)
        guard !Task.isCancelled, self.rootURL == rootURL, rootSessionLease?.id == sessionID else { throw CancellationError() }
        sourceRecheckResults[sourceID] = index.source.isIndexIncomplete
            ? LocalizedMessage("Source check incomplete. Diagnostic (original): %@", arguments: [index.source.indexStatusReason ?? "Unknown"])
            : LocalizedMessage("Checked %@ Skills in this source.", arguments: [String(index.availableSkills.count)])
        statusMessage = sourceRecheckResults[sourceID]
    }

    func refreshSources() async throws {
        guard rootURL != nil else {
            throw SkillsHubLibraryFailure.missingRoot
        }
        // Manual re-check is a full authorized-range reconciliation: it re-reads the
        // Root snapshot, re-discovers local/ directories, and re-scans Agent
        // directories. It advances no source baseline and writes no authoritative JSON
        // beyond registering newly discovered manual skills; source changes still
        // require a new confirmed plan.
        performScopedRecheck(scopes: nil, fullScan: true)
        await waitForPendingRechecks()
        guard observationStatus.isUnavailable == false else { return }
        setStatus("Re-check complete. Source changes require a new confirmed plan.")
        errorMessage = nil
    }

    func refreshLocalSources() async throws {
        guard let rootURL else { throw SkillsHubLibraryFailure.missingRoot }
        if isRefreshingLocalSources {
            await waitForPendingRechecks()
            return
        }
        isRefreshingLocalSources = true
        defer { if self.rootURL == rootURL { isRefreshingLocalSources = false } }
        performLocalSourcesRecheck()
        await waitForPendingRechecks()
    }

    private func sameRemovalScope(
        _ current: ManagedRelationClearPlan,
        _ confirmed: ManagedRelationClearPlan
    ) -> Bool {
        current.assetID == confirmed.assetID
            && current.skillID == confirmed.skillID
            && current.assetRevision == confirmed.assetRevision
            && current.manifestDigest == confirmed.manifestDigest
            && current.items == confirmed.items
    }

    @concurrent nonisolated private static func readSourceForRecheck(
        source: SkillSource, root: URL, skills: [InstalledSkill], fileManager: FileManager
    ) async throws -> (index: LocalSourceIndexResult, skills: [InstalledSkill]) {
        try Task.checkCancellation()
        guard let path = source.localPath else { throw SourceUpdateError.invalidSource }
        let index = LocalSourceIndexer(fileManager: fileManager)
            .index(directory: URL(fileURLWithPath: path), sourceID: source.id)
        let validator = SkillValidator(fileManager: fileManager)
        let observed = try skills.map { skill in
            try Task.checkCancellation()
            var skill = skill
            skill.validation = validator.validate(skillDirectory: URL(fileURLWithPath: skill.installedPath),
                rootDirectory: root, sourceMetadataPresent: skill.sourceID != nil)
            if let candidate = index.availableSkills.first(where: {
                SkillCatalogPresentationService.matchesLocation(skill, candidate: $0, source: source)
            }) {
                skill.name = candidate.name
                skill.description = candidate.description
            }
            return skill
        }
        return (index, observed)
    }

    private func sourceDirectoryIdentity(_ url: URL) throws -> TargetFileIdentity {
        let identity = try LinkNodeIdentity.read(at: url.standardizedFileURL)
        guard identity.kind == S_IFDIR else {
            throw SourceRemovalError.invalidScope
        }
        return identity.file
    }

    private func applySourceRemovalSnapshot(_ snapshot: RootSnapshot) {
        guard rootURL?.standardizedFileURL.path == snapshot.metadata.rootConfig.rootPath else { return }
        rootSnapshot = snapshot
        sources = snapshot.metadata.sources
        availableSkills = snapshot.metadata.availableSkills
        installedSkills = snapshot.metadata.installedSkills
        agentLinks = []
        tags = snapshot.metadata.tags
    }
}
