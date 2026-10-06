import Foundation

nonisolated enum SkillSourceKind: String, Codable, CaseIterable, Hashable {
    case githubRepository
    case npmPackage
    case localDirectory
    case manualFilesystem
}

nonisolated enum GitHubSourceMode: String, Codable, CaseIterable, Hashable {
    case single
    case collection
    case mixed
    case unknown
}

nonisolated enum SkillValidationStatus: String, Codable, Hashable {
    case valid
    case warning
    case invalid
}

nonisolated enum CandidateCheckStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case valid
    case warning
    case blocked
    case unreadable
}

nonisolated enum SourceRegistrationState: String, Codable, Hashable, Sendable {
    case registered
    case needsAttention
}

nonisolated enum ValidationSeverity: String, Codable, Hashable {
    case warning
    case error
}

nonisolated enum RiskKind: String, Codable, CaseIterable, Hashable {
    case script
    case executable
    case externalURL
    case largeAsset
    case crossDirectoryReference
    case symlink
}

nonisolated enum AgentKind: String, Codable, CaseIterable, Hashable {
    case claudeCode
    case codex
    case cursor
    case hermesAgent
    case geminiCLI
}

nonisolated enum AgentLinkScope: String, Codable, Hashable {
    case global
    case project
}

nonisolated enum PurposeSource: String, Codable, Hashable {
    case generated
    case user
}

