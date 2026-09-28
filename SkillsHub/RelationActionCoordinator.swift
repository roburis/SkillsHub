import Foundation

nonisolated struct RelationActionFacts: Codable, Hashable, Sendable {
    var relation: AgentRelationIdentity
    var rootPath: String
    var rootSessionOwnerIdentity: String
    var metadataGeneration: UInt64
    var metadataDigest: String
    var metadataFileIdentity: TargetFileIdentity?
    var metadataParentIdentity: TargetFileIdentity?
    var assetID: UUID
    var assetRevision: String?
    var assetManifestDigest: String?
    var assetValidationStatus: SkillValidationStatus?
    var canonicalPath: String
    var profileID: String
    var profileVersion: Int
    var profileSchemaVersion: Int
    var agentDetected: Bool
    var targetPath: String
    var authorizationFingerprint: String
    var linkPath: String
    var nodeKind: TargetNodeKind
    var nodeFingerprint: String?
    var linkText: String?
    var resolvedTargetPath: String?
    var targetIsReadable: Bool
    var targetIsWritable: Bool
    var observationLimitation: String?
    var observationDigest: String
    var ownership: RelationOwnershipClassification
    var currentIntent: EnablementIntent?
}

nonisolated struct RelationActionToken: Hashable, Sendable {
    let actionID: UUID
    let relation: AgentRelationIdentity
    let desiredEnabled: Bool
    let facts: RelationActionFacts
    let factsDigest: String
    let targetLeaseOwnerIdentity: String
    let tokenDigest: String

    fileprivate init(
        actionID: UUID,
        desiredEnabled: Bool,
        facts: RelationActionFacts,
        factsDigest: String,
        targetLeaseOwnerIdentity: String,
        tokenDigest: String
    ) {
        self.actionID = actionID
        self.relation = facts.relation
        self.desiredEnabled = desiredEnabled
        self.facts = facts
        self.factsDigest = factsDigest
        self.targetLeaseOwnerIdentity = targetLeaseOwnerIdentity
        self.tokenDigest = tokenDigest
    }
}

nonisolated enum RelationActionTokenBuildError: Error, Equatable, Sendable {
    case invalidRootSessionOwner
    case rootSnapshotMismatch
    case assetSnapshotMismatch
    case relationAssetMismatch
    case relationAgentMismatch
    case relationScopeMismatch
    case targetQualificationInvalid
    case targetUnavailable
    case invalidSkillFormat
    case observationRelationMismatch
    case currentIntentRelationMismatch
    case intentSnapshotMismatch
    case targetLeaseOwnerMismatch
}

