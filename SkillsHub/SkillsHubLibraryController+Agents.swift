import CryptoKit
import Darwin
import Foundation

enum AgentDefaultDirectoryRefreshStatus: Equatable {
    case manageable
    case missing
    case authorizationRequired
    case unverifiable
    case otherDirectoryConfigured

    var descriptionKey: String {
        switch self {
        case .manageable: "Default directory verified"
        case .missing: "Directory does not exist"
        case .authorizationRequired: "Authorization required"
        case .unverifiable: "Unable to verify directory"
        case .otherDirectoryConfigured: "Another directory is configured; default was skipped"
        }
    }
}

nonisolated struct AgentDirectoryChangeBlocker: Hashable, Identifiable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case access
        case managedRelation
        case enabledSelection
        case unresolvedRelation
        case unfinishedOperation
    }

    var kind: Kind
    var id: String
    var title: LocalizedMessage
    var detail: LocalizedMessage
    var skillID: String?
}

extension SkillsHubLibraryController {
    func refreshDefaultAgentDirectories() async {
        guard hasRoot else {
            defaultAgentDirectoryRefresh = [:]
            return
        }
        let priorFindings = agentFindings
        await refreshAgentLightScan(checkInstallation: true)
        let unavailableIDs = Set(agentDetections.filter { !$0.skillsDirectoryExists || !$0.readable }.map(\.agentID))
        // Keep the last observed entries visible with the verification failure until access is restored.
        agentFindings += priorFindings.filter { finding in
            unavailableIDs.contains(finding.agentID)
                && [.localDirectoryNotManaged, .externalSymlinkNotManaged].contains(finding.type)
                && !agentFindings.contains(where: { $0.id == finding.id })
        }
        for agent in [AgentKind.codex, .claudeCode] {
            let status = inspectDefaultAgentDirectory(agent)
            if status == .manageable {
                do {
                    try await auditAgentDirectory(agentID: agent.rawValue)
                    defaultAgentDirectoryRefresh[agent] = .manageable
                } catch {
                    defaultAgentDirectoryRefresh[agent] = .unverifiable
                    handle(error)
                }
            } else {
                defaultAgentDirectoryRefresh[agent] = status
                if status != .otherDirectoryConfigured {
                    agentDirectoryAuditFailures[agent.rawValue] = "Agent directory has not been verified."
                }
            }
        }
    }

