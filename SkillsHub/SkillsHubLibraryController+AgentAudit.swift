import Darwin
import Foundation

extension SkillsHubLibraryController {
    func refreshAgentLightScan(checkInstallation: Bool = false) async {
        guard let rootURL, !Task.isCancelled else { return }
        // ponytail: serialize scans sharing one generation; use per-Agent generations if parallel scans are needed.
        let sessionID = rootSessionLease?.id
        let id = UUID()
        let pendingLightScan = agentLightScanTask?.task
        let pendingAudits = Array(agentDirectoryAuditTasks.values)
        let task = Task {
            await pendingLightScan?.value
            for job in pendingAudits { _ = await job.task.result }
            guard !Task.isCancelled, self.rootURL == rootURL, rootSessionLease?.id == sessionID else { return }
            await performAgentLightScan(checkInstallation: checkInstallation)
        }
        agentLightScanTask = (id, task)
        defer { if agentLightScanTask?.id == id { agentLightScanTask = nil } }
        await task.value
    }

    private func performAgentLightScan(checkInstallation: Bool) async {
        guard let rootURL else { return }
        let sessionID = rootSessionLease?.id
        agentObservationGeneration &+= 1
        let generation = agentObservationGeneration
        let snapshot = rootSnapshot
        let auditState = agentAuditLocalState
        let overrides = agentPathOverrides
        var leases: [SecurityScopedAccessLease] = []
        do {
            if let rootLease = rootSessionLease {
                leases.append(try securityScopedAccessProvider.acquire(url: rootLease.url, owner: .inspection(UUID())))
            }
        } catch { handle(error); return }
        defer { leases.forEach { _ = $0.end(by: $0.owner) } }
        let directories = agentAuditService.agentDescriptors(
            homeDirectory: agentHomeDirectory, overrides: agentPathOverrides,
            customAgents: agentAuditLocalState.customAgents
        ).map(\.skillsDirectory)
        let authorizations = (try? await startupAccessStore.resolvePresentationAccess(to: directories)) ?? [:]
        guard !Task.isCancelled, self.rootURL == rootURL, rootSessionLease?.id == sessionID,
              rootSnapshot == snapshot, generation == agentObservationGeneration else { return }
        for directory in Set(directories.map(\.standardizedFileURL)) {
            guard let authorization = authorizations[directory.path],
                  !authorization.isStale,
                  authorization.url.standardizedFileURL == directory,
                  let lease = try? securityScopedAccessProvider.acquire(
                      url: authorization.url, owner: .inspection(UUID())
                  ) else { continue }
            leases.append(lease)
        }
        let read = await Self.scanAgents(service: agentAuditService,
            rootURL: rootURL,
            homeDirectory: agentHomeDirectory,
            overrides: agentPathOverrides,
            localState: auditState,
            checkInstallation: checkInstallation, environment: agentEnvironment, fileManager: fileManager
        )
        guard !Task.isCancelled, self.rootURL == rootURL, rootSessionLease?.id == sessionID,
              rootSnapshot == snapshot, agentPathOverrides == overrides,
              generation == agentObservationGeneration else { return }
        let result = read.audit
        agentPathSettingsSnapshot = read.paths
        agentDetections = result.detections
        let retainedFindings = agentFindings.filter { finding in
            guard [.localDirectoryNotManaged, .externalSymlinkNotManaged, .brokenSymlink,
                   .duplicateWithHub, .aliasConflict, .rootMovedRepairAvailable, .invalidEntry].contains(finding.type),
                  let detection = result.detections.first(where: { $0.agentID == finding.agentID }),
                  detection.skillsDirectoryExists, detection.readable, detection.writable,
                  let snapshot = localState.agentAuditSnapshots.first(where: {
                      $0.agentID == finding.agentID && $0.skillsDirectory == detection.skillsDirectory
                  }),
                  snapshot.entryCount == detection.entryCount,
                  !result.findings.contains(where: {
                      $0.agentID == finding.agentID && $0.type == .pendingAudit
                  }) else { return false }
            return true
        }
        agentFindings = result.findings + retainedFindings
        for agent in [AgentKind.codex, .claudeCode] where defaultAgentDirectoryRefresh[agent] == .manageable {
            let detection = result.detections.first { $0.agentID == agent.rawValue }
            let snapshot = localState.agentAuditSnapshots.first {
                $0.agentID == agent.rawValue && $0.skillsDirectory == detection?.skillsDirectory
            }
            if detection?.skillsDirectoryExists != true || detection?.readable != true || detection?.writable != true
                || snapshot?.entryCount != detection?.entryCount
                || result.findings.contains(where: { $0.agentID == agent.rawValue && $0.type == .pendingAudit }) {
                defaultAgentDirectoryRefresh[agent] = .unverifiable
            }
        }
        localState.detectedAgentsSnapshot = result.detections
        localState.lastAgentLightScanAt = Date()
        await refreshRelationObservations(for: result.detections)
        await waitForPresentationObservation()
    }

