import Darwin
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class SkillsHubLibraryController {
    let metadataStore: SkillsHubMetadataStore
    let presentationService: SkillCatalogPresentationService
    let settingsService: AppSettingsService
    let agentLinkService: AgentLinkService
    let agentPathResolver: AgentPathResolver
    let localStateStore: SkillsHubLocalStateStore
    let agentAuditService: AgentDirectoryAuditService
    let sourceRemovalService: SourceRemovalService
    let sourceUpdateService: SourceUpdateService
    let startupAccessStore: StartupAccessStoring
    @ObservationIgnored let securityScopedAccessProvider: SecurityScopedAccessProvider
    let phase1OperationPlanner: Phase1OperationPlanner
    @ObservationIgnored let relationActionCoordinator: RelationActionCoordinator
    @ObservationIgnored let relationActionRuntime: RelationActionControllerRuntime
    #if DEBUG
    @ObservationIgnored var phase1OperationCoordinator: Phase1OperationCoordinator
    @ObservationIgnored var phase1UITestFixtureLease: SecurityScopedAccessLease?
    @ObservationIgnored var githubHTTPDataClientOverride: HTTPDataClient?
    #else
    let phase1OperationCoordinator: Phase1OperationCoordinator
    #endif
    let fileManager: FileManager
    let localization: SkillsHubLocalization
    @ObservationIgnored let languagePreferences: AppLanguagePreferences?
    let appSupportURL: URL
    let agentHomeDirectory: URL
    let agentEnvironment: [String: String]
    var rootURL: URL? {
        didSet {
            requestPresentationObservation()
            defaultAgentDirectoryRefresh = [:]
            agentDirectoryAuditFailures = [:]
            if oldValue?.standardizedFileURL != rootURL?.standardizedFileURL {
                agentCapabilitySnapshot = [:]
                catalogItems = []
                catalogItemsByID = [:]
                catalogItemsBySource = [:]
                localSourcesInspectionSnapshot = []
                agentFindings = []
                missingCatalogItemIDs = []
                relationOwnershipSnapshot = [:]
                observedLocalSourceNames = nil
                isRefreshingLocalSources = false
                resolvedRootPath = nil

                rebuildCatalogPresentation()
            }
        }
    }
    var availableSkills: [AvailableSkill] {
        didSet { if oldValue != availableSkills { rebuildCatalogPresentation(); requestPresentationObservation() } }
    }
    var installedSkills: [InstalledSkill] {
        didSet { if oldValue != installedSkills { rebuildCatalogPresentation(); requestPresentationObservation() } }
    }
    var sources: [SkillSource] {
        didSet { if oldValue != sources { rebuildCatalogPresentation(); requestPresentationObservation() } }
    }
    // Observation only; persistent identities remain available to Agents and recovery.
    var missingCatalogItemIDs: Set<String> = []
    var catalogItems: [Phase1SkillPresentation] = []
    var catalogItemsByID: [String: Phase1SkillPresentation] = [:]
    var catalogItemsBySource: [UUID: [Phase1SkillPresentation]] = [:]
    var localSourcesInspectionSnapshot: [SkillSource] = []
    var agentLinks: [AgentLinkRecord] {
        didSet { if oldValue != agentLinks { rebuildAgentPresentation() } }
    }
    var tags: [TagRecord]
    var statusMessage: LocalizedMessage?
    var errorMessage: LocalizedMessage?
    var scanStatusMessage: LocalizedMessage?
    var isRefreshingInstalled: Bool
    var isRefreshingLocalSources = false
    var observedLocalSourceNames: Set<String>? {
        didSet { if oldValue != observedLocalSourceNames { rebuildCatalogPresentation() } }
    }
    @ObservationIgnored var resolvedRootPath: String?
    @ObservationIgnored var libraryReadGeneration: UInt64 = 0
    @ObservationIgnored var rootInspectionGeneration: UInt64 = 0
    @ObservationIgnored var agentObservationGeneration: UInt64 = 0
    var scannedSkillCount: Int
    var searchText: String
    var language: AppLanguage {
        didSet { languagePreferences?.language = language }
    }
    var cachePolicyName: String
    var agentPathOverrides: [AgentKind: String] {
        didSet { if oldValue != agentPathOverrides { agentCapabilitySnapshot = [:]; agentPathSettingsSnapshot = []; requestPresentationObservation() } }
    }
    var localState: SkillsHubLocalState {
        didSet {
            rebuildRelationPresentationIndexes()
            if oldValue.targetObservations != localState.targetObservations { requestPresentationObservation() }
        }
    }
    var agentDetections: [AgentDetectionSnapshot] {
        didSet {
            if oldValue.map(\.installationEvidence) != agentDetections.map(\.installationEvidence) {
                desktopIconSnapshot = [:]
                observedDesktopIconPaths = []
            }
            if oldValue != agentDetections { agentCapabilitySnapshot = [:]; rebuildAgentPresentation() }
        }
    }
    var agentFindings: [AgentDirectoryFinding]
    var defaultAgentDirectoryRefresh: [AgentKind: AgentDefaultDirectoryRefreshStatus] = [:]
    var agentDirectoryAuditFailures: [String: LocalizedMessage] = [:]
    var rootSnapshot: RootSnapshot? {
        didSet {
            rebuildRelationPresentationIndexes()
            if oldValue?.metadata.agents != rootSnapshot?.metadata.agents { agentCapabilitySnapshot = [:]; rebuildAgentPresentation() }
            if oldValue?.metadata.enablementIntents != rootSnapshot?.metadata.enablementIntents {
                rebuildCatalogPresentation()
            }
            requestPresentationObservation()
        }
    }
    var agentDescriptorSnapshot = InstalledAgentDescriptorBuilder().build(
        detections: [], configurations: AgentConfigurationRecord.phase1BuiltIns, links: []
    )
    var agentPathSettingsSnapshot: [AgentPathSettingRecord] = []
    var agentCapabilitySnapshot: [String: AgentCapabilityPresentation] = [:]
    var contentObservationSnapshot: [String: TargetObservation] = [:]
    var relationOwnershipSnapshot: [String: RelationOwnershipClassification] = [:]
    var desktopIconSnapshot: [String: NSImage] = [:]
    @ObservationIgnored var observedDesktopIconPaths: Set<String> = []
    var isRefreshingPresentation = false
    @ObservationIgnored var presentationObservationGeneration: UInt64 = 0
    @ObservationIgnored var presentationObservationTask: Task<Void, Never>?
    var presentationIntents: [String: EnablementIntent] = [:]
    var presentationObservations: [String: TargetObservation] = [:]
    var presentationVerifications: [String: VerificationRecord] = [:]
    var presentationEvidence: [String: ManagedRelationEvidence] = [:]
    var pendingRootInitialization: RootInspectionFacts?
    var lastRootInspectionResult: RootInspectionResult?
    var pendingPhase1OperationPlan: Phase1OperationPlan?
    var sourceRecheckResults: [UUID: LocalizedMessage] = [:]
    var recheckingSourceIDs: Set<UUID> = []
    var sourceUpdateChecks: [UUID: Bool] = [:]
    var sourceUpdateCheckDates: [UUID: Date] = [:]
    var checkingSourceIDs: Set<UUID> = []
    var updateCheckSummary: LocalizedMessage?
    var sourceUpdatePreview: SourceUpdatePreview?
    var sourceUpdateResult: SourceUpdateResult?
    var sourceUpdateFailures: [UUID: LocalizedMessage]
    var sourceUpdateFocusPath: String?
    var phase1Tasks: [Phase1TaskRecord]
    var relationActionResults: [String: ControllerRelationActionResult]
    var inFlightRelationActionIDs: Set<String>
    @ObservationIgnored var rootSessionLease: SecurityScopedAccessLease? {
        didSet { requestPresentationObservation() }
    }
    @ObservationIgnored private var pendingInspectionLeases: [String: SecurityScopedAccessLease]
    @ObservationIgnored let observation: FilesystemObservationController
    var observationStatus: ObservationLifecycleStatus
    /// Monotonic recheck token. Each recheck snapshots it before scanning and discards
    /// its own result if a newer recheck (or Root/session change) superseded it.
    @ObservationIgnored var recheckGeneration: UInt64
    @ObservationIgnored var recheckTask: Task<Void, Never>?
    @ObservationIgnored var recheckTaskID: UUID?
    @ObservationIgnored var pendingRecheckScopes: Set<ObservationScope>
    @ObservationIgnored var pendingFullRecheck: Bool
    @ObservationIgnored var pendingManagedRootReload: Bool
    @ObservationIgnored var pendingLocalOnlyRecheck = true
    init(
        metadataStore: SkillsHubMetadataStore = SkillsHubMetadataStore(),
        presentationService: SkillCatalogPresentationService = SkillCatalogPresentationService(),
        settingsService: AppSettingsService = AppSettingsService(),
        agentLinkService: AgentLinkService = AgentLinkService(),
        agentPathResolver: AgentPathResolver = AgentPathResolver(),
        localStateStore: SkillsHubLocalStateStore = SkillsHubLocalStateStore(),
        agentAuditService: AgentDirectoryAuditService = AgentDirectoryAuditService(),
        sourceRemovalService: SourceRemovalService? = nil,
        sourceUpdateService: SourceUpdateService? = nil,
        localization: SkillsHubLocalization = SkillsHubLocalization(),
        languagePreferences: AppLanguagePreferences? = nil,
        fileManager: FileManager = .default,
        appSupportURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("SkillsHub", isDirectory: true) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("SkillsHub", isDirectory: true),
        agentHomeDirectory: URL = UserHomeDirectoryResolver.currentHomeDirectory(),
        agentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        startupAccessStore: StartupAccessStoring? = nil,
        securityScopedAccessProvider: SecurityScopedAccessProvider = SecurityScopedAccessProvider(),
        filesystemEventStreamFactory: @escaping () -> any FilesystemEventStreaming = { InertFilesystemEventStream() }
    ) {
        self.metadataStore = metadataStore
        self.presentationService = presentationService
        self.settingsService = settingsService
        self.agentLinkService = agentLinkService
        self.agentPathResolver = agentPathResolver
        self.localStateStore = localStateStore
        self.agentAuditService = agentAuditService
        self.sourceRemovalService = sourceRemovalService ?? SourceRemovalService(fileManager: fileManager)
        self.sourceUpdateService = sourceUpdateService ?? SourceUpdateService(fileManager: fileManager)
        self.startupAccessStore = startupAccessStore ?? SecurityScopedStartupAccessStore(appSupportURL: appSupportURL, fileManager: fileManager)
        self.securityScopedAccessProvider = securityScopedAccessProvider
        self.phase1OperationPlanner = Phase1OperationPlanner(fileManager: fileManager)
        self.phase1OperationCoordinator = Phase1OperationCoordinator(metadataStore: metadataStore, fileManager: fileManager)
        self.relationActionCoordinator = RelationActionCoordinator()
        self.relationActionRuntime = RelationActionControllerRuntime(
            metadataStore: metadataStore,
            localStateStore: localStateStore,
            linkService: agentLinkService,
            fileManager: fileManager
        )
        #if DEBUG
        self.phase1UITestFixtureLease = nil
        self.githubHTTPDataClientOverride = nil
        #endif
        self.localization = localization
        self.languagePreferences = languagePreferences
        self.fileManager = fileManager
        self.appSupportURL = appSupportURL
        self.agentHomeDirectory = agentHomeDirectory
        self.agentEnvironment = agentEnvironment
        self.availableSkills = []
        self.installedSkills = []
        self.sources = []
        self.agentLinks = []
        self.tags = []
        self.scanStatusMessage = nil
        self.isRefreshingInstalled = false
        self.scannedSkillCount = 0
        self.searchText = ""
        self.language = languagePreferences?.language ?? .system
        self.cachePolicyName = "Default"
        self.agentPathOverrides = [:]
        self.localState = SkillsHubLocalState()
        self.agentDetections = []
        self.agentFindings = []
        self.rootSnapshot = nil
        self.pendingRootInitialization = nil
        self.lastRootInspectionResult = nil
        self.pendingPhase1OperationPlan = nil
        self.sourceUpdatePreview = nil
        self.sourceUpdateResult = nil
        self.sourceUpdateFailures = [:]
        self.sourceUpdateFocusPath = nil
        self.phase1Tasks = []
        self.relationActionResults = [:]
        self.inFlightRelationActionIDs = []
        self.rootSessionLease = nil
        self.pendingInspectionLeases = [:]
        self.observation = FilesystemObservationController(streamFactory: filesystemEventStreamFactory)
        self.observationStatus = .notStarted
        self.recheckGeneration = 0
        self.recheckTask = nil
        self.recheckTaskID = nil
        self.pendingRecheckScopes = []
        self.pendingFullRecheck = false
        self.pendingManagedRootReload = false
    }

    func rememberUserSelectedAccess(to url: URL) throws {
        let normalizedURL = url.standardizedFileURL
        let key = normalizedURL.path
        if let staleLease = pendingInspectionLeases.removeValue(forKey: key) {
            try endSecurityScopedAccessLease(staleLease)
        }
        let lease: SecurityScopedAccessLease
        do {
            lease = try securityScopedAccessProvider.acquire(
                url: normalizedURL,
                owner: .inspection(UUID())
            )
        } catch SecurityScopedAccessError.startDenied {
            throw SkillsHubLibraryFailure.invalidSource("Folder authorization was not granted.")
        }
        do {
        try startupAccessStore.saveAccess(to: normalizedURL)
            requestPresentationObservation()
            pendingInspectionLeases[key] = lease
        } catch {
            do {
                try endSecurityScopedAccessLease(lease)
            } catch let releaseError {
                throw releaseError
            }
            throw error
        }
    }

    func acquireSecurityScopedAccess(
        to url: URL,
        owner: SecurityScopedAccessOwner,
        endingSelectedInspection: Bool = true,
        resolvingPersistedBookmark: Bool = false
    ) throws -> SecurityScopedAccessLease {
        let normalizedURL = url.standardizedFileURL
        if endingSelectedInspection,
           let inspectionLease = pendingInspectionLeases.removeValue(forKey: normalizedURL.path) {
            try endSecurityScopedAccessLease(inspectionLease)
        }

        let resolution = resolvingPersistedBookmark
            ? try startupAccessStore.resolveAccess(to: normalizedURL)
            : nil
        let accessURL = resolution?.url ?? normalizedURL
        let lease = try securityScopedAccessProvider.acquire(url: accessURL, owner: owner)
        if resolution?.isStale == true {
            do {
                try startupAccessStore.saveAccess(to: accessURL)
            } catch {
                do {
                    try endSecurityScopedAccessLease(lease)
                } catch let releaseError {
                    throw releaseError
                }
                throw error
            }
        }
        return lease
    }

    func inspectPersistedAccess(to url: URL) throws -> Bool {
        let normalizedURL = url.standardizedFileURL
        guard let resolution = try startupAccessStore.resolveAccess(to: normalizedURL) else {
            return false
        }
        let lease = try securityScopedAccessProvider.acquire(
            url: resolution.url,
            owner: .inspection(UUID())
        )
        if resolution.isStale {
            do {
                try startupAccessStore.saveAccess(to: resolution.url)
            } catch {
                do {
                    try endSecurityScopedAccessLease(lease)
                } catch let releaseError {
                    throw releaseError
                }
                throw error
            }
        }
        try endSecurityScopedAccessLease(lease)
        return true
    }

    func endSelectedInspectionAccess(to url: URL) throws {
        let key = url.standardizedFileURL.path
        guard let lease = pendingInspectionLeases.removeValue(forKey: key) else {
            return
        }
        try endSecurityScopedAccessLease(lease)
    }

    func takeSelectedInspectionLease(to url: URL) -> SecurityScopedAccessLease? {
        pendingInspectionLeases.removeValue(forKey: url.standardizedFileURL.path)
    }

    func endSecurityScopedAccessLease(_ lease: SecurityScopedAccessLease) throws {
        let result = lease.end(by: lease.owner)
        guard result == .stopped else {
            let detail = lease.stopFailureDescription ?? String(describing: result)
            throw SkillsHubLibraryFailure.invalidSource(
                "Security-scoped access release failed for \(lease.owner.identity): \(detail)"
            )
        }
    }
}

