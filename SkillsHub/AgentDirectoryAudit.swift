import CryptoKit
import Darwin
import Foundation

nonisolated struct BuiltInAgentAdapter: Codable, Hashable, Identifiable {
    var agentID: String
    var agent: AgentKind?
    var displayName: String
    var markerPathRelativeToHome: String
    var defaultSkillsDirectoryRelativeToHome: String
    var supportsSymlink: Bool

    var id: String { agentID }

    init(kind: AgentKind, displayName: String, markerPathRelativeToHome: String, defaultSkillsDirectoryRelativeToHome: String, supportsSymlink: Bool) {
        self.agentID = kind.rawValue
        self.agent = kind
        self.displayName = displayName
        self.markerPathRelativeToHome = markerPathRelativeToHome
        self.defaultSkillsDirectoryRelativeToHome = defaultSkillsDirectoryRelativeToHome
        self.supportsSymlink = supportsSymlink
    }

    init(agentID: String, displayName: String, markerPathRelativeToHome: String, defaultSkillsDirectoryRelativeToHome: String, supportsSymlink: Bool) {
        self.agentID = agentID
        self.agent = nil
        self.displayName = displayName
        self.markerPathRelativeToHome = markerPathRelativeToHome
        self.defaultSkillsDirectoryRelativeToHome = defaultSkillsDirectoryRelativeToHome
        self.supportsSymlink = supportsSymlink
    }

    static let all: [BuiltInAgentAdapter] = [
        BuiltInAgentAdapter(kind: .codex, displayName: "Codex", markerPathRelativeToHome: ".codex", defaultSkillsDirectoryRelativeToHome: ".codex/skills", supportsSymlink: true),
        BuiltInAgentAdapter(kind: .claudeCode, displayName: "Claude Code", markerPathRelativeToHome: ".claude", defaultSkillsDirectoryRelativeToHome: ".claude/skills", supportsSymlink: true),
        BuiltInAgentAdapter(kind: .cursor, displayName: "Cursor", markerPathRelativeToHome: ".cursor", defaultSkillsDirectoryRelativeToHome: ".cursor/skills", supportsSymlink: true),
        BuiltInAgentAdapter(kind: .hermesAgent, displayName: "Hermes Agent", markerPathRelativeToHome: ".hermes", defaultSkillsDirectoryRelativeToHome: ".hermes/skills", supportsSymlink: true),
        BuiltInAgentAdapter(kind: .geminiCLI, displayName: "Gemini CLI", markerPathRelativeToHome: ".gemini", defaultSkillsDirectoryRelativeToHome: ".gemini/skills", supportsSymlink: true),
        BuiltInAgentAdapter(agentID: "agents", displayName: "Agents", markerPathRelativeToHome: ".agents", defaultSkillsDirectoryRelativeToHome: ".agents/skills", supportsSymlink: true)
    ]
}

nonisolated enum AgentSkillEntryKind: String, Codable, CaseIterable, Hashable {
    case hubManagedSymlink
    case externalSymlink
    case brokenSymlink
    case localDirectory
    case plainFile
    case invalid
    case missing
}

nonisolated enum AgentFindingType: String, Codable, CaseIterable, Hashable {
    case pendingAudit
    case missingSkillsDirectory
    case permissionDenied
    case localDirectoryNotManaged
    case externalSymlinkNotManaged
    case brokenSymlink
    case duplicateWithHub
    case aliasConflict
    case copiedButAgentStillLocal
    case copiedButAgentStillExternal
    case linkDrift
    case rootMovedRepairAvailable
    case rollbackFailed
    case invalidEntry
}

nonisolated enum AgentFindingSeverity: String, Codable, CaseIterable, Hashable {
    case error
    case warning
    case suggestion

    var sortRank: Int {
        switch self {
        case .error: return 0
        case .warning: return 1
        case .suggestion: return 2
        }
    }
}

nonisolated enum AgentFindingDomain: String, Codable, Hashable {
    case hubValidation
    case agentDirectory
    case link
    case ignored
}

nonisolated enum AgentFindingAction: String, Codable, Hashable {
    case auditAgentDirectory
    case createSkillsDirectory
    case viewPermissionGuidance
    case moveToHub
    case copyToHub
    case retargetToHub
    case deleteBrokenLink
    case viewLightweightDiff
    case useRecommendedAlias
    case replaceWithHubSymlink
    case restoreHubLink
    case previewRepair
    case viewRepairGuidance
    case openLocation
}

nonisolated enum MatchStrength: String, Codable, Hashable {
    case strong
    case medium
    case weak
    case none
}

nonisolated enum MatchEvidence: String, Codable, Hashable {
    case resolvedPath
    case skillFileHash
    case sourceIdentity
    case metadataName
    case entryName
}

nonisolated struct HubSkillMatchCandidate: Codable, Hashable, Identifiable {
    var hubSkillID: String
    var displayName: String
    var hubRelativePath: String
    var matchStrength: MatchStrength
    var evidence: [MatchEvidence]

    var id: String { hubSkillID }
}