nonisolated struct RelationActionTokenBuilder: Sendable {
    func build(
        actionID: UUID,
        desiredEnabled: Bool,
        relation: AgentRelationIdentity,
        rootURL: URL,
        rootSessionOwner: SecurityScopedAccessOwner,
        snapshot: RootSnapshot,
        asset: InstalledSkill,
        targetAccess: AgentTargetAccess,
        observation: TargetObservation,
        ownership: RelationOwnershipClassification,
        currentIntent: EnablementIntent?
    ) throws -> RelationActionToken {
        do {
            let currentFacts = try facts(
                relation: relation,
                rootURL: rootURL,
                rootSessionOwner: rootSessionOwner,
                snapshot: snapshot,
                asset: asset,
                qualification: try targetAccess.revalidatedQualification(),
                observation: observation,
                ownership: ownership,
                currentIntent: currentIntent
            )
            return try token(
                actionID: actionID,
                desiredEnabled: desiredEnabled,
                facts: currentFacts,
                targetAccess: targetAccess
            )
        } catch {
            _ = targetAccess.endByOwningAction()
            throw error
        }
    }

    func facts(
        relation: AgentRelationIdentity,
        rootURL: URL,
        rootSessionOwner: SecurityScopedAccessOwner,
        snapshot: RootSnapshot,
        asset: InstalledSkill,
        qualification: AgentTargetQualification,
        observation: TargetObservation,
        ownership: RelationOwnershipClassification,
        currentIntent: EnablementIntent?
    ) throws -> RelationActionFacts {
        guard case .rootSession = rootSessionOwner else {
            throw RelationActionTokenBuildError.invalidRootSessionOwner
        }
        let normalizedRootPath = rootURL.standardizedFileURL.path
        guard URL(fileURLWithPath: snapshot.metadata.rootConfig.rootPath).standardizedFileURL.path == normalizedRootPath,
              snapshot.metadata.generation == snapshot.generation else {
            throw RelationActionTokenBuildError.rootSnapshotMismatch
        }
        guard asset.assetID == relation.assetID else {
            throw RelationActionTokenBuildError.relationAssetMismatch
        }
        guard snapshot.metadata.installedSkills.first(where: { $0.assetID == relation.assetID }) == asset else {
            throw RelationActionTokenBuildError.assetSnapshotMismatch
        }
        guard qualification.agentID == relation.agentID else {
            throw RelationActionTokenBuildError.relationAgentMismatch
        }
        guard qualification.scope == relation.scope, relation.scope == .global else {
            throw RelationActionTokenBuildError.relationScopeMismatch
        }
        guard qualification.allowsManagedWrite,
              qualification.authorizationStatus == .current,
              let profileID = qualification.profileID,
              let profileVersion = qualification.profileVersion,
              let schemaVersion = qualification.schemaVersion,
              let target = qualification.target else {
            throw RelationActionTokenBuildError.targetQualificationInvalid
        }
        if let agent = qualification.agent {
            guard let currentProfile = AgentCapabilityProfileRegistry.builtIn.profile(
                for: agent,
                scope: qualification.scope
            ),
            currentProfile.profileID == profileID,
            currentProfile.profileVersion == profileVersion,
            currentProfile.schemaVersion == schemaVersion else {
                throw RelationActionTokenBuildError.targetQualificationInvalid
            }
        } else {
            guard profileID == "skillshub.agent-profile.custom.global@1",
                  profileVersion == 1,
                  schemaVersion == AgentCapabilityProfileRegistry.currentSchemaVersion else {
                throw RelationActionTokenBuildError.targetQualificationInvalid
            }
        }
        guard observation.relation == relation else {
            throw RelationActionTokenBuildError.observationRelationMismatch
        }
        if let currentIntent,
           AgentRelationIdentity(
               assetID: currentIntent.assetID,
               agentID: currentIntent.agentID,
               scope: currentIntent.scope
           ) != relation {
            throw RelationActionTokenBuildError.currentIntentRelationMismatch
        }
        let snapshotIntent = snapshot.metadata.enablementIntents.first { intent in
            intent.assetID == relation.assetID
                && intent.agentID == relation.agentID
                && intent.scope == relation.scope
        }
        guard snapshotIntent == currentIntent else {
            throw RelationActionTokenBuildError.intentSnapshotMismatch
        }

        let normalizedTarget = target.standardizedFileURL.path
        return RelationActionFacts(
            relation: relation,
            rootPath: normalizedRootPath,
            rootSessionOwnerIdentity: rootSessionOwner.identity,
            metadataGeneration: snapshot.generation,
            metadataDigest: snapshot.metadataDigest,
            metadataFileIdentity: snapshot.metadataFileIdentity,
            metadataParentIdentity: snapshot.metadataParentIdentity,
            assetID: asset.assetID,
            assetRevision: asset.currentRevision,
            assetManifestDigest: asset.manifestDigest,
            assetValidationStatus: asset.validation.status,
            canonicalPath: URL(fileURLWithPath: asset.installedPath).standardizedFileURL.path,
            profileID: profileID,
            profileVersion: profileVersion,
            profileSchemaVersion: schemaVersion,
            agentDetected: true,
            targetPath: normalizedTarget,
            authorizationFingerprint: SHA256Digest.hex(Data("current|\(normalizedTarget)".utf8)),
            linkPath: observation.linkPath,
            nodeKind: observation.nodeKind,
            nodeFingerprint: observation.fileIdentity?.fingerprint,
            linkText: observation.linkText,
            resolvedTargetPath: observation.resolvedTargetPath,
            targetIsReadable: observation.isReadable,
            targetIsWritable: observation.isWritable,
            observationLimitation: observation.limitation,
            observationDigest: observationDigest(of: observation),
            ownership: ownership,
            currentIntent: currentIntent
        )
    }

    private func token(
        actionID: UUID,
        desiredEnabled: Bool,
        facts: RelationActionFacts,
        targetAccess: AgentTargetAccess
    ) throws -> RelationActionToken {
        let isReadOnlyNoChange = desiredEnabled
            && facts.ownership == .exactManagedLink
            && facts.currentIntent?.isEnabled == true
        guard facts.targetIsReadable,
              facts.targetIsWritable || isReadOnlyNoChange,
              facts.observationLimitation == nil else {
            throw RelationActionTokenBuildError.targetUnavailable
        }
        if desiredEnabled,
           facts.ownership != .exactManagedLink,
           facts.assetValidationStatus == .invalid {
            throw RelationActionTokenBuildError.invalidSkillFormat
        }
        let expectedOwner = targetAccess.qualification.agent.map {
            SecurityScopedAccessOwner.agentTarget(actionID: actionID, agent: $0)
        } ?? SecurityScopedAccessOwner.configuredAgentTarget(
            actionID: actionID,
            agentID: targetAccess.qualification.agentID
        )
        guard targetAccess.owner == expectedOwner,
              targetAccess.qualification.agentID == facts.relation.agentID,
              targetAccess.qualification.scope == facts.relation.scope,
              targetAccess.qualification.target?.standardizedFileURL.path == facts.targetPath else {
            throw RelationActionTokenBuildError.targetLeaseOwnerMismatch
        }
        let factsDigest = digest(of: facts)
        let ownerIdentity = targetAccess.owner.identity
        return RelationActionToken(
            actionID: actionID,
            desiredEnabled: desiredEnabled,
            facts: facts,
            factsDigest: factsDigest,
            targetLeaseOwnerIdentity: ownerIdentity,
            tokenDigest: tokenDigest(
                actionID: actionID,
                desiredEnabled: desiredEnabled,
                factsDigest: factsDigest,
                targetLeaseOwnerIdentity: ownerIdentity
            )
        )
    }

    func digest(of facts: RelationActionFacts) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256Digest.hex((try? encoder.encode(facts)) ?? Data())
    }

    func observationDigest(of observation: TargetObservation) -> String {
        let facts = RelationActionObservedNodeFacts(
            relation: observation.relation,
            linkPath: observation.linkPath,
            nodeKind: observation.nodeKind,
            linkText: observation.linkText,
            resolvedTargetPath: observation.resolvedTargetPath,
            nodeFingerprint: observation.fileIdentity?.fingerprint,
            isReadable: observation.isReadable,
            isWritable: observation.isWritable,
            limitation: observation.limitation,
            nodeIdentity: observation.nodeIdentity,
            parentIdentity: observation.parentIdentity
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256Digest.hex((try? encoder.encode(facts)) ?? Data())
    }

    func tokenDigest(
        actionID: UUID,
        desiredEnabled: Bool,
        factsDigest: String,
        targetLeaseOwnerIdentity: String
    ) -> String {
        let payload = RelationActionTokenDigestPayload(
            actionID: actionID,
            desiredEnabled: desiredEnabled,
            factsDigest: factsDigest,
            targetLeaseOwnerIdentity: targetLeaseOwnerIdentity
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256Digest.hex((try? encoder.encode(payload)) ?? Data())
    }
}

nonisolated private struct RelationActionObservedNodeFacts: Codable {
    let relation: AgentRelationIdentity
    let linkPath: String
    let nodeKind: TargetNodeKind
    let linkText: String?
    let resolvedTargetPath: String?
    let nodeFingerprint: String?
    let isReadable: Bool
    let isWritable: Bool
    let limitation: String?
    let nodeIdentity: LinkNodeIdentity?
    let parentIdentity: LinkNodeIdentity?
}

nonisolated private struct RelationActionTokenDigestPayload: Codable {
    let actionID: UUID
    let desiredEnabled: Bool
    let factsDigest: String
    let targetLeaseOwnerIdentity: String
}

nonisolated struct RelationActionAuthorization: Hashable, Sendable {
    let actionID: UUID
    let relation: AgentRelationIdentity
    let desiredEnabled: Bool
    let facts: RelationActionFacts
    let factsDigest: String
    let tokenDigest: String
}

nonisolated struct BrokenLinkDeletionFacts: Codable, Hashable, Sendable {
    let rootPath: String
    let rootSessionOwnerIdentity: String
    let rootIdentity: LinkNodeIdentity
    let agentID: String
    let agentDisplayName: String
    let authorizedDirectoryPath: String
    let parentIdentity: LinkNodeIdentity
    let linkPath: String
    let nodeIdentity: LinkNodeIdentity
    let rawTarget: String
    let resolvedTargetPath: String
}

nonisolated struct BrokenLinkDeletionPlan: Hashable, Identifiable, Sendable {
    let actionID: UUID
    let facts: BrokenLinkDeletionFacts
    let factsDigest: String

    var id: UUID { actionID }
}

nonisolated struct BrokenLinkDeletionToken: Hashable, Sendable {
    let plan: BrokenLinkDeletionPlan
    let targetLeaseOwnerIdentity: String
}

nonisolated struct BrokenLinkDeletionAuthorization: Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case confirmedBrokenLink = "confirmed-broken-link"
    }

    let kind: Kind
    let actionID: UUID
    let facts: BrokenLinkDeletionFacts
    let factsDigest: String
}