    @concurrent nonisolated private static func scanAgents(
        service: AgentDirectoryAuditService, rootURL: URL, homeDirectory: URL,
        overrides: [AgentKind: String], localState: SkillsHubLocalState, checkInstallation: Bool,
        environment: [String: String], fileManager: FileManager
    ) async -> (audit: AgentDirectoryAuditResult, paths: [AgentPathSettingRecord]) {
        let audit = service.lightScan(rootURL: rootURL, homeDirectory: homeDirectory,
            overrides: overrides, localState: localState, checkInstallation: checkInstallation)
        let paths = await inspectAgentPathSettings(detections: audit.detections, home: homeDirectory, environment: environment, overrides: overrides, fileManager: fileManager)
        return (audit, paths)
    }

    @concurrent nonisolated private static func inspectAgentDirectory(
        service: AgentDirectoryAuditService, target: URL, agentID: String, rootURL: URL,
        homeDirectory: URL, overrides: [AgentKind: String],
        localState: SkillsHubLocalState, installedSkills: [InstalledSkill], fileManager: FileManager
    ) async throws -> AgentDirectoryAuditResult {
        try Task.checkCancellation()
        let identity = try LinkNodeIdentity.read(at: target)
        var directory: ObjCBool = false
        guard !FileAccessService(fileManager: fileManager).isSymlink(target),
              fileManager.fileExists(atPath: target.path, isDirectory: &directory), directory.boolValue,
              try LinkNodeIdentity.read(at: target) == identity else {
            throw AgentTargetAccessError.qualificationFailed(.permissionRequired)
        }
        let result = try service.fullAudit(agentID: agentID, rootURL: rootURL,
            homeDirectory: homeDirectory, overrides: overrides,
            localState: localState, installedSkills: installedSkills)
        guard try LinkNodeIdentity.read(at: target) == identity else {
            throw AgentTargetAccessError.qualificationFailed(.permissionRequired)
        }
        return result
    }

    func auditAgentDirectory(agentID: String) async throws {
        if let job = agentDirectoryAuditTasks[agentID] { return try await job.task.value }
        let id = UUID()
        let root = rootURL
        let session = rootSessionLease?.id
        let pendingLightScan = agentLightScanTask?.task
        let pendingAudits = Array(agentDirectoryAuditTasks.values)
        let task = Task {
            await pendingLightScan?.value
            for job in pendingAudits { _ = await job.task.result }
            try Task.checkCancellation()
            guard rootURL == root, rootSessionLease?.id == session else { throw CancellationError() }
            try await runAgentDirectoryAudit(agentID: agentID)
        }
        agentDirectoryAuditTasks[agentID] = (id, task)
        auditingAgentIDs.insert(agentID)
        defer {
            if agentDirectoryAuditTasks[agentID]?.id == id {
                agentDirectoryAuditTasks.removeValue(forKey: agentID)
                auditingAgentIDs.remove(agentID)
            }
        }
        try await task.value
    }

    private func runAgentDirectoryAudit(agentID: String) async throws {
        do {
            try await performAgentDirectoryAudit(agentID: agentID)
            agentDirectoryAuditFailures.removeValue(forKey: agentID)
        } catch {
            if error is CancellationError { throw error }
            if case let AgentTargetAccessError.qualificationFailed(reason) = error {
                agentDirectoryAuditFailures[agentID] = LocalizedMessage(agentQualificationFailureDescription(reason))
                if [.permissionRequired, .bookmarkStale, .authorizationTargetMismatch].contains(reason) {
                    agentDirectoryAccessFailures[agentID] = .authorizationRequired
                } else {
                    agentDirectoryAccessFailures.removeValue(forKey: agentID)
                }
            } else {
                agentDirectoryAuditFailures[agentID] = errorPresentation(for: error)
                if case AgentTargetAccessError.leaseUnavailable = error {
                    agentDirectoryAccessFailures[agentID] = .accessFailed(errorPresentation(for: error))
                }
            }
            if let agent = AgentKind(rawValue: agentID), defaultAgentDirectoryRefresh[agent] != nil {
                defaultAgentDirectoryRefresh[agent] = .unverifiable
            }
            throw error
        }
    }

