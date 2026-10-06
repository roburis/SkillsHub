import Foundation

extension SkillsHubLibraryController {
    var hasRoot: Bool {
        rootURL != nil
    }

    var settingsRootPathDisplay: String {
        rootURL?.path ?? suggestedRootURL.path
    }

    var suggestedRootURL: URL {
        rootURL ?? defaultRootURL
    }

    func bootstrapDefaultRootIfPresent() async throws {
        guard rootURL == nil else {
            return
        }
        let resolutions = try await startupAccessStore.resolvePresentationAccess(to: [defaultRootURL])
        guard rootURL == nil, !Task.isCancelled,
              let resolution = resolutions[defaultRootURL.standardizedFileURL.path] else {
            return
        }
        let inspectionLease = try securityScopedAccessProvider.acquire(
            url: resolution.url,
            owner: .inspection(UUID())
        )
        if resolution.isStale {
            do {
                try startupAccessStore.saveAccess(to: resolution.url)
            } catch {
                try endSecurityScopedAccessLease(inspectionLease)
                throw error
            }
        }
        do {
            let result = try await inspectRoot(
                defaultRootURL,
                inspectionLease: inspectionLease
            )
            if case .existingRoot(let facts) = result {
                try await activateExistingRoot(
                    facts,
                    announceStatus: false,
                    resolvingPersistedBookmark: true
                )
            } else if case .initializationRequired(let facts) = result {
                try await activateExistingRoot(facts, announceStatus: false, resolvingPersistedBookmark: true)
            }
            if rootURL != nil {
                await refreshAgentLightScan(checkInstallation: true)
                for descriptor in visibleInstalledAgentDescriptors where agentDetections.contains(where: {
                    $0.agentID == descriptor.id && $0.detected
                }) {
                    try? await auditAgentDirectory(agentID: descriptor.id)
                }
            }
        } catch {
            if isRootPermissionError(error) {
                return
            }
            throw error
        }
    }

    func connectExistingRoot(_ url: URL) async throws {
        try ensureRootSwitchAllowed(to: url)
        let inspectionLease = try securityScopedAccessProvider.acquire(
            url: url.standardizedFileURL,
            owner: .inspection(UUID())
        )
        let result = try await inspectRoot(url, inspectionLease: inspectionLease)
        let facts = try connectionFacts(result)
        try await activateExistingRoot(facts, announceStatus: true, resolvingPersistedBookmark: false)
    }

    @discardableResult
    func inspectSelectedRoot(_ url: URL) async throws -> RootInspectionResult {
        let normalizedURL = url.standardizedFileURL
        try ensureRootSwitchAllowed(to: normalizedURL)
        guard let inspectionLease = takeSelectedInspectionLease(to: normalizedURL) else {
            throw SkillsHubLibraryFailure.invalidSource("Root selection access is unavailable.")
        }
        return try await inspectRoot(
            normalizedURL,
            inspectionLease: inspectionLease
        )
    }

    private func connectionFacts(_ result: RootInspectionResult) throws -> RootInspectionFacts {
        switch result {
        case .existingRoot(let facts), .initializationRequired(let facts): return facts
        case .invalid(let failure): throw SkillsHubLibraryFailure.invalidSource(rootInspectionMessage(for: failure))
        case .cancelled: throw CancellationError()
        }
    }

    func connectSelectedRoot(_ url: URL) async throws {
        let result = try await inspectSelectedRoot(url)
        let facts = try connectionFacts(result)
        try await activateExistingRoot(facts, announceStatus: true, resolvingPersistedBookmark: false)
    }

    @discardableResult
    func cancelRootSelection() -> RootInspectionResult {
        rootInspectionGeneration &+= 1
        let result = RootInspectionResult.cancelled
        lastRootInspectionResult = result
        errorMessage = nil
        return result
    }

    private func inspectRoot(
        _ url: URL,
        inspectionLease: SecurityScopedAccessLease
    ) async throws -> RootInspectionResult {
        let normalizedURL = url.standardizedFileURL
        rootInspectionGeneration &+= 1
        let generation = rootInspectionGeneration
        let previousRoot = rootURL
        let previousSession = rootSessionLease?.id
        let result = await metadataStore.inspectRoot(at: normalizedURL)
        do {
            try endSecurityScopedAccessLease(inspectionLease)
        } catch {
            lastRootInspectionResult = .invalid(
                .invalidMetadata(path: normalizedURL.path, reason: String(describing: error))
            )
            throw error
        }
        guard !Task.isCancelled, generation == rootInspectionGeneration,
              rootURL == previousRoot, rootSessionLease?.id == previousSession else { throw CancellationError() }
        lastRootInspectionResult = result
        switch result {
        case .existingRoot:
            discardPendingRootInitializationAccess()
            errorMessage = nil
        case .initializationRequired:
            discardPendingRootInitializationAccess()
            errorMessage = nil
            statusMessage = nil
        case .invalid(let failure):
            discardPendingRootInitializationAccess()
            errorMessage = rootInspectionMessage(for: failure)
            statusMessage = nil
        case .cancelled:
            break
        }
        return result
    }