nonisolated struct AgentDetectionSnapshot: Codable, Hashable, Identifiable {
    var agentID: String
    var agent: AgentKind?
    var displayName: String
    var markerPath: String
    var skillsDirectory: String
    var detected: Bool
    var skillsDirectoryExists: Bool
    var entryCount: Int
    var readable: Bool
    var writable: Bool
    var isCustom: Bool
    var installationEvidence: AgentInstallationEvidence? = nil

    var id: String { agentID }
}

nonisolated struct AgentAuditSnapshot: Codable, Hashable, Identifiable {
    var agentID: String
    var displayName: String
    var skillsDirectory: String
    var lastFullAuditAt: Date
    var entryCount: Int
    var directoryFingerprint: String

    var id: String { agentID }
}

nonisolated struct CustomAgentRecord: Codable, Hashable, Identifiable {
    var id: String
    var displayName: String
    var skillsDirectory: String
    var createdAt: Date
}

nonisolated struct AgentManagedLinkRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var agentID: String
    var agent: AgentKind?
    var alias: String
    var linkPath: String
    var targetPath: String
    var hubSkillID: String
    var hubRelativePath: String
    var rootAtCreation: String
    var createdAt: Date
    var lastVerifiedAt: Date?

    init(
        id: UUID = UUID(),
        agentID: String,
        agent: AgentKind?,
        alias: String,
        linkPath: String,
        targetPath: String,
        hubSkillID: String,
        hubRelativePath: String,
        rootAtCreation: String,
        createdAt: Date = Date(),
        lastVerifiedAt: Date? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.agent = agent
        self.alias = alias
        self.linkPath = linkPath
        self.targetPath = targetPath
        self.hubSkillID = hubSkillID
        self.hubRelativePath = hubRelativePath
        self.rootAtCreation = rootAtCreation
        self.createdAt = createdAt
        self.lastVerifiedAt = lastVerifiedAt
    }
}

nonisolated struct AgentDirectoryFinding: Codable, Hashable, Identifiable {
    var id: String
    var agentID: String
    var agent: AgentKind?
    var agentDisplayName: String
    var domain: AgentFindingDomain
    var severity: AgentFindingSeverity
    var type: AgentFindingType
    var entryName: String
    var entryKind: AgentSkillEntryKind
    var summary: String
    var evidence: [String]
    var sourcePath: String?
    var targetPath: String?
    var linkPath: String?
    var symlinkTarget: String?
    var skillFileHash: String?
    var matchCandidates: [HubSkillMatchCandidate]
    var recommendedAction: AgentFindingAction
    var ignored: Bool

    var primaryMatch: HubSkillMatchCandidate? {
        matchCandidates.sorted { lhs, rhs in
            strengthRank(lhs.matchStrength) < strengthRank(rhs.matchStrength)
        }.first
    }

    private func strengthRank(_ strength: MatchStrength) -> Int {
        switch strength {
        case .strong: return 0
        case .medium: return 1
        case .weak: return 2
        case .none: return 3
        }
    }
}

nonisolated struct AgentDirectoryAuditResult: Codable, Hashable {
    var detections: [AgentDetectionSnapshot]
    var findings: [AgentDirectoryFinding]
    var auditSnapshots: [AgentAuditSnapshot]
}

