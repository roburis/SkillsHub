import Foundation

nonisolated enum ControllerRelationActionOutcome: String, Equatable, Sendable {
    case succeeded
    case noChange = "no-change"
    case blocked
    case failed
    case unknown
    case stale
    case replayed
    case cancelled
}

nonisolated struct ControllerRelationActionResult: Sendable {
    let relation: AgentRelationIdentity
    var outcome: ControllerRelationActionOutcome
    let execution: RelationActionExecutionResult?
    var safeNextStep: String

    private init(
        relation: AgentRelationIdentity,
        outcome: ControllerRelationActionOutcome,
        execution: RelationActionExecutionResult?,
        safeNextStep: String
    ) {
        self.relation = relation
        self.outcome = outcome
        self.execution = execution
        self.safeNextStep = safeNextStep
    }

    static func replayed(_ relation: AgentRelationIdentity) -> Self {
        Self(
            relation: relation,
            outcome: .replayed,
            execution: nil,
            safeNextStep: "Wait for the current action on this relation to finish."
        )
    }

    init(
        relation: AgentRelationIdentity,
        coordination: RelationActionCoordinationResult<RelationActionExecutionResult>
    ) {
        self.relation = relation
        switch coordination.outcome {
        case .completed(let execution):
            self.execution = execution
            self.outcome = switch execution.status {
            case .succeeded: .succeeded
            case .noChange: .noChange
            case .blocked: .blocked
            case .failed: .failed
            case .unknown: .unknown
            }
            self.safeNextStep = execution.safeNextStep
        case .replayed:
            self.execution = nil
            self.outcome = .replayed
            self.safeNextStep = "Observe current facts before preparing another action."
        case .stale:
            self.execution = nil
            self.outcome = .stale
            self.safeNextStep = "Observe current facts before preparing another action."
        case .blocked:
            self.execution = nil
            self.outcome = .blocked
            self.safeNextStep = "Review the current target authorization before trying again."
        case .cancelled:
            self.execution = nil
            self.outcome = .cancelled
            self.safeNextStep = "Observe current facts before preparing another action."
        case .failed:
            self.execution = nil
            self.outcome = .failed
            self.safeNextStep = "Observe current facts before preparing another action."
        }

        if coordination.leaseRelease != .stopped {
            self.outcome = .unknown
            self.safeNextStep = "Review target access before preparing another action."
        }
    }
}

nonisolated enum ControllerRelationActionError: Error, Equatable, Sendable {
    case unsupportedAgent(String)
    case invalidSkillAlias(String)
    case missingRootSession
}