    private func performAgentDirectoryAudit(agentID: String) async throws {
        guard let rootURL else {
            throw SkillsHubLibraryFailure.missingRoot
        }
        guard let descriptor = visibleInstalledAgentDescriptors.first(where: { $0.id == agentID }),
              let path = descriptor.skillsDirectory else {
            throw ControllerRelationActionError.unsupportedAgent(agentID)
        }
        let target = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let targetAccess = try acquireAgentTargetAccess(agentID: agentID, actionID: UUID())
        defer { _ = targetAccess.endByOwningAction() }
        guard targetAccess.qualification.target?.standardizedFileURL == target else {
            throw AgentTargetAccessError.qualificationFailed(.permissionRequired)
        }
        agentObservationGeneration &+= 1
        let generation = agentObservationGeneration
        let sessionID = rootSessionLease?.id
        let snapshot = rootSnapshot
        let inputSkills = installedSkills
        let inputOverrides = agentPathOverrides
        let rootLease = try rootSessionLease.map {
            try securityScopedAccessProvider.acquire(url: $0.url, owner: .inspection(UUID()))
        }
        defer { if let rootLease { _ = rootLease.end(by: rootLease.owner) } }
        let result = try await Self.inspectAgentDirectory(service: agentAuditService,
            target: target, agentID: agentID, rootURL: rootURL,
            homeDirectory: agentHomeDirectory, overrides: inputOverrides,
            localState: agentAuditLocalState, installedSkills: inputSkills, fileManager: fileManager)
        guard !Task.isCancelled, self.rootURL == rootURL, rootSessionLease?.id == sessionID,
              rootSnapshot == snapshot, installedSkills == inputSkills, agentPathOverrides == inputOverrides,
              generation == agentObservationGeneration else { throw CancellationError() }
        agentDirectoryAccessFailures.removeValue(forKey: agentID)
        agentDirectoryAuditFailures.removeValue(forKey: agentID)
        await mergeAgentAuditResult(result, agentID: agentID)
        await waitForPresentationObservation()
        guard !Task.isCancelled, self.rootURL == rootURL, rootSessionLease?.id == sessionID,
              rootSnapshot == snapshot, generation == agentObservationGeneration else { throw CancellationError() }
        let unverifiable = localState.verificationRecords.filter {
            $0.relation.agentID == agentID && $0.conclusion == .currentlyUnverifiable
        }.count
        if let failure = agentDirectoryAccessFailures[agentID] {
            errorMessage = failure.message
        } else if unverifiable > 0 {
            setStatus("Checked %@: %@ relationships could not be verified.", agentDisplayName(for: agentID), String(unverifiable))
            errorMessage = nil
        } else {
            setStatus("Audited %@.", agentDisplayName(for: agentID))
            errorMessage = nil
        }
        try saveLocalState()
    }

    func auditAllDetectedAgentDirectories() async throws {
        guard hasRoot else { throw SkillsHubLibraryFailure.missingRoot }
        var checkedIDs = Set<String>()
        for descriptor in visibleInstalledAgentDescriptors where agentDetections.contains(where: { $0.agentID == descriptor.id && $0.detected }) {
            try await auditAgentDirectory(agentID: descriptor.id)
            checkedIDs.insert(descriptor.id)
        }
        let unverifiable = localState.verificationRecords.filter {
            checkedIDs.contains($0.relation.agentID) && $0.conclusion == .currentlyUnverifiable
        }.count
        if let failure = checkedIDs.compactMap({ agentDirectoryFailure($0) }).first {
            errorMessage = failure
        } else if unverifiable > 0 {
            setStatus("Checked Agent directories: %@ relationships could not be verified.", String(unverifiable))
        } else {
            setStatus("Audited detected agent directories.")
        }
    }

    func prepareBrokenLinkDeletion(findingID: String) throws -> BrokenLinkDeletionPlan {
        guard let finding = agentFindings.first(where: { $0.id == findingID }),
              finding.type == .brokenSymlink,
              finding.entryKind == .brokenSymlink,
              let linkPath = finding.linkPath,
              let rawTarget = finding.symlinkTarget,
              let resolvedTarget = finding.targetPath else {
            throw BrokenLinkDeletionError.confirmedFactsChanged
        }
        return try prepareBrokenLinkDeletion(agentID: finding.agentID, linkPath: linkPath,
            rawTarget: rawTarget, resolvedTarget: resolvedTarget)
    }