nonisolated enum SkillsHubLibraryFailure: Error, Equatable {
    case missingRoot
    case missingSkill(String)
    case invalidSource(LocalizedMessage)
    case missingAgentPath(AgentKind)
}

#if DEBUG
extension SkillsHubLibraryController {
    static func emptyUIFixture(
        configuration: Phase1UITestFixtureConfiguration,
        languagePreferences: AppLanguagePreferences? = nil
    ) throws -> SkillsHubLibraryController {
        let controller = makeUIFixtureController(
            configuration: configuration,
            languagePreferences: languagePreferences
        )
        try controller.acquireUIFixtureAccess(configuration: configuration)
        controller.rootURL = nil
        controller.errorMessage = nil
        controller.statusMessage = nil
        controller.scannedSkillCount = 0
        return controller
    }

    static func uiFixture(
        configuration: Phase1UITestFixtureConfiguration,
        languagePreferences: AppLanguagePreferences? = nil
    ) throws -> SkillsHubLibraryController {
        let home = configuration.home
        let root = configuration.root
        let sourceRoot = configuration.source
        let controller = makeUIFixtureController(
            configuration: configuration,
            languagePreferences: languagePreferences
        )
        if configuration.githubImportFixture {
            controller.githubHTTPDataClientOverride = Phase1UITestGitHubHTTPClient(
                traceURL: configuration.runRoot.appending(path: "github-requests.jsonl")
            )
        }
        try controller.acquireUIFixtureAccess(configuration: configuration)
        let requiredFiles = [
            sourceRoot.appending(path: "review-fixture/SKILL.md"),
            sourceRoot.appending(path: "candidate-fixture/SKILL.md"),
            root.appending(path: "local/review-fixture/SKILL.md"),
            root.appending(path: "local/trash-fixture/SKILL.md"),
            root.appending(path: "local/roles-skills/SKILL.md"),
            root.appending(path: "local/roles-skills/workflows/product-development/platforms/apple/workflow-apple-feature-delivery/SKILL.md")
        ]
        guard requiredFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw SkillsHubLibraryFailure.invalidSource("The UI test process did not create the complete fixture tree before launch.")
        }
        if configuration.creationMaterialFixture,
           FileManager.default.fileExists(atPath: root.appendingPathComponent(".skillshub.json").path) {
            // Read the persisted fixture without reseeding its canonical metadata.
            controller.rootURL = root
            Task {
                do {
                    try await controller.reloadFromDisk()
                    await controller.refreshAgentLightScan(checkInstallation: true)
                } catch { controller.handle(error) }
            }
            return controller
        }

