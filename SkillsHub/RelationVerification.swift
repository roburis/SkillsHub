import Darwin
import Foundation

nonisolated enum RelationOwnershipClassification: String, Codable, Hashable, Sendable {
    case vacant
    case exactManagedLink = "exact-managed-link"
    case unmanagedNode = "unmanaged-node"
    case externalLink = "external-link"
    case brokenLink = "broken-link"
    case unreadable
}

nonisolated struct RelationOwnershipInspection: Hashable, Sendable {
    var observation: TargetObservation
    var classification: RelationOwnershipClassification
}

nonisolated struct RelationVerificationInput: Hashable, Sendable {
    var relation: AgentRelationIdentity
    var bindings: RelationVerificationBindings
    var observation: TargetObservation?
    var limitations: [String]
}

nonisolated struct RelationOwnershipInspector: Sendable {
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func inspect(
        linkURL: URL,
        relation: AgentRelationIdentity,
        canonicalTargetPath: String
    ) throws -> RelationOwnershipInspection {
        let linkPath = linkURL.standardizedFileURL.path
        var status = stat()
        let result = linkPath.withCString { Darwin.lstat($0, &status) }

        guard result == 0 else {
            let errorNumber = errno
            if errorNumber == ENOENT || errorNumber == ENOTDIR {
                let parentPath = linkURL.deletingLastPathComponent().standardizedFileURL.path
                var observation = TargetObservation(
                    relation: relation,
                    linkPath: linkPath,
                    nodeKind: .vacant,
                    linkText: nil,
                    resolvedTargetPath: nil,
                    fileIdentity: nil,
                    isReadable: FileManager.default.isReadableFile(atPath: parentPath),
                    isWritable: FileManager.default.isWritableFile(atPath: parentPath),
                    observedAt: now(),
                    limitation: nil
                )
                observation.parentIdentity = try? LinkNodeIdentity.read(at: linkURL.deletingLastPathComponent())
                return RelationOwnershipInspection(observation: observation, classification: .vacant)
            }

            let limitation = String(cString: strerror(errorNumber))
            let observation = TargetObservation(
                relation: relation,
                linkPath: linkPath,
                nodeKind: .unreadable,
                linkText: nil,
                resolvedTargetPath: nil,
                fileIdentity: nil,
                isReadable: false,
                isWritable: false,
                observedAt: now(),
                limitation: limitation
            )
            return RelationOwnershipInspection(observation: observation, classification: .unreadable)
        }

        let fileIdentity = TargetFileIdentity(
            volumeNumber: UInt64(status.st_dev),
            fileNumber: UInt64(status.st_ino)
        )
        let nodeIdentity = LinkNodeIdentity(status)
        let parentIdentity = try? LinkNodeIdentity.read(at: linkURL.deletingLastPathComponent())
        let fileType = status.st_mode & mode_t(S_IFMT)
        let nodeKind: TargetNodeKind
        var linkText: String?
        var resolvedTargetPath: String?
        var limitation: String?

        switch fileType {
        case mode_t(S_IFLNK):
            do {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
                linkText = destination
                let targetURL = Self.resolvedTargetURL(linkText: destination, linkURL: linkURL)
                switch Self.probeTarget(atPath: targetURL.path) {
                case .exists:
                    nodeKind = .symbolicLink
                    resolvedTargetPath = targetURL.resolvingSymlinksInPath().standardizedFileURL.path
                case .missing:
                    nodeKind = .brokenSymbolicLink
                    resolvedTargetPath = targetURL.standardizedFileURL.path
                case .unreadable(let errorNumber):
                    nodeKind = .unreadable
                    resolvedTargetPath = targetURL.standardizedFileURL.path
                    limitation = String(cString: strerror(errorNumber))
                }
            } catch {
                nodeKind = .unreadable
                limitation = error.localizedDescription
            }
        case mode_t(S_IFDIR):
            nodeKind = .directory
        case mode_t(S_IFREG):
            nodeKind = .regularFile
        default:
            nodeKind = .other
        }

        let permissionPath: String
        switch nodeKind {
        case .symbolicLink, .brokenSymbolicLink:
            permissionPath = linkURL.deletingLastPathComponent().standardizedFileURL.path
        case .vacant, .directory, .regularFile, .other, .unreadable:
            permissionPath = linkPath
        }
        var observation = TargetObservation(
            relation: relation,
            linkPath: linkPath,
            nodeKind: nodeKind,
            linkText: linkText,
            resolvedTargetPath: resolvedTargetPath,
            fileIdentity: fileIdentity,
            isReadable: limitation == nil && FileManager.default.isReadableFile(atPath: permissionPath),
            isWritable: limitation == nil && FileManager.default.isWritableFile(atPath: permissionPath),
            observedAt: now(),
            limitation: limitation
        )
        observation.nodeIdentity = nodeIdentity
        observation.parentIdentity = parentIdentity
        if (try? LinkNodeIdentity.read(at: linkURL)) != nodeIdentity
            || (try? LinkNodeIdentity.read(at: linkURL.deletingLastPathComponent())) != parentIdentity {
            observation.limitation = "node-or-parent-changed-during-observation"
        }
        return RelationOwnershipInspection(
            observation: observation,
            classification: Self.classify(
                observation: observation,
                expectedLinkPath: linkPath,
                canonicalTargetPath: canonicalTargetPath
            )
        )
    }

    static func classify(
        observation: TargetObservation,
        expectedLinkPath: String,
        canonicalTargetPath: String
    ) -> RelationOwnershipClassification {
        switch observation.nodeKind {
        case .vacant:
            return .vacant
        case .unreadable:
            return .unreadable
        case .directory, .regularFile, .other:
            return .unmanagedNode
        case .symbolicLink, .brokenSymbolicLink:
            guard
                observation.limitation == nil,
                observation.isReadable,
                URL(fileURLWithPath: observation.linkPath).standardizedFileURL.path
                    == URL(fileURLWithPath: expectedLinkPath).standardizedFileURL.path,
                observation.resolvedTargetPath.map(Self.canonicalizedPath) == Self.canonicalizedPath(canonicalTargetPath)
            else {
                return observation.nodeKind == .brokenSymbolicLink ? .brokenLink : .externalLink
            }
            return .exactManagedLink
        }
    }

    private static func resolvedTargetURL(linkText: String, linkURL: URL) -> URL {
        if linkText.hasPrefix("/") {
            return URL(fileURLWithPath: linkText)
        }
        return linkURL.deletingLastPathComponent().appendingPathComponent(linkText)
    }

    private enum TargetProbe {
        case exists
        case missing
        case unreadable(Int32)
    }

    private static func probeTarget(atPath path: String) -> TargetProbe {
        let result = path.withCString { Darwin.access($0, F_OK) }
        guard result != 0 else { return .exists }

        let errorNumber = errno
        if errorNumber == ENOENT || errorNumber == ENOTDIR || errorNumber == ELOOP {
            return .missing
        }
        return .unreadable(errorNumber)
    }

    private static func canonicalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

nonisolated enum RelationVerifier {
    static func verify(
        actionFacts facts: RelationActionFacts,
        rootGeneration: UInt64,
        intent: EnablementIntent,
        observation: TargetObservation,
        limitations: [String]
    ) -> VerificationRecord {
        let bindings = RelationVerificationBindings(
            rootGeneration: rootGeneration,
            assetRevision: facts.assetRevision,
            manifestDigest: facts.assetManifestDigest,
            canonicalPath: facts.canonicalPath,
            canonicalPathFingerprint: SHA256Digest.hex(Data(facts.canonicalPath.utf8)),
            profileID: facts.profileID,
            profileVersion: facts.profileVersion,
            profileSchemaVersion: facts.profileSchemaVersion,
            profileIsValid: true,
            agentExists: facts.agentDetected,
            globalTargetPath: facts.targetPath,
            authorizationFingerprint: facts.authorizationFingerprint,
            targetIsAuthorized: true,
            isReadable: observation.isReadable,
            isWritable: observation.isWritable,
            linkPath: observation.linkPath,
            nodeKind: observation.nodeKind,
            nodeFingerprint: observation.fileIdentity?.fingerprint,
            linkText: observation.linkText,
            resolvedTargetPath: observation.resolvedTargetPath,
            observationDigest: observation.digest,
            enablementIntent: intent
        )
        return verify(
            RelationVerificationInput(
                relation: facts.relation,
                bindings: bindings,
                observation: observation,
                limitations: limitations
            )
        )
    }

    static func verify(_ input: RelationVerificationInput) -> VerificationRecord {
        let conclusion: VerificationConclusion
        let limitations = combinedLimitations(for: input)

        if input.observation == nil {
            conclusion = .notVerified
        } else if !limitations.isEmpty || !hasCompleteCurrentFacts(input) {
            conclusion = .currentlyUnverifiable
        } else {
            conclusion = conclusionFromCompleteFacts(input)
        }

        return VerificationRecord(
            relation: input.relation,
            conclusion: conclusion,
            bindings: input.bindings,
            factsDigest: input.bindings.digest,
            observedAt: input.observation?.observedAt ?? .distantPast,
            limitations: limitations,
            safeNextStep: safeNextStep(for: conclusion)
        )
    }

    static func consume(
        _ record: VerificationRecord,
        against input: RelationVerificationInput
    ) -> VerificationConclusion {
        let current = verify(input)
        guard
            record.relation == input.relation,
            record.factsDigest == record.bindings.digest,
            record.bindings == input.bindings,
            record.factsDigest == current.factsDigest,
            record.conclusion == current.conclusion
        else {
            return current.conclusion == .verifiedConsistent ? .notVerified : current.conclusion
        }
        return record.conclusion
    }

    private static func hasCompleteCurrentFacts(_ input: RelationVerificationInput) -> Bool {
        guard
            input.bindings.profileIsValid,
            input.bindings.agentExists,
            input.bindings.targetIsAuthorized,
            input.bindings.isReadable,
            input.bindings.isWritable,
            let observation = input.observation,
            observation.relation == input.relation,
            input.relation.scope == .global,
            input.bindings.enablementIntent.assetID == input.relation.assetID,
            input.bindings.enablementIntent.agentID == input.relation.agentID,
            input.bindings.enablementIntent.scope == input.relation.scope,
            input.bindings.enablementIntent.generation <= input.bindings.rootGeneration,
            Self.standardizedPath(observation.linkPath) == Self.standardizedPath(input.bindings.linkPath),
            Self.standardizedPath(input.bindings.globalTargetPath)
                == Self.standardizedPath(URL(fileURLWithPath: input.bindings.linkPath).deletingLastPathComponent().path),
            observation.nodeKind == input.bindings.nodeKind,
            observation.fileIdentity?.fingerprint == input.bindings.nodeFingerprint,
            observation.linkText == input.bindings.linkText,
            observation.resolvedTargetPath == input.bindings.resolvedTargetPath,
            observation.digest == input.bindings.observationDigest,
            observation.isReadable == input.bindings.isReadable,
            observation.isWritable == input.bindings.isWritable
        else {
            return false
        }
        return true
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func conclusionFromCompleteFacts(
        _ input: RelationVerificationInput
    ) -> VerificationConclusion {
        guard let observation = input.observation else { return .notVerified }
        let classification = RelationOwnershipInspector.classify(
            observation: observation,
            expectedLinkPath: input.bindings.linkPath,
            canonicalTargetPath: input.bindings.canonicalPath
        )

        if input.bindings.enablementIntent.isEnabled {
            guard
                classification == .exactManagedLink,
                observation.nodeKind == .symbolicLink
            else {
                return .drifted
            }
            return .verifiedConsistent
        }

        return classification == .exactManagedLink ? .drifted : .verifiedConsistent
    }

    private static func combinedLimitations(for input: RelationVerificationInput) -> [String] {
        var limitations = input.limitations
        if let limitation = input.observation?.limitation, !limitations.contains(limitation) {
            limitations.append(limitation)
        }
        return limitations
    }

    private static func safeNextStep(for conclusion: VerificationConclusion) -> String {
        switch conclusion {
        case .notVerified:
            "observe-current-relation"
        case .verifiedConsistent:
            "none"
        case .drifted:
            "review-current-relation"
        case .currentlyUnverifiable:
            "restore-current-access-and-observe"
        }
    }
}

nonisolated extension SkillsHubLocalState {
    func replacingRelationState(
        _ relation: AgentRelationIdentity,
        observation: TargetObservation,
        verification: VerificationRecord
    ) -> SkillsHubLocalState {
        var next = self
        next.targetObservations.removeAll { $0.relation == relation }
        next.targetObservations.append(observation)
        next.verificationRecords.removeAll { $0.relation == relation }
        next.verificationRecords.append(verification)
        next.targetObservations.sort { $0.id < $1.id }
        next.verificationRecords.sort { $0.id < $1.id }
        return next
    }
}