    func activateExistingRoot(
        _ facts: RootInspectionFacts,
        announceStatus: Bool,
        resolvingPersistedBookmark: Bool
    ) async throws {
        let normalizedURL = facts.url.standardizedFileURL
        cancelPendingRechecks()
        libraryReadGeneration &+= 1
        let generation = libraryReadGeneration
        let previousRootURL = rootURL
        let previousSessionID = rootSessionLease?.id
        let previousSnapshot = rootSnapshot
        let reusesCurrentSession = previousRootURL?.standardizedFileURL == normalizedURL && rootSessionLease != nil
        let nextRootLease: SecurityScopedAccessLease?
        let inspectionLease = try reusesCurrentSession ? rootSessionLease.map {
            try securityScopedAccessProvider.acquire(url: $0.url, owner: .inspection(UUID()))
        } : nil
        defer { if let inspectionLease { _ = inspectionLease.end(by: inspectionLease.owner) } }
        if reusesCurrentSession {
            try endSelectedInspectionAccess(to: normalizedURL)
            nextRootLease = nil
        } else {
            nextRootLease = try acquireSecurityScopedAccess(to: normalizedURL,
                owner: .rootSession(UUID()), resolvingPersistedBookmark: resolvingPersistedBookmark)
        }
        let result: (snapshot: RootSnapshot, skills: [InstalledSkill], state: SkillsHubLocalState, tasks: [Phase1TaskRecord], resolvedRootPath: String?)
        do {
            result = try await Self.readActivatedLibrary(facts: facts, metadataStore: metadataStore,
                localStateStore: localStateStore, fileManager: fileManager)
            guard !Task.isCancelled, libraryReadGeneration == generation,
                  rootURL == previousRootURL, rootSessionLease?.id == previousSessionID,
                  rootSnapshot == previousSnapshot else { throw CancellationError() }
        } catch {
            if let nextRootLease { try endSecurityScopedAccessLease(nextRootLease) }
            throw error
        }
        let rebuildsMetadata = facts.snapshot == nil
        let previousLease = rootSessionLease
        rootURL = normalizedURL
        if let nextRootLease { rootSessionLease = nextRootLease }
        if nextRootLease != nil, let previousLease { try endSecurityScopedAccessLease(previousLease) }
        await applyLibraryRead(result, rootURL: normalizedURL,
            preserveUnboundTasks: previousRootURL?.standardizedFileURL == normalizedURL)
        guard !Task.isCancelled, rootURL == normalizedURL, libraryReadGeneration == generation,
              rootSessionLease?.id == (nextRootLease?.id ?? previousSessionID) else { throw CancellationError() }
        // Subscribe to filesystem events for the now-active Root, then run the initial
        // authorized-range scan. Any prior subscription (e.g. a switched-away Root) is
        // stopped inside subscribe().
        await subscribeAndInitialScan()
        guard !Task.isCancelled, rootURL == normalizedURL,
              rootSessionLease?.id == (nextRootLease?.id ?? previousSessionID) else { throw CancellationError() }
        guard announceStatus || rebuildsMetadata else {
            return
        }
        setStatus(rebuildsMetadata ? "Management records were rebuilt." : "Root configured.")
        errorMessage = nil
    }

    @concurrent nonisolated private static func readActivatedLibrary(
        facts: RootInspectionFacts, metadataStore: SkillsHubMetadataStore,
        localStateStore: SkillsHubLocalStateStore, fileManager: FileManager
    ) async throws -> (snapshot: RootSnapshot, skills: [InstalledSkill], state: SkillsHubLocalState, tasks: [Phase1TaskRecord], resolvedRootPath: String?) {
        if let inspected = facts.snapshot {
            let current = try metadataStore.loadCurrentSnapshot(from: facts.url)
            guard current.metadataDigest == inspected.metadataDigest else { throw MetadataCommitError.staleDigest }
        }
        return try await readLibrary(at: facts.url, metadataStore: metadataStore,
            localStateStore: localStateStore, fileManager: fileManager)
    }

    // MARK: - Filesystem observation