nonisolated struct SkillsHubLocalState: Codable, Hashable {
    var schemaVersion: Int
    var lastAgentLightScanAt: Date?
    var detectedAgentsSnapshot: [AgentDetectionSnapshot]
    var agentAuditSnapshots: [AgentAuditSnapshot]
    var ignoredFindingFingerprints: [String]
    var activeAgentLinks: [AgentManagedLinkRecord]
    var customAgents: [CustomAgentRecord]
    var agentPathOverrides: [AgentKind: String]
    var operationFailureFindings: [AgentDirectoryFinding]?
    var targetObservations: [TargetObservation]
    var managedRelationEvidence: [ManagedRelationEvidence]
    var verificationRecords: [VerificationRecord]

    init(
        schemaVersion: Int = 1,
        lastAgentLightScanAt: Date? = nil,
        detectedAgentsSnapshot: [AgentDetectionSnapshot] = [],
        agentAuditSnapshots: [AgentAuditSnapshot] = [],
        ignoredFindingFingerprints: [String] = [],
        activeAgentLinks: [AgentManagedLinkRecord] = [],
        customAgents: [CustomAgentRecord] = [],
        agentPathOverrides: [AgentKind: String] = [:],
        operationFailureFindings: [AgentDirectoryFinding]? = nil,
        targetObservations: [TargetObservation] = [],
        managedRelationEvidence: [ManagedRelationEvidence] = [],
        verificationRecords: [VerificationRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.lastAgentLightScanAt = lastAgentLightScanAt
        self.detectedAgentsSnapshot = detectedAgentsSnapshot
        self.agentAuditSnapshots = agentAuditSnapshots
        self.ignoredFindingFingerprints = ignoredFindingFingerprints
        self.activeAgentLinks = activeAgentLinks
        self.customAgents = customAgents
        self.agentPathOverrides = agentPathOverrides
        self.operationFailureFindings = operationFailureFindings
        self.targetObservations = targetObservations
        self.managedRelationEvidence = managedRelationEvidence
        self.verificationRecords = verificationRecords
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case lastAgentLightScanAt
        case detectedAgentsSnapshot
        case agentAuditSnapshots
        case ignoredFindingFingerprints
        case activeAgentLinks
        case operationFailureFindings
        case targetObservations
        case managedRelationEvidence
        case verificationRecords
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        lastAgentLightScanAt = try container.decodeIfPresent(Date.self, forKey: .lastAgentLightScanAt)
        detectedAgentsSnapshot = try container.decodeIfPresent(
            [AgentDetectionSnapshot].self,
            forKey: .detectedAgentsSnapshot
        ) ?? []
        agentAuditSnapshots = try container.decodeIfPresent([AgentAuditSnapshot].self, forKey: .agentAuditSnapshots) ?? []
        ignoredFindingFingerprints = try container.decodeIfPresent(
            [String].self,
            forKey: .ignoredFindingFingerprints
        ) ?? []
        activeAgentLinks = try container.decodeIfPresent([AgentManagedLinkRecord].self, forKey: .activeAgentLinks) ?? []
        customAgents = []
        agentPathOverrides = [:]
        operationFailureFindings = try container.decodeIfPresent(
            [AgentDirectoryFinding].self,
            forKey: .operationFailureFindings
        )
        targetObservations = try container.decodeIfPresent([TargetObservation].self, forKey: .targetObservations) ?? []
        managedRelationEvidence = try container.decodeIfPresent(
            [ManagedRelationEvidence].self,
            forKey: .managedRelationEvidence
        ) ?? []
        verificationRecords = try container.decodeIfPresent([VerificationRecord].self, forKey: .verificationRecords) ?? []
    }
}

nonisolated final class SkillsHubLocalStateStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func localStateFile(for rootURL: URL) -> URL {
        rootURL.appendingPathComponent(".skillshub.local.json")
    }

    func operationLogFile(for rootURL: URL) -> URL {
        rootURL.appendingPathComponent(".skillshub.operations.jsonl")
    }

    func load(from rootURL: URL) throws -> SkillsHubLocalState {
        let file = localStateFile(for: rootURL)
        guard fileManager.fileExists(atPath: file.path) else {
            return SkillsHubLocalState()
        }
        let data = try Data(contentsOf: file)
        return try decoder.decode(SkillsHubLocalState.self, from: data)
    }

    func save(_ state: SkillsHubLocalState, to rootURL: URL) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try encoder.encode(state)
        try data.write(to: localStateFile(for: rootURL), options: [.atomic])
    }
}