        if let faultInjection = configuration.faultInjection {
            controller.phase1OperationCoordinator = Phase1OperationCoordinator(
                metadataStore: controller.metadataStore,
                fileManager: controller.fileManager,
                faultInjection: faultInjection
            )
        }
        let sourceID = fixtureUUID("11111111-1111-1111-1111-111111111111")
        let managedSource = configuration.sourceUpdateFixture
            ? root.appending(path: "local/review-fixture", directoryHint: .isDirectory)
            : root.appending(path: "local/fixture-source", directoryHint: .isDirectory)
        let externalSource = sourceRoot.appending(path: "review-fixture", directoryHint: .isDirectory)
        let sourceIndex = LocalSourceIndexer().index(directory: managedSource, sourceID: sourceID)
        let baseline = configuration.sourceUpdateFixture
            ? try ContentManifestBuilder().build(for: managedSource, authorizedRoot: managedSource)
            : nil

        controller.rootURL = root
        controller.sources = [
            SkillSource(
                id: sourceID,
                kind: .localDirectory,
                name: "Fixture Source",
                localPath: managedSource.path,
                externalLocalPath: configuration.sourceUpdateFixture ? externalSource.path : nil,
                contentFingerprint: sourceIndex.source.contentFingerprint,
                directoryIdentity: sourceIndex.source.directoryIdentity,
                externalDirectoryIdentity: configuration.sourceUpdateFixture
                    ? LocalSourceIndexer().index(directory: externalSource, sourceID: sourceID).source.directoryIdentity
                    : nil,
                lastCheckedAt: Date(timeIntervalSince1970: 0),
                baselineManifest: baseline
            )
        ]
        controller.availableSkills = [
            AvailableSkill(
                id: "review-fixture",
                sourceID: sourceID,
                skillPath: configuration.sourceUpdateFixture ? "." : "review-fixture",
                name: "Review Fixture",
                description: "Reviews refreshed code changes from a fixture source.",
                validation: .valid,
                candidateID: "fixture-review-candidate",
                manifestDigest: sourceIndex.availableSkills.first { $0.skillPath == "review-fixture" }?.manifestDigest
            ),
            AvailableSkill(
                id: "candidate-fixture",
                sourceID: sourceID,
                skillPath: "candidate-fixture",
                name: "Candidate Fixture",
                description: "A valid local candidate waiting for a reviewed managed-copy plan.",
                validation: .valid,
                candidateID: "fixture-publish-candidate",
                manifestDigest: sourceIndex.availableSkills.first { $0.skillPath == "candidate-fixture" }?.manifestDigest
            )
        ]
        controller.installedSkills = [
            InstalledSkill(
                id: "review-fixture",
                sourceID: sourceID,
                name: "Review Fixture",
                description: "Reviews code changes from a fixture source.",
                installedPath: (configuration.sourceUpdateFixture ? managedSource : managedSource.appending(path: "review-fixture")).path,
                sourceKind: .localDirectory,
                validation: .valid,
                purpose: PurposeMetadata(text: "Review fixture purpose.", source: .user, updatedAt: Date(timeIntervalSince1970: 0)),
                tagIDs: [],
                installedAt: Date(timeIntervalSince1970: 0),
                assetID: fixtureUUID("33333333-3333-4333-a333-333333333333"),
                candidateID: "fixture-review-candidate"
            ),
            InstalledSkill(
                id: "broken-fixture",
                sourceID: nil,
                name: "Broken Fixture",
                description: "Shows an invalid skill in Needs Attention.",
                installedPath: root.appendingPathComponent("local/broken-fixture", isDirectory: true).path,
                sourceKind: .manualFilesystem,
                validation: SkillValidationResult(
                    status: .invalid,
                    messages: [
                        ValidationMessage(id: "missing-skill-file", severity: .error, message: "Missing SKILL.md")
                    ],
                    risks: []
                ),
                purpose: nil,
                tagIDs: [],
                installedAt: Date(timeIntervalSince1970: 1)
            ),
            InstalledSkill(
                id: "roles-skills",
                sourceID: nil,
                name: "roles-skills",
                description: "Routes agents to role and workflow skill packs.",
                installedPath: root.appendingPathComponent("local/roles-skills", isDirectory: true).path,
                sourceKind: .localDirectory,
                validation: .valid,
                purpose: PurposeMetadata(text: "Composite roles fixture.", source: .generated, updatedAt: Date(timeIntervalSince1970: 2)),
                tagIDs: [],
                installedAt: Date(timeIntervalSince1970: 2)
            ),
            InstalledSkill(
                id: "trash-fixture",
                sourceID: nil,
                name: "Trash Fixture",
                description: "Isolated direct source used only for Trash acceptance.",
                installedPath: root.appendingPathComponent("local/trash-fixture", isDirectory: true).path,
                sourceKind: .manualFilesystem,
                validation: .valid,
                purpose: nil,
                tagIDs: [],
                installedAt: Date(timeIntervalSince1970: 3)
            )
        ]
        if configuration.githubRemovalFixture {
            let sourceID = fixtureUUID("22222222-2222-2222-2222-222222222222")
            let repository = root.appending(path: "github/acme/github-removal-fixture", directoryHint: .isDirectory)
            let index = LocalSourceIndexer().index(directory: repository, sourceID: sourceID)
            controller.sources.append(SkillSource(
                id: sourceID,
                kind: .githubRepository,
                name: "acme/github-removal-fixture",
                urlString: "https://github.com/acme/github-removal-fixture",
                ref: "main",
                resolvedVersion: "fixture-commit",
                localPath: repository.path,
                contentFingerprint: index.source.contentFingerprint,
                directoryIdentity: index.source.directoryIdentity
            ))
            controller.availableSkills.append(AvailableSkill(
                id: "github-removal-fixture",
                sourceID: sourceID,
                skillPath: ".",
                name: "Trash Fixture",
                description: "Isolated GitHub source used only for Trash acceptance.",
                validation: .valid,
                candidateID: "github-removal-candidate",
                manifestDigest: index.availableSkills.first?.manifestDigest
            ))
            controller.installedSkills.append(InstalledSkill(
                id: "github-removal-fixture",
                sourceID: sourceID,
                name: "Trash Fixture",
                description: "Isolated GitHub source used only for Trash acceptance.",
                installedPath: repository.path,
                sourceKind: .githubRepository,
                validation: .valid,
                purpose: nil,
                tagIDs: [],
                installedAt: Date(timeIntervalSince1970: 4),
                candidateID: "github-removal-candidate"
            ))
        }
        var fixtureManagedEvidence: ManagedRelationEvidence?
        if let rolesSkill = controller.installedSkills.first(where: { $0.id == "roles-skills" }) {
            let relation = AgentRelationIdentity(
                assetID: rolesSkill.assetID,
                agentID: AgentKind.codex.rawValue,
                scope: .global
            )
            let linkURL = home.appending(path: ".codex/skills/roles-skills")
            let observation = try RelationOwnershipInspector().inspect(
                linkURL: linkURL,
                relation: relation,
                canonicalTargetPath: rolesSkill.installedPath,
                evidence: nil
            ).observation
            guard let fileIdentity = observation.fileIdentity else {
                throw SkillsHubLibraryFailure.invalidSource(
                    "UI fixture link identity is unavailable: \(linkURL.path)"
                )
            }
            fixtureManagedEvidence = ManagedRelationEvidence(
                relation: relation,
                linkPath: linkURL.path,
                canonicalTargetPath: rolesSkill.installedPath,
                profileID: "skillshub.agent-profile.codex.global@1",
                profileVersion: 1,
                createdAtGeneration: 0,
                fileIdentity: fileIdentity,
                createdAt: Date(timeIntervalSince1970: 0)
            )
        }
        controller.agentFindings = [
            AgentDirectoryFinding(
                id: "fixture-agent-broken-link",
                agentID: AgentKind.codex.rawValue,
                agent: .codex,
                agentDisplayName: "Codex",
                domain: .link,
                severity: .warning,
                type: .brokenSymlink,
                entryName: "codex-review",
                entryKind: .brokenSymlink,
                summary: "Agent entry is a broken symlink.",
                evidence: ["Symlink target: \(configuration.runRoot.appending(path: "missing-codex-review").path)"],
                sourcePath: home.appending(path: ".codex/skills/codex-review").path,
                targetPath: configuration.runRoot.appending(path: "missing-codex-review").path,
                linkPath: home.appending(path: ".codex/skills/codex-review").path,
                symlinkTarget: configuration.runRoot.appending(path: "missing-codex-review").path,
                skillFileHash: nil,
                matchCandidates: [],
                recommendedAction: .deleteBrokenLink,
                ignored: false
            ),
            AgentDirectoryFinding(
                id: "fixture-agent-duplicate",
                agentID: AgentKind.codex.rawValue,
                agent: .codex,
                agentDisplayName: "Codex",
                domain: .agentDirectory,
                severity: .warning,
                type: .duplicateWithHub,
                entryName: "shared-review",
                entryKind: .localDirectory,
                summary: "Agent entry may duplicate a Hub skill.",
                evidence: ["Metadata name: Shared Review", "Entry name: shared-review"],
                sourcePath: home.appending(path: ".codex/skills/shared-review", directoryHint: .isDirectory).path,
                targetPath: nil,
                linkPath: nil,
                symlinkTarget: nil,
                skillFileHash: "sha256:fixture-shared-review",
                matchCandidates: [
                    HubSkillMatchCandidate(
                        hubSkillID: "shared-review-a",
                        displayName: "Shared Review A",
                        hubRelativePath: "local/shared-review-a",
                        matchStrength: .medium,
                        evidence: [.metadataName]
                    ),
                    HubSkillMatchCandidate(
                        hubSkillID: "shared-review-b",
                        displayName: "Shared Review B",
                        hubRelativePath: "local/shared-review-b",
                        matchStrength: .medium,
                        evidence: [.metadataName, .entryName]
                    )
                ],
                recommendedAction: .viewLightweightDiff,
                ignored: false
            ),
            AgentDirectoryFinding(
                id: "fixture-agent-owned",
                agentID: AgentKind.codex.rawValue,
                agent: .codex,
                agentDisplayName: "Codex",
                domain: .agentDirectory,
                severity: .suggestion,
                type: .localDirectoryNotManaged,
                entryName: "agent-owned-review",
                entryKind: .localDirectory,
                summary: "This directory is owned by Codex and is not managed by Skills Hub.",
                evidence: ["Entry kind: local directory", "Ownership: no Skills Hub relation evidence"],
                sourcePath: home.appending(path: ".codex/skills/agent-owned-review", directoryHint: .isDirectory).path,
                targetPath: nil,
                linkPath: nil,
                symlinkTarget: nil,
                skillFileHash: nil,
                matchCandidates: [],
                recommendedAction: .openLocation,
                ignored: false
            ),
            AgentDirectoryFinding(
                id: "fixture-agent-permission",
                agentID: AgentKind.claudeCode.rawValue,
                agent: .claudeCode,
                agentDisplayName: "Claude Code",
                domain: .agentDirectory,
                severity: .error,
                type: .permissionDenied,
                entryName: "claude-skills",
                entryKind: .missing,
                summary: "Agent skills directory is not readable or writable.",
                evidence: ["Skills directory: \(home.appending(path: ".claude/skills", directoryHint: .isDirectory).path)"],
                sourcePath: home.appending(path: ".claude/skills", directoryHint: .isDirectory).path,
                targetPath: nil,
                linkPath: nil,
                symlinkTarget: nil,
                skillFileHash: nil,
                matchCandidates: [],
                recommendedAction: .viewPermissionGuidance,
                ignored: false
            )
        ]
        controller.agentDetections = [
            AgentDetectionSnapshot(
                agentID: AgentKind.codex.rawValue,
                agent: .codex,
                displayName: AgentKind.codex.displayName,
                markerPath: home.appending(path: ".codex", directoryHint: .isDirectory).path,
                skillsDirectory: home.appending(path: ".codex/skills", directoryHint: .isDirectory).path,
                detected: true,
                skillsDirectoryExists: true,
                entryCount: 0,
                readable: true,
                writable: true,
                isCustom: false,
                installationEvidence: AgentInstallationEvidence(
                    agent: .codex,
                    digest: "ui-fixture-installation-codex"
                )
            ),
            AgentDetectionSnapshot(
                agentID: AgentKind.claudeCode.rawValue,
                agent: .claudeCode,
                displayName: AgentKind.claudeCode.displayName,
                markerPath: home.appending(path: ".claude", directoryHint: .isDirectory).path,
                skillsDirectory: home.appending(path: ".claude/skills", directoryHint: .isDirectory).path,
                detected: true,
                skillsDirectoryExists: true,
                entryCount: 0,
                readable: true,
                writable: true,
                isCustom: false,
                installationEvidence: AgentInstallationEvidence(
                    agent: .claudeCode,
                    digest: "ui-fixture-installation-claudeCode"
                )
            )
        ]
        controller.phase1Tasks = [
            fixtureTask(id: fixtureUUID("55555555-5555-5555-5555-555555555555"), kind: .registerLocalSource, phase: .waitingConfirmation, title: "Register local source", result: "Waiting for confirmation.", time: 4),
            fixtureTask(id: fixtureUUID("66666666-6666-6666-6666-666666666666"), kind: .publishManagedCopy, phase: .verifying, title: "Publish managed Skill", result: "Verifying current facts.", time: 3),
            fixtureTask(id: fixtureUUID("77777777-7777-7777-7777-777777777777"), kind: .publishManagedCopy, phase: .needsAttention, title: "Publish managed Skill", result: "Current target cannot be verified.", time: 2),
            fixtureTask(id: fixtureUUID("88888888-8888-8888-8888-888888888888"), kind: .registerLocalSource, phase: .completed, title: "Register local source", result: "Registered after explicit confirmation; no Skill was managed.", time: 1),
            fixtureRelationTask(
                id: fixtureUUID("99999999-9999-9999-9999-999999999991"),
                skillID: "review-fixture",
                outcome: "Blocked",
                limitation: "The exact Agent target authorization is no longer current.",
                safeNextStep: "Restore current target authorization in Agent configuration, then observe current facts.",
                time: 7
            ),
            fixtureRelationTask(
                id: fixtureUUID("99999999-9999-9999-9999-999999999992"),
                skillID: "review-fixture",
                outcome: "Failed",
                limitation: "The write stopped before a verified relationship delta.",
                safeNextStep: "Open the current Skill and inspect the preserved conflict before another action.",
                time: 6
            ),
            fixtureRelationTask(
                id: fixtureUUID("99999999-9999-9999-9999-999999999993"),
                skillID: "removed-fixture",
                outcome: "Unknown",
                limitation: "Post-write observation is incomplete and the original Skill is no longer reachable.",
                safeNextStep: "Keep this evidence read-only and recover navigation from the current Skills list.",
                time: 5
            )
        ]
        try controller.metadataStore.ensureRootLayout(at: root)
        let updateAgents = [
            AgentConfigurationRecord(
                id: AgentKind.codex.rawValue,
                agent: .codex,
                displayName: AgentKind.codex.displayName,
                iconMonogram: nil,
                skillsDirectory: home.appending(path: ".codex/skills", directoryHint: .isDirectory).path
            ),
            AgentConfigurationRecord(
                id: AgentKind.claudeCode.rawValue,
                agent: .claudeCode,
                displayName: AgentKind.claudeCode.displayName,
                iconMonogram: nil,
                skillsDirectory: home.appending(path: ".claude/skills", directoryHint: .isDirectory).path
            ),
            AgentConfigurationRecord(
                id: "custom",
                agent: nil,
                displayName: "Custom Agent",
                iconMonogram: "CA",
                skillsDirectory: home.appending(path: ".custom/skills", directoryHint: .isDirectory).path
            )
        ]
        let overflowAgents = updateAgents + (1...16).map { index in
            AgentConfigurationRecord(
                id: "overflow-\(index)",
                agent: nil,
                displayName: index == 16 ? "zzzz 非常に長いカスタムAgent名" : "Overflow Agent \(index.formatted(.number.precision(.integerLength(2))))",
                iconMonogram: index == 16 ? "日本語A" : "A\(index)",
                skillsDirectory: home.appending(path: ".overflow-\(index)/skills", directoryHint: .isDirectory).path
            )
        }
        if configuration.agentOverflowFixture {
            for configuration in overflowAgents where configuration.agent == nil {
                guard let skillsDirectory = configuration.skillsDirectory else { continue }
                let directory = URL(fileURLWithPath: skillsDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                controller.agentDetections.append(AgentDetectionSnapshot(
                    agentID: configuration.id,
                    agent: nil,
                    displayName: configuration.displayName,
                    markerPath: directory.deletingLastPathComponent().path,
                    skillsDirectory: directory.path,
                    detected: true,
                    skillsDirectoryExists: true,
                    entryCount: 0,
                    readable: true,
                    writable: true,
                    isCustom: true
                ))
            }
        }
        let updateIntents = configuration.sourceUpdateFixture
            ? updateAgents.map {
                EnablementIntent(
                    assetID: controller.installedSkills[0].assetID,
                    agentID: $0.id,
                    scope: .global,
                    isEnabled: true,
                    generation: 0
                )
            }
            : []
        controller.rootSnapshot = try controller.metadataStore.writeInitialMetadata(
            SkillsHubMetadata(
                rootConfig: RootConfig(rootPath: root.path),
                sources: controller.sources,
                availableSkills: controller.availableSkills,
                installedSkills: controller.installedSkills,
                agents: configuration.agentOverflowFixture
                    ? overflowAgents
                    : configuration.sourceUpdateFixture ? updateAgents : Array(updateAgents.prefix(2)),
                tags: controller.tags,
                uiState: controller.persistedUIState(),
                enablementIntents: updateIntents,
                managedRelationEvidence: [fixtureManagedEvidence].compactMap { $0 }
            ),
            to: root
        )
        controller.agentPathOverrides = Self.agentPathOverrides(
            from: controller.rootSnapshot?.metadata.agents ?? []
        )
        if configuration.installationStatusFixture {
            Task { await controller.refreshAgentLightScan(checkInstallation: true) }
        }
        return controller
    }