    /// User-facing scan message reflecting observation state. When observation is
    /// unavailable the managed facts are unknown until recovery; the message says so
    /// with the specific reason. Returns `nil` when observation is trusted so the
    /// normal scan-count message stands.
    var observationStatusPresentation: LocalizedMessage? {
        guard case .unavailable(let reason) = observationStatus else { return nil }
        switch reason {
        case .permissionLost:
            return "Folder access was lost. Managed facts are unknown until access is restored."
        case .monitorFailed:
            return "File monitoring is unavailable. Managed facts are unknown until it recovers."
        case .scanFailed:
            return "The last re-check failed. Managed facts are unknown until the next successful re-check."
        }
    }

    var observationStatusMessage: String? {
        observationStatusPresentation.map(localized)
    }

    var observationDisplayMessage: String? {
        if isRefreshingInstalled {
            return localization.localized("Checking managed files…", language: language)
        }
        return observationStatusMessage ?? scanStatusMessage.map(localized)
    }

    /// Reflects the current observation state onto `scanStatusMessage`. Called after a
    /// recheck so the UI shows the unknown state whenever observation is unavailable.
    private func applyObservationStatusToScanMessage() {
        if let message = observationStatusPresentation {
            scanStatusMessage = message
        }
    }

    /// Subscribes to filesystem events for the current Root and authorized Agent
    /// directories, then performs a full authorized-range recheck. Subscribing first
    /// closes the gap where a change lands between the scan and the subscription.
    ///
    /// The initial recheck runs regardless of whether the stream started; if the
    /// stream failed the facts are still refreshed once, but observation is marked
    /// ``ObservationLifecycleStatus/unavailable`` so the UI shows the state as unknown.
    func subscribeAndInitialScan() async {
        cancelPendingRechecks()
        guard let rootURL else {
            observation.stop()
            observationStatus = .notStarted
            return
        }
        let sessionID = rootSessionLease?.id
        let subscription = FilesystemObservationController.Subscription(
            rootURL: rootURL,
            agentDirectories: observableAgentDirectories()
        )
        let started = observation.subscribe(subscription) { [weak self] batch in
            self?.handleObservedDirty(batch)
        }
        if started {
            observationStatus = .observing
        } else {
            observationStatus = .unavailable(reason: .monitorFailed)
        }
        do {
            // Finish the ordinary reload before returning from Root activation. This
            // prevents the initial scan from racing a user action that starts as soon
            // as the Root becomes available. Runtime discovery remains asynchronous
            // because its metadata write is serialized by RootMutationOwner.
            try await reloadFromDisk()
            guard self.rootURL == rootURL, rootSessionLease?.id == sessionID else { return }
            enqueueScopedRecheck(scopes: nil, fullScan: true, reloadManagedRoot: false)
        } catch {
            guard self.rootURL == rootURL, rootSessionLease?.id == sessionID,
                  !(error is CancellationError) else { return }
            observationStatus = .unavailable(
                reason: isRootPermissionError(error) ? .permissionLost : .scanFailed
            )
        }
        applyObservationStatusToScanMessage()
    }

    /// Authorized Agent skills directories to watch, keyed by Agent id. Only directories
    /// that currently exist and are detected are watched; external original source
    /// folders are never included.
    private func observableAgentDirectories() -> [String: URL] {
        var directories: [String: URL] = [:]
        for detection in agentDetections where detection.skillsDirectoryExists && detection.skillsDirectory.isEmpty == false {
            directories[detection.agentID] = URL(fileURLWithPath: detection.skillsDirectory, isDirectory: true)
        }
        return directories
    }

    /// MainActor entry for a coalesced dirty batch. A root change or a lost/dropped
    /// batch escalates to a full authorized-range scan; otherwise only the touched
    /// scopes are rechecked.
    func handleObservedDirty(_ batch: FilesystemEventBatch) {
        if batch.rootChanged || batch.needsFullScan {
            performScopedRecheck(scopes: nil, fullScan: true)
        } else {
            performScopedRecheck(scopes: batch.scopes, fullScan: false)
        }
    }

    /// Runs a generation-gated recheck. `scopes == nil` (or `fullScan`) rechecks the
    /// whole authorized range; otherwise only the given scopes. A newer recheck, or a
    /// Root/session change during the scan, discards this recheck's result so a stale
    /// scan never lands (old Root / old generation returns are dropped).
    func performScopedRecheck(scopes: Set<ObservationScope>?, fullScan: Bool) {
        enqueueScopedRecheck(scopes: scopes, fullScan: fullScan, reloadManagedRoot: true)
    }

    func performLocalSourcesRecheck() {
        enqueueScopedRecheck(scopes: [.managedRoot], fullScan: false, reloadManagedRoot: true, localOnly: true)
    }