nonisolated struct RootConfig: Codable, Hashable, Identifiable {
    var id: UUID
    var rootPath: String
    var appSupportPath: String?
    var languageOverride: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        rootPath: String,
        appSupportPath: String? = nil,
        languageOverride: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.rootPath = rootPath
        self.appSupportPath = appSupportPath
        self.languageOverride = languageOverride
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

nonisolated struct SkillSource: Codable, Hashable, Identifiable {
    var id: UUID
    var kind: SkillSourceKind
    var name: String
    var urlString: String?
    var githubRepositoryID: Int64?
    var ref: String?
    var requestedVersionRange: String?
    var resolvedVersion: String?
    var tarballURLString: String?
    var localPath: String?
    var externalLocalPath: String?
    var sourceMode: GitHubSourceMode?
    var isFullMirrorEnabled: Bool
    var isIndexIncomplete: Bool
    var indexStatusReason: String?
    var contentFingerprint: String?
    var directoryIdentity: TargetFileIdentity?
    var externalDirectoryIdentity: TargetFileIdentity?
    var lastCheckedAt: Date?
    var registrationState: SourceRegistrationState
    // complete last-successful content baseline; nil means the baseline is unknown.
    var baselineManifest: ContentManifest?

    init(
        id: UUID = UUID(),
        kind: SkillSourceKind,
        name: String,
        urlString: String? = nil,
        githubRepositoryID: Int64? = nil,
        ref: String? = nil,
        requestedVersionRange: String? = nil,
        resolvedVersion: String? = nil,
        tarballURLString: String? = nil,
        localPath: String? = nil,
        externalLocalPath: String? = nil,
        sourceMode: GitHubSourceMode? = nil,
        isFullMirrorEnabled: Bool = false,
        isIndexIncomplete: Bool = false,
        indexStatusReason: String? = nil,
        contentFingerprint: String? = nil,
        directoryIdentity: TargetFileIdentity? = nil,
        externalDirectoryIdentity: TargetFileIdentity? = nil,
        lastCheckedAt: Date? = nil,
        registrationState: SourceRegistrationState = .registered,
        baselineManifest: ContentManifest? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.urlString = urlString
        self.githubRepositoryID = githubRepositoryID
        self.ref = ref
        self.requestedVersionRange = requestedVersionRange
        self.resolvedVersion = resolvedVersion
        self.tarballURLString = tarballURLString
        self.localPath = localPath
        self.externalLocalPath = externalLocalPath
        self.sourceMode = sourceMode
        self.isFullMirrorEnabled = isFullMirrorEnabled
        self.isIndexIncomplete = isIndexIncomplete
        self.indexStatusReason = indexStatusReason
        self.contentFingerprint = contentFingerprint
        self.directoryIdentity = directoryIdentity
        self.externalDirectoryIdentity = externalDirectoryIdentity
        self.lastCheckedAt = lastCheckedAt
        self.registrationState = registrationState
        self.baselineManifest = baselineManifest
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, urlString, githubRepositoryID, ref, requestedVersionRange, resolvedVersion
        case tarballURLString, localPath, externalLocalPath, sourceMode, isFullMirrorEnabled
        case isIndexIncomplete, indexStatusReason, contentFingerprint, directoryIdentity, externalDirectoryIdentity, lastCheckedAt
        case registrationState, baselineManifest
    }

}

nonisolated struct AvailableSkill: Codable, Hashable, Identifiable {
    var id: String
    var sourceID: UUID
    var skillPath: String
    var name: String
    var description: String
    var validation: SkillValidationResult
    var candidateID: String
    var manifestDigest: String?
    var checkStatus: CandidateCheckStatus
    var generatedAtGeneration: UInt64

    init(
        id: String,
        sourceID: UUID,
        skillPath: String,
        name: String,
        description: String,
        validation: SkillValidationResult,
        candidateID: String? = nil,
        manifestDigest: String? = nil,
        checkStatus: CandidateCheckStatus? = nil,
        generatedAtGeneration: UInt64 = 0
    ) {
        self.id = id
        self.sourceID = sourceID
        self.skillPath = skillPath
        self.name = name
        self.description = description
        self.validation = validation
        self.candidateID = candidateID ?? UUID().uuidString
        self.manifestDigest = manifestDigest
        self.checkStatus = checkStatus ?? Self.checkStatus(for: validation.status)
        self.generatedAtGeneration = generatedAtGeneration
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceID, skillPath, name, description, validation
        case candidateID, manifestDigest, checkStatus, generatedAtGeneration
    }

    private static func checkStatus(for status: SkillValidationStatus) -> CandidateCheckStatus {
        switch status {
        case .valid: .valid
        case .warning: .warning
        case .invalid: .blocked
        }
    }
}

nonisolated struct InstalledSkill: Codable, Hashable, Identifiable {
    var id: String
    var sourceID: UUID?
    var name: String
    var description: String
    var installedPath: String
    var sourceKind: SkillSourceKind
    var isExternalLink: Bool
    var validation: SkillValidationResult
    var purpose: PurposeMetadata?
    var tagIDs: [String]
    var installedAt: Date
    var assetID: UUID
    var candidateID: String?
    var canonicalPathComponent: String
    var currentRevision: String?
    var manifestDigest: String?
    var managedGeneration: UInt64
    // first-successful stable link name; nil means no link name has been established yet.
    var stableLinkName: String?

    init(
        id: String,
        sourceID: UUID?,
        name: String,
        description: String,
        installedPath: String,
        sourceKind: SkillSourceKind,
        isExternalLink: Bool = false,
        validation: SkillValidationResult,
        purpose: PurposeMetadata?,
        tagIDs: [String],
        installedAt: Date,
        assetID: UUID = UUID(),
        candidateID: String? = nil,
        canonicalPathComponent: String? = nil,
        currentRevision: String? = nil,
        manifestDigest: String? = nil,
        managedGeneration: UInt64 = 0,
        stableLinkName: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.description = description
        self.installedPath = installedPath
        self.sourceKind = sourceKind
        self.isExternalLink = isExternalLink
        self.validation = validation
        self.purpose = purpose
        self.tagIDs = tagIDs
        self.installedAt = installedAt
        self.assetID = assetID
        self.candidateID = candidateID
        self.canonicalPathComponent = canonicalPathComponent ?? URL(fileURLWithPath: installedPath).lastPathComponent
        self.currentRevision = currentRevision
        self.manifestDigest = manifestDigest
        self.managedGeneration = managedGeneration
        self.stableLinkName = stableLinkName
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sourceID
        case name
        case description
        case installedPath
        case sourceKind
        case isExternalLink
        case validation
        case purpose
        case tagIDs
        case installedAt
        case assetID
        case candidateID
        case canonicalPathComponent
        case currentRevision
        case manifestDigest
        case managedGeneration
        case stableLinkName
    }

}

nonisolated struct EnablementIntent: Codable, Hashable, Identifiable, Sendable {
    var assetID: UUID
    var agentID: String
    var scope: AgentLinkScope
    var isEnabled: Bool
    var generation: UInt64

    var id: String { "\(assetID.uuidString)|\(agentID)|\(scope.rawValue)" }
}

nonisolated struct AgentRelationIdentity: Codable, Hashable, Identifiable, Sendable {
    var assetID: UUID
    var agentID: String
    var scope: AgentLinkScope

    var id: String { "\(assetID.uuidString)|\(agentID)|\(scope.rawValue)" }
}

nonisolated enum TargetNodeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case vacant
    case symbolicLink = "symbolic-link"
    case brokenSymbolicLink = "broken-symbolic-link"
    case directory
    case regularFile = "regular-file"
    case other
    case unreadable
}

nonisolated struct TargetFileIdentity: Codable, Hashable, Sendable {
    var volumeNumber: UInt64
    var fileNumber: UInt64

    var fingerprint: String {
        SHA256Digest.hex(Data("\(volumeNumber)|\(fileNumber)".utf8))
    }
}