nonisolated enum BrokenLinkDeletionError: Error, Equatable, Sendable {
    case invalidRootSession
    case invalidAgentTarget
    case invalidLinkPath
    case notSymbolicLink
    case targetExists
    case targetStatusUnknown(Int32)
    case confirmedFactsChanged
}

nonisolated struct BrokenLinkDeletionTokenBuilder: Sendable {
    func digest(of facts: BrokenLinkDeletionFacts) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256Digest.hex((try? encoder.encode(facts)) ?? Data())
    }

    func token(
        confirmedPlan: BrokenLinkDeletionPlan,
        targetAccess: AgentTargetAccess
    ) throws -> BrokenLinkDeletionToken {
        let qualification = try targetAccess.revalidatedQualification()
        guard qualification.agentID == confirmedPlan.facts.agentID,
              qualification.scope == .global,
              qualification.authorizationStatus == .current,
              qualification.allowsManagedWrite,
              qualification.target?.standardizedFileURL.path == confirmedPlan.facts.authorizedDirectoryPath,
              digest(of: confirmedPlan.facts) == confirmedPlan.factsDigest else {
            throw BrokenLinkDeletionError.invalidAgentTarget
        }
        return BrokenLinkDeletionToken(
            plan: confirmedPlan,
            targetLeaseOwnerIdentity: targetAccess.owner.identity
        )
    }
}