    private func enqueueScopedRecheck(
        scopes: Set<ObservationScope>?,
        fullScan: Bool,
        reloadManagedRoot: Bool,
        localOnly: Bool = false
    ) {
        guard rootURL != nil else { return }
        invalidateSourceUpdatePreviews()
        recheckGeneration &+= 1
        pendingManagedRootReload = pendingManagedRootReload || reloadManagedRoot
        pendingLocalOnlyRecheck = pendingLocalOnlyRecheck && localOnly
        if fullScan || scopes == nil {
            pendingFullRecheck = true
            pendingRecheckScopes.removeAll()
        } else if pendingFullRecheck == false {
            pendingRecheckScopes.formUnion(scopes ?? [])
        }
        guard recheckTask == nil else { return }
        isRefreshingInstalled = true
        let taskID = UUID()
        recheckTaskID = taskID
        recheckTask = Task { [weak self] in
            await self?.drainPendingRechecks(taskID: taskID)
        }
    }

    private func drainPendingRechecks(taskID: UUID) async {
        while recheckTaskID == taskID,
              pendingFullRecheck || pendingRecheckScopes.isEmpty == false {
            let fullScan = pendingFullRecheck
            let scopes = fullScan ? nil : pendingRecheckScopes
            let reloadManagedRoot = pendingManagedRootReload
            let localOnly = pendingLocalOnlyRecheck
            pendingFullRecheck = false
            pendingRecheckScopes.removeAll()
            pendingManagedRootReload = false
            pendingLocalOnlyRecheck = true
            let generation = recheckGeneration
            await runScopedRecheck(
                scopes: scopes,
                fullScan: fullScan,
                reloadManagedRoot: reloadManagedRoot,
                generation: generation,
                localOnly: localOnly
            )
            await Task.yield()
        }
        if recheckTaskID == taskID {
            recheckTask = nil
            recheckTaskID = nil
            isRefreshingInstalled = false
        }
    }

    private func runScopedRecheck(
        scopes: Set<ObservationScope>?,
        fullScan: Bool,
        reloadManagedRoot: Bool,
        generation: UInt64,
        localOnly: Bool
    ) async {
        let sessionID = rootSessionLease?.id
        let contextRoot = rootURL
        func contextIsCurrent() -> Bool {
            generation == recheckGeneration
                && rootSessionLease?.id == sessionID
                && rootURL == contextRoot
        }

        let effectiveScopes: Set<ObservationScope>
        if fullScan || scopes == nil {
            var full: Set<ObservationScope> = [.managedRoot]
            for agentID in observableAgentDirectories().keys {
                full.insert(.agentDirectory(agentID: agentID))
            }
            effectiveScopes = full
        } else {
            effectiveScopes = scopes ?? []
        }

        var failureReason: ObservationLifecycleStatus.Reason?
        if effectiveScopes.contains(.managedRoot) {
            let previous = ReloadSnapshot(controller: self)
            do {
                if reloadManagedRoot {
                    try await reloadFromDisk(refreshAgents: !localOnly)
                }
                try await runtimeLocalDiscovery(expectedGeneration: generation, localOnly: localOnly)
            } catch {
                if contextIsCurrent() { previous.restore(to: self) }
                failureReason = isRootPermissionError(error) ? .permissionLost : .scanFailed
            }
        }
        let touchesAgents = effectiveScopes.contains { scope in
            if case .agentDirectory = scope { return true }
            return false
        }
        // A managed-root recheck already ran the Agent light scan inside reloadFromDisk;
        // only scan here when Agent scopes are touched without a managed-root recheck.
        if failureReason == nil,
           touchesAgents,
           effectiveScopes.contains(.managedRoot) == false {
            await refreshAgentLightScan()
        }

        // Scan-during-scan: a newer recheck (or Root/session change) took over; drop
        // this generation's completion so only the newest recheck's result lands.
        guard contextIsCurrent() else { return }
        if let failureReason {
            observationStatus = .unavailable(reason: failureReason)
        } else if observation.isObserving {
            observationStatus = .observing
        }
        applyObservationStatusToScanMessage()
    }

    func cancelPendingRechecks() {
        recheckTask?.cancel()
        recheckTask = nil
        recheckTaskID = nil
        pendingRecheckScopes.removeAll()
        pendingFullRecheck = false
        pendingManagedRootReload = false
        pendingLocalOnlyRecheck = true
        recheckGeneration &+= 1
        isRefreshingInstalled = false
    }

    func waitForPendingRechecks() async {
        while let task = recheckTask {
            await task.value
        }
    }