    func prepareBrokenLinkDeletion(relation: AgentRelationIdentity) throws -> BrokenLinkDeletionPlan {
        guard let observation = localState.targetObservations.first(where: { $0.relation == relation }),
              observation.nodeKind == .brokenSymbolicLink,
              let rawTarget = observation.linkText, let resolvedTarget = observation.resolvedTargetPath else {
            throw BrokenLinkDeletionError.confirmedFactsChanged
        }
        let plan = try prepareBrokenLinkDeletion(agentID: relation.agentID, linkPath: observation.linkPath,
            rawTarget: rawTarget, resolvedTarget: resolvedTarget)
        guard plan.facts.nodeIdentity == observation.nodeIdentity,
              plan.facts.parentIdentity == observation.parentIdentity else {
            throw BrokenLinkDeletionError.confirmedFactsChanged
        }
        return plan
    }

    private func prepareBrokenLinkDeletion(agentID: String, linkPath: String, rawTarget: String,
                                          resolvedTarget: String) throws -> BrokenLinkDeletionPlan {
        guard let rootURL, let rootSessionOwner = rootSessionLease?.owner else {
            throw BrokenLinkDeletionError.invalidRootSession
        }
        let actionID = UUID()
        let targetAccess = try acquireAgentTargetAccess(agentID: agentID, actionID: actionID)
        defer { _ = targetAccess.endByOwningAction() }
        let plan = try relationActionRuntime.prepareBrokenLinkDeletionPlan(
            actionID: actionID,
            rootURL: rootURL,
            rootSessionOwner: rootSessionOwner,
            agentID: agentID,
            agentDisplayName: agentDisplayName(for: agentID),
            targetAccess: targetAccess,
            linkURL: URL(fileURLWithPath: linkPath)
        )
        guard plan.facts.rawTarget == rawTarget,
              plan.facts.resolvedTargetPath == URL(fileURLWithPath: resolvedTarget).standardizedFileURL.path else {
            throw BrokenLinkDeletionError.confirmedFactsChanged
        }
        return plan
    }

    func deleteBrokenLink(
        using confirmedPlan: BrokenLinkDeletionPlan
    ) async throws -> RelationActionCoordinationResult<BrokenLinkDeletionExecutionResult> {
        guard let rootURL,
              let rootSessionOwner = rootSessionLease?.owner else {
            throw BrokenLinkDeletionError.invalidRootSession
        }
        let actionKey = "broken-link:\(confirmedPlan.facts.linkPath)"
        guard inFlightRelationActionIDs.insert(actionKey).inserted else {
            throw BrokenLinkDeletionError.confirmedFactsChanged
        }
        defer { inFlightRelationActionIDs.remove(actionKey) }

        let targetAccess = try acquireAgentTargetAccess(
            agentID: confirmedPlan.facts.agentID,
            actionID: confirmedPlan.actionID
        )
        let token: BrokenLinkDeletionToken
        do {
            token = try relationActionRuntime.brokenLinkDeletionToken(
                confirmedPlan: confirmedPlan,
                targetAccess: targetAccess
            )
        } catch {
            _ = targetAccess.endByOwningAction()
            throw error
        }
        let runtime = relationActionRuntime
        let coordination = await relationActionCoordinator.coordinate(
            token: token,
            rootURL: rootURL,
            targetAccess: targetAccess,
            currentFacts: {
                try runtime.currentBrokenLinkDeletionFacts(
                    rootURL: rootURL,
                    rootSessionOwner: rootSessionOwner,
                    agentID: confirmedPlan.facts.agentID,
                    agentDisplayName: confirmedPlan.facts.agentDisplayName,
                    targetAccess: targetAccess,
                    linkURL: URL(fileURLWithPath: confirmedPlan.facts.linkPath)
                )
            },
            perform: { authorization in
                runtime.executeBrokenLinkDeletion(authorization: authorization, rootURL: rootURL)
            }
        )
        try? await auditAgentDirectory(agentID: confirmedPlan.facts.agentID)
        switch coordination.outcome {
        case .completed(let result) where result.status == .succeeded:
            setStatus("Deleted broken link node for %@.", confirmedPlan.facts.agentDisplayName)
            errorMessage = nil
        case .completed(let result):
            errorMessage = result.failureMessage ?? "The broken link deletion did not complete. Recheck the Agent directory."
            if let retainedPath = result.retainedPath {
                errorMessage = LocalizedMessage("Link deletion needs recovery at %@.", arguments: [retainedPath])
            }
        case .stale:
            errorMessage = "The link changed after confirmation. Nothing was deleted."
        default:
            errorMessage = coordination.failureMessage ?? "The broken link deletion did not complete. Recheck the Agent directory."
        }
        return coordination
    }