nonisolated enum RelationActionStaleReason: Equatable, Sendable {
    case relationChanged
    case rootSessionInvalidated
    case metadataGenerationChanged
    case metadataDigestChanged
    case factsChanged
}

nonisolated enum RelationActionBlockReason: Equatable, Sendable {
    case targetLeaseOwnerMismatch
    case targetLeaseFactsMismatch
}

nonisolated enum RelationActionOutcome<Success: Sendable>: Sendable {
    case completed(Success)
    case replayed
    case stale(RelationActionStaleReason)
    case blocked(RelationActionBlockReason)
    case cancelled
    case failed
}

extension RelationActionOutcome: Equatable where Success: Equatable {}

nonisolated struct RelationActionCoordinationResult<Success: Sendable>: Sendable {
    let outcome: RelationActionOutcome<Success>
    let leaseRelease: SecurityScopedAccessEndResult
}

actor RelationActionCoordinator {
    private let rootMutationOwner: RootMutationOwner
    private var consumedActionIDs: Set<UUID> = []

    init(rootMutationOwner: RootMutationOwner = .shared) {
        self.rootMutationOwner = rootMutationOwner
    }

    func coordinate<Success: Sendable>(
        token: RelationActionToken,
        rootURL: URL,
        targetAccess: AgentTargetAccess,
        currentFacts: @Sendable () async throws -> RelationActionFacts,
        perform: @Sendable (RelationActionAuthorization) async throws -> Success
    ) async -> RelationActionCoordinationResult<Success> {
        let outcome: RelationActionOutcome<Success>
        if consumedActionIDs.insert(token.actionID).inserted == false {
            outcome = .replayed
        } else if targetAccess.owner.identity != token.targetLeaseOwnerIdentity {
            outcome = .blocked(.targetLeaseOwnerMismatch)
        } else if Self.targetAccessMatches(token: token, targetAccess: targetAccess) == false {
            outcome = .blocked(.targetLeaseFactsMismatch)
        } else if rootURL.standardizedFileURL.path != token.facts.rootPath {
            outcome = .stale(.rootSessionInvalidated)
        } else {
            outcome = await rootMutationOwner.perform(at: rootURL) {
                do {
                    try Task.checkCancellation()
                    let current = try await currentFacts()
                    guard let staleReason = Self.staleReason(token: token, current: current) else {
                        let authorization = RelationActionAuthorization(
                            actionID: token.actionID,
                            relation: token.relation,
                            desiredEnabled: token.desiredEnabled,
                            facts: current,
                            factsDigest: token.factsDigest,
                            tokenDigest: token.tokenDigest
                        )
                        return .completed(try await perform(authorization))
                    }
                    return .stale(staleReason)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed
                }
            }
        }
        return RelationActionCoordinationResult(
            outcome: outcome,
            leaseRelease: targetAccess.endByOwningAction()
        )
    }

    func coordinate<Success: Sendable>(
        token: BrokenLinkDeletionToken,
        rootURL: URL,
        targetAccess: AgentTargetAccess,
        currentFacts: @Sendable () async throws -> BrokenLinkDeletionFacts,
        perform: @Sendable (BrokenLinkDeletionAuthorization) async throws -> Success
    ) async -> RelationActionCoordinationResult<Success> {
        let outcome: RelationActionOutcome<Success>
        if consumedActionIDs.insert(token.plan.actionID).inserted == false {
            outcome = .replayed
        } else if targetAccess.owner.identity != token.targetLeaseOwnerIdentity {
            outcome = .blocked(.targetLeaseOwnerMismatch)
        } else if rootURL.standardizedFileURL.path != token.plan.facts.rootPath {
            outcome = .stale(.rootSessionInvalidated)
        } else {
            outcome = await rootMutationOwner.perform(at: rootURL) {
                do {
                    try Task.checkCancellation()
                    let current = try await currentFacts()
                    guard current == token.plan.facts,
                          BrokenLinkDeletionTokenBuilder().digest(of: current) == token.plan.factsDigest else {
                        return .stale(.factsChanged)
                    }
                    return .completed(try await perform(BrokenLinkDeletionAuthorization(
                        kind: .confirmedBrokenLink,
                        actionID: token.plan.actionID,
                        facts: current,
                        factsDigest: token.plan.factsDigest
                    )))
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed
                }
            }
        }
        return RelationActionCoordinationResult(
            outcome: outcome,
            leaseRelease: targetAccess.endByOwningAction()
        )
    }

    private static func staleReason(
        token: RelationActionToken,
        current: RelationActionFacts
    ) -> RelationActionStaleReason? {
        guard current.relation == token.relation else { return .relationChanged }
        guard current.rootPath == token.facts.rootPath,
              current.rootSessionOwnerIdentity == token.facts.rootSessionOwnerIdentity else {
            return .rootSessionInvalidated
        }
        guard current.metadataGeneration == token.facts.metadataGeneration else {
            return .metadataGenerationChanged
        }
        guard current.metadataDigest == token.facts.metadataDigest else {
            return .metadataDigestChanged
        }
        guard current == token.facts,
              RelationActionTokenBuilder().digest(of: current) == token.factsDigest else {
            return .factsChanged
        }
        return nil
    }

    private static func targetAccessMatches(
        token: RelationActionToken,
        targetAccess: AgentTargetAccess
    ) -> Bool {
        let qualification = targetAccess.qualification
        return qualification.agentID == token.relation.agentID
            && qualification.scope == token.relation.scope
            && qualification.profileID == token.facts.profileID
            && qualification.profileVersion == token.facts.profileVersion
            && qualification.schemaVersion == token.facts.profileSchemaVersion
            && qualification.authorizationStatus == .current
            && qualification.allowsManagedWrite
            && qualification.target?.standardizedFileURL.path == token.facts.targetPath
    }
}