    private func acquireUIFixtureAccess(
        configuration: Phase1UITestFixtureConfiguration
    ) throws {
        let lease = try securityScopedAccessProvider.acquire(
            url: configuration.authorizedFixtureParent,
            owner: .rootSession(configuration.runID)
        )
        phase1UITestFixtureLease = lease
        try configuration.validateAccessibleDirectories(fileManager: fileManager)
        rootSessionLease = try securityScopedAccessProvider.acquire(
            url: configuration.root,
            owner: .rootSession(UUID())
        )
    }

    private static func makeUIFixtureController(
        configuration: Phase1UITestFixtureConfiguration,
        languagePreferences: AppLanguagePreferences?
    ) -> SkillsHubLibraryController {
        SkillsHubLibraryController(
            agentLinkService: configuration.creationMaterialFixture
                ? AgentLinkService(relationPrimitiveHook: { point, _ in
                    if point == .afterMaterialIsolation { throw CocoaError(.fileWriteUnknown) }
                }) : AgentLinkService(),
            agentAuditService: AgentDirectoryAuditService { agent, _ in
                guard agent == .codex || agent == .claudeCode else { return .absent }
                if configuration.installationStatusFixture {
                    let value = try? String(contentsOf: configuration.runRoot.appendingPathComponent("installation-status"), encoding: .utf8)
                    if value?.trimmingCharacters(in: .whitespacesAndNewlines) == "icons-desktop" {
                        return .present(AgentInstallationEvidence(agent: agent, digest: "fixture-icon-\(agent.rawValue)", cliInstalled: false,
                                                                 desktopAppPath: configuration.runRoot.appendingPathComponent("\(agent.rawValue).app").path))
                    }
                    guard agent == .codex else { return .absent }
                    switch value?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    case "desktop":
                        return .present(AgentInstallationEvidence(agent: agent, digest: "fixture-desktop", cliInstalled: false, desktopAppPath: "/fixture/Codex.app"))
                    case "cli":
                        return .present(AgentInstallationEvidence(agent: agent, digest: "fixture-cli", cliInstalled: true))
                    case "absent": return .absent
                    default: return .unverifiable
                    }
                }
                return .present(
                    AgentInstallationEvidence(
                        agent: agent,
                        digest: "ui-fixture-installation-\(agent.rawValue)"
                    )
                )
            },
            languagePreferences: languagePreferences,
            agentHomeDirectory: configuration.home,
            agentEnvironment: [:],
            startupAccessStore: Phase1UITestFixtureStartupAccessStore(
                authorizedParent: configuration.authorizedFixtureParent,
                withheldTarget: configuration.agentAuthorizationFixture
                    ? configuration.home.appending(path: ".codex/skills", directoryHint: .isDirectory) : nil
            ),
            securityScopedAccessProvider: SecurityScopedAccessProvider(
                adapter: Phase1UITestFixtureAccessAdapter(
                    authorizedParent: configuration.authorizedFixtureParent
                )
            )
        )
    }

    private static func fixtureTask(
        id: UUID,
        kind: Phase1TaskKind,
        phase: Phase1OperationPhase,
        title: String,
        result: String,
        time: TimeInterval
    ) -> Phase1TaskRecord {
        Phase1TaskRecord(
            id: id,
            kind: kind,
            title: LocalizedMessage(title),
            objectID: kind == .registerLocalSource ? "fixture-source" : "candidate-fixture",
            phase: phase,
            result: LocalizedMessage(result),
            planDigest: "fixture-plan-\(Int(time))",
            events: [
                Phase1TaskEvent(id: id, phase: phase, message: LocalizedMessage(result), occurredAt: Date(timeIntervalSince1970: time))
            ],
            updatedAt: Date(timeIntervalSince1970: time)
        )
    }

    private static func fixtureRelationTask(
        id: UUID,
        skillID: String,
        outcome: String,
        limitation: String,
        safeNextStep: String,
        time: TimeInterval
    ) -> Phase1TaskRecord {
        let relation = AgentRelationIdentity(
            assetID: StableIdentity.assetID(candidateID: skillID, canonicalPathComponent: skillID),
            agentID: AgentKind.codex.rawValue,
            scope: .global
        )
        return Phase1TaskRecord(
            id: id,
            kind: .setAgentRelation,
            title: "Enable Codex for \(skillID)",
            objectID: skillID,
            phase: .needsAttention,
            result: "Current relationship requires attention.",
            planDigest: "fixture-relation-\(outcome.lowercased())",
            events: [
                Phase1TaskEvent(id: UUID(), phase: .executing, message: "The action was limited to Codex and \(skillID).", occurredAt: Date(timeIntervalSince1970: time - 2)),
                Phase1TaskEvent(id: UUID(), phase: .observing, message: "Current filesystem facts were re-read.", occurredAt: Date(timeIntervalSince1970: time - 1)),
                Phase1TaskEvent(id: UUID(), phase: .needsAttention, message: .verbatim(limitation), occurredAt: Date(timeIntervalSince1970: time))
            ],
            updatedAt: Date(timeIntervalSince1970: time),
            relationEvidence: Phase1RelationTaskEvidence(
                relation: relation,
                agentDisplayName: AgentKind.codex.displayName,
                skillID: skillID,
                skillName: skillID,
                desiredEnabled: true,
                outcome: outcome,
                actualDelta: ["No verified relationship delta is claimed."],
                verification: .currentlyUnverifiable,
                limitations: [limitation],
                safeNextStep: safeNextStep
            )
        )
    }

    private static func fixtureUUID(_ value: String) -> UUID {
        guard let identifier = UUID(uuidString: value) else {
            fatalError("Invalid static UI fixture UUID: \(value)")
        }
        return identifier
    }

}
#endif
