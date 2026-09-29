import Foundation

extension SkillsHubLibraryController {
    var hasRoot: Bool {
        rootURL != nil
    }

    var rootPathDisplay: String {
        rootURL?.path ?? localization.localized("No root selected", language: language)
    }

    var settingsRootPathDisplay: String {
        rootURL?.path ?? suggestedRootURL.path
    }

    var suggestedRootURL: URL {
        rootURL ?? defaultRootURL
    }

    func bootstrapDefaultRootIfPresent() throws {
        guard rootURL == nil else {
            return
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: defaultRootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }
        guard let resolution = try startupAccessStore.resolveAccess(to: defaultRootURL) else {
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
            let result = try inspectRoot(
                defaultRootURL,
                inspectionLease: inspectionLease
            )
            if case .existingRoot(let facts) = result {
                try activateExistingRoot(
                    facts,
                    announceStatus: false,
                    resolvingPersistedBookmark: true
                )
            } else if case .initializationRequired(let facts) = result {
                try activateExistingRoot(facts, announceStatus: false, resolvingPersistedBookmark: true)
            }
        } catch {
            if isRootPermissionError(error) {
                return
            }
            throw error
        }
    }

    func connectExistingRoot(_ url: URL) throws {
        try ensureRootSwitchAllowed(to: url)
        let inspectionLease = try securityScopedAccessProvider.acquire(
            url: url.standardizedFileURL,
            owner: .inspection(UUID())
        )
        let result = try inspectRoot(url, inspectionLease: inspectionLease)
        let facts = try connectionFacts(result)
        try activateExistingRoot(facts, announceStatus: true, resolvingPersistedBookmark: false)
    }