    func ensureRootSwitchAllowed(to requestedURL: URL) throws {
        let requestedPath = requestedURL.standardizedFileURL.path
        if rootURL?.standardizedFileURL.path == requestedPath { return }
        if let task = phase1Tasks
            .filter({ $0.phase != .completed })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            throw SkillsHubLibraryFailure.invalidSource(
                "Operation \(task.id.uuidString) is not settled. Open Operation and Recovery before switching the Root."
            )
        }
        if let relationID = inFlightRelationActionIDs.sorted().first {
            throw SkillsHubLibraryFailure.invalidSource(
                "Agent relationship operation \(relationID) is still running. Open Operation and Recovery before switching the Root."
            )
        }
    }

    func rootInspectionMessage(for failure: RootInspectionFailure) -> LocalizedMessage {
        errorPresentation(for: failure)
    }

    func reloadFromDisk(preserveUnboundTasks: Bool = true, refreshAgents: Bool = true) async throws {
        guard let rootURL else { throw SkillsHubLibraryFailure.missingRoot }
        libraryReadGeneration &+= 1
        let generation = libraryReadGeneration
        let sessionID = rootSessionLease?.id
        let expected = rootSnapshot
        let recheck = recheckGeneration
        let lease = try rootSessionLease.map {
            try securityScopedAccessProvider.acquire(url: $0.url, owner: .inspection(UUID()))
        }
        defer { if let lease { _ = lease.end(by: lease.owner) } }
        let result = try await Self.readLibrary(
            at: rootURL, metadataStore: metadataStore, localStateStore: localStateStore, fileManager: fileManager
        )
        guard !Task.isCancelled, self.rootURL == rootURL, rootSessionLease?.id == sessionID,
              libraryReadGeneration == generation, recheckGeneration == recheck,
              rootSnapshot == expected else { throw CancellationError() }
        await applyLibraryRead(result, rootURL: rootURL, preserveUnboundTasks: preserveUnboundTasks)
        guard !Task.isCancelled, self.rootURL == rootURL, rootSessionLease?.id == sessionID,
              libraryReadGeneration == generation, rootSnapshot == result.snapshot else { throw CancellationError() }
        if refreshAgents { await refreshAgentLightScan() }
    }

    private func applyLibraryRead(
        _ result: (snapshot: RootSnapshot, skills: [InstalledSkill], state: SkillsHubLocalState, tasks: [Phase1TaskRecord], resolvedRootPath: String?),
        rootURL: URL, preserveUnboundTasks: Bool
    ) async {
        resolvedRootPath = result.resolvedRootPath
        let metadata = result.snapshot.metadata
        rootSnapshot = result.snapshot
        sources = metadata.sources
        availableSkills = metadata.availableSkills
        installedSkills = result.skills
        tags = metadata.tags
        cachePolicyName = metadata.uiState["cachePolicyName"] ?? "Default"
        localState = result.state
        agentPathOverrides = Self.agentPathOverrides(from: metadata.agents)
        agentLinks = []
        scannedSkillCount = installedSkills.count
        scanStatusMessage = LocalizedMessage("Scanned %d managed skill directories.", arguments: [String(installedSkills.count)])
        errorMessage = nil
        let retainedTasks = phase1Tasks.filter {
            $0.operationPlan?.rootPath == rootURL.standardizedFileURL.path
                || (preserveUnboundTasks && $0.operationPlan == nil)
        }
        phase1Tasks = result.tasks
        for var task in retainedTasks {
            if task.phase == .waitingConfirmation,
               let plan = task.operationPlan,
               plan.expectedGeneration != rootSnapshot?.generation {
                task.phase = .needsAttention
                task.result = "Current facts changed; prepare a new plan."
            }
            if !phase1Tasks.contains(where: { $0.id == task.id })
                || [.preparing, .executing, .observing, .verifying].contains(task.phase) {
                upsertTask(task)
            }
        }
        await mergeRecoveredOperationTasks(rootURL: rootURL)

    }

    @concurrent nonisolated private static func readLibrary(
        at root: URL, metadataStore: SkillsHubMetadataStore,
        localStateStore: SkillsHubLocalStateStore, fileManager: FileManager
    ) async throws -> (snapshot: RootSnapshot, skills: [InstalledSkill], state: SkillsHubLocalState, tasks: [Phase1TaskRecord], resolvedRootPath: String?) {
        try Task.checkCancellation()
        let snapshot = try metadataStore.loadOrCreateSnapshot(from: root)
        let state = try localStateStore.load(from: root)
        let tasks = try Phase1OperationJournal(rootURL: root, fileManager: fileManager).recoverTasks()
        let skills = try await validateManagedSkills(snapshot.metadata.installedSkills, root: root, fileManager: fileManager)
let resolvedRootPath: String?
        if let resolved = Darwin.realpath(root.path, nil) {
            resolvedRootPath = String(cString: resolved)
            free(resolved)
        } else { resolvedRootPath = nil }
        return (snapshot, skills, state, tasks, resolvedRootPath)
    }

    @concurrent nonisolated private static func validateManagedSkills(
        _ skills: [InstalledSkill], root: URL, fileManager: FileManager
    ) async throws -> [InstalledSkill] {
        let validator = SkillValidator(fileManager: fileManager)
        return try skills.map { skill in
            try Task.checkCancellation()
            var observed = skill
            observed.validation = validator.validate(
                skillDirectory: URL(fileURLWithPath: skill.installedPath, isDirectory: true),
                rootDirectory: root, sourceMetadataPresent: skill.sourceID != nil
            )
            return observed
        }
    }

    /// Re-enumerates current Root content directories at runtime and registers only the
    /// candidates at new exact locations. Nested entries are independent skills.
    /// Existing identities and missing registrations are retained; observations only
    /// refresh content facts and never transfer relationships after a move.
    @discardableResult
    func runtimeLocalDiscovery(
        observedAt: Date = Date(),
        expectedGeneration: UInt64? = nil,
        localOnly: Bool = false
    ) async throws -> Int {
        guard let rootURL, let expected = rootSnapshot else {
            return 0
        }
        let sessionID = rootSessionLease?.id
        let lease = try rootSessionLease.map { try securityScopedAccessProvider.acquire(url: $0.url, owner: .inspection(UUID())) }
        defer { if let lease { _ = lease.end(by: lease.owner) } }
        let inputSkills = installedSkills
        let inputSources = sources
        let inputCandidates = availableSkills
        let discovery = try await Self.observeRootContent(
            rootURL: rootURL,
            observedAt: observedAt,
            fileManager: fileManager,
            sources: localSourcesForInspection + githubSourcesForPresentation,
            localOnly: localOnly
        )
        let validated = try await Self.validateManagedSkills(inputSkills, root: rootURL, fileManager: fileManager)
        guard !Task.isCancelled, self.rootURL == rootURL, rootSessionLease?.id == sessionID,
              rootSnapshot == expected, installedSkills == inputSkills, sources == inputSources,
              availableSkills == inputCandidates, expectedGeneration.map({ $0 == recheckGeneration }) ?? true else { return 0 }
        let registeredPaths = installedSkills.map(Self.standardizedInstalledPath)
        let newSkills = discovery.installedSkills.filter { candidate in
            !registeredPaths.contains(Self.standardizedInstalledPath(for: candidate))
        }.map { discovered in
            var skill = discovered
            if let source = sources.filter({ source in
                guard let path = source.localPath else { return false }
                let root = URL(fileURLWithPath: path).standardizedFileURL.path
                return skill.installedPath == root || skill.installedPath.hasPrefix(root + "/")
            }).max(by: { ($0.localPath?.count ?? 0) < ($1.localPath?.count ?? 0) }) {
                skill.sourceID = source.id
                skill.sourceKind = source.kind
            }
            return skill
        }
        if let expectedGeneration,
           expectedGeneration != recheckGeneration {
            return 0
        }
        // Observe unsettled content without adopting a partially committed operation's locations.
        if !phase1Tasks.contains(where: { $0.phase != .completed && $0.recoveryEvidence != nil }) {
            guard try await registerDiscoveredLocalSkills(newSkills, rootURL: rootURL, expected: expected) else { return 0 }
        }
        guard !Task.isCancelled, self.rootURL == rootURL, rootSessionLease?.id == sessionID,
              expectedGeneration.map({ $0 == recheckGeneration }) ?? true else { return 0 }
        let previous = availableSkills
        let localIDs = Set(localSourcesForInspection.map(\.id))
        availableSkills = (localOnly ? previous.filter { !localIDs.contains($0.sourceID) } : []) + discovery.availableSkills.map { candidate in
            var observed = candidate
            if let old = previous.first(where: { $0.sourceID == candidate.sourceID && $0.skillPath == candidate.skillPath }) {
                observed.id = old.id
                observed.candidateID = old.candidateID
                observed.generatedAtGeneration = old.generatedAtGeneration
            }
            return observed
        }
        observedLocalSourceNames = discovery.localSourceNames
        let validationByAsset = Dictionary(validated.map { ($0.assetID, $0.validation) }, uniquingKeysWith: { first, _ in first })
        var updatedSkills = installedSkills
        for index in updatedSkills.indices {
            if let validation = validationByAsset[updatedSkills[index].assetID] {
                updatedSkills[index].validation = validation
            }
            if let observed = discovery.installedSkills.first(where: {
                Self.standardizedInstalledPath(for: $0) == Self.standardizedInstalledPath(for: updatedSkills[index])
            }) {
                updatedSkills[index].name = observed.name
                updatedSkills[index].description = observed.description
                updatedSkills[index].validation = observed.validation
            }
        }
        installedSkills = updatedSkills
        await refreshRelationObservations(for: agentDetections)
        await waitForPresentationObservation()
        guard !Task.isCancelled, self.rootURL == rootURL, rootSessionLease?.id == sessionID,
              expectedGeneration.map({ $0 == recheckGeneration }) ?? true else { return 0 }
        // Commit list visibility only after a complete scan; failed enumeration retains it.
        missingCatalogItemIDs.formIntersection(Set(catalogItemsByID.keys))
        for (id, observation) in contentObservationSnapshot {
            if observation.nodeKind == .vacant { missingCatalogItemIDs.insert(id) }
            else if observation.nodeKind != .unreadable { missingCatalogItemIDs.remove(id) }
        }
        rebuildCatalogPresentation()
        return newSkills.count
    }

    @concurrent nonisolated private static func observeRootContent(
        rootURL: URL, observedAt: Date, fileManager: FileManager, sources: [SkillSource], localOnly: Bool
    ) async throws -> RootContentDiscovery {
        try Task.checkCancellation()
        return try RootContentDiscovery.observe(rootURL: rootURL, observedAt: observedAt,
            fileManager: fileManager, sources: sources, localOnly: localOnly)
    }

    /// Registers exact new locations and fills only uniquely verifiable associations
    /// through the single writer. Existing asset identity and relationship evidence stay
    /// intact; observations without registration changes perform no metadata write.
    @discardableResult
    func registerDiscoveredLocalSkills(
        _ discovered: [InstalledSkill],
        rootURL: URL,
        expected: RootSnapshot,
        sourceID: UUID? = nil
    ) async throws -> Bool {
        let sessionID = rootSessionLease?.id
        let snapshot = try await Self.registerDiscoveredSkills(discovered, rootURL: rootURL,
            expected: expected, sourceID: sourceID, metadataStore: metadataStore)
        guard !Task.isCancelled, self.rootURL == rootURL, rootSessionLease?.id == sessionID,
              rootSnapshot == expected else { return false }
        if snapshot != expected { applyDiscoverySnapshot(snapshot) }
        return true
    }

    @concurrent nonisolated private static func registerDiscoveredSkills(
        _ discovered: [InstalledSkill], rootURL: URL, expected: RootSnapshot,
        sourceID: UUID?, metadataStore: SkillsHubMetadataStore
    ) async throws -> RootSnapshot {
        func associations(in metadata: SkillsHubMetadata) -> [UUID: AvailableSkill] {
            var result: [UUID: AvailableSkill] = [:]
            for skill in metadata.installedSkills where skill.candidateID == nil && skill.sourceID != nil {
                if let sourceID, skill.sourceID != sourceID { continue }
                let source = metadata.sources.first { $0.id == skill.sourceID }
                let matches = metadata.availableSkills.filter {
                    SkillCatalogPresentationService.matchesLocation(skill, candidate: $0, source: source)
                }
                if matches.count == 1,
                   !metadata.installedSkills.contains(where: { $0.assetID != skill.assetID && $0.candidateID == matches[0].candidateID }) {
                    result[skill.assetID] = matches[0]
                }
            }
            return result
        }
        guard !discovered.isEmpty || !associations(in: expected.metadata).isEmpty else {
            return expected
        }
        return try await RootMutationOwner.shared.perform(at: rootURL) {
            try Task.checkCancellation()
            return try metadataStore.commit(at: rootURL, expected: expected) { metadata in
                let candidates = associations(in: metadata)
                for index in metadata.installedSkills.indices {
                    if let candidate = candidates[metadata.installedSkills[index].assetID] {
                        metadata.installedSkills[index].candidateID = candidate.candidateID
                        metadata.installedSkills[index].canonicalPathComponent = candidate.skillPath
                    }
                }
                var existingPaths = Set(metadata.installedSkills.map(Self.standardizedInstalledPath))
                for skill in discovered
                where existingPaths.insert(Self.standardizedInstalledPath(for: skill)).inserted {
                    metadata.installedSkills.append(skill)
                }
            }
        }
    }

    nonisolated private static func standardizedInstalledPath(for skill: InstalledSkill) -> String {
        URL(fileURLWithPath: skill.installedPath, isDirectory: true).standardizedFileURL.path
    }

    /// Applies a freshly committed snapshot after runtime local discovery. Mirrors the
    /// rootPath match and monotonic-generation guard of the Phase 1 snapshot apply so a
    /// stale or foreign snapshot is ignored, then re-validates the registered skills.
    private func applyDiscoverySnapshot(_ snapshot: RootSnapshot) {
        guard rootURL?.standardizedFileURL.path == snapshot.metadata.rootConfig.rootPath,
              rootSnapshot.map({ $0.generation <= snapshot.generation }) ?? true else { return }
        rootSnapshot = snapshot
        sources = snapshot.metadata.sources
        availableSkills = snapshot.metadata.availableSkills
        let validations = Dictionary(installedSkills.map { ($0.assetID, $0.validation) }, uniquingKeysWith: { first, _ in first })
        installedSkills = snapshot.metadata.installedSkills.map { skill in
            var skill = skill
            if let validation = validations[skill.assetID] { skill.validation = validation }
            return skill
        }
        agentLinks = []
        tags = snapshot.metadata.tags
        scannedSkillCount = installedSkills.count
        scanStatusMessage = LocalizedMessage("Scanned %d managed skill directories.", arguments: [String(installedSkills.count)])
    }

    func saveLocalState() throws {
        guard let rootURL else {
            throw SkillsHubLibraryFailure.missingRoot
        }
        try localStateStore.save(localState, to: rootURL)
    }

    func persistedUIState() -> [String: String] {
        ["cachePolicyName": cachePolicyName]
    }

    static func agentPathOverrides(
        from configurations: [AgentConfigurationRecord]
    ) -> [AgentKind: String] {
        return configurations.reduce(into: [:]) { result, configuration in
            guard let agent = configuration.agent, let path = configuration.skillsDirectory else { return }
            result[agent] = path
        }
    }

    private struct ReloadSnapshot {
        var availableSkills: [AvailableSkill]
        var installedSkills: [InstalledSkill]
        var sources: [SkillSource]
        var agentLinks: [AgentLinkRecord]
        var tags: [TagRecord]
        var statusMessage: LocalizedMessage?
        var errorMessage: LocalizedMessage?
        var scanStatusMessage: LocalizedMessage?
        var scannedSkillCount: Int
        var cachePolicyName: String
        var agentPathOverrides: [AgentKind: String]
        var localState: SkillsHubLocalState
        var agentDetections: [AgentDetectionSnapshot]
        var agentFindings: [AgentDirectoryFinding]
        var rootSnapshot: RootSnapshot?
        var phase1Tasks: [Phase1TaskRecord]
        var missingCatalogItemIDs: Set<String>
        var observedLocalSourceNames: Set<String>?

        init(controller: SkillsHubLibraryController) {
            availableSkills = controller.availableSkills
            installedSkills = controller.installedSkills
            sources = controller.sources
            agentLinks = controller.agentLinks
            tags = controller.tags
            statusMessage = controller.statusMessage
            errorMessage = controller.errorMessage
            scanStatusMessage = controller.scanStatusMessage
            scannedSkillCount = controller.scannedSkillCount
            cachePolicyName = controller.cachePolicyName
            agentPathOverrides = controller.agentPathOverrides
            localState = controller.localState
            agentDetections = controller.agentDetections
            agentFindings = controller.agentFindings
            rootSnapshot = controller.rootSnapshot
            phase1Tasks = controller.phase1Tasks
            missingCatalogItemIDs = controller.missingCatalogItemIDs
            observedLocalSourceNames = controller.observedLocalSourceNames
        }

        func restore(to controller: SkillsHubLibraryController) {
            controller.availableSkills = availableSkills
            controller.installedSkills = installedSkills
            controller.sources = sources
            controller.agentLinks = agentLinks
            controller.tags = tags
            controller.statusMessage = statusMessage
            controller.errorMessage = errorMessage
            controller.scanStatusMessage = scanStatusMessage
            controller.scannedSkillCount = scannedSkillCount
            controller.cachePolicyName = cachePolicyName
            controller.agentPathOverrides = agentPathOverrides
            controller.localState = localState
            controller.agentDetections = agentDetections
            controller.agentFindings = agentFindings
            controller.rootSnapshot = rootSnapshot
            controller.phase1Tasks = phase1Tasks
            controller.missingCatalogItemIDs = missingCatalogItemIDs
            controller.observedLocalSourceNames = observedLocalSourceNames
            controller.rebuildCatalogPresentation()
        }
    }

    private func isRootPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == EPERM || nsError.code == EACCES {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isRootPermissionError(underlying)
        }
        return false
    }

}