nonisolated struct TargetObservation: Codable, Hashable, Identifiable, Sendable {
    var relation: AgentRelationIdentity
    var linkPath: String
    var nodeKind: TargetNodeKind
    var linkText: String?
    var resolvedTargetPath: String?
    var fileIdentity: TargetFileIdentity?
    var isReadable: Bool
    var isWritable: Bool
    var observedAt: Date
    var limitation: String?
    var nodeIdentity: LinkNodeIdentity? = nil
    var parentIdentity: LinkNodeIdentity? = nil

    var id: String { relation.id }

    var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return SHA256Digest.hex((try? encoder.encode(self)) ?? Data())
    }
}

nonisolated enum VerificationConclusion: String, Codable, CaseIterable, Hashable, Sendable {
    case notVerified = "not-verified"
    case verifiedConsistent = "verified-consistent"
    case drifted
    case currentlyUnverifiable = "currently-unverifiable"
}

nonisolated struct RelationVerificationBindings: Codable, Hashable, Sendable {
    var rootGeneration: UInt64
    var assetRevision: String?
    var manifestDigest: String?
    var canonicalPath: String
    var canonicalPathFingerprint: String
    var profileID: String
    var profileVersion: Int
    var profileSchemaVersion: Int
    var profileIsValid: Bool
    var agentExists: Bool
    var globalTargetPath: String
    var authorizationFingerprint: String
    var targetIsAuthorized: Bool
    var isReadable: Bool
    var isWritable: Bool
    var linkPath: String
    var nodeKind: TargetNodeKind
    var nodeFingerprint: String?
    var linkText: String?
    var resolvedTargetPath: String?
    var observationDigest: String
    var enablementIntent: EnablementIntent

    var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256Digest.hex((try? encoder.encode(self)) ?? Data())
    }
}

nonisolated struct VerificationRecord: Codable, Hashable, Identifiable, Sendable {
    var relation: AgentRelationIdentity
    var conclusion: VerificationConclusion
    var bindings: RelationVerificationBindings
    var factsDigest: String
    var observedAt: Date
    var limitations: [String]
    var safeNextStep: String

    var id: String { relation.id }
}

nonisolated enum StableIdentity {
    // Source-relative association key; AvailableSkill.candidateID is independently persisted.
    static func candidateID(sourceID: UUID, relativePath: String) -> String {
        "candidate:\(sourceID.uuidString.lowercased()):\(normalizedRelativePath(relativePath))"
    }

    static func uuid(namespace: String, value: String) -> UUID {
        let digest = SHA256Digest.hex(Data("\(namespace)|\(value)".utf8))
        let source = Array(digest.utf8.prefix(32))
        let hex = String(decoding: source, as: UTF8.self)
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-4\(hex.dropFirst(13).prefix(3))-a\(hex.dropFirst(17).prefix(3))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted) ?? UUID()
    }

    static func assetID(candidateID: String, canonicalPathComponent: String) -> UUID {
        uuid(namespace: "asset", value: "\(candidateID)|\(canonicalPathComponent)")
    }

    private static func normalizedRelativePath(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        return normalized == "." ? "." : normalized.split(separator: "/").map(String.init).joined(separator: "/")
    }
}

nonisolated struct ValidationMessage: Codable, Hashable, Identifiable {
    var id: String
    var severity: ValidationSeverity
    var message: String

    init(id: String, severity: ValidationSeverity, message: String) {
        self.id = id
        self.severity = severity
        self.message = message
    }
}

nonisolated struct RiskMarker: Codable, Hashable, Identifiable {
    var id: String
    var kind: RiskKind
    var path: String
    var detail: String
}

nonisolated struct SkillValidationResult: Codable, Hashable {
    var status: SkillValidationStatus
    var messages: [ValidationMessage]
    var risks: [RiskMarker]

    static let valid = SkillValidationResult(status: .valid, messages: [], risks: [])
}

nonisolated struct AgentLinkRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var agentID: String
    var agent: AgentKind?
    var scope: AgentLinkScope
    var skillID: String
    var linkPath: String
    var targetPath: String
    var projectID: UUID?

    init(
        id: UUID = UUID(),
        agentID: String? = nil,
        agent: AgentKind? = nil,
        scope: AgentLinkScope,
        skillID: String,
        linkPath: String,
        targetPath: String,
        projectID: UUID? = nil
    ) {
        precondition(agentID?.isEmpty == false || agent != nil, "Agent link requires a stable agent identity.")
        self.id = id
        self.agentID = agentID ?? agent?.rawValue ?? ""
        self.agent = agent
        self.scope = scope
        self.skillID = skillID
        self.linkPath = linkPath
        self.targetPath = targetPath
        self.projectID = projectID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case agentID
        case agent
        case scope
        case skillID
        case linkPath
        case targetPath
        case projectID
    }

}

nonisolated struct TagRecord: Codable, Hashable, Identifiable {
    var id: String
    var displayName: String
}

nonisolated struct PurposeMetadata: Codable, Hashable {
    var text: String
    var source: PurposeSource
    var updatedAt: Date
}
