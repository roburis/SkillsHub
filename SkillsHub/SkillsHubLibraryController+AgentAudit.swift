import Foundation

extension SkillsHubLibraryController {
    func refreshAgentLightScan(checkInstallation: Bool = false) {
        guard let rootURL else {
            return
        }
        let result = agentAuditService.lightScan(
            rootURL: rootURL,
            homeDirectory: agentHomeDirectory,
            overrides: agentPathOverrides,
            localState: agentAuditLocalState,
            checkInstallation: checkInstallation
        )
        agentDetections = result.detections
        agentFindings = result.findings
        localState.detectedAgentsSnapshot = result.detections
        localState.lastAgentLightScanAt = Date()
        refreshRelationObservations(for: result.detections)
    }

    func auditAgentDirectory(agentID: String) throws {
        guard let rootURL else {
            throw SkillsHubLibraryFailure.missingRoot
        }
        let result = agentAuditService.fullAudit(
            agentID: agentID,
            rootURL: rootURL,
            homeDirectory: agentHomeDirectory,
            overrides: agentPathOverrides,
            localState: agentAuditLocalState,
            installedSkills: installedSkills
        )
        mergeAgentAuditResult(result, agentID: agentID)
        setStatus("Audited %@.", agentDisplayName(for: agentID))
        errorMessage = nil
        try saveLocalState()
    }

    func auditAllDetectedAgentDirectories() throws {
        guard let rootURL else {
            throw SkillsHubLibraryFailure.missingRoot
        }
        let result = agentAuditService.fullAudit(
            agentID: nil,
            rootURL: rootURL,
            homeDirectory: agentHomeDirectory,
            overrides: agentPathOverrides,
            localState: agentAuditLocalState,
            installedSkills: installedSkills
        )
        mergeAgentAuditResult(result)
        setStatus("Audited detected agent directories.")
        errorMessage = nil
        try saveLocalState()
    }

    func prepareBrokenLinkDeletion(findingID: String) throws -> BrokenLinkDeletionPlan {
        guard let finding = agentFindings.first(where: { $0.id == findingID }),
              finding.type == .brokenSymlink,
              finding.entryKind == .brokenSymlink,
              let linkPath = finding.linkPath,
              let rawTarget = finding.symlinkTarget,
              let resolvedTarget = finding.targetPath,
              let rootURL,
              let rootSessionOwner = rootSessionLease?.owner else {
            throw BrokenLinkDeletionError.confirmedFactsChanged
        }
        let actionID = UUID()
        let targetAccess = try acquireAgentTargetAccess(agentID: finding.agentID, actionID: actionID)
        defer { _ = targetAccess.endByOwningAction() }
        let plan = try relationActionRuntime.prepareBrokenLinkDeletionPlan(
            actionID: actionID,
            rootURL: rootURL,
            rootSessionOwner: rootSessionOwner,
            agentID: finding.agentID,
            agentDisplayName: finding.agentDisplayName,
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
        try? auditAgentDirectory(agentID: confirmedPlan.facts.agentID)
        switch coordination.outcome {
        case .completed(let result) where result.status == .succeeded:
            setStatus("Deleted broken link node for %@.", confirmedPlan.facts.agentDisplayName)
            errorMessage = nil
        case .completed(let result):
            errorMessage = "Broken link was not deleted. Next step: \(result.safeNextStep)."
        case .stale:
            errorMessage = "The link changed after confirmation. Nothing was deleted."
        default:
            errorMessage = "The broken link deletion did not complete. Recheck the Agent directory."
        }
        return coordination
    }

    private func mergeAgentAuditResult(_ result: AgentDirectoryAuditResult, agentID: String? = nil) {
        agentDetections = agentDetections.filter { agentID != nil && $0.agentID != agentID }
            + result.detections
        agentFindings = agentFindings.filter { agentID != nil && $0.agentID != agentID }
            + result.findings.filter { agentID == nil || $0.agentID == agentID }
        localState.detectedAgentsSnapshot = agentDetections
        localState.agentAuditSnapshots = result.auditSnapshots
        refreshRelationObservations(for: result.detections)
    }

    func refreshRelationObservations(for detections: [AgentDetectionSnapshot], assetIDs: Set<UUID>? = nil) {
        for previous in localState.targetObservations where assetIDs?.contains(previous.relation.assetID) ?? true {
            let relation = previous.relation
            guard relation.scope == .global,
                  detections.contains(where: { $0.agentID == relation.agentID }),
                  let descriptor = installedAgentDescriptors.first(where: { $0.id == relation.agentID }),
                  let targetPath = descriptor.skillsDirectory,
                  let skill = rootSnapshot?.metadata.installedSkills.first(where: { $0.assetID == relation.assetID })
            else { continue }

            let target = URL(fileURLWithPath: targetPath, isDirectory: true).standardizedFileURL
            let evidence = rootSnapshot?.metadata.managedRelationEvidence.first { $0.relation == relation }
            let observation: TargetObservation
            do {
                guard let authorization = try startupAccessStore.resolveAccess(to: target),
                      !authorization.isStale, authorization.url.standardizedFileURL == target
                else { throw AgentTargetAccessError.qualificationFailed(.permissionRequired) }
                let linkURL = try relationActionRuntime.linkURL(
                    linkName: relationLinkName(asset: skill),
                    targetDirectory: target
                )
                let lease = try securityScopedAccessProvider.acquire(url: authorization.url, owner: .inspection(UUID()))
                let inspection = Result {
                    try RelationOwnershipInspector().inspect(
                        linkURL: linkURL, relation: relation,
                        canonicalTargetPath: skill.installedPath, evidence: evidence
                    )
                }
                try endSecurityScopedAccessLease(lease)
                observation = try inspection.get().observation
            } catch {
                observation = TargetObservation(
                    relation: relation, linkPath: previous.linkPath, nodeKind: .unreadable,
                    linkText: nil, resolvedTargetPath: nil, fileIdentity: nil,
                    isReadable: false, isWritable: false, observedAt: Date(),
                    limitation: error.localizedDescription
                )
            }

            localState.targetObservations.removeAll { $0.relation == relation }
            localState.targetObservations.append(observation)
            let intent = rootSnapshot?.metadata.enablementIntents.first { $0.id == relation.id }
            if let input = currentRelationVerificationInput(
                relation: relation, skill: skill, intent: intent, observation: observation,
                capability: agentCapabilityPresentation(descriptor)
            ) {
                localState = localState.replacingRelationState(
                    relation, observation: observation, evidence: evidence,
                    verification: RelationVerifier.verify(input)
                )
            }
        }
    }

    private func agentDisplayName(for agentID: String) -> String {
        agentConfigurations.first(where: { $0.id == agentID })?.displayName
            ?? agentDetections.first(where: { $0.agentID == agentID })?.displayName
            ?? AgentKind(rawValue: agentID)?.displayName
            ?? agentID
    }

}