    private func inspectDefaultAgentDirectory(_ agent: AgentKind) -> AgentDefaultDirectoryRefreshStatus {
        let target = agentPathResolver.globalSkillsDirectory(
            for: agent, environment: agentEnvironment, homeDirectory: agentHomeDirectory
        ).standardizedFileURL
        if resolvedAgentSkillsDirectory(for: agent).standardizedFileURL != target {
            return .otherDirectoryConfigured
        }
        if let configured = agentConfigurations.first(where: { $0.id == agent.rawValue })?.skillsDirectory,
           URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL != target {
            return .otherDirectoryConfigured
        }
        var node = stat()
        if lstat(target.path, &node) == -1 {
            return errno == ENOENT ? .missing : .unverifiable
        }
        if node.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
            return .unverifiable
        }
        let authorization: StartupAccessBookmarkResolution
        do {
            guard let resolved = try startupAccessStore.resolveAccess(to: target) else {
                return .authorizationRequired
            }
            authorization = resolved
        } catch {
            return .unverifiable
        }
        guard !authorization.isStale,
              authorization.url.standardizedFileURL == target else {
            return .unverifiable
        }
        let lease: SecurityScopedAccessLease
        do {
            lease = try securityScopedAccessProvider.acquire(
                url: authorization.url,
                owner: .agentTarget(actionID: UUID(), agent: agent)
            )
        } catch {
            return .unverifiable
        }
        defer { _ = lease.end(by: lease.owner) }
        guard !FileAccessService(fileManager: fileManager).isSymlink(target) else {
            return .unverifiable
        }
        guard isDirectory(target) else {
            return .unverifiable
        }
        let qualification = AgentTargetQualifier().qualify(
            agent: agent,
            detected: false,
            candidates: [target],
            authorization: authorization
        )
        return qualification.allowsManagedWrite ? .manageable : .unverifiable
    }

    var agentConfigurations: [AgentConfigurationRecord] {
        rootSnapshot?.metadata.agents ?? AgentConfigurationRecord.phase1BuiltIns
    }

    func rebuildAgentPresentation() {
        agentDescriptorSnapshot = InstalledAgentDescriptorBuilder().build(
            detections: agentDetections, configurations: agentConfigurations, links: agentLinks
        )
        requestPresentationObservation()
    }

    var installedAgentDescriptors: [InstalledAgentDescriptor] {
        agentDescriptorSnapshot
    }

    var visibleInstalledAgentDescriptors: [InstalledAgentDescriptor] {
        installedAgentDescriptors.filter { $0.isVisibleOnCards && $0.id != "agents" }
    }

    var sidebarAgentDescriptors: [InstalledAgentDescriptor] {
        visibleInstalledAgentDescriptors.filter(\.isVisibleInSidebar)
    }

    var configuredAgentCapabilities: [AgentCapabilityPresentation] {
        visibleInstalledAgentDescriptors.map(agentCapabilityPresentation)
    }

    func agentCapabilityPresentation(
        _ descriptor: InstalledAgentDescriptor
    ) -> AgentCapabilityPresentation {
        if let capability = agentCapabilitySnapshot[descriptor.id] { return capability }
        let qualifier = AgentTargetQualifier()
        let qualification = if let agent = descriptor.agent {
            qualifier.qualify(agent: agent, detected: descriptor.isDetected, candidates: [], authorization: nil)
        } else {
            qualifier.qualify(customAgentID: descriptor.id, detected: descriptor.isDetected, candidates: [], authorization: nil)
        }
        var capability = capabilityPresentation(
            for: descriptor,
            qualification: qualification
        )
        capability.unavailableReason = "Checking…"
        return capability
    }

    // Observation consumers requalify current facts; display snapshots never authorize a write.
    func inspectAgentCapabilityPresentation(_ descriptor: InstalledAgentDescriptor) async throws -> AgentCapabilityPresentation {
        let target = descriptor.skillsDirectory.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? descriptor.agent.map { resolvedAgentSkillsDirectory(for: $0).standardizedFileURL }
        let targets = target.map { [descriptor.id: $0] } ?? [:]
        let authorizations = try await startupAccessStore.resolvePresentationAccess(to: Array(targets.values))
        let result = try await Self.observePresentation(root: nil, items: [], descriptors: [descriptor],
            targets: targets, detections: Set(agentDetections.filter(\.detected).map(\.agentID)),
            authorizations: authorizations, fileManager: fileManager, iconPaths: [], observations: [], assets: [:])
        guard let qualification = result.qualifications[descriptor.id] else { throw CancellationError() }
        return capabilityPresentation(for: descriptor, qualification: qualification)
    }

    func capabilityPresentation(for descriptor: InstalledAgentDescriptor, qualification: AgentTargetQualification) -> AgentCapabilityPresentation {
        AgentCapabilityPresentation(
            agentID: descriptor.id,
            displayName: descriptor.displayName,
            isPresent: qualification.agentDetected,
            targetPath: qualification.target?.path ?? qualification.candidates.first?.path ?? descriptor.skillsDirectory ?? descriptor.agent.map { resolvedAgentSkillsDirectory(for: $0).path },
            authorizationStatus: qualification.authorizationStatus,
            profileID: qualification.profileID,
            profileVersion: qualification.profileVersion,
            profileSchemaVersion: qualification.schemaVersion,
            canDetect: qualification.profileID != nil,
            canClassify: qualification.profileID != nil && qualification.agentDetected,
            canManageRelations: qualification.allowsManagedWrite,
            unavailableReason: qualification.failure.map(agentQualificationFailureDescription)
        )
    }

    func relationPresentations(for skill: InstalledSkill) -> [AgentRelationPresentation] {
        visibleInstalledAgentDescriptors.map { descriptor in
            let relation = AgentRelationIdentity(
                assetID: skill.assetID,
                agentID: descriptor.id,
                scope: .global
            )
            let intent = presentationIntents[relation.id]
            let observation = presentationObservations[relation.id]
            let currentObservation = agentDirectoryAuditFailures[descriptor.id] == nil || observation?.nodeKind == .unreadable
                ? observation : nil
            let record = presentationVerifications[relation.id]
            let capability = agentCapabilityPresentation(descriptor)
            let result = relationActionResults[relation.id]
            let verification = currentVerificationConclusion(
                record: record,
                relation: relation,
                skill: skill,
                intent: intent,
                observation: observation,
                capability: capability
            )
            let safeNextStep = if record?.conclusion != verification {
                safeNextStep(for: verification)
            } else {
                displaySafeNextStep(
                    result?.safeNextStep,
                    conclusion: verification
                )
            }
            return AgentRelationPresentation(
                relation: relation,
                agentDisplayName: descriptor.displayName,
                skillID: skill.id,
                skillName: skill.name,
                intendedEnabled: intent?.isEnabled,
                observation: currentObservation?.nodeKind,
                verification: verification,
                isInFlight: inFlightRelationActionIDs.contains(relation.id),
                canPerformAction: capability.canManageRelations,
                unavailableReason: capability.unavailableReason,
                lastOutcome: result?.outcome,
                safeNextStep: safeNextStep,
                linkPath: currentObservation?.linkPath,
                linkText: currentObservation?.linkText,
                resolvedTargetPath: currentObservation?.resolvedTargetPath,
                ownership: currentObservation == nil ? .unreadable : relationOwnershipSnapshot[relation.id] ?? .unreadable
            )
        }
    }

    var detectedBuiltInAgents: [AgentKind] {
        let detected = Set(agentDetections.compactMap { detection -> AgentKind? in
            guard detection.detected, !detection.isCustom else {
                return nil
            }
            return detection.agent
        })
        return AgentKind.allCases.filter { detected.contains($0) }
    }

    var agentPathSettings: [AgentPathSettingRecord] {
        if !agentPathSettingsSnapshot.isEmpty { return agentPathSettingsSnapshot }
        return AgentKind.allCases.map { agent in
            let path = agentPathResolver.globalSkillsDirectory(for: agent, environment: agentEnvironment, homeDirectory: agentHomeDirectory)
            let resolved = resolvedAgentSkillsDirectory(for: agent)
            return AgentPathSettingRecord(agent: agent, markerPath: path.deletingLastPathComponent().path,
                configuredPath: agentPathOverrides[agent], defaultPath: path.path, resolvedPath: resolved.path,
                detected: false, isOverride: agentPathOverrides[agent] != nil, directoryExists: false,
                skillsDirectoryExists: false, isWritable: false,
                status: Self.agentPathStatus(isOverride: agentPathOverrides[agent] != nil, skillsDirectoryExists: false, isWritable: false))
        }
    }

    @concurrent nonisolated static func inspectAgentPathSettings(
        detections: [AgentDetectionSnapshot], home: URL, environment: [String: String],
        overrides: [AgentKind: String], fileManager: FileManager
    ) async -> [AgentPathSettingRecord] {
        let agentPathResolver = AgentPathResolver()
        return AgentKind.allCases.map { agent in
            let detection = detections.first { $0.agent == agent }
            let defaultPath = agentPathResolver.globalSkillsDirectory(for: agent, environment: environment, homeDirectory: home)
            let resolvedPath = overrides[agent].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultPath
            let markerPath = detection?.detected == true
                ? detection?.markerPath ?? defaultPath.deletingLastPathComponent().path
                : defaultPath.deletingLastPathComponent().path
            let markerURL = URL(fileURLWithPath: markerPath, isDirectory: true)
            let markerExists = detection?.detected == true || (fileManager.fileExists(atPath: markerURL.path) || FileAccessService(fileManager: fileManager).isSymlink(markerURL))
            let skillsExists = detection?.skillsDirectoryExists == true || ((try? resolvedPath.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            let isWritable = skillsExists
                ? fileManager.isWritableFile(atPath: resolvedPath.path)
                : (markerExists && fileManager.isWritableFile(atPath: markerURL.path))
            let isOverride = overrides[agent] != nil
            return AgentPathSettingRecord(
                agent: agent,
                markerPath: markerPath,
                configuredPath: overrides[agent],
                defaultPath: defaultPath.path,
                resolvedPath: resolvedPath.path,
                detected: markerExists,
                isOverride: isOverride,
                directoryExists: markerExists,
                skillsDirectoryExists: skillsExists,
                isWritable: isWritable,
                status: Self.agentPathStatus(isOverride: isOverride, skillsDirectoryExists: skillsExists, isWritable: isWritable)
            )
        }
    }

    func saveAgentDisplayFields(agentID: String, displayName: String, iconMonogram: String?) async throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else {
            throw SkillsHubLibraryFailure.invalidSource("Agent name is required.")
        }
        guard var configuration = agentConfigurations.first(where: { $0.id == agentID }) else {
            throw SkillsHubLibraryFailure.invalidSource("Agent configuration not found.")
        }
        if configuration.agent == nil {
            configuration.iconMonogram = try validatedAgentMonogram(iconMonogram ?? "")
        }
        configuration.displayName = name
        guard agentConfigurations.first(where: { $0.id == agentID }) != configuration else { return }

        try await commitAgentConfiguration { configurations in
            configurations.removeAll { $0.id == agentID }
            configurations.append(configuration)
        }
        setStatus("Name and abbreviation saved for %@.", name)
    }

    func agentDirectoryChangeBlockers(agentID: String) -> [AgentDirectoryChangeBlocker] {
        guard let snapshot = rootSnapshot,
              let configuration = snapshot.metadata.agents.first(where: { $0.id == agentID }) else {
            return [AgentDirectoryChangeBlocker(
                kind: .access,
                id: "configuration-missing",
                title: "Agent configuration is unavailable",
                detail: "Reconnect the current Management Directory before changing this directory.",
                skillID: nil
            )]
        }
        return agentDirectoryChangeBlockers(
            agentID: agentID,
            configuration: configuration,
            snapshot: snapshot
        )
    }

    func saveAgentDirectory(agentID: String, newDirectory: URL) async throws {
        guard let rootURL else { throw SkillsHubLibraryFailure.missingRoot }
        let directory = newDirectory.standardizedFileURL
        guard isDirectory(directory) else {
            throw SkillsHubLibraryFailure.invalidSource("The selected Agent skills target is not a directory.")
        }
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw SkillsHubLibraryFailure.invalidSource("The Agent skills target cannot be a symbolic link.")
        }
        guard try inspectPersistedAccess(to: directory) else {
            throw SkillsHubLibraryFailure.invalidSource("Authorize the exact Agent skills target before saving.")
        }
        guard let initialSnapshot = rootSnapshot,
              let initialConfiguration = initialSnapshot.metadata.agents.first(where: { $0.id == agentID }) else {
            throw SkillsHubLibraryFailure.invalidSource("Agent configuration not found.")
        }
        let oldDirectory = configuredSkillsDirectory(for: initialConfiguration)
        guard oldDirectory != directory else {
            try endSelectedInspectionAccess(to: directory)
            return
        }

        let newAccess = try acquireSecurityScopedAccess(
            to: directory,
            owner: .configuredAgentTarget(actionID: UUID(), agentID: agentID),
            resolvingPersistedBookmark: true
        )
        defer { try? endSecurityScopedAccessLease(newAccess) }
        let oldAccess = try acquireAgentTargetAccess(agentID: agentID, actionID: UUID())
        defer { _ = oldAccess.endByOwningAction() }
        let oldIdentity = try LinkNodeIdentity.read(at: oldDirectory)
        let newIdentity = try LinkNodeIdentity.read(at: directory)
        let metadataStore = metadataStore

        let saved: RootSnapshot
        do {
            saved = try await RootMutationOwner.shared.perform(at: rootURL) {
                let current = try metadataStore.loadCurrentSnapshot(from: rootURL)
                return try metadataStore.commit(at: rootURL, expected: current) { metadata in
                    guard let index = metadata.agents.firstIndex(where: { $0.id == agentID }),
                          configuredSkillsDirectory(for: metadata.agents[index]) == oldDirectory,
                          try LinkNodeIdentity.read(at: oldDirectory) == oldIdentity,
                          try LinkNodeIdentity.read(at: directory) == newIdentity else {
                        throw SkillsHubLibraryFailure.invalidSource("Agent directory facts changed before saving. The old configuration was kept.")
                    }
                    let currentOverrides = Self.agentPathOverrides(
                        from: metadata.agents
                    )
                    let currentAudit = try agentAuditService.fullAudit(
                        agentID: agentID,
                        rootURL: rootURL,
                        homeDirectory: agentHomeDirectory,
                        overrides: currentOverrides,
                        localState: agentAuditLocalState(configurations: metadata.agents),
                        installedSkills: metadata.installedSkills
                    )
                    let blockers = agentDirectoryChangeBlockers(
                        agentID: agentID,
                        configuration: metadata.agents[index],
                        snapshot: current,
                        findings: currentAudit.findings,
                        qualification: oldAccess.qualification
                    )
                    guard blockers.isEmpty else {
                        throw SkillsHubLibraryFailure.invalidSource("Please resolve the listed Agent relationships or operations before changing the directory.")
                    }
                    guard metadata.agents.allSatisfy({
                        $0.id == agentID || configuredSkillsDirectory(for: $0) != directory
                    }) else {
                        throw SkillsHubLibraryFailure.invalidSource("Another Agent already uses this skills directory.")
                    }
                    metadata.agents[index].skillsDirectory = directory.path
                }
            }
        } catch {
            if let observed = try? metadataStore.loadCurrentSnapshot(from: rootURL) {
                rootSnapshot = observed
                agentPathOverrides = Self.agentPathOverrides(
                    from: observed.metadata.agents
                )
            }
            throw error
        }
        guard saved.metadata.agents.first(where: { $0.id == agentID })?.skillsDirectory == directory.path else {
            throw SkillsHubLibraryFailure.invalidSource("The saved Agent directory could not be verified.")
        }
        rootSnapshot = saved
        agentPathOverrides = Self.agentPathOverrides(from: saved.metadata.agents)
        await refreshAgentLightScan(checkInstallation: true)
        errorMessage = nil
        setStatus("Agent directory saved. Re-enable Skills explicitly when ready.")
    }

    private func agentDirectoryChangeBlockers(
        agentID: String,
        configuration: AgentConfigurationRecord,
        snapshot: RootSnapshot,
        findings: [AgentDirectoryFinding]? = nil,
        qualification: AgentTargetQualification? = nil
    ) -> [AgentDirectoryChangeBlocker] {
        var blockers: [AgentDirectoryChangeBlocker] = []
        let currentDirectory = configuredSkillsDirectory(for: configuration)
        let capability = visibleInstalledAgentDescriptors.first(where: { $0.id == agentID })
            .map { descriptor in
                qualification.map { capabilityPresentation(for: descriptor, qualification: $0) }
                    ?? agentCapabilityPresentation(descriptor)
            }
        if capability?.canManageRelations != true || capability?.targetPath.map({
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }) != currentDirectory {
            blockers.append(AgentDirectoryChangeBlocker(
                kind: .access,
                id: "old-directory-unavailable",
                title: "Current directory cannot be verified",
                detail: capability?.unavailableReason.map { LocalizedMessage($0) } ?? "Restore access to the current Agent directory and recheck it.",
                skillID: nil
            ))
        }

        let skillsByAsset = Dictionary(uniqueKeysWithValues: snapshot.metadata.installedSkills.map { ($0.assetID, $0) })
        let relationIDs = Set(
            snapshot.metadata.enablementIntents.filter {
                $0.agentID == agentID && $0.scope == .global && $0.isEnabled
            }.map(\.id)
        )
        for relationID in relationIDs.sorted() {
            let intent = snapshot.metadata.enablementIntents.first { $0.id == relationID }
            let relation = intent.map {
                AgentRelationIdentity(assetID: $0.assetID, agentID: $0.agentID, scope: $0.scope)
            }
            guard let relation else { continue }
            let skill = skillsByAsset[relation.assetID]
            if intent?.isEnabled == true {
                blockers.append(AgentDirectoryChangeBlocker(
                    kind: .enabledSelection,
                    id: "enabled-\(relation.id)",
                    title: .verbatim(skill?.name ?? relation.assetID.uuidString),
                    detail: "This Skill is still selected for this Agent. Disable it explicitly before changing directories.",
                    skillID: skill?.id
                ))
            }
            if localState.targetObservations.first(where: { $0.relation == relation })?.nodeKind == .unreadable {
                blockers.append(AgentDirectoryChangeBlocker(
                    kind: .unresolvedRelation,
                    id: "unreadable-\(relation.id)",
                    title: .verbatim(skill?.name ?? relation.assetID.uuidString),
                    detail: "The current relationship could not be verified.",
                    skillID: skill?.id
                ))
            }
        }

        for finding in findings ?? agentFindings where finding.agentID == agentID
            && [.pendingAudit, .permissionDenied, .directoryEnumerationFailed, .linkDrift, .rollbackFailed, .invalidEntry].contains(finding.type) {
            blockers.append(AgentDirectoryChangeBlocker(
                kind: .unresolvedRelation,
                id: "finding-\(finding.id)",
                title: .verbatim(finding.entryName),
                detail: finding.presentationMessage,
                skillID: finding.primaryMatch?.hubSkillID
            ))
        }
        for task in phase1Tasks where task.badgeEligible && (
            task.relationEvidence?.relation.agentID == agentID || task.recoveryEvidence?.agentID == agentID
                || ([.setAgentRelation, .deleteBrokenLink].contains(task.kind)
                    && task.recoveryEvidence != nil && task.recoveryEvidence?.agentID == nil)
        ) {
            blockers.append(AgentDirectoryChangeBlocker(
                kind: .unfinishedOperation,
                id: "task-\(task.id.uuidString)",
                title: task.relationEvidence.map { .verbatim($0.skillName) } ?? task.title,
                detail: task.result,
                skillID: task.relationEvidence?.skillID
            ))
        }
        if findings != nil, let rootURL {
            do {
                let operations = try RelationActionOperationRecordStore(fileManager: fileManager).unfinishedOperationBlockers(
                    agentID: agentID,
                    rootURL: rootURL
                )
                blockers.append(contentsOf: operations.map { operation in
                    AgentDirectoryChangeBlocker(
                        kind: .unfinishedOperation,
                        id: "operation-\(operation.id.uuidString)",
                        title: LocalizedMessage(operation.title),
                        detail: "Review operation \(operation.id.uuidString) before changing this Agent directory.",
                        skillID: nil
                    )
                })
            } catch {
                blockers.append(AgentDirectoryChangeBlocker(
                    kind: .unfinishedOperation,
                    id: "operation-records-unavailable",
                    title: "Operation records cannot be verified",
                    detail: errorPresentation(for: error),
                    skillID: nil
                ))
            }
        }
        return Array(Set(blockers)).sorted { $0.id < $1.id }
    }

    private func configuredSkillsDirectory(for configuration: AgentConfigurationRecord) -> URL {
        if let path = configuration.skillsDirectory {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return configuration.agent.map {
            agentPathResolver.globalSkillsDirectory(for: $0, environment: agentEnvironment, homeDirectory: agentHomeDirectory)
                .standardizedFileURL
        } ?? URL(fileURLWithPath: "", isDirectory: true)
    }

    func acquireAgentTargetAccess(agentID: String, actionID: UUID) throws -> AgentTargetAccess {
        guard let descriptor = visibleInstalledAgentDescriptors.first(where: { $0.id == agentID }),
              let path = descriptor.skillsDirectory else {
            throw ControllerRelationActionError.unsupportedAgent(agentID)
        }
        let target = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let detection = agentDetections.first { $0.agentID == agentID }
        let authorization = try startupAccessStore.resolveAccess(to: target)
        let qualification = if let agent = descriptor.agent {
            AgentTargetQualifier().qualify(
                agent: agent,
                detected: detection?.detected == true,
                candidates: [target],
                authorization: authorization
            )
        } else {
            AgentTargetQualifier().qualify(
                customAgentID: agentID,
                detected: detection?.detected == true,
                candidates: [target],
                authorization: authorization
            )
        }
        if let failure = qualification.failure {
            throw AgentTargetAccessError.qualificationFailed(failure)
        }
        guard let qualifiedTarget = qualification.target else {
            throw AgentTargetAccessError.qualificationFailed(.targetMissing)
        }
        let owner = descriptor.agent.map {
            SecurityScopedAccessOwner.agentTarget(actionID: actionID, agent: $0)
        } ?? .configuredAgentTarget(actionID: actionID, agentID: agentID)
        let lease: SecurityScopedAccessLease
        do {
            lease = try securityScopedAccessProvider.acquire(url: qualifiedTarget, owner: owner)
        } catch SecurityScopedAccessError.startDenied {
            throw AgentTargetAccessError.leaseUnavailable
        }
        guard isDirectory(target) else {
            _ = lease.end(by: owner)
            throw AgentTargetAccessError.qualificationFailed(.targetMissing)
        }
        return AgentTargetAccess(
            qualification: qualification,
            lease: lease
        )
    }

    func acquireAgentTargetAccess(agent: AgentKind, actionID: UUID) throws -> AgentTargetAccess {
        try acquireAgentTargetAccess(agentID: agent.rawValue, actionID: actionID)
    }

    private func currentVerificationConclusion(
        record: VerificationRecord?,
        relation: AgentRelationIdentity,
        skill: InstalledSkill,
        intent: EnablementIntent?,
        observation: TargetObservation?,
        capability: AgentCapabilityPresentation
    ) -> VerificationConclusion {
        guard let record else { return .notVerified }
        guard capability.canManageRelations else { return .currentlyUnverifiable }
        guard let input = currentRelationVerificationInput(
            relation: relation, skill: skill, intent: intent,
            observation: observation, capability: capability
        ) else { return .notVerified }
        return RelationVerifier.consume(record, against: input)
    }

    func currentRelationVerificationInput(
        relation: AgentRelationIdentity,
        skill: InstalledSkill,
        intent: EnablementIntent?,
        observation: TargetObservation?,
        capability: AgentCapabilityPresentation
    ) -> RelationVerificationInput? {
        guard let snapshot = rootSnapshot,
              let intent,
              let observation,
              let profileID = capability.profileID,
              let profileVersion = capability.profileVersion,
              let profileSchemaVersion = capability.profileSchemaVersion,
              let targetPath = capability.targetPath
        else { return nil }

        let canonicalPath = URL(fileURLWithPath: skill.installedPath).standardizedFileURL.path
        let normalizedTargetPath = URL(fileURLWithPath: targetPath).standardizedFileURL.path
        let bindings = RelationVerificationBindings(
            rootGeneration: snapshot.generation,
            assetRevision: skill.currentRevision,
            manifestDigest: skill.manifestDigest,
            canonicalPath: canonicalPath,
            canonicalPathFingerprint: SHA256Digest.hex(Data(canonicalPath.utf8)),
            profileID: profileID,
            profileVersion: profileVersion,
            profileSchemaVersion: profileSchemaVersion,
            profileIsValid: true,
            agentExists: true,
            globalTargetPath: normalizedTargetPath,
            authorizationFingerprint: SHA256Digest.hex(Data("current|\(normalizedTargetPath)".utf8)),
            targetIsAuthorized: capability.authorizationStatus == .current,
            isReadable: observation.isReadable,
            isWritable: observation.isWritable,
            linkPath: URL(fileURLWithPath: normalizedTargetPath).appendingPathComponent(relationLinkName(asset: skill)).path,
            nodeKind: observation.nodeKind,
            nodeFingerprint: observation.fileIdentity?.fingerprint,
            linkText: observation.linkText,
            resolvedTargetPath: observation.resolvedTargetPath,
            observationDigest: observation.digest,
            enablementIntent: intent
        )
        return RelationVerificationInput(
            relation: relation,
            bindings: bindings,
            observation: observation,
            limitations: []
        )
    }

    private func safeNextStep(for conclusion: VerificationConclusion) -> String {
        switch conclusion {
        case .notVerified: "Observe current facts before preparing another action."
        case .verifiedConsistent: "No action is required."
        case .drifted: "Review the current relation before preparing another action."
        case .currentlyUnverifiable: "Restore current access and observe the relation again."
        }
    }

    private func displaySafeNextStep(
        _ value: String?,
        conclusion: VerificationConclusion
    ) -> String {
        switch value {
        case "none": safeNextStep(for: conclusion)
        case "observe-current-relation": "Observe current facts before preparing another action."
        case "review-current-relation": "Review the current relation before preparing another action."
        case "restore-current-access-and-observe": "Restore current access and observe the relation again."
        case "reauthorize-current-relation": "Review current relation facts and authorize a new action."
        case "Wait for the current action on this relation to finish.",
             "Observe current facts before preparing another action.",
             "Review the current target authorization before trying again.",
             "Review target access before preparing another action.",
             "Review creation materials in Operation Details.": value!
        default: safeNextStep(for: conclusion)
        }
    }

    func agentQualificationFailureDescription(
        _ failure: AgentTargetQualificationFailure
    ) -> String {
        switch failure {
        case .profileUnavailable: "No current supported capability profile is available."
        case .targetMissing: "The Agent skills target is missing."
        case .targetAmbiguous: "More than one Agent target is eligible."
        case .permissionRequired: "Authorize the exact Agent skills target in Settings."
        case .bookmarkStale: "The saved target authorization is stale. Reauthorize it in Settings."
        case .authorizationTargetMismatch: "The saved authorization belongs to a different target."
        }
    }

    func createAgentSkillsDirectory(agent: AgentKind) async throws {
        try await createAgentSkillsDirectory(at: resolvedAgentSkillsDirectory(for: agent), displayName: agent.displayName)
    }

    func createAgentSkillsDirectory(agentID: String) async throws {
        if let agent = AgentKind(rawValue: agentID) {
            try await createAgentSkillsDirectory(agent: agent)
            return
        }
        guard let descriptor = installedAgentDescriptors.first(where: { $0.id == agentID }),
              let path = descriptor.skillsDirectory else {
            throw SkillsHubLibraryFailure.invalidSource("Agent not found.")
        }
        try await createAgentSkillsDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            displayName: descriptor.displayName
        )
    }

    @discardableResult
    func addCustomAgent(
        displayName: String,
        iconMonogram: String,
        skillsDirectory: URL
    ) async throws -> AgentConfigurationRecord {
        guard rootURL != nil else {
            throw SkillsHubLibraryFailure.missingRoot
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SkillsHubLibraryFailure.invalidSource("Custom agent name is required.")
        }
        let monogram = try validatedAgentMonogram(iconMonogram)
        let directory = skillsDirectory.standardizedFileURL
        guard isDirectory(directory) else {
            throw SkillsHubLibraryFailure.invalidSource("The selected Agent skills target is not a directory.")
        }
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw SkillsHubLibraryFailure.invalidSource("The Agent skills target cannot be a symbolic link.")
        }
        guard try inspectPersistedAccess(to: directory) else {
            throw SkillsHubLibraryFailure.invalidSource("Authorize the exact Agent skills target before saving.")
        }
        let record: AgentConfigurationRecord
        do {
            guard agentConfigurations.allSatisfy({ $0.skillsDirectory != directory.path }) else {
                throw SkillsHubLibraryFailure.invalidSource("Custom agent already exists.")
            }
            record = AgentConfigurationRecord(
                id: customAgentID(displayName: trimmedName, skillsDirectory: directory.path),
                agent: nil,
                displayName: trimmedName,
                iconMonogram: monogram,
                skillsDirectory: directory.path
            )
            try await commitAgentConfiguration { $0.append(record) }
        } catch {
            do {
                try endSelectedInspectionAccess(to: directory)
            } catch let releaseError {
                throw releaseError
            }
            throw error
        }
        try endSelectedInspectionAccess(to: directory)
        await refreshAgentLightScan()
        setStatus("Added custom agent %@.", trimmedName)
        errorMessage = nil
        return record
    }

    func prepareManagedRelationClearPlan(assetID: UUID) throws -> ManagedRelationClearPlan {
        guard let rootURL else { throw SkillsHubLibraryFailure.missingRoot }
        return try prepareManagedRelationClearPlan(
            assetID: assetID,
            snapshot: metadataStore.loadCurrentSnapshot(from: rootURL)
        )
    }

    private func prepareManagedRelationClearPlan(
        assetID: UUID,
        snapshot: RootSnapshot
    ) throws -> ManagedRelationClearPlan {
        guard let rootURL else {
            throw SkillsHubLibraryFailure.missingRoot
        }
        rootSnapshot = snapshot
        guard let rootSessionOwner = rootSessionLease?.owner else {
            throw ControllerRelationActionError.missingRootSession
        }
        guard let asset = snapshot.metadata.installedSkills.first(where: { $0.assetID == assetID }) else {
            throw SkillsHubLibraryFailure.missingSkill(assetID.uuidString)
        }
        try requireUnambiguousIdentity(assetID: assetID, snapshot: snapshot)

        let relevantAgentIDs = Set(
            snapshot.metadata.enablementIntents.compactMap { intent in
                intent.assetID == asset.assetID && intent.scope == .global && intent.isEnabled
                    ? intent.agentID : nil
            }
        )
        let descriptors = Dictionary(uniqueKeysWithValues: visibleInstalledAgentDescriptors.map { ($0.id, $0) })
        let items = relevantAgentIDs.sorted().map { agentID -> ManagedRelationClearItem in
            let relation = AgentRelationIdentity(assetID: asset.assetID, agentID: agentID, scope: .global)
            guard let descriptor = descriptors[agentID] else {
                return ManagedRelationClearItem(
                    relation: relation,
                    agentDisplayName: agentID,
                    linkPath: "Unavailable",
                    disposition: .blocked,
                    detail: "Agent configuration is unavailable; no cleanup was authorized."
                )
            }

            let actionID = UUID()
            do {
                let access = try acquireAgentTargetAccess(agentID: agentID, actionID: actionID)
                defer { _ = access.endByOwningAction() }
                let linkURL = try relationActionRuntime.linkURL(
                    linkName: relationLinkName(asset: asset),
                    targetDirectory: access.qualification.target
                        ?? URL(fileURLWithPath: descriptor.skillsDirectory ?? "", isDirectory: true)
                )
                let facts = try relationActionRuntime.currentFacts(
                    relation: relation,
                    rootURL: rootURL,
                    rootSessionOwner: rootSessionOwner,
                    targetAccess: access,
                    linkURL: linkURL
                )
                let disposition: ManagedRelationClearDisposition = switch facts.ownership {
                case .exactManagedLink, .vacant: .removable
                case .unmanagedNode, .externalLink, .brokenLink, .unreadable: .blocked
                }
                return ManagedRelationClearItem(
                    relation: relation,
                    agentDisplayName: descriptor.displayName,
                    linkPath: facts.linkPath,
                    disposition: disposition,
                    detail: facts.ownership.clearMessage
                )
            } catch {
                return ManagedRelationClearItem(
                    relation: relation,
                    agentDisplayName: descriptor.displayName,
                    linkPath: descriptor.skillsDirectory ?? "Unavailable",
                    disposition: .blocked,
                    detail: errorPresentation(for: error)
                )
            }
        }

        return ManagedRelationClearPlan(
            assetID: asset.assetID,
            skillID: asset.id,
            skillName: asset.name,
            rootGeneration: snapshot.generation,
            assetRevision: asset.currentRevision,
            manifestDigest: asset.manifestDigest,
            items: items
        )
    }

    func clearAllManagedRelations(
        using confirmedPlan: ManagedRelationClearPlan
    ) async throws -> ManagedRelationClearResult {
        guard try prepareManagedRelationClearPlan(assetID: confirmedPlan.assetID) == confirmedPlan else {
            throw ManagedRelationClearError.planChanged
        }

        var items: [ManagedRelationClearResultItem] = []
        for item in confirmedPlan.items {
            guard item.disposition == .removable else {
                items.append(
                    ManagedRelationClearResultItem(
                        relation: item.relation,
                        agentDisplayName: item.agentDisplayName,
                        outcome: .blocked,
                        detail: item.detail
                    )
                )
                continue
            }
            do {
                let result = try await setGlobalAgentEnablement(
                    agentID: item.relation.agentID,
                    assetID: confirmedPlan.assetID,
                    enabled: false
                )
                items.append(
                    ManagedRelationClearResultItem(
                        relation: item.relation,
                        agentDisplayName: item.agentDisplayName,
                        outcome: result.outcome,
                        detail: LocalizedMessage(displaySafeNextStep(
                            result.safeNextStep,
                            conclusion: result.execution?.verification?.conclusion ?? .notVerified
                        ))
                    )
                )
            } catch {
                items.append(
                    ManagedRelationClearResultItem(
                        relation: item.relation,
                        agentDisplayName: item.agentDisplayName,
                        outcome: .failed,
                        detail: errorPresentation(for: error)
                    )
                )
            }
        }

        let completed = items.filter { $0.outcome == .succeeded || $0.outcome == .noChange }.count
        let blocked = items.count - completed
        if completed == items.count {
            setStatus("Cleared all %lld managed relationships for %@.", Int64(completed), confirmedPlan.skillName)
        } else {
            setStatus("Cleared %lld managed relationships for %@; %lld Agent results need attention.", Int64(completed), confirmedPlan.skillName, Int64(blocked))
        }
        return ManagedRelationClearResult(
            skillID: confirmedPlan.skillID,
            skillName: confirmedPlan.skillName,
            items: items
        )
    }

    func setGlobalAgentEnablement(
        agentID: String,
        assetID: UUID,
        enabled: Bool,
        recordOnly: Bool = false
    ) async throws -> ControllerRelationActionResult {
        guard let descriptor = visibleInstalledAgentDescriptors.first(where: { $0.id == agentID }) else {
            throw ControllerRelationActionError.unsupportedAgent(agentID)
        }
        guard let rootURL, let snapshot = rootSnapshot else {
            throw SkillsHubLibraryFailure.missingRoot
        }
        guard let rootSessionOwner = rootSessionLease?.owner else {
            throw ControllerRelationActionError.missingRootSession
        }
        guard let asset = snapshot.metadata.installedSkills.first(where: { $0.assetID == assetID }) else {
            throw SkillsHubLibraryFailure.missingSkill(assetID.uuidString)
        }
        try requireUnambiguousIdentity(assetID: assetID, snapshot: snapshot)

        let relation = AgentRelationIdentity(
            assetID: asset.assetID,
            agentID: agentID,
            scope: .global
        )
        guard inFlightRelationActionIDs.insert(relation.id).inserted else {
            return .replayed(relation)
        }
        defer { inFlightRelationActionIDs.remove(relation.id) }

        let actionID = UUID()
        var relationTask = startingRelationTask(
            actionID: actionID,
            relation: relation,
            agentDisplayName: descriptor.displayName,
            asset: asset,
            desiredEnabled: enabled
        )
        upsertTask(relationTask)

        let targetAccess: AgentTargetAccess
        do {
            targetAccess = try acquireAgentTargetAccess(agentID: agentID, actionID: actionID)
        } catch {
            upsertTask(failedRelationTask(relationTask, error: error, agentID: agentID, agentDisplayName: descriptor.displayName, asset: asset, desiredEnabled: enabled))
            throw error
        }
        let linkURL: URL
        let token: RelationActionToken
        do {
            linkURL = try relationActionRuntime.linkURL(
                linkName: relationLinkName(asset: asset),
                targetDirectory: targetAccess.qualification.target
                    ?? URL(fileURLWithPath: descriptor.skillsDirectory ?? "", isDirectory: true)
            )
            token = try relationActionRuntime.prepareToken(
                actionID: actionID,
                desiredEnabled: enabled,
                relation: relation,
                rootURL: rootURL,
                rootSessionOwner: rootSessionOwner,
                snapshot: snapshot,
                asset: asset,
                targetAccess: targetAccess,
                linkURL: linkURL
            )
            // A record-only confirmation must never authorize removing a filesystem node.
            if recordOnly, enabled || token.facts.nodeKind != .vacant {
                throw SkillsHubLibraryFailure.invalidSource(
                    "The link is no longer absent. Recheck before cancelling the enablement record.")
            }
        } catch {
            _ = targetAccess.endByOwningAction()
            upsertTask(failedRelationTask(relationTask, error: error, agentID: agentID, agentDisplayName: descriptor.displayName, asset: asset, desiredEnabled: enabled))
            throw error
        }

        relationTask.phase = .executing
        relationTask.planDigest = token.tokenDigest
        relationTask.result = "Identity-bound single-relation action is executing."
        relationTask.events.append(
            Phase1TaskEvent(
                id: UUID(),
                phase: .executing,
                message: "One-time relation token consumed for \(descriptor.displayName) only.",
                occurredAt: Date()
            )
        )
        relationTask.updatedAt = Date()
        upsertTask(relationTask)

        let runtime = relationActionRuntime
        let coordination = await relationActionCoordinator.coordinate(
            token: token,
            rootURL: rootURL,
            targetAccess: targetAccess,
            currentFacts: {
                try runtime.currentFacts(
                    relation: relation,
                    rootURL: rootURL,
                    rootSessionOwner: rootSessionOwner,
                    targetAccess: targetAccess,
                    linkURL: linkURL
                )
            },
            perform: { authorization in
                runtime.execute(authorization: authorization, rootURL: rootURL, targetAccess: targetAccess)
            }
        )
        let result = ControllerRelationActionResult(
            relation: relation,
            coordination: coordination
        )
        relationActionResults[relation.id] = result
        if let currentSnapshot = try? metadataStore.loadCurrentSnapshot(from: rootURL) {
            rootSnapshot = currentSnapshot
        }
        if let currentLocalState = try? localStateStore.load(from: rootURL) {
            localState = currentLocalState
        }
        if result.execution?.metadataDelta == .committed,
           let currentSnapshot = rootSnapshot {
            refreshOtherRelationVerifications(
                excluding: relation,
                rootURL: rootURL,
                rootSessionOwner: rootSessionOwner,
                snapshot: currentSnapshot
            )
        }
        await waitForPresentationObservation()
        let currentRelation = relationPresentations(for: asset).first { $0.relation == relation }
        upsertTask(
            completedRelationTask(
                relationTask,
                result: result,
                agentDisplayName: descriptor.displayName,
                asset: asset,
                desiredEnabled: enabled,
                currentRelation: currentRelation
            )
        )
        setRelationActionStatus(result, skillID: asset.name, agentDisplayName: descriptor.displayName)
        errorMessage = nil
        return result
    }

    private func requireUnambiguousIdentity(assetID: UUID, snapshot: RootSnapshot) throws {
        let items = presentationService.phase1Items(
            availableSkills: snapshot.metadata.availableSkills,
            installedSkills: snapshot.metadata.installedSkills,
            sources: snapshot.metadata.sources,
            enablementIntents: snapshot.metadata.enablementIntents,
            rootURL: URL(fileURLWithPath: snapshot.metadata.rootConfig.rootPath)
        )
        guard let item = items.first(where: { $0.managed?.assetID == assetID }), !item.identityConflict else {
            throw SkillsHubLibraryFailure.invalidSource("Skill identity conflicts with its source location. Re-check before changing relationships.")
        }
    }

    private func refreshOtherRelationVerifications(
        excluding changedRelation: AgentRelationIdentity,
        rootURL: URL,
        rootSessionOwner: SecurityScopedAccessOwner,
        snapshot: RootSnapshot
    ) {
        for intent in snapshot.metadata.enablementIntents {
            let relation = AgentRelationIdentity(
                assetID: intent.assetID,
                agentID: intent.agentID,
                scope: intent.scope
            )
            guard relation != changedRelation,
                  relation.scope == .global,
                  let descriptor = visibleInstalledAgentDescriptors.first(where: { $0.id == relation.agentID }),
                  let asset = snapshot.metadata.installedSkills.first(where: {
                      $0.assetID == relation.assetID
                  }) else {
                continue
            }

            do {
                let access = try acquireAgentTargetAccess(agentID: relation.agentID, actionID: UUID())
                defer { _ = access.endByOwningAction() }
                let linkURL = try relationActionRuntime.linkURL(
                    linkName: relationLinkName(asset: asset),
                    targetDirectory: access.qualification.target
                        ?? URL(fileURLWithPath: descriptor.skillsDirectory ?? "", isDirectory: true)
                )
                _ = try relationActionRuntime.refreshVerification(
                    relation: relation,
                    rootURL: rootURL,
                    rootSessionOwner: rootSessionOwner,
                    targetAccess: access,
                    linkURL: linkURL
                )
            } catch {
                // The previous record remains available as immutable history, but
                // current presentation will reject it against the new generation.
                continue
            }
        }

        if let currentLocalState = try? localStateStore.load(from: rootURL) {
            localState = currentLocalState
        }
    }

    private func startingRelationTask(
        actionID: UUID,
        relation: AgentRelationIdentity,
        agentDisplayName: String,
        asset: InstalledSkill,
        desiredEnabled: Bool
    ) -> Phase1TaskRecord {
        let now = Date()
        return Phase1TaskRecord(
            id: actionID,
            kind: .setAgentRelation,
            title: desiredEnabled
                ? "Enable \(agentDisplayName) for \(asset.name)"
                : "Disable \(agentDisplayName) for \(asset.name)",
            objectID: asset.id,
            phase: .preparing,
            result: "Preparing current facts for exactly one Agent relationship.",
            planDigest: SHA256Digest.hex(Data("\(actionID.uuidString)|\(relation.id)|\(desiredEnabled)".utf8)),
            events: [
                Phase1TaskEvent(
                    id: UUID(),
                    phase: .preparing,
                    message: "Bound action to \(relation.id); other Agent relationships are excluded.",
                    occurredAt: now
                )
            ],
            updatedAt: now
        )
    }

    private func failedRelationTask(
        _ task: Phase1TaskRecord,
        error: Error,
        agentID: String,
        agentDisplayName: String,
        asset: InstalledSkill,
        desiredEnabled: Bool
    ) -> Phase1TaskRecord {
        var failed = task
        let limitation = String(describing: error)
        let relation = AgentRelationIdentity(assetID: asset.assetID, agentID: agentID, scope: .global)
        let currentRelation = relationPresentations(for: asset).first { $0.relation == relation }
        let now = Date()
        failed.phase = .needsAttention
        failed.result = "Relation action failed before execution; current Agent and Skill facts remain authoritative."
        failed.events.append(
            Phase1TaskEvent(
                id: UUID(),
                phase: .needsAttention,
                message: "Failed before a verified relation delta: \(limitation)",
                occurredAt: now
            )
        )
        failed.relationEvidence = Phase1RelationTaskEvidence(
            relation: relation,
            agentDisplayName: agentDisplayName,
            skillID: asset.id,
            skillName: asset.name,
            desiredEnabled: desiredEnabled,
            outcome: Phase1RelationTaskProjection.outcomeLabel(.failed),
            actualDelta: ["No verified filesystem or metadata delta."],
            verification: currentRelation?.verification ?? .notVerified,
            limitations: [limitation],
            safeNextStep: currentRelation?.safeNextStep
                ?? "Open the current Agent or Skill and observe current facts before another action."
        )
        failed.updatedAt = now
        return failed
    }

    private func completedRelationTask(
        _ task: Phase1TaskRecord,
        result: ControllerRelationActionResult,
        agentDisplayName: String,
        asset: InstalledSkill,
        desiredEnabled: Bool,
        currentRelation: AgentRelationPresentation?
    ) -> Phase1TaskRecord {
        var completed = task
        let now = Date()
        let execution = result.execution
        let actualDelta = relationDeltaDescriptions(execution)
        let verification = execution?.verification?.conclusion
            ?? currentRelation?.verification
            ?? .notVerified
        let limitations = execution?.limitations ?? ["No post-action execution evidence was produced."]
        let safeNextStep = currentRelation?.safeNextStep
            ?? displaySafeNextStep(result.safeNextStep, conclusion: verification)
        let finalPhase: Phase1OperationPhase = execution?.creationMaterials?.status == .retained
            ? .needsAttention : Phase1RelationTaskProjection.finalPhase(for: result.outcome)

        completed.events.append(
            Phase1TaskEvent(
                id: UUID(),
                phase: .observing,
                message: .verbatim(actualDelta.joined(separator: " ")),
                occurredAt: now
            )
        )
        completed.events.append(
            Phase1TaskEvent(
                id: UUID(),
                phase: .verifying,
                message: "Current relationship conclusion was recorded.",
                occurredAt: now
            )
        )
        completed.events.append(
            Phase1TaskEvent(
                id: UUID(),
                phase: finalPhase,
                message: "Relation action finished. Review the current conclusion and safe next step.",
                occurredAt: now
            )
        )
        completed.phase = finalPhase
        completed.result = relationResultMessage(
            outcome: result.outcome,
            agentName: agentDisplayName,
            skillName: asset.name
        )
        completed.relationEvidence = Phase1RelationTaskEvidence(
            relation: result.relation,
            agentDisplayName: agentDisplayName,
            skillID: asset.id,
            skillName: asset.name,
            desiredEnabled: desiredEnabled,
            outcome: Phase1RelationTaskProjection.outcomeLabel(result.outcome),
            actualDelta: actualDelta,
            verification: verification,
            limitations: limitations,
            safeNextStep: safeNextStep
        )
        completed.updatedAt = now
        if let execution, execution.creationMaterials != nil, let rootURL {
            let recovery = relationActionRuntime.recoverCurrentFacts(operationID: task.id, rootURL: rootURL)
            completed.recoveryEvidence = Phase1RecoveryEvidence(components: recovery.components.map {
                Phase1RecoveryComponent(kind: $0.kind.rawValue, state: Phase1RecoveryState($0.state), path: $0.path, detail: $0.detail)
            }, creationMaterials: recovery.creationMaterials, agentID: result.relation.agentID)
        }
        return completed
    }

    private func relationResultMessage(
        outcome: ControllerRelationActionOutcome,
        agentName: String,
        skillName: String
    ) -> LocalizedMessage {
        switch outcome {
        case .succeeded: "Succeeded: \(agentName) relationship for \(skillName)."
        case .noChange: "No change: \(agentName) relationship for \(skillName)."
        case .blocked: "Blocked: \(agentName) relationship for \(skillName)."
        case .failed: "Failed: \(agentName) relationship for \(skillName)."
        case .unknown: "Unknown: \(agentName) relationship for \(skillName)."
        case .stale: "Stale: \(agentName) relationship for \(skillName)."
        case .replayed: "Already running: \(agentName) relationship for \(skillName)."
        case .cancelled: "Cancelled: \(agentName) relationship for \(skillName)."
        }
    }

    private func relationDeltaDescriptions(
        _ execution: RelationActionExecutionResult?
    ) -> [String] {
        guard let execution else { return ["No verified filesystem or metadata delta."] }
        var descriptions = execution.fileEvents.map { event in
            switch event {
            case .created(let path): "Created link: \(path)."
            case .isolated(let path): "Isolated link: \(path)."
            case .removed(let path): "Removed link: \(path)."
            case .restored(let path): "Restored link: \(path)."
            case .creationCompensated(let path): "Compensated link creation: \(path)."
            case .compensationFailed(let path): "Compensation failed at: \(path)."
            case .retainedForRecovery(let path): "Retained recovery object: \(path)."
            }
        }
        if execution.metadataDelta != .none {
            descriptions.append("Metadata delta: \(execution.metadataDelta.rawValue).")
        }
        if let materials = execution.creationMaterials {
            descriptions.append(materials.status == .settled
                ? "Creation directory settled" : "Creation materials retained; review current facts.")
        }
        if descriptions.isEmpty {
            descriptions.append("No filesystem or metadata change.")
        }
        return descriptions
    }

    private func setRelationActionStatus(
        _ result: ControllerRelationActionResult,
        skillID: String,
        agentDisplayName: String
    ) {
        switch result.outcome {
        case .succeeded:
            setStatus("Updated %@ for %@.", skillID, agentDisplayName)
        case .noChange:
            setStatus("%@ for %@ is already current.", skillID, agentDisplayName)
        case .blocked, .stale, .replayed:
            setStatus("%@ for %@ was not changed. View the current relationship for the next step.", skillID, agentDisplayName)
        case .failed, .unknown, .cancelled:
            setStatus("%@ for %@ needs attention. View the current relationship for the next step.", skillID, agentDisplayName)
        }
    }

    func relationLinkName(asset: InstalledSkill) -> String {
        asset.stableLinkName
            ?? asset.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolvedAgentSkillsDirectory(for agent: AgentKind) -> URL {
        if let override = agentPathOverrides[agent] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return agentPathResolver.globalSkillsDirectory(for: agent, environment: agentEnvironment, homeDirectory: agentHomeDirectory)
    }

    var agentAuditLocalState: SkillsHubLocalState {
        agentAuditLocalState(configurations: agentConfigurations)
    }

    private func agentAuditLocalState(configurations: [AgentConfigurationRecord]) -> SkillsHubLocalState {
        var state = localState
        let authoritative = configurations.compactMap { configuration -> CustomAgentRecord? in
            guard configuration.agent == nil, let path = configuration.skillsDirectory else { return nil }
            return CustomAgentRecord(
                id: configuration.id,
                displayName: configuration.displayName,
                skillsDirectory: path,
                createdAt: .distantPast
            )
        }
        state.customAgents = authoritative
        state.activeAgentLinks = (rootSnapshot?.metadata.enablementIntents ?? []).compactMap { intent in
            guard intent.isEnabled,
                  let skill = installedSkills.first(where: { $0.assetID == intent.assetID }),
                  let configuration = configurations.first(where: { $0.id == intent.agentID }) else { return nil }
            let target = configuredSkillsDirectory(for: configuration)
            return AgentManagedLinkRecord(agentID: intent.agentID, agent: configuration.agent,
                alias: relationLinkName(asset: skill),
                linkPath: target.appendingPathComponent(relationLinkName(asset: skill)).path,
                targetPath: skill.installedPath, hubSkillID: skill.id,
                hubRelativePath: "", rootAtCreation: rootURL?.path ?? "",
                createdAt: .distantPast)
        }
        return state
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func createAgentSkillsDirectory(at url: URL, displayName: String) async throws {
        guard rootURL != nil else {
            throw SkillsHubLibraryFailure.missingRoot
        }
        let parent = url.deletingLastPathComponent()
        guard isDirectory(parent) else {
            throw SkillsHubLibraryFailure.invalidSource("Parent directory does not exist.")
        }
        guard !itemExistsOrIsSymlink(url) else {
            if isDirectory(url) {
                await refreshAgentLightScan()
                setStatus("Skills directory already exists for %@.", displayName)
                errorMessage = nil
                return
            }
            throw SkillsHubLibraryFailure.invalidSource("Skills directory path is occupied.")
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        await refreshAgentLightScan()
        setStatus("Created skills directory for %@.", displayName)
        errorMessage = nil
        try saveLocalState()
    }

    private func itemExistsOrIsSymlink(_ url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            return true
        }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    var defaultRootURL: URL {
        agentHomeDirectory.appendingPathComponent("skills-hub", isDirectory: true)
    }

    nonisolated static func agentPathStatus(isOverride: Bool, skillsDirectoryExists: Bool, isWritable: Bool) -> AgentPathStatus {
        if !isWritable && skillsDirectoryExists {
            return .notWritable
        }
        if isOverride {
            return .custom
        }
        return skillsDirectoryExists ? .detected : .missing
    }

    private func customAgentID(displayName: String, skillsDirectory: String) -> String {
        let slug = displayName
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
        let digest = SHA256.hash(data: Data(skillsDirectory.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(8)
        return "custom-\(slug.isEmpty ? "agent" : slug)-\(digest)"
    }

    private func validatedAgentMonogram(_ value: String) throws -> String {
        guard let monogram = AgentPresentation.normalizedIconMonogram(value) else {
            throw SkillsHubLibraryFailure.invalidSource("Enter 1–4 visible characters for the icon abbreviation.")
        }
        return monogram
    }

    private func commitAgentConfiguration(
        _ mutation: @escaping (inout [AgentConfigurationRecord]) -> Void
    ) async throws {
        guard let rootURL, let expected = rootSnapshot else {
            throw SkillsHubLibraryFailure.missingRoot
        }
        let metadataStore = metadataStore
        let snapshot = try await RootMutationOwner.shared.perform(at: rootURL) {
            try metadataStore.commit(at: rootURL, expected: expected) { metadata in
                mutation(&metadata.agents)
                metadata.agents.sort {
                    let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
                }
            }
        }
        rootSnapshot = snapshot
        agentPathOverrides = Self.agentPathOverrides(
            from: snapshot.metadata.agents
        )
        await refreshAgentLightScan(checkInstallation: true)
        errorMessage = nil
    }

}
