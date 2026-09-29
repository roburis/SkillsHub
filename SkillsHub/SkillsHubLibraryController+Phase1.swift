import Foundation

extension SkillsHubLibraryController {
    var phase1TaskBadgeCount: Int {
        phase1Tasks.filter(\.badgeEligible).count
    }

    func establishSelectedRoot(_ url: URL) async {
        do {
            let result = try inspectSelectedRoot(url)
            switch result {
            case .existingRoot(let facts):
                try activateExistingRoot(facts, announceStatus: true, resolvingPersistedBookmark: false)
            case .initializationRequired(let facts):
                if fileManager.fileExists(atPath: metadataStore.rootLayout(for: facts.url).skillshubMetadataFile.path) {
                    try activateExistingRoot(facts, announceStatus: true, resolvingPersistedBookmark: false)
                } else {
                    let plan = try phase1OperationPlanner.rootInitializationPlan(facts: facts)
                    pendingRootInitialization = facts
                    await executePhase1Operation(plan, directlyAuthorized: true)
                }
            case .invalid(let failure):
                throw SkillsHubLibraryFailure.invalidSource(rootInspectionMessage(for: failure))
            case .cancelled:
                return
            }
        } catch {
            handle(error)
        }
    }

    func prepareLocalSourceRegistration(from directory: URL) throws {
        let normalized = directory.standardizedFileURL
        let sourceID = UUID()
        let lease = try acquireSecurityScopedAccess(to: normalized, owner: .source(sourceID))
        let planResult: Result<Phase1OperationPlan, Error>
        do {
            let snapshot = try currentPhase1Snapshot()
            guard sources.contains(where: { $0.kind == .localDirectory && $0.localPath == normalized.path }) == false else {
                throw SkillsHubLibraryFailure.invalidSource("Local source already registered.")
            }
            planResult = .success(
                try phase1OperationPlanner.sourceRegistrationPlan(
                    directory: normalized,
                    snapshot: snapshot,
                    sourceID: sourceID
                )
            )
        } catch {
            planResult = .failure(error)
        }
        try endSecurityScopedAccessLease(lease)
        let plan = try planResult.get()
        pendingPhase1OperationPlan = plan
        upsertTask(waitingTask(for: plan))
        setStatus("Local source plan is waiting for confirmation.")
        errorMessage = nil
    }

    func importLocalSource(from directory: URL) async {
        let normalized = directory.standardizedFileURL
        let sourceID = UUID()
        do {
            let snapshot = try currentPhase1Snapshot()
            let rootURL = try requiredRootURL()
            guard sources.contains(where: {
                $0.kind == .localDirectory
                    && ($0.externalLocalPath == normalized.path || $0.localPath == normalized.path)
            }) == false else {
                throw SkillsHubLibraryFailure.invalidSource("Local source already imported.")
            }
            let lease = try acquireSecurityScopedAccess(to: normalized, owner: .source(sourceID))
            let planResult: Result<Phase1OperationPlan, Error>
            do {
                let fileManager = fileManager
                let planning = Task.detached(priority: .userInitiated) {
                    try Phase1OperationPlanner(fileManager: fileManager).localSourceImportPlan(
                        directory: normalized,
                        rootURL: rootURL,
                        snapshot: snapshot,
                        sourceID: sourceID
                    )
                }
                planResult = .success(try await withTaskCancellationHandler {
                    try await planning.value
                } onCancel: {
                    planning.cancel()
                })
            } catch {
                planResult = .failure(error)
            }
            try endSecurityScopedAccessLease(lease)
            await executePhase1Operation(try planResult.get(), directlyAuthorized: true)
        } catch {
            handle(error)
        }
    }

    func addGitHubSource(_ rawURL: String) async {
        do {
            let snapshot = try currentPhase1Snapshot()
            let rootURL = try requiredRootURL()
            setStatus("Fetching and checking the complete repository…")
            errorMessage = nil
            let result = try await indexGitHubSource(rawURL: rawURL)
            let stager = FileSystemGitHubSourceStager(
                stagingRoot: appSupportURL.appendingPathComponent("GitHubStaging", isDirectory: true),
                fileManager: fileManager
            )
            guard result.issue == nil, let staged = result.stagedRepository else {
                throw SkillsHubLibraryFailure.invalidSource(githubSourceMessage(for: result.issue))
            }
            let plan: Phase1OperationPlan
            do {
                plan = try phase1OperationPlanner.githubSourceImportPlan(
                    result: result,
                    rootURL: rootURL,
                    snapshot: snapshot
                )
            } catch {
                try? stager.discard(staged)
                throw error
            }
            if await executePhase1Operation(plan, directlyAuthorized: true) {
                do {
                    try stager.discard(staged)
                } catch {
                    setStatus("GitHub source imported; its temporary staged copy could not be removed.")
                }
            }
        } catch {
            handle(error)
        }
    }