    @discardableResult
    func inspectSelectedRoot(_ url: URL) throws -> RootInspectionResult {
        let normalizedURL = url.standardizedFileURL
        try ensureRootSwitchAllowed(to: normalizedURL)
        guard let inspectionLease = takeSelectedInspectionLease(to: normalizedURL) else {
            throw SkillsHubLibraryFailure.invalidSource("Root selection access is unavailable.")
        }
        return try inspectRoot(
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

    func connectSelectedRoot(_ url: URL) throws {
        let result = try inspectSelectedRoot(url)
        let facts = try connectionFacts(result)
        try activateExistingRoot(facts, announceStatus: true, resolvingPersistedBookmark: false)
    }

    @discardableResult
    func cancelRootSelection() -> RootInspectionResult {
        let result = RootInspectionResult.cancelled
        lastRootInspectionResult = result
        errorMessage = nil
        return result
    }

    private func inspectRoot(
        _ url: URL,
        inspectionLease: SecurityScopedAccessLease
    ) throws -> RootInspectionResult {
        let normalizedURL = url.standardizedFileURL
        let result = metadataStore.inspectRoot(at: normalizedURL)
        do {
            try endSecurityScopedAccessLease(inspectionLease)
        } catch {
            lastRootInspectionResult = .invalid(
                .invalidMetadata(path: normalizedURL.path, reason: String(describing: error))
            )
            throw error
        }
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
    ) throws {
        let normalizedURL = facts.url.standardizedFileURL
        let rebuildsMetadata = facts.snapshot == nil
            && fileManager.fileExists(atPath: metadataStore.rootLayout(for: normalizedURL).skillshubMetadataFile.path)
        let previousRootURL = rootURL
        let reusesCurrentSession = previousRootURL?.standardizedFileURL.path == normalizedURL.path
            && rootSessionLease != nil
        let nextRootLease: SecurityScopedAccessLease?
        if reusesCurrentSession {
            try endSelectedInspectionAccess(to: normalizedURL)
            nextRootLease = nil
        } else {
            nextRootLease = try acquireSecurityScopedAccess(
                to: normalizedURL,
                owner: .rootSession(UUID()),
                resolvingPersistedBookmark: resolvingPersistedBookmark
            )
        }

        do {
            if let inspectedSnapshot = facts.snapshot {
                let current = try metadataStore.loadCurrentSnapshot(from: normalizedURL)
                guard current.metadataDigest == inspectedSnapshot.metadataDigest else {
                    throw MetadataCommitError.staleDigest
                }
            }
            _ = try metadataStore.loadOrCreateSnapshot(from: normalizedURL)
            rootURL = normalizedURL
            try reloadFromDisk(preserveUnboundTasks: previousRootURL?.standardizedFileURL.path == normalizedURL.path)
        } catch {
            rootURL = previousRootURL
            if let nextRootLease {
                do {
                    try endSecurityScopedAccessLease(nextRootLease)
                } catch let releaseError {
                    throw releaseError
                }
            }
            throw error
        }
        if let nextRootLease {
            let previousLease = rootSessionLease
            rootSessionLease = nextRootLease
            if let previousLease {
                try endSecurityScopedAccessLease(previousLease)
            }
        }
        // Subscribe to filesystem events for the now-active Root, then run the initial
        // authorized-range scan. Any prior subscription (e.g. a switched-away Root) is
        // stopped inside subscribe().
        subscribeAndInitialScan()
        guard announceStatus || rebuildsMetadata else {
            return
        }
        setStatus(rebuildsMetadata ? "Management records were rebuilt." : "Root configured.")
        errorMessage = nil
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
    func subscribeAndInitialScan() {
        cancelPendingRechecks()
        guard let rootURL else {
            observation.stop()
            observationStatus = .notStarted
            return
        }
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
            try reloadFromDisk()
            enqueueScopedRecheck(scopes: nil, fullScan: true, reloadManagedRoot: false)
        } catch {
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

    private func enqueueScopedRecheck(
        scopes: Set<ObservationScope>?,
        fullScan: Bool,
        reloadManagedRoot: Bool
    ) {
        guard rootURL != nil else { return }
        invalidateSourceUpdatePreviews()
        recheckGeneration &+= 1
        pendingManagedRootReload = pendingManagedRootReload || reloadManagedRoot
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
            pendingFullRecheck = false
            pendingRecheckScopes.removeAll()
            pendingManagedRootReload = false
            let generation = recheckGeneration
            await runScopedRecheck(
                scopes: scopes,
                fullScan: fullScan,
                reloadManagedRoot: reloadManagedRoot,
                generation: generation
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
        generation: UInt64
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
            do {
                if reloadManagedRoot {
                    try reloadFromDisk()
                }
                try await runtimeLocalDiscovery(expectedGeneration: generation)
            } catch {
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
            refreshAgentLightScan()
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
        if let plan = pendingPhase1OperationPlan {
            throw SkillsHubLibraryFailure.invalidSource(
                "Operation \(plan.id.uuidString) is still waiting for action. Open Operation and Recovery before switching the Root."
            )
        }
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
        switch failure {
        case .missing(let path):
            return "The selected directory no longer exists: \(path)"
        case .notDirectory(let path):
            return "The selected object is not a directory: \(path)"
        case .symbolicLink(let path):
            return "A symbolic link cannot be used as the Management Directory: \(path)"
        case .unreadable(let path):
            return "The selected directory is not readable: \(path)"
        case .invalidMetadata(let path, let reason):
            return "The metadata at \(path) is damaged or unreadable: \(reason)"
        }
    }

    func reloadFromDisk(preserveUnboundTasks: Bool = true) throws {
        let snapshot = ReloadSnapshot(controller: self)
        do {
            try performReloadFromDisk(preserveUnboundTasks: preserveUnboundTasks)
        } catch {
            snapshot.restore(to: self)
            throw error
        }
    }

    private func performReloadFromDisk(preserveUnboundTasks: Bool) throws {
        guard let rootURL else {
            throw SkillsHubLibraryFailure.missingRoot
        }
        let snapshot = try metadataStore.loadOrCreateSnapshot(from: rootURL)
        rootSnapshot = snapshot
        let metadata = snapshot.metadata
        availableSkills = metadata.availableSkills
        sources = metadata.sources
        installedSkills = metadata.installedSkills
        tags = metadata.tags
        cachePolicyName = metadata.uiState["cachePolicyName"] ?? "Default"
        localState = try localStateStore.load(from: rootURL)
        agentPathOverrides = Self.agentPathOverrides(from: metadata.agents)
        agentLinks = []
        refreshManualSkills()
        refreshAgentLightScan()
        let retainedTasks = phase1Tasks.filter {
            $0.operationPlan?.rootPath == rootURL.standardizedFileURL.path
                || (preserveUnboundTasks && $0.operationPlan == nil)
        }
        phase1Tasks = try Phase1OperationJournal(rootURL: rootURL, fileManager: fileManager).recoverTasks()
        for var task in retainedTasks {
            if task.phase == .waitingConfirmation,
               let plan = task.operationPlan,
               plan.expectedGeneration != rootSnapshot?.generation {
                task.phase = .needsAttention
                task.result = "Current facts changed; prepare a new plan."
                if pendingPhase1OperationPlan?.id == task.id { pendingPhase1OperationPlan = nil }
            }
            if !phase1Tasks.contains(where: { $0.id == task.id })
                || [.preparing, .executing, .observing, .verifying].contains(task.phase) {
                upsertTask(task)
            }
        }
        mergeRecoveredOperationTasks(rootURL: rootURL)
    }

    func refreshManualSkills() {
        guard let rootURL, rootSnapshot != nil else {
            return
        }
        let validator = SkillValidator(fileManager: fileManager)
        for index in installedSkills.indices {
            let installedURL = URL(fileURLWithPath: installedSkills[index].installedPath, isDirectory: true)
            installedSkills[index].validation = validator.validate(
                skillDirectory: installedURL,
                rootDirectory: rootURL,
                sourceMetadataPresent: installedSkills[index].sourceID != nil
            )
        }
        scannedSkillCount = installedSkills.count
        scanStatusMessage = LocalizedMessage("Scanned %d managed skill directories.", arguments: [String(installedSkills.count)])
        errorMessage = nil
    }

    /// Re-enumerates current Root content directories at runtime and registers only the
    /// candidates that are not already recorded, keyed by standardized `installedPath`.
    ///
    /// The path key deduplicates against every existing registration — including
    /// source-owned `localDirectory` skills that live under `local/<folder>/` — so an
    /// imported source is never re-registered as `manualFilesystem`. Deleted or moved
    /// directories are intentionally left untouched here: their persistent registration
    /// and missing records are preserved (Q-002/REQ-018); `refreshManualSkills()` marks
    /// them `.invalid` instead of pruning.
    @discardableResult
    func runtimeLocalDiscovery(
        observedAt: Date = Date(),
        expectedGeneration: UInt64? = nil
    ) async throws -> Int {
        guard let rootURL, let expected = rootSnapshot else {
            return 0
        }
        let discovery = try RootContentDiscovery.observe(
            rootURL: rootURL,
            observedAt: observedAt,
            fileManager: fileManager
        )
        let registeredPaths = installedSkills.map(Self.standardizedInstalledPath)
        let newSkills = discovery.installedSkills.filter { candidate in
            !Self.isPath(Self.standardizedInstalledPath(for: candidate), coveredByAnyOf: registeredPaths)
        }
        guard newSkills.isEmpty == false else {
            return 0
        }
        if let expectedGeneration,
           expectedGeneration != recheckGeneration {
            return 0
        }
        try await registerDiscoveredLocalSkills(newSkills, rootURL: rootURL, expected: expected)
        return newSkills.count
    }

    /// Appends newly discovered manual-filesystem skills through the single-writer CAS
    /// commit (already inside `RootMutationOwner`). It never enables an Agent, never
    /// touches existing `installedSkills`, and re-checks the path key inside the mutation
    /// so a concurrent registration cannot create a duplicate. Empty input performs no
    /// write, keeping pure observation from advancing the authoritative JSON.
    private func registerDiscoveredLocalSkills(
        _ discovered: [InstalledSkill],
        rootURL: URL,
        expected: RootSnapshot
    ) async throws {
        guard discovered.isEmpty == false else {
            return
        }
        let metadataStore = metadataStore
        let snapshot = try await RootMutationOwner.shared.perform(at: rootURL) {
            try Task.checkCancellation()
            return try metadataStore.commit(at: rootURL, expected: expected) { metadata in
                let existingPaths = metadata.installedSkills.map(Self.standardizedInstalledPath)
                for skill in discovered
                where !Self.isPath(Self.standardizedInstalledPath(for: skill), coveredByAnyOf: existingPaths) {
                    metadata.installedSkills.append(skill)
                }
            }
        }
        applyDiscoverySnapshot(snapshot)
    }

    private static func standardizedInstalledPath(for skill: InstalledSkill) -> String {
        URL(fileURLWithPath: skill.installedPath, isDirectory: true).standardizedFileURL.path
    }

    /// A candidate is already covered when its path equals, or is nested under, any
    /// registered `installedPath`. Nesting matters because an already-registered
    /// bundle directory owns its child skill directories; re-discovering them as
    /// separate manual-filesystem skills would duplicate a registered bundle.
    private static func isPath(_ candidate: String, coveredByAnyOf registered: [String]) -> Bool {
        registered.contains { existing in
            candidate == existing || candidate.hasPrefix(existing.hasSuffix("/") ? existing : existing + "/")
        }
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
        installedSkills = snapshot.metadata.installedSkills
        agentLinks = []
        tags = snapshot.metadata.tags
        refreshManualSkills()
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

    func ensuredAppContainerLayout() throws -> AppContainerLayout {
        try metadataStore.ensureAppContainerLayout(at: appSupportURL)
        return metadataStore.appContainerLayout(for: appSupportURL)
    }

    private func preferredInstalledSkillOrder(lhs: InstalledSkill, rhs: InstalledSkill) -> Bool {
        return lhs.installedPath.localizedCaseInsensitiveCompare(rhs.installedPath) == .orderedAscending
    }

    private func topLevelDiscoveredSkills(_ skills: [InstalledSkill]) -> [InstalledSkill] {
        let paths = skills.map { URL(fileURLWithPath: $0.installedPath, isDirectory: true).standardizedFileURL.path }
        return skills.filter { skill in
            let candidatePath = URL(fileURLWithPath: skill.installedPath, isDirectory: true).standardizedFileURL.path
            return !paths.contains { parentPath in
                candidatePath != parentPath && candidatePath.hasPrefix(parentPath + "/")
            }
        }
    }

    private func shouldReplaceInstalledSkill(_ current: InstalledSkill, with candidate: InstalledSkill) -> Bool {
        if current.installedPath == candidate.installedPath {
            return true
        }
        return current.sourceKind == .manualFilesystem && candidate.sourceKind == .localDirectory
    }

    private func pruneMissingLocalSkills(discovered: [InstalledSkill]) {
        let discoveredIDs = Set(discovered.map(\.id))
        installedSkills.removeAll { skill in
            isRefreshManagedLocalSkill(skill) && !discoveredIDs.contains(skill.id)
        }
    }

    private func isRefreshManagedLocalSkill(_ skill: InstalledSkill) -> Bool {
        skill.sourceKind == .manualFilesystem || skill.sourceKind == .localDirectory
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
        var pendingPhase1OperationPlan: Phase1OperationPlan?
        var phase1Tasks: [Phase1TaskRecord]

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
            pendingPhase1OperationPlan = controller.pendingPhase1OperationPlan
            phase1Tasks = controller.phase1Tasks
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
            controller.pendingPhase1OperationPlan = pendingPhase1OperationPlan
            controller.phase1Tasks = phase1Tasks
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