nonisolated final class RelationActionControllerRuntime: @unchecked Sendable {
    private let metadataStore: SkillsHubMetadataStore
    private let localStateStore: SkillsHubLocalStateStore
    private let inspector: RelationOwnershipInspector
    private let executor: RelationActionExecutor
    private let tokenBuilder: RelationActionTokenBuilder
    private let brokenLinkInspector: BrokenLinkDeletionInspector
    private let brokenLinkTokenBuilder: BrokenLinkDeletionTokenBuilder

    init(
        metadataStore: SkillsHubMetadataStore,
        localStateStore: SkillsHubLocalStateStore,
        linkService: AgentLinkService,
        fileManager: FileManager
    ) {
        self.metadataStore = metadataStore
        self.localStateStore = localStateStore
        self.inspector = RelationOwnershipInspector()
        self.executor = RelationActionExecutor(
            metadataStore: metadataStore,
            localStateStore: localStateStore,
            linkService: linkService,
            fileManager: fileManager
        )
        self.tokenBuilder = RelationActionTokenBuilder()
        self.brokenLinkInspector = BrokenLinkDeletionInspector(fileManager: fileManager)
        self.brokenLinkTokenBuilder = BrokenLinkDeletionTokenBuilder()
    }

    func linkURL(linkName: String, targetDirectory: URL) throws -> URL {
        guard
            linkName.isEmpty == false,
            linkName != ".",
            linkName != "..",
            linkName.contains("/") == false,
            linkName.contains("\\") == false,
            linkName.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) == false })
        else {
            throw ControllerRelationActionError.invalidSkillAlias(linkName)
        }
        return targetDirectory.standardizedFileURL.appendingPathComponent(linkName)
    }

    func prepareToken(
        actionID: UUID,
        desiredEnabled: Bool,
        relation: AgentRelationIdentity,
        rootURL: URL,
        rootSessionOwner: SecurityScopedAccessOwner,
        snapshot: RootSnapshot,
        asset: InstalledSkill,
        targetAccess: AgentTargetAccess,
        linkURL: URL
    ) throws -> RelationActionToken {
        let evidence = snapshot.metadata.managedRelationEvidence.first { $0.relation == relation }
        let inspection = try inspector.inspect(
            linkURL: linkURL,
            relation: relation,
            canonicalTargetPath: asset.installedPath,
            evidence: evidence
        )
        return try tokenBuilder.build(
            actionID: actionID,
            desiredEnabled: desiredEnabled,
            relation: relation,
            rootURL: rootURL,
            rootSessionOwner: rootSessionOwner,
            snapshot: snapshot,
            asset: asset,
            targetAccess: targetAccess,
            observation: inspection.observation,
            ownership: inspection.classification,
            currentIntent: currentIntent(in: snapshot, relation: relation)
        )
    }

    func currentFacts(
        relation: AgentRelationIdentity,
        rootURL: URL,
        rootSessionOwner: SecurityScopedAccessOwner,
        targetAccess: AgentTargetAccess,
        linkURL: URL
    ) throws -> RelationActionFacts {
        let snapshot = try metadataStore.loadCurrentSnapshot(from: rootURL)
        guard let asset = snapshot.metadata.installedSkills.first(where: {
            $0.assetID == relation.assetID
        }) else {
            throw SkillsHubLibraryFailure.missingSkill(relation.assetID.uuidString)
        }
        let evidence = snapshot.metadata.managedRelationEvidence.first { $0.relation == relation }
        let inspection = try inspector.inspect(
            linkURL: linkURL,
            relation: relation,
            canonicalTargetPath: asset.installedPath,
            evidence: evidence
        )
        return try tokenBuilder.facts(
            relation: relation,
            rootURL: rootURL,
            rootSessionOwner: rootSessionOwner,
            snapshot: snapshot,
            asset: asset,
            qualification: try targetAccess.revalidatedQualification(),
            observation: inspection.observation,
            ownership: inspection.classification,
            currentIntent: currentIntent(in: snapshot, relation: relation)
        )
    }

    func execute(
        authorization: RelationActionAuthorization,
        rootURL: URL,
        targetAccess: AgentTargetAccess
    ) -> RelationActionExecutionResult {
        executor.execute(authorization: authorization, rootURL: rootURL, currentInstallation: { nil })
    }

    func recoverCurrentFacts(operationID: UUID, rootURL: URL) -> RelationActionRecoveryResult {
        executor.recover(
            operationID: operationID,
            rootURL: rootURL,
            currentInstallation: { nil },
            recordObservation: false
        )
    }

    func prepareBrokenLinkDeletionPlan(
        actionID: UUID,
        rootURL: URL,
        rootSessionOwner: SecurityScopedAccessOwner,
        agentID: String,
        agentDisplayName: String,
        targetAccess: AgentTargetAccess,
        linkURL: URL
    ) throws -> BrokenLinkDeletionPlan {
        let facts = try currentBrokenLinkDeletionFacts(
            rootURL: rootURL,
            rootSessionOwner: rootSessionOwner,
            agentID: agentID,
            agentDisplayName: agentDisplayName,
            targetAccess: targetAccess,
            linkURL: linkURL
        )
        return BrokenLinkDeletionPlan(
            actionID: actionID,
            facts: facts,
            factsDigest: brokenLinkTokenBuilder.digest(of: facts)
        )
    }

    func currentBrokenLinkDeletionFacts(
        rootURL: URL,
        rootSessionOwner: SecurityScopedAccessOwner,
        agentID: String,
        agentDisplayName: String,
        targetAccess: AgentTargetAccess,
        linkURL: URL
    ) throws -> BrokenLinkDeletionFacts {
        try brokenLinkInspector.facts(
            rootURL: rootURL,
            rootSessionOwner: rootSessionOwner,
            agentID: agentID,
            agentDisplayName: agentDisplayName,
            qualification: try targetAccess.revalidatedQualification(),
            linkURL: linkURL
        )
    }

    func brokenLinkDeletionToken(
        confirmedPlan: BrokenLinkDeletionPlan,
        targetAccess: AgentTargetAccess
    ) throws -> BrokenLinkDeletionToken {
        try brokenLinkTokenBuilder.token(confirmedPlan: confirmedPlan, targetAccess: targetAccess)
    }

    func executeBrokenLinkDeletion(
        authorization: BrokenLinkDeletionAuthorization,
        rootURL: URL
    ) -> BrokenLinkDeletionExecutionResult {
        executor.executeBrokenLinkDeletion(authorization: authorization, rootURL: rootURL)
    }

    func refreshVerification(
        relation: AgentRelationIdentity,
        rootURL: URL,
        rootSessionOwner: SecurityScopedAccessOwner,
        targetAccess: AgentTargetAccess,
        linkURL: URL
    ) throws -> VerificationRecord {
        let snapshot = try metadataStore.loadCurrentSnapshot(from: rootURL)
        guard let asset = snapshot.metadata.installedSkills.first(where: {
            $0.assetID == relation.assetID
        }) else {
            throw SkillsHubLibraryFailure.missingSkill(relation.assetID.uuidString)
        }
        guard let intent = currentIntent(in: snapshot, relation: relation) else {
            throw SkillsHubLibraryFailure.invalidSource("Relation intent is missing.")
        }
        let localState = try localStateStore.load(from: rootURL)
        let evidence = snapshot.metadata.managedRelationEvidence.first { $0.relation == relation }
        let inspection = try inspector.inspect(
            linkURL: linkURL,
            relation: relation,
            canonicalTargetPath: asset.installedPath,
            evidence: evidence
        )
        let facts = try tokenBuilder.facts(
            relation: relation,
            rootURL: rootURL,
            rootSessionOwner: rootSessionOwner,
            snapshot: snapshot,
            asset: asset,
            qualification: try targetAccess.revalidatedQualification(),
            observation: inspection.observation,
            ownership: inspection.classification,
            currentIntent: intent
        )
        let verification = RelationVerifier.verify(
            actionFacts: facts,
            rootGeneration: snapshot.generation,
            intent: intent,
            observation: inspection.observation,
            evidence: evidence,
            limitations: []
        )
        let next = localState.replacingRelationState(
            relation,
            observation: inspection.observation,
            evidence: evidence,
            verification: verification
        )
        try localStateStore.save(next, to: rootURL)
        return verification
    }

    private func currentIntent(
        in snapshot: RootSnapshot,
        relation: AgentRelationIdentity
    ) -> EnablementIntent? {
        snapshot.metadata.enablementIntents.first {
            $0.assetID == relation.assetID
                && $0.agentID == relation.agentID
                && $0.scope == relation.scope
        }
    }
}