    private func mergeAgentAuditResult(_ result: AgentDirectoryAuditResult, agentID: String? = nil) async {
        let root = rootSnapshot
        let session = rootSessionLease?.id
        let generation = agentObservationGeneration
        await refreshRelationObservations(for: result.detections)
        guard !Task.isCancelled, rootSnapshot == root, rootSessionLease?.id == session,
              agentObservationGeneration == generation else { return }
        // Keep other Agents in their existing order during a scoped audit.
        let replacements = Dictionary(result.detections.map { ($0.agentID, $0) }, uniquingKeysWith: { first, _ in first })
        agentDetections = agentID == nil ? result.detections
            : agentDetections.map { replacements[$0.agentID] ?? $0 }
                + result.detections.filter { candidate in !agentDetections.contains { $0.agentID == candidate.agentID } }
        agentFindings = agentFindings.filter { agentID != nil && $0.agentID != agentID }
            + result.findings.filter { agentID == nil || $0.agentID == agentID }
        localState.detectedAgentsSnapshot = agentDetections
        localState.agentAuditSnapshots = result.auditSnapshots
    }

    func refreshRelationObservations(for detections: [AgentDetectionSnapshot], assetIDs: Set<UUID>? = nil) async {
        let root = rootURL
        let sessionID = rootSessionLease?.id
        let expected = rootSnapshot
        let generation = agentObservationGeneration
        let previousState = localState
        var updates: [(observation: TargetObservation, verification: VerificationRecord?)] = []
        var capabilities: [String: AgentCapabilityPresentation] = [:]
        var directoryAccess: [String: Result<SecurityScopedAccessLease, Error>] = [:]
        defer {
            for case .success(let lease) in directoryAccess.values {
                do { try endSecurityScopedAccessLease(lease) } catch { handle(error) }
            }
        }
        let targetURLs = installedAgentDescriptors.compactMap { $0.skillsDirectory.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL } }
        let authorizations: [String: StartupAccessBookmarkResolution]
        let authorizationError: Error?
        do {
            authorizations = try await startupAccessStore.resolvePresentationAccess(to: targetURLs)
            authorizationError = nil
        } catch {
            authorizations = [:]
            authorizationError = error
        }
        guard !Task.isCancelled, rootURL == root, rootSessionLease?.id == sessionID,
              rootSnapshot == expected, generation == agentObservationGeneration else { return }
        for previous in previousState.targetObservations where assetIDs?.contains(previous.relation.assetID) ?? true {
            let relation = previous.relation
            guard relation.scope == .global,
                  detections.contains(where: { $0.agentID == relation.agentID }),
                  let descriptor = installedAgentDescriptors.first(where: { $0.id == relation.agentID }),
                  let targetPath = descriptor.skillsDirectory,
                  let skill = rootSnapshot?.metadata.installedSkills.first(where: { $0.assetID == relation.assetID })
            else { continue }

            let target = URL(fileURLWithPath: targetPath, isDirectory: true).standardizedFileURL
            if directoryAccess[target.path] == nil {
                directoryAccess[target.path] = Result {
                    var node = stat()
                    if lstat(target.path, &node) == -1, errno == ENOENT || errno == ENOTDIR {
                        throw AgentTargetAccessError.qualificationFailed(.targetMissing)
                    }
                    if let authorizationError { throw authorizationError }
                    guard let authorization = authorizations[target.path], !authorization.isStale,
                          authorization.url.standardizedFileURL == target else {
                        throw AgentTargetAccessError.qualificationFailed(.permissionRequired)
                    }
                    return try securityScopedAccessProvider.acquire(url: authorization.url, owner: .inspection(UUID()))
                }
            }
            do {
                _ = try directoryAccess[target.path]!.get()
                agentDirectoryAccessFailures.removeValue(forKey: relation.agentID)
            } catch {
                if case AgentTargetAccessError.qualificationFailed(.targetMissing) = error {
                    agentDirectoryAccessFailures.removeValue(forKey: relation.agentID)
                    agentDirectoryAuditFailures[relation.agentID] = errorPresentation(for: error)
                } else if case AgentTargetAccessError.qualificationFailed(.permissionRequired) = error {
                    agentDirectoryAccessFailures[relation.agentID] = .authorizationRequired
                } else {
                    agentDirectoryAccessFailures[relation.agentID] = .accessFailed(errorPresentation(for: error))
                }
                // Keep the last observation and its timestamp; it is no longer current evidence.
                continue
            }
            let observation: TargetObservation
            do {
                let linkURL = try relationActionRuntime.linkURL(
                    linkName: relationLinkName(asset: skill),
                    targetDirectory: target
                )
                let inspection = await Self.inspectRelationNode(linkURL: linkURL, relation: relation,
                    canonicalTargetPath: skill.installedPath)
                guard !Task.isCancelled, rootURL == root, rootSessionLease?.id == sessionID,
                      rootSnapshot == expected, generation == agentObservationGeneration else { return }
                observation = try inspection.get()
            } catch {
                observation = TargetObservation(
                    relation: relation, linkPath: previous.linkPath, nodeKind: .unreadable,
                    linkText: nil, resolvedTargetPath: nil, fileIdentity: nil,
                    isReadable: false, isWritable: false, observedAt: Date(),
                    limitation: error.localizedDescription
                )
            }

            let capability: AgentCapabilityPresentation
            do {
                if let cached = capabilities[descriptor.id] { capability = cached }
                else {
                    capability = try await inspectAgentCapabilityPresentation(descriptor)
                    capabilities[descriptor.id] = capability
                }
            } catch {
                updates.append((observation, nil))
                continue
            }
            guard !Task.isCancelled, rootURL == root, rootSessionLease?.id == sessionID,
                  rootSnapshot == expected, generation == agentObservationGeneration else { return }
            let intent = rootSnapshot?.metadata.enablementIntents.first { $0.id == relation.id }
            let input = currentRelationVerificationInput(
                relation: relation, skill: skill, intent: intent, observation: observation,
                capability: capability
            )
            updates.append((observation, input.map(RelationVerifier.verify)))
        }
        guard !Task.isCancelled, rootURL == root, rootSessionLease?.id == sessionID,
              rootSnapshot == expected, generation == agentObservationGeneration else { return }
        // Merge into the latest state; an intervening relation action owns its newer result.
        var next = localState
        for update in updates {
            let relation = update.observation.relation
            guard next.targetObservations.first(where: { $0.relation == relation })
                    == previousState.targetObservations.first(where: { $0.relation == relation }),
                  next.verificationRecords.first(where: { $0.relation == relation })
                    == previousState.verificationRecords.first(where: { $0.relation == relation }) else { continue }
            next.targetObservations.removeAll { $0.relation == relation }
            next.targetObservations.append(update.observation)
            next.verificationRecords.removeAll { $0.relation == relation }
            if let verification = update.verification { next.verificationRecords.append(verification) }
            if let skill = installedSkills.first(where: { $0.assetID == relation.assetID }),
               let target = capabilities[relation.agentID]?.targetPath {
                relationOwnershipSnapshot[relation.id] = RelationOwnershipInspector.classify(
                    observation: update.observation,
                    expectedLinkPath: URL(fileURLWithPath: target).appendingPathComponent(relationLinkName(asset: skill)).path,
                    canonicalTargetPath: skill.installedPath)
            } else { relationOwnershipSnapshot.removeValue(forKey: relation.id) }
        }
        agentCapabilitySnapshot.merge(capabilities, uniquingKeysWith: { _, current in current })
        localState = next
    }

    @concurrent nonisolated private static func inspectRelationNode(
        linkURL: URL, relation: AgentRelationIdentity, canonicalTargetPath: String) async -> Result<TargetObservation, Error> {
        Result {
            try Task.checkCancellation()
            return try RelationOwnershipInspector().inspect(linkURL: linkURL, relation: relation,
                canonicalTargetPath: canonicalTargetPath).observation
        }
    }

    private func agentDisplayName(for agentID: String) -> String {
        agentConfigurations.first(where: { $0.id == agentID })?.displayName
            ?? agentDetections.first(where: { $0.agentID == agentID })?.displayName
            ?? AgentKind(rawValue: agentID)?.displayName
            ?? agentID
    }

}