    func indexGitHubSource(
        rawURL: String,
        trackedBranch: String? = nil,
        repositoryID: Int64? = nil,
        sourceID: UUID = UUID()
    ) async throws -> GitHubIndexResult {
        let stagingRoot = appSupportURL.appendingPathComponent("GitHubStaging", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let apiClient: GitHubRESTAPIClient
        #if DEBUG
        apiClient = GitHubRESTAPIClient(httpClient: githubHTTPDataClientOverride ?? URLSessionHTTPDataClient())
        #else
        apiClient = GitHubRESTAPIClient()
        #endif
        return await GitHubSourceIndexer(
            apiClient: apiClient,
            stager: FileSystemGitHubSourceStager(stagingRoot: stagingRoot, fileManager: fileManager)
        ).index(
            rawURL: rawURL,
            trackedBranch: trackedBranch,
            repositoryID: repositoryID,
            sourceID: sourceID
        )
    }

    private func githubSourceMessage(for issue: GitHubSourceIssue?) -> LocalizedMessage {
        switch issue {
        case .noSkills: "No source was added because the complete repository contains no SKILL.md candidates."
        case .unsupportedVersion: "The first version supports repository roots on their default branch only."
        case .cancelled: "GitHub source addition was cancelled."
        case .rateLimited: "GitHub rate-limited this request. Try again after the service limit resets."
        case .branchUnavailable: "The recorded GitHub branch is unavailable."
        case .repositoryTooLarge: "The repository exceeds the safe fetch or staging budget."
        case .pathRestricted: "The public repository is unavailable or cannot be read without authentication."
        case .treeTruncated, .archiveInvalid, .contentMismatch: "The complete repository could not be verified, so nothing was added."
        case .networkFailure, .timedOut: "The repository check failed. Existing managed content was not changed."
        case .unsupportedProvider, .invalidURL: "Enter a public GitHub repository root such as https://github.com/owner/repository."
        case .repositoryChanged: "The repository identity changed during the operation. Check it again."
        case nil: "The repository check did not produce a publishable source."
        }
    }

    func prepareManagedCopy(candidateID: String) throws {
        let snapshot = try currentPhase1Snapshot()
        guard let candidate = availableSkills.first(where: { $0.candidateID == candidateID || $0.id == candidateID }),
              let source = sources.first(where: { $0.id == candidate.sourceID }),
              let rootURL
        else {
            throw SkillsHubLibraryFailure.missingSkill(candidateID)
        }
        guard candidate.checkStatus == .valid || candidate.checkStatus == .warning else {
            throw SkillsHubLibraryFailure.invalidSource("Candidate is blocked or unreadable.")
        }
        guard candidate.generatedAtGeneration == snapshot.generation else {
            throw Phase1OperationError.staleFacts
        }
        guard let sourcePath = source.localPath else {
            throw SkillsHubLibraryFailure.invalidSource("Local source path is unavailable.")
        }
        let lease = try acquireSecurityScopedAccess(
            to: URL(fileURLWithPath: sourcePath, isDirectory: true),
            owner: .source(source.id),
            endingSelectedInspection: false,
            resolvingPersistedBookmark: true
        )
        let planResult: Result<Phase1OperationPlan, Error>
        do {
            planResult = .success(
                try phase1OperationPlanner.managedCopyPlan(
                    candidate: candidate,
                    source: source,
                    rootURL: rootURL,
                    snapshot: snapshot
                )
            )
        } catch {
            planResult = .failure(error)
        }
        try endSecurityScopedAccessLease(lease)
        let plan = try planResult.get()
        pendingPhase1OperationPlan = plan
        upsertTask(waitingTask(for: plan))
        setStatus("Managed copy plan is waiting for confirmation.")
        errorMessage = nil
    }

    func confirmPendingPhase1Operation() async {
        guard let plan = pendingPhase1OperationPlan else {
            handle(SkillsHubLibraryFailure.invalidSource("No Phase 1 operation is waiting for confirmation."))
            return
        }
        guard plan.kind != .initializeRoot else {
            pendingPhase1OperationPlan = nil
            handle(SkillsHubLibraryFailure.invalidSource("Root establishment must start from the Establish Management Directory button."))
            return
        }
        await executePhase1Operation(plan, directlyAuthorized: false)
    }

    @discardableResult
    private func executePhase1Operation(
        _ plan: Phase1OperationPlan,
        directlyAuthorized: Bool
    ) async -> Bool {
        let operationLeases: [SecurityScopedAccessLease]
        do {
            operationLeases = try acquireOperationLeases(for: plan)
        } catch {
            handle(error)
            return false
        }
        if plan.kind != .initializeRoot {
            pendingPhase1OperationPlan = nil
        }
        let token = phase1OperationPlanner.confirmation(for: plan)
        var running = waitingTask(for: plan)
        running.phase = .executing
        running.result = directlyAuthorized
            ? "Explicit action authorized; executing the immutable plan."
            : "Confirmed; executing the immutable plan."
        running.events.append(
            Phase1TaskEvent(
                id: UUID(),
                phase: .executing,
                message: directlyAuthorized
                    ? "Explicit action submitted."
                    : "One-time confirmation submitted.",
                occurredAt: Date()
            )
        )
        running.updatedAt = Date()
        upsertTask(running)
        let sessionID = rootSessionLease?.id
        let previousRoot = rootURL
        func contextIsCurrent() -> Bool {
            rootSessionLease?.id == sessionID && rootURL == previousRoot
                && (plan.kind != .initializeRoot || pendingRootInitialization?.url.path == plan.rootPath)
        }
        let progress = AsyncStream<Phase1JournalRecord>.makeStream()
        async let completion = phase1OperationCoordinator.commit(plan: plan, confirmation: token, progress: progress.continuation)
        for await record in progress.stream {
            guard contextIsCurrent(), record.event != .final else { continue }
            running.phase = record.phase == .waitingConfirmation ? .executing : record.phase
            running.result = .verbatim(record.result)
            running.events.append(Phase1TaskEvent(id: UUID(), phase: record.phase, message: LocalizedMessage(record.result), occurredAt: record.occurredAt))
            running.updatedAt = record.occurredAt
            upsertTask(running)
        }
        let result = await completion
        do {
            for lease in operationLeases.reversed() {
                try endSecurityScopedAccessLease(lease)
            }
        } catch {
            handle(error)
            return false
        }
        guard contextIsCurrent() else { return false }
        var finished = result.task
        finished.events = running.events + result.task.events.suffix(1)
        upsertTask(finished)
        if plan.kind != .initializeRoot, let snapshot = result.snapshot {
            applyPhase1Snapshot(snapshot)
        }
        guard result.succeeded, let snapshot = result.snapshot else {
            if plan.kind == .initializeRoot {
                pendingRootInitialization = RootInspectionFacts(
                    url: URL(fileURLWithPath: plan.rootPath, isDirectory: true)
                )
            }
            errorMessage = result.task.result
            statusMessage = nil
            return false
        }
        do {
            if plan.kind == .initializeRoot {
                try activateInitializedRoot(plan: plan, snapshot: snapshot)
            } else {
                applyPhase1Snapshot(snapshot)
            }
        } catch {
            handle(error)
            return false
        }
        statusMessage = result.task.result
        errorMessage = nil
        return true
    }

    func cancelPendingPhase1Operation() async {
        guard let plan = pendingPhase1OperationPlan else { return }
        pendingPhase1OperationPlan = nil
        let task = await phase1OperationCoordinator.cancel(plan: plan)
        upsertTask(task)
        statusMessage = task.result
    }

    func discardPendingRootInitializationAccess() {
        pendingRootInitialization = nil
    }

    private func currentPhase1Snapshot() throws -> RootSnapshot {
        guard let rootSnapshot else {
            throw SkillsHubLibraryFailure.missingRoot
        }
        return rootSnapshot
    }

    private func requiredRootURL() throws -> URL {
        guard let rootURL else { throw SkillsHubLibraryFailure.missingRoot }
        return rootURL
    }

    private func acquireOperationLeases(for plan: Phase1OperationPlan) throws -> [SecurityScopedAccessLease] {
        var leases: [SecurityScopedAccessLease] = []
        let owner = SecurityScopedAccessOwner.operation(plan.id)
        let rootURL = URL(fileURLWithPath: plan.rootPath, isDirectory: true)
        do {
            leases.append(
                try acquireSecurityScopedAccess(
                    to: rootURL,
                    owner: owner,
                    endingSelectedInspection: false,
                    resolvingPersistedBookmark: true
                )
            )
            if plan.source?.kind == .localDirectory,
               let sourcePath = plan.source?.externalLocalPath ?? plan.source?.localPath {
                leases.append(
                    try acquireSecurityScopedAccess(
                        to: URL(fileURLWithPath: sourcePath, isDirectory: true),
                        owner: owner,
                        endingSelectedInspection: false,
                        resolvingPersistedBookmark: true
                    )
                )
            }
            return leases
        } catch {
            for lease in leases.reversed() {
                do {
                    try endSecurityScopedAccessLease(lease)
                } catch let releaseError {
                    throw releaseError
                }
            }
            throw error
        }
    }

    private func applyPhase1Snapshot(_ snapshot: RootSnapshot) {
        guard rootURL?.standardizedFileURL.path == snapshot.metadata.rootConfig.rootPath,
              rootSnapshot.map({ $0.generation <= snapshot.generation }) ?? true else { return }
        rootSnapshot = snapshot
        sources = snapshot.metadata.sources
        availableSkills = snapshot.metadata.availableSkills
        installedSkills = snapshot.metadata.installedSkills
        agentLinks = []
        tags = snapshot.metadata.tags
    }

    private func activateInitializedRoot(
        plan: Phase1OperationPlan,
        snapshot: RootSnapshot
    ) throws {
        let normalizedRoot = URL(fileURLWithPath: plan.rootPath, isDirectory: true).standardizedFileURL
        guard plan.kind == .initializeRoot,
              snapshot.generation == 0,
              snapshot.metadata.rootConfig.rootPath == normalizedRoot.path,
              pendingRootInitialization?.url.standardizedFileURL.path == normalizedRoot.path else {
            throw Phase1OperationError.invalidPlan
        }
        pendingRootInitialization = nil
        lastRootInspectionResult = .existingRoot(
            RootInspectionFacts(url: normalizedRoot, snapshot: snapshot)
        )
        let nextRootLease = try acquireSecurityScopedAccess(
            to: normalizedRoot,
            owner: .rootSession(UUID()),
            endingSelectedInspection: false,
            resolvingPersistedBookmark: true
        )
        let previousLease = rootSessionLease
        rootSessionLease = nextRootLease
        rootURL = normalizedRoot
        applyPhase1Snapshot(snapshot)
        localState = plan.initialLocalState ?? SkillsHubLocalState()
        agentPathOverrides = Self.agentPathOverrides(
            from: snapshot.metadata.agents
        )
        agentDetections = localState.detectedAgentsSnapshot
        agentFindings = localState.operationFailureFindings ?? []
        scannedSkillCount = 0
        scanStatusMessage = nil
        if let previousLease {
            try endSecurityScopedAccessLease(previousLease)
        }
        // Newly established Root: subscribe and run the initial authorized-range scan.
        subscribeAndInitialScan()
    }

    private func waitingTask(for plan: Phase1OperationPlan) -> Phase1TaskRecord {
        Phase1TaskRecord(
            id: plan.id,
            kind: plan.kind.taskKind,
            title: LocalizedMessage(operationTitle(for: plan.kind)),
            objectID: operationObjectID(for: plan),
            phase: .waitingConfirmation,
            result: "Waiting for confirmation.",
            planDigest: plan.planDigest,
            events: [
                Phase1TaskEvent(
                    id: UUID(),
                    phase: .waitingConfirmation,
                    message: "Immutable plan prepared.",
                    occurredAt: Date()
                )
            ],
            updatedAt: Date(),
            operationPlan: plan
        )
    }

    private func operationTitle(for kind: Phase1OperationKind) -> String {
        switch kind {
        case .initializeRoot: return "Establish Management Directory"
        case .importLocalSource: return "Import local source"
        case .importGitHubSource: return "Import GitHub source"
        case .registerLocalSource: return "Register local source"
        case .publishManagedCopy: return "Publish managed Skill"
        }
    }

    private func operationObjectID(for plan: Phase1OperationPlan) -> String {
        switch plan.kind {
        case .initializeRoot: return plan.rootPath
        case .importLocalSource, .importGitHubSource: return plan.source?.id.uuidString ?? plan.rootPath
        case .registerLocalSource: return plan.source?.id.uuidString ?? plan.rootPath
        case .publishManagedCopy: return plan.selectedCandidate?.candidateID ?? plan.rootPath
        }
    }

    func recheckRecoveryTasks() {
        do {
            try reloadFromDisk()
            setStatus("Current operation facts were re-checked. No recorded action was replayed.")
            errorMessage = nil
        } catch {
            handle(error)
        }
    }

    func mergeRecoveredOperationTasks(rootURL: URL) {
        var recovered: [Phase1TaskRecord] = []
        let relationStore = RelationActionOperationRecordStore(fileManager: fileManager)
        let operationPath = metadataStore.rootLayout(for: rootURL).operationRecoveryDirectory.path
        let relationIDs: [UUID]
        do {
            relationIDs = try relationStore.recoveryOperationIDs(rootURL: rootURL)
        } catch {
            relationIDs = []
            recovered.append(unknownRecoveryTask(
                id: StableIdentity.uuid(namespace: "operation-recovery", value: operationPath),
                kind: .setAgentRelation,
                title: "Operation records are unavailable",
                objectID: rootURL.path,
                path: operationPath,
                error: error
            ))
        }
        for operationID in relationIDs {
            recovered.append(recoveredRelationTask(operationID: operationID, rootURL: rootURL, store: relationStore))
        }
        let sourceIDs = (try? sourceRemovalService.recoveryOperationIDs(rootURL: rootURL)) ?? []
        for operationID in sourceIDs where !relationIDs.contains(operationID) {
            recovered.append(recoveredSourceRemovalTask(operationID: operationID, rootURL: rootURL))
        }
        let updateIDs = (try? sourceUpdateService.recoveryOperationIDs(rootURL: rootURL)) ?? []
        for operationID in updateIDs where !relationIDs.contains(operationID) && !sourceIDs.contains(operationID) {
            recovered.append(recoveredSourceUpdateTask(operationID: operationID, rootURL: rootURL))
        }
        let recoveredIDs = Set(recovered.map(\.id))
        phase1Tasks.removeAll {
            ($0.recoveryEvidence != nil && $0.operationPlan == nil) || recoveredIDs.contains($0.id)
        }
        for task in recovered { upsertTask(task) }
    }

    private func recoveredRelationTask(
        operationID: UUID,
        rootURL: URL,
        store: RelationActionOperationRecordStore
    ) -> Phase1TaskRecord {
        let operationPath = metadataStore.rootLayout(for: rootURL).operationRecoveryDirectory
            .appendingPathComponent(operationID.uuidString, isDirectory: true).path
        do {
            switch try store.loadRecoveryRecord(operationID: operationID, rootURL: rootURL) {
            case .relation(let record):
                let recovery = relationActionRuntime.recoverCurrentFacts(operationID: operationID, rootURL: rootURL)
                let components = recovery.components.map {
                    Phase1RecoveryComponent(
                        kind: $0.kind.rawValue,
                        state: recoveryState($0.state),
                        path: $0.path,
                        detail: $0.detail
                    )
                }
                let asset = rootSnapshot?.metadata.installedSkills.first { $0.assetID == record.relation.assetID }
                let agentName = visibleInstalledAgentDescriptors.first { $0.id == record.relation.agentID }?.displayName
                    ?? record.relation.agentID
                let skillName = asset?.name ?? record.relation.assetID.uuidString
                return Phase1TaskRecord(
                    id: operationID,
                    kind: .setAgentRelation,
                    title: record.desiredEnabled
                        ? "Enable \(agentName) for \(skillName)"
                        : "Disable \(agentName) for \(skillName)",
                    objectID: asset?.id ?? record.relation.assetID.uuidString,
                    phase: recoveryPhase(components),
                    result: recoverySummary(components),
                    planDigest: record.factsDigest,
                    events: recoveryEvents(components, at: record.completedAt ?? record.observations.last?.observedAt ?? Date()),
                    updatedAt: record.completedAt ?? record.observations.last?.observedAt ?? Date(),
                    relationEvidence: Phase1RelationTaskEvidence(
                        relation: record.relation,
                        agentDisplayName: agentName,
                        skillID: asset?.id ?? record.relation.assetID.uuidString,
                        skillName: skillName,
                        desiredEnabled: record.desiredEnabled,
                        outcome: recoveryPhase(components) == .completed ? "Completed" : "Needs attention",
                        actualDelta: components.map { "\($0.kind): \($0.state.presentationLabel)" },
                        verification: recovery.verification?.conclusion ?? .currentlyUnverifiable,
                        limitations: recovery.limitations,
                        safeNextStep: recovery.safeNextStep
                    ),
                    recoveryEvidence: Phase1RecoveryEvidence(components: components, agentID: record.relation.agentID)
                )
            case .brokenLink(let record):
                let originalIdentity = try? LinkNodeIdentity.read(at: URL(fileURLWithPath: record.facts.linkPath))
                let retainedPath = record.removal?.isolationPath
                let retainedIdentity = retainedPath.flatMap { try? LinkNodeIdentity.read(at: URL(fileURLWithPath: $0)) }
                let nodeState: Phase1RecoveryState
                if originalIdentity == record.facts.nodeIdentity {
                    nodeState = .notCompleted
                } else if originalIdentity == nil, retainedIdentity == record.facts.nodeIdentity {
                    nodeState = .notCompleted
                } else if originalIdentity == nil, retainedIdentity == nil, record.completedAt != nil {
                    nodeState = .completed
                } else {
                    nodeState = .unknown
                }
                var components = [
                    Phase1RecoveryComponent(kind: "link-node", state: nodeState, path: record.facts.linkPath, detail: "observed-current-link-node"),
                    Phase1RecoveryComponent(kind: "operation-materials", state: .completed, path: operationPath, detail: "recovery-record-readable")
                ]
                if let retainedPath {
                    components.append(Phase1RecoveryComponent(
                        kind: "retained-node",
                        state: retainedIdentity == record.facts.nodeIdentity ? .notCompleted : (retainedIdentity == nil ? .completed : .unknown),
                        path: retainedPath,
                        detail: "observed-current-retained-node"
                    ))
                }
                let updatedAt = record.completedAt ?? fileModificationDate(operationPath) ?? Date()
                return Phase1TaskRecord(
                    id: operationID,
                    kind: .deleteBrokenLink,
                    title: "Delete broken link for \(record.facts.agentDisplayName)",
                    objectID: record.facts.agentID,
                    phase: recoveryPhase(components),
                    result: recoverySummary(components),
                    planDigest: record.factsDigest,
                    events: recoveryEvents(components, at: updatedAt),
                    updatedAt: updatedAt,
                    recoveryEvidence: Phase1RecoveryEvidence(components: components, agentID: record.facts.agentID)
                )
            }
        } catch {
            return unknownRecoveryTask(
                id: operationID,
                kind: .setAgentRelation,
                title: "Unverifiable Agent operation",
                objectID: operationID.uuidString,
                path: operationPath,
                error: error
            )
        }
    }

    private func recoveredSourceRemovalTask(operationID: UUID, rootURL: URL) -> Phase1TaskRecord {
        let operationPath = rootURL.standardizedFileURL
            .appendingPathComponent(".skillshub-operations/\(operationID.uuidString)", isDirectory: true).path
        do {
            let record = try sourceRemovalService.loadRecord(operationID: operationID, rootURL: rootURL)
            let snapshot = try? metadataStore.loadCurrentSnapshot(from: rootURL)
            let sourceURL = URL(fileURLWithPath: record.sourcePath, isDirectory: true)
            let sourceIdentity = currentDirectoryIdentity(sourceURL)
            let trashIdentity = record.trashPath.flatMap { try? LinkNodeIdentity.read(at: URL(fileURLWithPath: $0)) }
            let contentState: Phase1RecoveryState
            if sourceIdentity == record.sourceIdentity {
                contentState = .notCompleted
            } else if sourceIdentity == nil, trashIdentity != nil {
                contentState = .completed
            } else {
                contentState = .unknown
            }
            let metadataState: Phase1RecoveryState
            if let snapshot {
                let sourcePresent = snapshot.metadata.sources.contains { $0.id == record.sourceID }
                let presentAssets = Set(snapshot.metadata.installedSkills.map(\.assetID)).intersection(record.skillAssetIDs)
                if !sourcePresent, presentAssets.isEmpty {
                    metadataState = .completed
                } else if sourcePresent, presentAssets.count == record.skillAssetIDs.count {
                    metadataState = .notCompleted
                } else {
                    metadataState = .unknown
                }
            } else {
                metadataState = .unknown
            }
            let currentRelations = Set((snapshot?.metadata.enablementIntents.map {
                AgentRelationIdentity(assetID: $0.assetID, agentID: $0.agentID, scope: $0.scope).id
            } ?? []) + (snapshot?.metadata.managedRelationEvidence.map(\.relation.id) ?? []))
            let relationState: Phase1RecoveryState = snapshot == nil
                ? .unknown
                : (record.relationIDs.contains(where: currentRelations.contains) ? .notCompleted : .completed)
            var components = [
                Phase1RecoveryComponent(kind: "content", state: contentState, path: record.sourcePath, detail: "observed-current-source-content"),
                Phase1RecoveryComponent(kind: "relationships", state: relationState, path: record.sourcePath, detail: "observed-current-managed-relations"),
                Phase1RecoveryComponent(kind: "metadata", state: metadataState, path: metadataStore.rootLayout(for: rootURL).skillshubMetadataFile.path, detail: "observed-current-metadata"),
                Phase1RecoveryComponent(kind: "operation-materials", state: .completed, path: operationPath, detail: "source-removal-record-readable")
            ]
            if let trashPath = record.trashPath {
                components.append(Phase1RecoveryComponent(
                    kind: "retained-location",
                    state: trashIdentity == nil ? .unknown : .completed,
                    path: trashPath,
                    detail: "observed-current-trash-location"
                ))
            }
            return Phase1TaskRecord(
                id: operationID,
                kind: .removeLocalSource,
                title: "Remove source \(sourceURL.lastPathComponent)",
                objectID: record.sourceID.uuidString,
                phase: recoveryPhase(components),
                result: recoverySummary(components),
                planDigest: record.planDigest,
                events: recoveryEvents(components, at: record.updatedAt),
                updatedAt: record.updatedAt,
                recoveryEvidence: Phase1RecoveryEvidence(
                    components: components,
                    sourceID: record.sourceID,
                    sourceKind: record.sourceKind
                )
            )
        } catch {
            return unknownRecoveryTask(
                id: operationID,
                kind: .removeLocalSource,
                title: "Unverifiable source removal",
                objectID: operationID.uuidString,
                path: operationPath,
                error: error
            )
        }
    }

    private func recoveredSourceUpdateTask(operationID: UUID, rootURL: URL) -> Phase1TaskRecord {
        let operationPath = rootURL.standardizedFileURL
            .appendingPathComponent(".skillshub-operations/\(operationID.uuidString)", isDirectory: true).path
        do {
            let record = try sourceUpdateService.loadRecord(operationID: operationID, rootURL: rootURL)
            let exchange = SourceDirectoryExchange()
            let exchangeRecord = try exchange.loadRecord(operationID: operationID, rootURL: rootURL)
            let observation = exchange.observe(exchangeRecord, rootURL: rootURL)
            let snapshot = try? metadataStore.loadCurrentSnapshot(from: rootURL)
            let source = snapshot?.metadata.sources.first { $0.id == record.sourceID }
            let contentState: Phase1RecoveryState = switch observation.current {
            case .prepared: .completed
            case .original: .notCompleted
            case .unknown: .unknown
            }
            let metadataState: Phase1RecoveryState
            let baselineState: Phase1RecoveryState
            if let source {
                if source.baselineManifest?.digest == exchangeRecord.prepared.manifest.digest {
                    metadataState = .completed
                    baselineState = .completed
                } else if source.baselineManifest?.digest == exchangeRecord.current.manifest.digest {
                    metadataState = .notCompleted
                    baselineState = .notCompleted
                } else {
                    metadataState = .unknown
                    baselineState = .unknown
                }
            } else {
                metadataState = .unknown
                baselineState = .unknown
            }
            let relationState: Phase1RecoveryState
            if let relationIDs = record.relationIDs, let snapshot {
                let currentRelations = Set(snapshot.metadata.enablementIntents.map {
                    AgentRelationIdentity(assetID: $0.assetID, agentID: $0.agentID, scope: $0.scope).id
                } + snapshot.metadata.managedRelationEvidence.map(\.relation.id))
                relationState = relationIDs.contains(where: currentRelations.contains) ? .notCompleted : .completed
            } else {
                relationState = .unknown
            }
            let trashIdentity = record.trashPath.flatMap { try? LinkNodeIdentity.read(at: URL(fileURLWithPath: $0)) }
            let retainedIdentity = record.retainedPath.flatMap { try? LinkNodeIdentity.read(at: URL(fileURLWithPath: $0)) }
            let disposalState: Phase1RecoveryState
            let disposalPath: String
            if trashIdentity == exchangeRecord.current.identity {
                disposalState = .completed
                disposalPath = record.trashPath ?? exchangeRecord.prepared.path
            } else if retainedIdentity == exchangeRecord.current.identity || observation.retained == .original {
                disposalState = .notCompleted
                disposalPath = record.retainedPath ?? exchangeRecord.prepared.path
            } else {
                disposalState = .unknown
                disposalPath = record.trashPath ?? record.retainedPath ?? exchangeRecord.prepared.path
            }
            let metadataPath = metadataStore.rootLayout(for: rootURL).skillshubMetadataFile.path
            let components = [
                Phase1RecoveryComponent(kind: "content", state: contentState, path: record.sourcePath, detail: "observed-current-source-content"),
                Phase1RecoveryComponent(kind: "relationships", state: relationState, path: record.sourcePath, detail: "observed-current-managed-relations"),
                Phase1RecoveryComponent(kind: "metadata", state: metadataState, path: metadataPath, detail: "observed-current-metadata"),
                Phase1RecoveryComponent(kind: "success-baseline", state: baselineState, path: metadataPath, detail: "observed-current-success-baseline"),
                Phase1RecoveryComponent(kind: "old-content-disposal", state: disposalState, path: disposalPath, detail: "observed-current-retained-or-trash-location"),
                Phase1RecoveryComponent(kind: "operation-materials", state: .completed, path: operationPath, detail: "source-update-records-readable")
            ]
            return Phase1TaskRecord(
                id: operationID,
                kind: .updateSource,
                title: "Update source \(URL(fileURLWithPath: record.sourcePath).lastPathComponent)",
                objectID: record.sourceID.uuidString,
                phase: recoveryPhase(components),
                result: recoverySummary(components),
                planDigest: record.planDigest,
                events: recoveryEvents(components, at: record.updatedAt),
                updatedAt: record.updatedAt,
                recoveryEvidence: Phase1RecoveryEvidence(
                    components: components,
                    sourceID: record.sourceID,
                    sourceKind: record.sourceKind
                )
            )
        } catch {
            return unknownRecoveryTask(
                id: operationID,
                kind: .updateSource,
                title: "Unverifiable source update",
                objectID: operationID.uuidString,
                path: operationPath,
                error: error
            )
        }
    }

    private func unknownRecoveryTask(
        id: UUID,
        kind: Phase1TaskKind,
        title: String,
        objectID: String,
        path: String,
        error: Error
    ) -> Phase1TaskRecord {
        let component = Phase1RecoveryComponent(
            kind: "operation-materials",
            state: .unknown,
            path: path,
            detail: String(describing: error)
        )
        let updatedAt = fileModificationDate(path) ?? Date()
        return Phase1TaskRecord(
            id: id,
            kind: kind,
            title: LocalizedMessage(title),
            objectID: objectID,
            phase: .needsAttention,
            result: recoverySummary([component]),
            planDigest: "unverifiable-operation-record",
            events: recoveryEvents([component], at: updatedAt),
            updatedAt: updatedAt,
            recoveryEvidence: Phase1RecoveryEvidence(components: [component])
        )
    }

    private func recoveryState(_ state: RelationActionRecoveryState) -> Phase1RecoveryState {
        switch state {
        case .completed: .completed
        case .notCompleted: .notCompleted
        case .unknown: .unknown
        }
    }

    private func recoveryPhase(_ components: [Phase1RecoveryComponent]) -> Phase1OperationPhase {
        components.allSatisfy { $0.state == .completed } ? .completed : .needsAttention
    }

    private func recoverySummary(_ components: [Phase1RecoveryComponent]) -> LocalizedMessage {
        let completed = components.filter { $0.state == .completed }.count
        let notCompleted = components.filter { $0.state == .notCompleted }.count
        let unknown = components.filter { $0.state == .unknown }.count
        return "Current facts: \(completed) completed, \(notCompleted) not completed, \(unknown) unknown. No action was replayed."
    }

    private func recoveryEvents(_ components: [Phase1RecoveryComponent], at date: Date) -> [Phase1TaskEvent] {
        components.map {
            let message: LocalizedMessage = switch $0.state {
            case .completed: "\($0.kind): completed. \($0.detail)"
            case .notCompleted: "\($0.kind): not completed. \($0.detail)"
            case .unknown: "\($0.kind): unknown. \($0.detail)"
            }
            return Phase1TaskEvent(
                id: StableIdentity.uuid(namespace: "recovery-component", value: "\($0.kind)|\($0.path)|\($0.state.rawValue)"),
                phase: $0.state == .completed ? .completed : .needsAttention,
                message: message,
                occurredAt: date
            )
        }
    }

    private func currentDirectoryIdentity(_ url: URL) -> TargetFileIdentity? {
        guard let identity = try? LinkNodeIdentity.read(at: url), identity.kind == S_IFDIR else { return nil }
        return identity.file
    }

    private func fileModificationDate(_ path: String) -> Date? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    func upsertTask(_ task: Phase1TaskRecord) {
        phase1Tasks.removeAll { $0.id == task.id }
        phase1Tasks.append(task)
        phase1Tasks.sort { $0.updatedAt > $1.updatedAt }
    }
}