nonisolated final class AgentDirectoryAuditService {
    private let fileManager: FileManager
    private let access: FileAccessService
    private let frontmatterParser: SkillFrontmatterParser
    private let now: () -> Date
    let installationPresence: @Sendable (AgentKind, URL) -> AgentInstallationResult

    init(fileManager: FileManager = .default, now: @escaping () -> Date = Date.init,
         frontmatterParser: SkillFrontmatterParser = SkillFrontmatterParser(),
         installationPresence: @escaping @Sendable (AgentKind, URL) -> AgentInstallationResult = { AgentInstallationDetector().detect(agent: $0, home: $1) }) {
        self.fileManager = fileManager
        self.access = FileAccessService(fileManager: fileManager)
        self.frontmatterParser = frontmatterParser
        self.now = now
        self.installationPresence = installationPresence
    }

    func lightScan(
        rootURL: URL,
        homeDirectory: URL,
        overrides: [AgentKind: String],
        localState: SkillsHubLocalState,
        checkInstallation: Bool = true
    ) -> AgentDirectoryAuditResult {
        let descriptors = agentDescriptors(homeDirectory: homeDirectory, overrides: overrides, customAgents: localState.customAgents)
        let detections = descriptors.map { descriptor in
            detectionSnapshot(for: descriptor, evidence: checkInstallation ? descriptor.agent.flatMap { installationPresence($0, homeDirectory).evidence } : localState.detectedAgentsSnapshot.first { $0.agentID == descriptor.agentID }?.installationEvidence)
        }
        let ignored = Set(localState.ignoredFindingFingerprints)
        var findings: [AgentDirectoryFinding] = []

        for detection in detections {
            if detection.detected && !detection.skillsDirectoryExists {
                findings.append(finding(
                    agentID: detection.agentID,
                    agent: detection.agent,
                    agentDisplayName: detection.displayName,
                    type: .missingSkillsDirectory,
                    entryName: detection.displayName,
                    entryKind: .missing,
                    sourcePath: detection.skillsDirectory,
                    targetPath: nil,
                    linkPath: nil,
                    symlinkTarget: nil,
                    skillFileHash: nil,
                    matchCandidates: [],
                    summary: "Agent detected, skills directory not created.",
                    evidence: ["Marker: \(detection.markerPath)", "Skills directory: \(detection.skillsDirectory)"],
                    ignoredFingerprints: ignored
                ))
                continue
            }

            if detection.detected && detection.skillsDirectoryExists && (!detection.readable || !detection.writable) {
                findings.append(finding(
                    agentID: detection.agentID,
                    agent: detection.agent,
                    agentDisplayName: detection.displayName,
                    type: .permissionDenied,
                    entryName: detection.displayName,
                    entryKind: .missing,
                    sourcePath: detection.skillsDirectory,
                    targetPath: nil,
                    linkPath: nil,
                    symlinkTarget: nil,
                    skillFileHash: nil,
                    matchCandidates: [],
                    summary: "Agent skills directory is not readable or writable.",
                    evidence: [
                        "Marker: \(detection.markerPath)",
                        "Skills directory: \(detection.skillsDirectory)",
                        "Readable: \(detection.readable)",
                        "Writable: \(detection.writable)"
                    ],
                    ignoredFingerprints: ignored
                ))
                continue
            }

            guard detection.detected, detection.skillsDirectoryExists, detection.entryCount > 0 else {
                continue
            }

            let currentFingerprint = structuralFingerprint(for: URL(fileURLWithPath: detection.skillsDirectory, isDirectory: true))
            let previous = localState.agentAuditSnapshots.first { $0.agentID == detection.agentID && $0.skillsDirectory == detection.skillsDirectory }
            if previous == nil || previous?.directoryFingerprint != currentFingerprint {
                findings.append(finding(
                    agentID: detection.agentID,
                    agent: detection.agent,
                    agentDisplayName: detection.displayName,
                    type: .pendingAudit,
                    entryName: detection.displayName,
                    entryKind: .missing,
                    sourcePath: detection.skillsDirectory,
                    targetPath: nil,
                    linkPath: nil,
                    symlinkTarget: nil,
                    skillFileHash: nil,
                    matchCandidates: [],
                    summary: "Found \(detection.entryCount) skill entries, not fully audited.",
                    evidence: ["Entry count: \(detection.entryCount)", "Structural fingerprint: \(currentFingerprint)"],
                    ignoredFingerprints: ignored
                ))
            }
        }

        findings.append(contentsOf: linkDriftFindings(rootURL: rootURL, state: localState, ignoredFingerprints: ignored))
        findings.append(contentsOf: localState.operationFailureFindings ?? [])
        return AgentDirectoryAuditResult(detections: detections, findings: sort(findings), auditSnapshots: localState.agentAuditSnapshots)
    }

    func fullAudit(
        agentID: String?,
        rootURL: URL,
        homeDirectory: URL,
        overrides: [AgentKind: String],
        localState: SkillsHubLocalState,
        installedSkills: [InstalledSkill]
    ) -> AgentDirectoryAuditResult {
        let descriptors = agentDescriptors(homeDirectory: homeDirectory, overrides: overrides, customAgents: localState.customAgents)
            .filter { agentID == nil || $0.agentID == agentID }
        let detections = descriptors.map { detectionSnapshot(for: $0, evidence: $0.agent.flatMap { installationPresence($0, homeDirectory).evidence }) }
        let ignored = Set(localState.ignoredFindingFingerprints)
        var findings: [AgentDirectoryFinding] = []
        var snapshots = localState.agentAuditSnapshots

        for descriptor in descriptors {
            let skillsDirectory = descriptor.skillsDirectory
            guard isDirectory(skillsDirectory) else {
                if itemExistsOrIsSymlink(descriptor.markerURL) {
                    findings.append(finding(
                        agentID: descriptor.agentID,
                        agent: descriptor.agent,
                        agentDisplayName: descriptor.displayName,
                        type: .missingSkillsDirectory,
                        entryName: descriptor.displayName,
                        entryKind: .missing,
                        sourcePath: skillsDirectory.path,
                        targetPath: nil,
                        linkPath: nil,
                        symlinkTarget: nil,
                        skillFileHash: nil,
                        matchCandidates: [],
                        summary: "Agent detected, skills directory not created.",
                        evidence: ["Skills directory: \(skillsDirectory.path)"],
                        ignoredFingerprints: ignored
                    ))
                }
                continue
            }

            let children = firstLevelChildren(in: skillsDirectory)
            for child in children {
                findings.append(contentsOf: findingsForEntry(
                    child,
                    descriptor: descriptor,
                    rootURL: rootURL,
                    installedSkills: installedSkills,
                    ignoredFingerprints: ignored,
                    localState: localState
                ))
            }

            let snapshot = AgentAuditSnapshot(
                agentID: descriptor.agentID,
                displayName: descriptor.displayName,
                skillsDirectory: skillsDirectory.path,
                lastFullAuditAt: now(),
                entryCount: children.count,
                directoryFingerprint: structuralFingerprint(for: skillsDirectory)
            )
            snapshots.removeAll { $0.agentID == snapshot.agentID && $0.skillsDirectory == snapshot.skillsDirectory }
            snapshots.append(snapshot)
        }

        findings.append(contentsOf: linkDriftFindings(rootURL: rootURL, state: localState, ignoredFingerprints: ignored))
        findings.append(contentsOf: localState.operationFailureFindings ?? [])
        return AgentDirectoryAuditResult(detections: detections, findings: sort(findings), auditSnapshots: snapshots.sorted { $0.displayName < $1.displayName })
    }

    func agentDescriptors(
        homeDirectory: URL,
        overrides: [AgentKind: String],
        customAgents: [CustomAgentRecord]
    ) -> [AgentDirectoryDescriptor] {
        let builtIns = BuiltInAgentAdapter.all.map { adapter in
            let marker = homeDirectory.appendingPathComponent(adapter.markerPathRelativeToHome, isDirectory: true)
            let defaultSkills = homeDirectory.appendingPathComponent(adapter.defaultSkillsDirectoryRelativeToHome, isDirectory: true)
            let override = adapter.agent.flatMap { overrides[$0] }
            let skills = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultSkills
            return AgentDirectoryDescriptor(
                agentID: adapter.agentID,
                agent: adapter.agent,
                displayName: adapter.displayName,
                markerURL: marker,
                skillsDirectory: skills,
                supportsSymlink: adapter.supportsSymlink,
                isCustom: false
            )
        }
        let custom = customAgents.map { customAgent in
            AgentDirectoryDescriptor(
                agentID: customAgent.id,
                agent: nil,
                displayName: customAgent.displayName,
                markerURL: URL(fileURLWithPath: customAgent.skillsDirectory, isDirectory: true).deletingLastPathComponent(),
                skillsDirectory: URL(fileURLWithPath: customAgent.skillsDirectory, isDirectory: true),
                supportsSymlink: true,
                isCustom: true
            )
        }
        return builtIns + custom
    }

    func shortID(originAgent: String, originPath: String, skillFileHash: String?, entryName: String) -> String {
        let basis = [originAgent, normalizedPath(URL(fileURLWithPath: originPath)), skillFileHash ?? entryName].joined(separator: "|")
        return String(Self.sha256Hex(Data(basis.utf8)).prefix(8))
    }

    private func findingsForEntry(
        _ entry: URL,
        descriptor: AgentDirectoryDescriptor,
        rootURL: URL,
        installedSkills: [InstalledSkill],
        ignoredFingerprints: Set<String>,
        localState: SkillsHubLocalState
    ) -> [AgentDirectoryFinding] {
        let inspection = inspectEntry(entry)
        if inspection.kind == .externalSymlink,
           isExactManagedLink(
               entry,
               descriptor: descriptor,
               installedSkills: installedSkills,
               localState: localState
           ) {
            return []
        }
        let candidates = matchCandidates(for: inspection, entry: entry, rootURL: rootURL, installedSkills: installedSkills)
        let type = findingType(for: inspection, candidates: candidates, entry: entry, descriptor: descriptor, rootURL: rootURL, localState: localState)
        guard let type else {
            return []
        }
        let summary: String
        switch type {
        case .localDirectoryNotManaged:
            summary = "Local directory is not governed by Skills Hub."
        case .externalSymlinkNotManaged:
            summary = "Agent entry points outside the Management Directory."
        case .brokenSymlink:
            summary = "Agent entry is a broken symlink."
        case .duplicateWithHub:
            summary = "Agent entry may duplicate a Hub skill."
        case .rootMovedRepairAvailable:
            summary = "Broken Hub-managed link can be repaired after root move."
        case .invalidEntry:
            summary = "Agent entry is not a supported skill directory."
        default:
            summary = type.rawValue
        }
        return [
            finding(
                agentID: descriptor.agentID,
                agent: descriptor.agent,
                agentDisplayName: descriptor.displayName,
                type: type,
                entryName: entry.lastPathComponent,
                entryKind: inspection.kind,
                sourcePath: entry.path,
                targetPath: inspection.targetPath,
                linkPath: inspection.kind == .externalSymlink || inspection.kind == .brokenSymlink || inspection.kind == .hubManagedSymlink ? entry.path : nil,
                symlinkTarget: inspection.symlinkTarget,
                skillFileHash: inspection.skillFileHash,
                matchCandidates: candidates,
                summary: summary,
                evidence: inspection.evidence,
                ignoredFingerprints: ignoredFingerprints
            )
        ]
    }

    private func findingType(
        for inspection: AgentEntryInspection,
        candidates: [HubSkillMatchCandidate],
        entry: URL,
        descriptor: AgentDirectoryDescriptor,
        rootURL: URL,
        localState: SkillsHubLocalState
    ) -> AgentFindingType? {
        switch inspection.kind {
        case .hubManagedSymlink:
            return nil
        case .externalSymlink:
            return .externalSymlinkNotManaged
        case .brokenSymlink:
            if rootMovedRecord(entry: entry, oldTarget: inspection.targetPath, descriptor: descriptor, rootURL: rootURL, localState: localState) != nil {
                return .rootMovedRepairAvailable
            }
            return .brokenSymlink
        case .localDirectory:
            return candidates.isEmpty ? .localDirectoryNotManaged : .duplicateWithHub
        case .plainFile, .invalid, .missing:
            return .invalidEntry
        }
    }

    private func inspectEntry(_ entry: URL) -> AgentEntryInspection {
        var evidence: [String] = []
        if access.isSymlink(entry) {
            do {
                let rawTarget = try fileManager.destinationOfSymbolicLink(atPath: entry.path)
                let target = try access.resolvedSymlinkTarget(entry)
                evidence.append("Symlink target: \(rawTarget)")
                evidence.append("Resolved target: \(target.path)")
                var status = stat()
                guard Darwin.fstatat(AT_FDCWD, target.path, &status, 0) == 0 else {
                    if errno == ENOENT || errno == ENOTDIR {
                        return AgentEntryInspection(kind: .brokenSymlink, targetPath: target.path, symlinkTarget: rawTarget, skillFileURL: nil, skillFileHash: nil, skillName: nil, skillDescription: nil, evidence: evidence)
                    }
                    evidence.append("Target status could not be verified (errno \(errno)).")
                    return AgentEntryInspection(kind: .invalid, targetPath: target.path, symlinkTarget: rawTarget, skillFileURL: nil, skillFileHash: nil, skillName: nil, skillDescription: nil, evidence: evidence)
                }
                return AgentEntryInspection(kind: .externalSymlink, targetPath: target.path, symlinkTarget: rawTarget, skillFileURL: nil, skillFileHash: nil, skillName: nil, skillDescription: nil, evidence: evidence)
            } catch {
                evidence.append("Symlink target could not be resolved.")
                return AgentEntryInspection(kind: .invalid, targetPath: nil, symlinkTarget: nil, skillFileURL: nil, skillFileHash: nil, skillName: nil, skillDescription: nil, evidence: evidence)
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory) else {
            return AgentEntryInspection(kind: .missing, targetPath: nil, symlinkTarget: nil, skillFileURL: nil, skillFileHash: nil, skillName: nil, skillDescription: nil, evidence: ["Entry missing: \(entry.path)"])
        }
        guard isDirectory.boolValue else {
            return AgentEntryInspection(kind: .plainFile, targetPath: entry.path, symlinkTarget: nil, skillFileURL: nil, skillFileHash: nil, skillName: nil, skillDescription: nil, evidence: ["Plain file: \(entry.path)"])
        }
        let skillFile = entry.appendingPathComponent("SKILL.md")
        let skill = readSkillSummary(from: skillFile)
        let localEvidence = skill.hash == nil ? evidence + ["Missing SKILL.md"] : evidence + skill.evidence
        return AgentEntryInspection(kind: .localDirectory, targetPath: entry.path, symlinkTarget: nil, skillFileURL: skillFile, skillFileHash: skill.hash, skillName: skill.name, skillDescription: skill.description, evidence: localEvidence)
    }

    private func isExactManagedLink(
        _ entry: URL,
        descriptor: AgentDirectoryDescriptor,
        installedSkills: [InstalledSkill],
        localState: SkillsHubLocalState
    ) -> Bool {
        localState.managedRelationEvidence.contains { evidence in
            guard evidence.relation.agentID == descriptor.agentID,
                  normalizedPath(URL(fileURLWithPath: evidence.linkPath)) == normalizedPath(entry),
                  let skill = installedSkills.first(where: { $0.assetID == evidence.relation.assetID }),
                  let inspection = try? RelationOwnershipInspector().inspect(
                      linkURL: entry,
                      relation: evidence.relation,
                      canonicalTargetPath: skill.installedPath,
                      evidence: evidence
                  )
            else { return false }
            return inspection.classification == .exactManagedLink
        }
    }

    private func matchCandidates(
        for inspection: AgentEntryInspection,
        entry: URL,
        rootURL: URL,
        installedSkills: [InstalledSkill]
    ) -> [HubSkillMatchCandidate] {
        installedSkills.compactMap { skill in
            var evidence: [MatchEvidence] = []
            let hubURL = URL(fileURLWithPath: skill.installedPath, isDirectory: true)
            if let targetPath = inspection.targetPath,
               normalizedPath(URL(fileURLWithPath: targetPath)) == normalizedPath(hubURL) {
                evidence.append(.resolvedPath)
            }
            if let hash = inspection.skillFileHash,
               let hubHash = readSkillSummary(from: hubURL.appendingPathComponent("SKILL.md")).hash,
               hash == hubHash {
                evidence.append(.skillFileHash)
            }
            if let name = inspection.skillName, name.caseInsensitiveCompare(skill.name) == .orderedSame {
                evidence.append(.metadataName)
            }
            if entry.lastPathComponent.caseInsensitiveCompare(skill.id) == .orderedSame {
                evidence.append(.entryName)
            }
            guard !evidence.isEmpty else {
                return nil
            }
            let strength: MatchStrength
            if evidence.contains(.resolvedPath) || evidence.contains(.skillFileHash) {
                strength = .strong
            } else if evidence.contains(.metadataName) {
                strength = .medium
            } else {
                strength = .weak
            }
            return HubSkillMatchCandidate(
                hubSkillID: skill.id,
                displayName: skill.name,
                hubRelativePath: relativePath(of: hubURL, to: rootURL),
                matchStrength: strength,
                evidence: evidence
            )
        }
        .sorted { lhs, rhs in
            if lhs.matchStrength != rhs.matchStrength {
                return strengthRank(lhs.matchStrength) < strengthRank(rhs.matchStrength)
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func finding(
        agentID: String,
        agent: AgentKind?,
        agentDisplayName: String,
        type: AgentFindingType,
        entryName: String,
        entryKind: AgentSkillEntryKind,
        sourcePath: String?,
        targetPath: String?,
        linkPath: String?,
        symlinkTarget: String?,
        skillFileHash: String?,
        matchCandidates: [HubSkillMatchCandidate],
        summary: String,
        evidence: [String],
        ignoredFingerprints: Set<String>
    ) -> AgentDirectoryFinding {
        let matchedID = matchCandidates.first?.hubSkillID
        let fingerprint = [
            agentID,
            sourcePath ?? "",
            entryKind.rawValue,
            type.rawValue,
            symlinkTarget ?? "",
            skillFileHash ?? "",
            matchedID ?? ""
        ].joined(separator: "|")
        let id = Self.sha256Hex(Data(fingerprint.utf8))
        return AgentDirectoryFinding(
            id: id,
            agentID: agentID,
            agent: agent,
            agentDisplayName: agentDisplayName,
            domain: domain(for: type),
            severity: severity(for: type),
            type: type,
            entryName: entryName,
            entryKind: entryKind,
            summary: summary,
            evidence: evidence,
            sourcePath: sourcePath,
            targetPath: targetPath,
            linkPath: linkPath,
            symlinkTarget: symlinkTarget,
            skillFileHash: skillFileHash,
            matchCandidates: matchCandidates,
            recommendedAction: recommendedAction(for: type, candidates: matchCandidates),
            ignored: ignoredFingerprints.contains(id)
        )
    }

    private func detectionSnapshot(for descriptor: AgentDirectoryDescriptor, evidence: AgentInstallationEvidence?) -> AgentDetectionSnapshot {
        let markerExists = descriptor.isCustom || itemExistsOrIsSymlink(descriptor.markerURL)
        let skillsExists = isDirectory(descriptor.skillsDirectory)
        let count = skillsExists ? firstLevelChildren(in: descriptor.skillsDirectory).count : 0
        let readable = skillsExists && fileManager.isReadableFile(atPath: descriptor.skillsDirectory.path)
        let writable = skillsExists && fileManager.isWritableFile(atPath: descriptor.skillsDirectory.path)
        return AgentDetectionSnapshot(
            agentID: descriptor.agentID,
            agent: descriptor.agent,
            displayName: descriptor.displayName,
            markerPath: descriptor.markerURL.path,
            skillsDirectory: descriptor.skillsDirectory.path,
            detected: descriptor.agent == .codex || descriptor.agent == .claudeCode ? evidence != nil : markerExists,
            skillsDirectoryExists: skillsExists,
            entryCount: count,
            readable: readable,
            writable: writable,
            isCustom: descriptor.isCustom,
            installationEvidence: evidence
        )
    }

    private func linkDriftFindings(rootURL: URL, state: SkillsHubLocalState, ignoredFingerprints: Set<String>) -> [AgentDirectoryFinding] {
        state.activeAgentLinks.compactMap { record in
            let link = URL(fileURLWithPath: record.linkPath)
            guard access.isSymlink(link) else {
                return finding(
                    agentID: record.agentID,
                    agent: record.agent,
                    agentDisplayName: record.agent?.displayName ?? record.agentID,
                    type: .linkDrift,
                    entryName: record.alias,
                    entryKind: .missing,
                    sourcePath: record.linkPath,
                    targetPath: record.targetPath,
                    linkPath: record.linkPath,
                    symlinkTarget: nil,
                    skillFileHash: nil,
                    matchCandidates: [],
                    summary: "Recorded Hub-managed link is missing or no longer a symlink.",
                    evidence: ["Recorded target: \(record.targetPath)"],
                    ignoredFingerprints: ignoredFingerprints
                )
            }
            guard let target = try? access.resolvedSymlinkTarget(link),
                  normalizedPath(target) == normalizedPath(URL(fileURLWithPath: record.targetPath)) else {
                return finding(
                    agentID: record.agentID,
                    agent: record.agent,
                    agentDisplayName: record.agent?.displayName ?? record.agentID,
                    type: .linkDrift,
                    entryName: record.alias,
                    entryKind: .externalSymlink,
                    sourcePath: record.linkPath,
                    targetPath: record.targetPath,
                    linkPath: record.linkPath,
                    symlinkTarget: try? access.resolvedSymlinkTarget(link).path,
                    skillFileHash: nil,
                    matchCandidates: [],
                    summary: "Recorded Hub-managed link points somewhere else.",
                    evidence: ["Recorded target: \(record.targetPath)"],
                    ignoredFingerprints: ignoredFingerprints
                )
            }
            return nil
        }
    }

    private func rootMovedRecord(
        entry: URL,
        oldTarget: String?,
        descriptor: AgentDirectoryDescriptor,
        rootURL: URL,
        localState: SkillsHubLocalState
    ) -> AgentManagedLinkRecord? {
        guard let oldTarget, access.isSymlink(entry) else {
            return nil
        }
        let entryPath = standardizedPath(entry)
        return localState.activeAgentLinks.first { record in
            let linkMatches = pathsMatch(record.linkPath, entry.path) || pathsMatch(record.linkPath, entryPath)
            let expectedOldTarget = URL(fileURLWithPath: record.rootAtCreation, isDirectory: true)
                .appendingPathComponent(record.hubRelativePath)
            let newTarget = rootURL.appendingPathComponent(record.hubRelativePath)
            let sameRecordedLink = record.agentID == descriptor.agentID
                && record.alias.caseInsensitiveCompare(entry.lastPathComponent) == .orderedSame
                && linkMatches
            return sameRecordedLink
                && pathsMatch(expectedOldTarget.path, oldTarget)
                && pathsMatch(record.targetPath, oldTarget)
                && itemExistsOrIsSymlink(newTarget)
        }
    }

    private func readSkillSummary(from skillFile: URL) -> (hash: String?, name: String?, description: String?, evidence: [String]) {
        guard let data = try? Data(contentsOf: skillFile) else {
            return (nil, nil, nil, [])
        }
        let text = String(decoding: data, as: UTF8.self)
        let frontmatter = try? frontmatterParser.parse(text)
        return (Self.sha256Hex(data), frontmatter?.name, frontmatter?.description, ["SKILL.md hash: \(Self.sha256Hex(data))"])
    }

    private func structuralFingerprint(for directory: URL) -> String {
        let children = firstLevelChildren(in: directory)
        let rows = children.map { child -> String in
            let values = try? child.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey])
            let target = (try? fileManager.destinationOfSymbolicLink(atPath: child.path)) ?? ""
            return [
                child.lastPathComponent,
                values?.isSymbolicLink == true ? "symlink" : (values?.isDirectory == true ? "dir" : "file"),
                target,
                "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)",
                "\(values?.fileSize ?? 0)"
            ].joined(separator: ":")
        }.joined(separator: "|")
        return Self.sha256Hex(Data(rows.utf8))
    }

    private func firstLevelChildren(in directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]))?
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending } ?? []
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func itemExistsOrIsSymlink(_ url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            return true
        }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        !pathVariants(lhs).isDisjoint(with: pathVariants(rhs))
    }

    private func pathVariants(_ path: String) -> Set<String> {
        let standardized = standardizedPath(URL(fileURLWithPath: path))
        let normalized = normalizedPath(URL(fileURLWithPath: path))
        var variants: Set<String> = [path, standardized, normalized]
        for variant in Array(variants) {
            if variant.hasPrefix("/private/var/") {
                variants.insert(String(variant.dropFirst("/private".count)))
            } else if variant.hasPrefix("/var/") {
                variants.insert("/private" + variant)
            }
        }
        return variants
    }

    private func relativePath(of url: URL, to rootURL: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else {
            return url.lastPathComponent
        }
        return String(path.dropFirst(root.count + 1))
    }

    private func severity(for type: AgentFindingType) -> AgentFindingSeverity {
        switch type {
        case .permissionDenied, .rollbackFailed, .linkDrift:
            return .error
        case .localDirectoryNotManaged, .externalSymlinkNotManaged, .brokenSymlink, .duplicateWithHub, .aliasConflict, .invalidEntry, .rootMovedRepairAvailable:
            return .warning
        case .pendingAudit, .missingSkillsDirectory, .copiedButAgentStillLocal, .copiedButAgentStillExternal:
            return .suggestion
        }
    }

    private func domain(for type: AgentFindingType) -> AgentFindingDomain {
        switch type {
        case .linkDrift, .rootMovedRepairAvailable, .brokenSymlink:
            return .link
        case .pendingAudit, .missingSkillsDirectory, .permissionDenied, .localDirectoryNotManaged, .externalSymlinkNotManaged, .duplicateWithHub, .aliasConflict, .copiedButAgentStillLocal, .copiedButAgentStillExternal, .rollbackFailed, .invalidEntry:
            return .agentDirectory
        }
    }

    private func recommendedAction(for type: AgentFindingType, candidates: [HubSkillMatchCandidate]) -> AgentFindingAction {
        switch type {
        case .pendingAudit:
            return .auditAgentDirectory
        case .missingSkillsDirectory:
            return .createSkillsDirectory
        case .permissionDenied:
            return .viewPermissionGuidance
        case .localDirectoryNotManaged:
            return .moveToHub
        case .externalSymlinkNotManaged:
            return .copyToHub
        case .brokenSymlink:
            return candidates.first?.matchStrength == .strong ? .retargetToHub : .deleteBrokenLink
        case .duplicateWithHub:
            return .viewLightweightDiff
        case .aliasConflict:
            return .useRecommendedAlias
        case .copiedButAgentStillLocal, .copiedButAgentStillExternal:
            return .replaceWithHubSymlink
        case .linkDrift:
            return .restoreHubLink
        case .rootMovedRepairAvailable:
            return .previewRepair
        case .rollbackFailed:
            return .viewRepairGuidance
        case .invalidEntry:
            return .openLocation
        }
    }

    private func sort(_ findings: [AgentDirectoryFinding]) -> [AgentDirectoryFinding] {
        findings.sorted {
            if $0.ignored != $1.ignored {
                return !$0.ignored
            }
            if $0.severity.sortRank != $1.severity.sortRank {
                return $0.severity.sortRank < $1.severity.sortRank
            }
            if $0.agentDisplayName != $1.agentDisplayName {
                return $0.agentDisplayName < $1.agentDisplayName
            }
            return $0.entryName < $1.entryName
        }
    }

    private func strengthRank(_ strength: MatchStrength) -> Int {
        switch strength {
        case .strong: return 0
        case .medium: return 1
        case .weak: return 2
        case .none: return 3
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct AgentDirectoryDescriptor: Hashable {
    var agentID: String
    var agent: AgentKind?
    var displayName: String
    var markerURL: URL
    var skillsDirectory: URL
    var supportsSymlink: Bool
    var isCustom: Bool
}

private struct AgentEntryInspection {
    var kind: AgentSkillEntryKind
    var targetPath: String?
    var symlinkTarget: String?
    var skillFileURL: URL?
    var skillFileHash: String?
    var skillName: String?
    var skillDescription: String?
    var evidence: [String]
}
