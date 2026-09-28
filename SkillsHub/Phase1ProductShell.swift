import SwiftUI

struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .english
}

private func appLocalized(_ text: String, language: AppLanguage) -> String {
    SkillsHubLocalization().localized(text, language: language)
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}

nonisolated enum Phase1NavigationDestination: Hashable, Identifiable {
    case allSkills
    case localSources
    case githubSources
    case agent(String)
    case tasks
    case settings
    case managementDirectory
    case operation(UUID)

    var id: String {
        switch self {
        case .allSkills: "all-skills"
        case .localSources: "local-sources"
        case .githubSources: "github-sources"
        case .agent(let id): "agent-\(id)"
        case .tasks: "tasks"
        case .settings: "settings"
        case .managementDirectory: "management-directory"
        case .operation(let id): "operation-\(id)"
        }
    }

    var title: String {
        switch self {
        case .allSkills: "All Skills"
        case .localSources: "Local Sources"
        case .githubSources: "GitHub Sources"
        case .agent: "Agent"
        case .tasks: "Operation and Recovery"
        case .settings: "Settings"
        case .managementDirectory: "Management Directory"
        case .operation: "Operation Details"
        }
    }
}

private struct Phase1AgentWorkspaceState {
    var query = ""
    var ownership: AgentWorkspaceOwnershipFilter = .all
    var needsAttentionOnly = false
    var selectedID: String?
}

private struct SkillsWorkspaceState {
    var selectedID: String?
    var sourceID: UUID?
    var query = ""
    var filter: Phase1SkillFilter = .all
    var needsAttentionOnly = false
}

struct Phase1ProductShell: View {

    @Bindable var library: SkillsHubLibraryController
    @Binding var selection: Phase1NavigationDestination
    @Binding var selectedLocalSourceID: UUID?
    @Binding var selectedGitHubSourceID: UUID?
    var establishRoot: () -> Void
    var connectRoot: () -> Void
    var addLocalSource: () -> Void
    var addGitHubSource: () -> Void
    var chooseAgentTarget: (AgentKind?, @escaping (URL) -> Void) -> Void
    @State private var skillsWorkspaceStates: [String: SkillsWorkspaceState] = [:]
    @State private var sourceReturnDestination: Phase1NavigationDestination?
    @State private var selectedSkillID: String?
    @State private var selectedSkillSourceID: UUID?
    @State private var skillReturnSourceID: UUID?
    @State private var sourceReturnSkillID: String?
    @State private var skillFilter: Phase1SkillFilter = .all
    @State private var skillNeedsAttentionOnly = false
    @State private var skillFocusRequest: String?
    @State private var localSourceQuery = ""
    @State private var githubSourceQuery = ""
    @State private var localSourceFocusRequest: UUID?
    @State private var githubSourceFocusRequest: UUID?
    @State private var agentWorkspaceStates: [String: Phase1AgentWorkspaceState] = [:]
    @State private var expandedTaskIDs: Set<UUID> = []
    @State private var taskScrollID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var configuredAgentID: String?
    @State private var isAddingAgent = false
    @State private var agentConfigurationDraft = AgentConfigurationDraft(
        displayName: "",
        iconMonogram: "",
        selectedTarget: nil,
        proposedTarget: nil
    )
    @State private var pendingNavigation: Phase1NavigationDestination?
    @State private var showUnsavedNavigationConfirmation = false
    @State private var dismissedObservationMessage: String?

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView(columnVisibility: $columnVisibility) {
                Phase1ProductSidebar(
                    selection: navigationSelection,
                    agents: library.visibleInstalledAgentDescriptors
                )
                .navigationSplitViewColumnWidth(min: 176, ideal: 196, max: 260)
                .toolbar(removing: .sidebarToggle)
                .background(FixedSidebarConfiguration())
            } detail: {
                VStack(spacing: 0) {
                    if let message = library.errorMessage {
                        StatusBanner(message: message, language: library.language, systemImage: "exclamationmark.triangle", style: .error)
                        Divider()
                    } else if let message = library.statusMessage {
                        StatusBanner(
                            message: message,
                            language: library.language,
                            systemImage: "checkmark.circle",
                            style: .status,
                            dismissAccessibilityLabel: appLocalized("Dismiss status", language: library.language),
                            dismiss: { library.clearStatus() }
                        )
                        Divider()
                    }
                    if let summary = library.updateCheckSummary {
                        HStack {
                            Text(library.localized(summary)).font(.callout)
                            Spacer()
                            Button(appLocalized("Dismiss status", language: library.language)) { library.updateCheckSummary = nil }
                                .disabled(!library.checkingSourceIDs.isEmpty)
                        }.padding(8)
                        Divider()
                    }
                    if selection == .allSkills, skillReturnSourceID == nil,
                       let message = library.observationDisplayMessage, message != dismissedObservationMessage {
                        HStack {
                            Label(message, systemImage: library.observationStatus.isUnavailable ? "exclamationmark.triangle" : "checkmark.circle")
                                .accessibilityValue(message)
                                .accessibilityIdentifier("filesystem-observation-status")
                            Spacer()
                            Button(appLocalized("Dismiss status", language: library.language)) { dismissedObservationMessage = message }
                                .disabled(library.isRefreshingInstalled)
                        }.font(.callout).padding(8)
                        Divider()
                    }
                    workspace
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .navigationTitle(usesToolbarTitle ? "" : title)
                .toolbar {
                    if usesToolbarTitle {
                        ToolbarItem(placement: .navigation) {
                            Text(title).font(.headline).frame(height: 36)
                        }
                    }
                }
            }
            .onChange(of: columnVisibility) { _, value in
                if value != .all { columnVisibility = .all }
            }
        }
        .frame(minWidth: 1040, minHeight: 560)
        .environment(\.appLanguage, library.language)
        .confirmationDialog(
            appLocalized("Discard unsaved changes?", language: library.language),
            isPresented: $showUnsavedNavigationConfirmation
        ) {
            Button(appLocalized("Save", language: library.language)) {
                saveAgentDraftAndNavigate()
            }
            .disabled(!canSaveAgentDraft)
            Button(appLocalized("Discard Changes", language: library.language), role: .destructive) {
                discardAgentDraftAndNavigate()
            }
            Button(appLocalized("Stay Here", language: library.language), role: .cancel) {
                pendingNavigation = nil
            }
        } message: {
            Text(appLocalized("The saved Agent configuration will remain unchanged.", language: library.language))
        }
    }

    private var workspace: AnyView {
        switch selection {
        case .allSkills:
            AnyView(skillsWorkspace)
        case .localSources:
            AnyView(Phase1SourcesWorkspace(
                library: library,
                selectedSourceID: $selectedLocalSourceID,
                focusRequest: $localSourceFocusRequest,
                kind: .localDirectory,
                addSource: addLocalSource,
                openSkills: { source in openSkills(for: source) },
                returnToSkills: sourceDetailReturnAction,
                query: $localSourceQuery
            ))
        case .githubSources:
            AnyView(Phase1SourcesWorkspace(
                library: library,
                selectedSourceID: $selectedGitHubSourceID,
                focusRequest: $githubSourceFocusRequest,
                kind: .githubRepository,
                addSource: addGitHubSource,
                openSkills: { source in openSkills(for: source) },
                returnToSkills: sourceDetailReturnAction,
                query: $githubSourceQuery
            ))
        case .agent(let id):
            AnyView(Phase1AgentWorkspace(
                library: library,
                descriptor: library.visibleInstalledAgentDescriptors.first { $0.id == id },
                addLocalSource: addLocalSource, openSource: openSourceDetail,
                query: agentWorkspaceBinding(for: id, \.query),
                ownership: agentWorkspaceBinding(for: id, \.ownership),
                needsAttentionOnly: agentWorkspaceBinding(for: id, \.needsAttentionOnly),
                selectedID: agentWorkspaceBinding(for: id, \.selectedID)
            ))
        case .tasks:
            AnyView(Phase1TasksView(
                tasks: library.phase1Tasks,
                language: library.language,
                expandedTaskIDs: $expandedTaskIDs,
                scrollID: $taskScrollID,
                recheck: library.recheckRecoveryTasks,
                openObject: openTaskObject,
                openAgent: openTaskAgent
            ))
        case .managementDirectory:
            AnyView(Phase1FirstRunWorkspace(library: library, establishRoot: establishRoot, connectRoot: connectRoot,
                openTasks: { requestNavigation(.tasks) })
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button(appLocalized("Back to Settings", language: library.language), systemImage: "chevron.left") { requestNavigation(.settings) }
                            .labelStyle(.iconOnly)
                            .frame(height: 36)
                    }
                })
        case .operation(let id):
            AnyView(Group {
                if let task = library.phase1Tasks.first(where: { $0.id == id }) {
                    ScrollView {
                        Phase1TaskRow(task: task, language: library.language, isExpanded: true, toggleExpanded: {},
                                      openObject: openTaskObject, openAgent: openTaskAgent, isDetailPage: true)
                            .padding(24)
                    }
                } else {
                    ContentUnavailableView(appLocalized("No pending operations", language: library.language), systemImage: "checklist")
                }
            }.toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(appLocalized("Back to Settings", language: library.language), systemImage: "chevron.left") { requestNavigation(.settings) }
                        .labelStyle(.iconOnly)
                        .frame(height: 36)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(appLocalized("Re-check current facts", language: library.language), systemImage: "arrow.clockwise", action: library.recheckRecoveryTasks)
                        .labelStyle(.iconOnly).frame(height: 36).help(appLocalized("Re-check current facts", language: library.language))
                }
            })
        case .settings:
            AnyView(Phase1SettingsWorkspace(
                library: library,
                establishRoot: establishRoot,
                connectRoot: connectRoot,
                chooseAgentTarget: chooseAgentTarget,
                openAgent: { requestNavigation(.agent($0)) },
                openTasks: { requestNavigation(.tasks) },
                openManagementDirectory: { requestNavigation(.managementDirectory) },
                openOperation: { requestNavigation(.operation($0)) },
                configuredAgentID: $configuredAgentID,
                isAddingAgent: $isAddingAgent,
                draft: $agentConfigurationDraft
            ))
        }
    }

    @ViewBuilder private var skillsWorkspace: some View {
        if !library.hasRoot {
            Phase1FirstRunWorkspace(
                library: library,
                establishRoot: establishRoot,
                connectRoot: connectRoot,
                openTasks: { requestNavigation(.tasks) }
            )
        } else {
            Phase1SkillsWorkspace(
                library: library,
                selectedSkillID: $selectedSkillID,
                selectedSourceID: $selectedSkillSourceID,
                returnSourceID: skillReturnSourceID,
                filter: $skillFilter,
                focusRequest: $skillFocusRequest,
                openSource: openSourceDetail,
                openSources: { requestNavigation(.localSources) },
                returnToSource: returnToSource, needsAttentionOnly: $skillNeedsAttentionOnly
            )
        }
    }

    private var usesToolbarTitle: Bool {
        selection == .settings || selection == .tasks || (selection == .allSkills && !library.hasRoot)
    }

    private var title: String {
        if selection == .allSkills && !library.hasRoot { return appLocalized("Management Directory", language: library.language) }
        if case .agent(let id) = selection {
            return library.installedAgentDescriptors.first { $0.id == id }?.displayName ?? appLocalized("Agent", language: library.language)
        }
        if selection == .allSkills, let sourceID = skillReturnSourceID,
           let source = (library.localSourcesForPresentation + library.githubSourcesForPresentation).first(where: { $0.id == sourceID }) {
            return library.presentationService.sourceName(for: source)
        }
        return appLocalized(selection.title, language: library.language)
    }

    private func saveSkillsWorkspace() {
        skillsWorkspaceStates[skillReturnSourceID?.uuidString ?? "all"] = SkillsWorkspaceState(
            selectedID: selectedSkillID, sourceID: selectedSkillSourceID, query: library.searchText,
            filter: skillFilter, needsAttentionOnly: skillNeedsAttentionOnly)
    }

    private func restoreSkillsWorkspace() {
        let state = skillsWorkspaceStates[skillReturnSourceID?.uuidString ?? "all"] ?? SkillsWorkspaceState()
        selectedSkillID = state.selectedID
        selectedSkillSourceID = skillReturnSourceID ?? state.sourceID
        library.searchText = state.query
        skillFilter = state.filter
        skillNeedsAttentionOnly = state.needsAttentionOnly
    }

    private func openSkills(for source: SkillSource) {
        saveSkillsWorkspace()
        skillReturnSourceID = source.id
        restoreSkillsWorkspace()
        requestNavigation(.allSkills)
    }

    private func openSourceDetail(_ item: Phase1SkillPresentation) {
        guard let source = item.source else { return }
        sourceReturnDestination = selection
        sourceReturnSkillID = item.id
        skillFocusRequest = item.id
        library.sourceUpdateFocusPath = item.relativeLocation
        setSelectedSource(source.id, kind: source.kind)
        requestNavigation(source.kind == .githubRepository ? .githubSources : .localSources)
    }

    private func returnFromSourceDetail() {
        sourceReturnSkillID = nil
        requestNavigation(sourceReturnDestination ?? .allSkills)
        sourceReturnDestination = nil
    }

    private var sourceDetailReturnAction: (() -> Void)? {
        sourceReturnSkillID == nil ? nil : { returnFromSourceDetail() }
    }

    private func returnToSource() {
        guard let sourceID = skillReturnSourceID else { return }
        guard let source = library.sources.first(where: { $0.id == sourceID })
            ?? library.localSourcesForPresentation.first(where: { $0.id == sourceID }) else { return }
        setSelectedSource(sourceID, kind: source.kind)
        requestNavigation(source.kind == .githubRepository ? .githubSources : .localSources)
    }

    private func openTaskObject(_ task: Phase1TaskRecord) {
        if task.kind == .initializeRoot {
            requestNavigation(.settings)
            library.setStatus("Re-observe the current object before preparing a new plan.")
        } else if task.kind == .deleteBrokenLink {
            requestNavigation(.agent(task.recoveryEvidence?.agentID ?? task.objectID))
        } else if task.kind == .removeLocalSource || task.kind == .updateSource {
            let sourceID = task.recoveryEvidence?.sourceID.flatMap { sourceID in
                library.sources.first { $0.id == sourceID }?.id
            }
            setSelectedSource(sourceID, kind: task.recoveryEvidence?.sourceKind ?? .localDirectory)
            requestNavigation(task.recoveryEvidence?.sourceKind == .githubRepository ? .githubSources : .localSources)
            if sourceID == nil {
                library.setStatus("The original source is no longer available. Review the current source list and the recorded locations.")
            }
        } else if task.kind == .importLocalSource || task.kind == .registerLocalSource || task.kind == .importGitHubSource {
            let kind: SkillSourceKind = task.kind == .importGitHubSource ? .githubRepository : .localDirectory
            setSelectedSource(library.sources.first { $0.id.uuidString == task.objectID }?.id, kind: kind)
            requestNavigation(kind == .githubRepository ? .githubSources : .localSources)
        } else {
            let objectID = task.relationEvidence?.skillID ?? task.objectID
            if let managed = library.installedSkills.first(where: {
                $0.id == objectID || $0.candidateID == objectID || $0.assetID == task.operationPlan?.assetID
            }) {
                selectedSkillID = managed.candidateID ?? managed.assetID.uuidString
            } else if let candidate = library.availableSkills.first(where: { $0.id == objectID || $0.candidateID == objectID }) {
                selectedSkillID = candidate.candidateID
            } else {
                selectedSkillID = nil
                library.clearError()
                library.setStatus("The original object is no longer available. Immutable task evidence remains read-only; browse current Skills to recover navigation.")
            }
            library.searchText = ""
            skillFilter = .all
            selectedSkillSourceID = nil
            skillReturnSourceID = nil
            requestNavigation(.allSkills)
        }
    }

    private func openTaskAgent(_ agentID: String) {
        requestNavigation(.agent(agentID))
    }

    private var navigationSelection: Binding<Phase1NavigationDestination> {
        Binding(get: { selection }, set: { destination in
            if destination == .allSkills, skillReturnSourceID != nil {
                saveSkillsWorkspace()
                skillReturnSourceID = nil
                restoreSkillsWorkspace()
            }
            requestNavigation(destination)
        })
    }

    private var hasUnsavedAgentDraft: Bool {
        guard isAddingAgent || configuredAgentID != nil else { return false }
        let configuration = configuredAgentID.flatMap { id in
            library.agentConfigurations.first { $0.id == id }
        }
        return agentConfigurationDraft.displayName != (configuration?.displayName ?? "")
            || agentConfigurationDraft.iconMonogram != (configuration?.iconMonogram ?? "")
            || (configuration == nil && agentConfigurationDraft.selectedTarget != nil)
            || agentConfigurationDraft.proposedTarget != nil
    }

    private var canSaveAgentDraft: Bool {
        guard let configuration = configuredAgentID.flatMap({ id in
            library.agentConfigurations.first { $0.id == id }
        }) else {
            return isAddingAgent && agentConfigurationDraft.selectedTarget != nil
                && !agentConfigurationDraft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && AgentPresentation.normalizedIconMonogram(agentConfigurationDraft.iconMonogram) != nil
        }
        return !agentConfigurationDraft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (configuration.agent != nil
                || AgentPresentation.normalizedIconMonogram(agentConfigurationDraft.iconMonogram) != nil)
    }

    private func requestNavigation(_ destination: Phase1NavigationDestination) {
        guard destination != selection else { return }
        guard selection == .settings, hasUnsavedAgentDraft else {
            selection = destination
            return
        }
        pendingNavigation = destination
        showUnsavedNavigationConfirmation = true
    }

    private func saveAgentDraftAndNavigate() {
        guard let destination = pendingNavigation else { return }
        guard canSaveAgentDraft else { return }
        Task { @MainActor in
            do {
                if isAddingAgent, let target = agentConfigurationDraft.selectedTarget {
                    let configuration = try await library.addCustomAgent(
                        displayName: agentConfigurationDraft.displayName,
                        iconMonogram: agentConfigurationDraft.iconMonogram,
                        skillsDirectory: target
                    )
                    configuredAgentID = configuration.id
                    isAddingAgent = false
                } else if let agentID = configuredAgentID {
                    try await library.saveAgentDisplayFields(
                        agentID: agentID,
                        displayName: agentConfigurationDraft.displayName,
                        iconMonogram: agentConfigurationDraft.iconMonogram
                    )
                    if let target = agentConfigurationDraft.proposedTarget {
                        try await library.saveAgentDirectory(agentID: agentID, newDirectory: target)
                        agentConfigurationDraft.selectedTarget = target
                        agentConfigurationDraft.proposedTarget = nil
                    }
                }
                pendingNavigation = nil
                selection = destination
            } catch {
                library.handle(error)
            }
        }
    }

    private func discardAgentDraftAndNavigate() {
        guard let destination = pendingNavigation else { return }
        configuredAgentID = nil
        isAddingAgent = false
        agentConfigurationDraft = AgentConfigurationDraft(
            displayName: "",
            iconMonogram: "",
            selectedTarget: nil,
            proposedTarget: nil
        )
        pendingNavigation = nil
        selection = destination
    }

    private func setSelectedSource(_ sourceID: UUID?, kind: SkillSourceKind) {
        if kind == .githubRepository {
            selectedGitHubSourceID = sourceID
            githubSourceFocusRequest = sourceID
        } else {
            selectedLocalSourceID = sourceID
            localSourceFocusRequest = sourceID
        }
    }

    private func agentWorkspaceBinding<Value>(
        for agentID: String,
        _ keyPath: WritableKeyPath<Phase1AgentWorkspaceState, Value>
    ) -> Binding<Value> {
        Binding(
            get: { (agentWorkspaceStates[agentID] ?? Phase1AgentWorkspaceState())[keyPath: keyPath] },
            set: { value in
                var state = agentWorkspaceStates[agentID] ?? Phase1AgentWorkspaceState()
                state[keyPath: keyPath] = value
                agentWorkspaceStates[agentID] = state
            }
        )
    }


}

private struct Phase1ProductSidebar: View {
    @Binding var selection: Phase1NavigationDestination
    var agents: [InstalledAgentDescriptor]
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section(appLocalized("Skills", language: language)) {
                    destinationRow(appLocalized("All Skills", language: language), systemImage: "square.stack.3d.up", destination: .allSkills)
                }
                Section(appLocalized("Sources", language: language)) {
                    destinationRow(appLocalized("Local", language: language), systemImage: "folder", destination: .localSources)
                    destinationRow("GitHub", systemImage: "network", destination: .githubSources)
                }
                Section(appLocalized("Agents", language: language)) {
                    if agents.isEmpty {
                        Button(appLocalized("Go to Settings", language: language)) {
                            selection = .settings
                        }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("agents-empty-state")
                    } else {
                        ForEach(agents) { agent in
                            Button {
                                selection = .agent(agent.id)
                            } label: {
                                HStack {
                                    Phase1AgentIcon(descriptor: agent, size: 22)
                                    Text(agent.displayName).lineLimit(1).truncationMode(.tail).help(agent.displayName)
                                }
                            }
                            .buttonStyle(.plain)
                            .tag(Phase1NavigationDestination.agent(agent.id))
                            .accessibilityIdentifier("nav-agent-\(agent.id)")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("phase1-product-sidebar")

            Divider()
            bottomRow(appLocalized("Settings", language: language), systemImage: "gearshape", destination: .settings)
            .padding(8)
        }
    }

    private func destinationRow(_ title: String, systemImage: String, destination: Phase1NavigationDestination) -> some View {
        Button { selection = destination } label: {
            Label(title, systemImage: systemImage)
        }
            .buttonStyle(.plain)
            .tag(destination)
            .accessibilityIdentifier("nav-\(destination.id)")
    }

    private func bottomRow(_ title: String, systemImage: String, destination: Phase1NavigationDestination) -> some View {
        Button {
            selection = destination
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(selection == destination ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("nav-\(destination.id)")
    }
}

private struct Phase1FirstRunWorkspace: View {
    @Bindable var library: SkillsHubLibraryController
    var establishRoot: () -> Void
    var connectRoot: () -> Void
    var openTasks: () -> Void

    private func localized(_ text: String) -> String {
        appLocalized(text, language: library.language)
    }

    private var rootPresentation: Phase1RootPresentation {
        Phase1RootPresentation(
            rootURL: library.rootURL,
            inspectionResult: library.lastRootInspectionResult,
            pendingInitialization: library.pendingRootInitialization,
            tasks: library.phase1Tasks,
            language: library.language
        )
    }

    var body: some View {
        ScrollView {
            rootDetail
        }
        .accessibilityIdentifier("first-run-workspace")
    }

    private var rootDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized(rootPresentation.title))
                .font(.title2)
                .bold()
            Text(localized(rootPresentation.statusLabel))
                .accessibilityLabel("\(localized("SkillsHub Root")). \(rootPresentation.accessibilityValue(language: library.language))")
                .accessibilityIdentifier("phase1-root-status")
            if let rootPath = rootPresentation.rootPath {
                Text(rootPath)
                    .font(.system(.body, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityLabel(localized("SkillsHub Root path"))
                    .accessibilityValue(rootPath)
            }
            GroupBox(localized("Nothing runs automatically")) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(localized("No automatic Root scan"), systemImage: "minus.circle")
                    Label(localized("No automatic source registration"), systemImage: "minus.circle")
                    Label(localized("No Agent link creation"), systemImage: "minus.circle")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(localized(rootPresentation.detail))
                .foregroundStyle(.secondary)
            if rootPresentation.primaryAction == .openTasks,
               let actionTitle = rootPresentation.primaryActionTitle {
                Button(actionTitle, action: openTasks)
                    .buttonStyle(.bordered)
            } else {
                HStack {
                    Spacer()
                    Button(localized("Establish Management Directory…"), action: establishRoot)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("establish-root-primary")
                    Button(localized("Connect Existing Directory…"), action: connectRoot)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("connect-root-primary")
                }
            }
        }
        .padding(24)
    }

}

private struct Phase1SkillsWorkspace: View {
    @Bindable var library: SkillsHubLibraryController
    @Binding var selectedSkillID: String?
    @Binding var selectedSourceID: UUID?
    var returnSourceID: UUID?
    @Binding var filter: Phase1SkillFilter
    @Binding var focusRequest: String?
    var openSource: (Phase1SkillPresentation) -> Void
    var openSources: () -> Void
    var returnToSource: () -> Void
    @Binding var needsAttentionOnly: Bool
    @State private var detailAnchor: String?
    @State private var detailFocusRequest = UUID()
    @FocusState private var listFocused: Bool

    private func localized(_ text: String) -> String { appLocalized(text, language: library.language) }

    private var sources: [SkillSource] {
        library.localSourcesForPresentation + library.githubSourcesForPresentation
    }
    private var allItems: [Phase1SkillPresentation] {
        library.presentationService.phase1Items(
            availableSkills: library.availableSkills, installedSkills: library.installedSkills,
            sources: sources, enablementIntents: library.rootSnapshot?.metadata.enablementIntents ?? []
        )
    }
    private func needsAttention(_ item: Phase1SkillPresentation) -> Bool {
        item.needsAttention || item.managed.map { library.relationPresentations(for: $0).contains(where: \.hasPresentationIssue) } == true
    }
    private var visibleItems: [Phase1SkillPresentation] {
        library.presentationService.filteredPhase1Items(allItems, query: library.searchText, filter: filter, sourceID: selectedSourceID)
            .filter { !needsAttentionOnly || needsAttention($0) }
    }
    private var selectedItem: Phase1SkillPresentation? { visibleItems.first { $0.id == selectedSkillID } }
    private var selectedSourceName: String? {
        sources.first { $0.id == selectedSourceID }.map { library.presentationService.sourceName(for: $0) }
    }
    private var checkSourceIDs: [UUID] {
        sources.filter { source in
            (returnSourceID == nil || source.id == returnSourceID) &&
            (source.kind == .githubRepository || source.externalLocalPath != nil)
        }.map(\.id)
    }

    var body: some View {
        GeometryReader { geometry in
            NativeWorkspaceSplit(preferenceKey: "SkillsHub.skills-list.width", stateKey: "\(library.rootURL?.path ?? "")/skills/\(returnSourceID?.uuidString ?? "all")", language: library.language) {
                skillList
            } right: {
                if let selectedItem {
                    Phase1SkillDetail(library: library, item: selectedItem,
                                      anchor: detailAnchor, focusRequest: detailFocusRequest, openSource: { openSource(selectedItem) })
                        .id(selectedItem.id)
                } else {
                    ContentUnavailableView(localized("Select a Skill"), systemImage: "square.stack.3d.up",
                                           description: Text(localized("Select an item to view its details.")))
                        .accessibilityIdentifier("skill-detail-empty")
                }
            }
            .toolbar {
                if returnSourceID != nil {
                    ToolbarItem(placement: .navigation) {
                        Button(localized("Back to Source"), systemImage: "chevron.left", action: returnToSource)
                            .labelStyle(.iconOnly).accessibilityIdentifier("return-to-source")
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task {
                            do {
                                if let returnSourceID { try await library.recheckSource(returnSourceID) }
                                else { try await library.refreshSources() }
                            } catch { library.handle(error) }
                        }
                    } label: {
                        if library.isRefreshingInstalled || !library.recheckingSourceIDs.isEmpty { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .help(localized("Re-check"))
                    .accessibilityLabel(localized("Re-check"))
                    .disabled(library.isRefreshingInstalled || !library.recheckingSourceIDs.isEmpty || !library.hasRoot)
                    .accessibilityIdentifier("recheck-filesystem")
                    if returnSourceID == nil || !checkSourceIDs.isEmpty {
                        Button { Task { await library.checkSourceUpdates(checkSourceIDs) } } label: {
                            if !library.checkingSourceIDs.isEmpty { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.down.circle") }
                        }
                        .help(localized("Check for Updates…"))
                        .accessibilityLabel(localized("Check for Updates…"))
                        .disabled(!library.checkingSourceIDs.isEmpty || checkSourceIDs.isEmpty || library.sourceUpdatePreview != nil)
                        .accessibilityIdentifier("check-all-source-updates")
                    }
                    if returnSourceID == nil {
                        Picker(localized("Source"), selection: $selectedSourceID) {
                            Text(localized("All Sources")).tag(UUID?.none)
                            ForEach(sources) { source in
                                Text(library.presentationService.sourceName(for: source)).tag(Optional(source.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: geometry.size.width < 900 ? 124 : 168)
                        .help(selectedSourceName ?? localized("All Sources"))
                        .accessibilityIdentifier("skill-source-filter")
                    }
                    Menu {
                        Picker(localized("Filter"), selection: $filter) {
                            ForEach([Phase1SkillFilter.all, .enabled, .notEnabled]) { value in
                                Text(localized(value.title)).tag(value)
                            }
                        }
                        Divider()
                        Toggle(localized("Needs Attention"), isOn: $needsAttentionOnly)
                        Button(localized("Reset State Filters")) { filter = .all; needsAttentionOnly = false }
                    } label: {
                        Label(localized(filter.title) + (needsAttentionOnly ? " · " + localized("Needs Attention") : ""), systemImage: "line.3.horizontal.decrease")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: geometry.size.width < 900 ? 112 : 148, alignment: .leading)
                    }
                    .frame(width: geometry.size.width < 900 ? 136 : 172)
                    .accessibilityIdentifier("skill-filter")
                }
                ToolbarItem(placement: .primaryAction) {
                    NativeWorkspaceSearch(text: $library.searchText,
                                          prompt: localized(returnSourceID == nil ? "Search All Skills…" : "Search This Source’s Skills…"),
                                          identifier: "skill-search")
                        .frame(width: geometry.size.width < 900 ? 220 : 276, height: 36)
                }
            }
        }
        .onChange(of: visibleItems.map(\.id), initial: true) { _, ids in
            if let selectedSkillID, !ids.contains(selectedSkillID) { self.selectedSkillID = nil }
        }
    }

    private var skillList: some View {
        List(selection: $selectedSkillID) {
            ForEach(visibleItems) { item in
                Phase1SkillRow(library: library, item: item,
                              openSource: { selectedSkillID = item.id; detailAnchor = "update"; detailFocusRequest = UUID() },
                              openProblem: { selectedSkillID = item.id; detailAnchor = "problem"; detailFocusRequest = UUID() },
                              showsSource: returnSourceID == nil)
                    .tag(item.id)
                    .listRowSeparator(item.id == visibleItems.last?.id ? .hidden : .visible, edges: .bottom)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if visibleItems.isEmpty {
                if library.isRefreshingInstalled {
                    ProgressView(localized("Checking…"))
                } else if allItems.isEmpty, returnSourceID == nil {
                    ContentUnavailableView {
                        Label(localized("No Skills yet"), systemImage: "square.stack.3d.up")
                    } description: {
                        Text(localized("Add a source to discover Skills."))
                    } actions: {
                        Button(localized("Go to Sources"), action: openSources)
                    }
                } else {
                    ContentUnavailableView(localized(allItems.isEmpty ? "No Skills yet" : "No matching Skills"), systemImage: "square.stack.3d.up",
                                           description: Text(localized(allItems.isEmpty ? "Add a source to discover Skills." : "No results match the current search and source filters. Clear either filter to continue.")))
                }
            }
        }
        .accessibilityIdentifier("skill-library-list")
        .focused($listFocused)
        .onAppear {
            if focusRequest != nil { listFocused = true; focusRequest = nil }
        }
    }
}

private struct Phase1SkillRow: View {
    @Bindable var library: SkillsHubLibraryController
    var item: Phase1SkillPresentation
    var openSource: () -> Void
    var openProblem: () -> Void = {}
    var showsSource = true
    private func localized(_ text: String) -> String { appLocalized(text, language: library.language) }
    private var relations: [AgentRelationPresentation] { item.managed.map(library.relationPresentations) ?? [] }
    private var needsAttention: Bool { item.needsAttention || relations.contains(where: \.hasPresentationIssue) }
    private var problemSummary: String {
        let messages = item.validationMessages.map(localized) + relations.filter(\.hasPresentationIssue).map {
            "\($0.agentDisplayName): \(localized($0.unavailableReason ?? $0.verification.presentationLabel))"
        }
        return messages.isEmpty ? localized("Needs Attention") : messages.joined(separator: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.name).font(.headline).lineLimit(1).help(item.name)
                if let sourceID = item.source?.id, library.sourceHasPreparedUpdate(sourceID) {
                    Button(action: openSource) { Image(systemName: "arrow.up.circle") }
                        .buttonStyle(.borderless).frame(minWidth: 24, minHeight: 24)
                        .help(localized("Source Update Available"))
                        .accessibilityLabel(localized("Source Update Available") + " · " + item.name)
                }
                if needsAttention {
                    Button(action: openProblem) { Image(systemName: "exclamationmark.triangle") }
                        .buttonStyle(.borderless).frame(minWidth: 24, minHeight: 24)
                        .help(problemSummary)
                        .accessibilityLabel(localized("Needs Attention") + " · " + item.name)
                }
                Spacer(minLength: 0)
            }
            Text(item.detail).lineLimit(2).foregroundStyle(.secondary)
            if showsSource {
                Text(item.source == nil ? localized(item.sourceName) : item.sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(item.sourceName)
            }
            Text(item.isEnabled
                 ? library.localized(LocalizedMessage("Enabled for %@ Agents", arguments: [String(relations.filter { $0.intendedEnabled == true }.count)]))
                 : localized("Not Enabled"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
        .accessibilityIdentifier("skill-row-\(item.id)")
    }
}

private struct Phase1SkillDetail: View {
    @Bindable var library: SkillsHubLibraryController
    var item: Phase1SkillPresentation
    var anchor: String? = nil
    var focusRequest = UUID()
    var openSource: () -> Void = {}
    var currentAgentID: String? = nil
    @State private var clearPlan: ManagedRelationClearPlan?
    @State private var clearPlanError: String?
    private func localized(_ text: String) -> String { appLocalized(text, language: library.language) }
    private var relations: [AgentRelationPresentation] { item.managed.map(library.relationPresentations) ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(item.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(item.detail).textSelection(.enabled)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.sourceName).foregroundStyle(.secondary)
                        if let sourceID = item.source?.id {
                            if let failure = library.sourceUpdateFailures[sourceID] {
                                Label(localized("Update check failed") + ": " + failure, systemImage: "exclamationmark.triangle")
                            } else if let available = library.sourceUpdateChecks[sourceID] {
                                Text(localized(available ? "Source Update Available" : "No source update was found. Managed content and its success baseline are unchanged."))
                            }
                        }
                        if item.source != nil {
                            Button(localized("View Source…"), action: openSource)
                        }
                    }
                    .id("update")
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(item.validationMessages, id: \.self) { message in
                            Label(localized(message), systemImage: "exclamationmark.triangle")
                        }
                    }.id("problem")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localized("Agent relationships")).font(.headline)
                        ForEach(relations.filter { currentAgentID == nil || $0.relation.agentID == currentAgentID }) { relation in
                            Phase1RelationDetail(library: library, relation: relation)
                        }
                        if let currentAgentID {
                            DisclosureGroup(localized("Other Agent relationships")) {
                                ForEach(relations.filter { $0.relation.agentID != currentAgentID }) { relation in
                                    Phase1RelationDetail(library: library, relation: relation)
                                }
                            }
                        }
                        if let managed = item.managed {
                            Button(localized("Clear all managed links"), role: .destructive) {
                                do {
                                    clearPlan = try library.prepareManagedRelationClearPlan(skillID: managed.id)
                                    clearPlanError = nil
                                } catch { clearPlanError = String(describing: error) }
                            }
                            .disabled(!library.inFlightRelationActionIDs.isEmpty)
                            .accessibilityIdentifier("clear-managed-relations")
                        } else {
                            Text(localized("This historical candidate is not part of a complete managed source. Import its whole source folder before enabling an Agent."))
                        }
                        if let clearPlanError { Text(clearPlanError).foregroundStyle(.red) }
                    }
                    .id("relations")
                    DisclosureGroup(localized("Paths and check details")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.managed?.installedPath ?? item.location)
                                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            ForEach(relations) { relation in
                                if let observed = library.localState.targetObservations.first(where: { $0.relation == relation.relation }) {
                                    Text(relation.agentDisplayName).font(.headline)
                                    Text(observed.linkPath).textSelection(.enabled)
                                    if let target = observed.resolvedTargetPath { Text(target).textSelection(.enabled) }
                                    Text(observed.observedAt, style: .date)
                                }
                            }
                            if let revision = item.managed?.currentRevision ?? item.candidate?.manifestDigest {
                                Text(revision).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .onAppear { if let anchor { proxy.scrollTo(anchor, anchor: .top) } }
            .onChange(of: focusRequest) { _, _ in if let anchor { proxy.scrollTo(anchor, anchor: .top) } }
        }
        .accessibilityIdentifier("skill-detail")
        .sheet(item: $clearPlan) { plan in Phase1ClearManagedRelationsSheet(library: library, plan: plan) }
    }
}

private struct Phase1ClearManagedRelationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var library: SkillsHubLibraryController
    var plan: ManagedRelationClearPlan
    @State private var result: ManagedRelationClearResult?
    @State private var errorMessage: String?
    @State private var isClearing = false

    private func localized(_ text: String) -> String { appLocalized(text, language: library.language) }

    private func localizedDetail(_ detail: String) -> String {
        let ownershipPrefix = "Current ownership is "
        let ownershipSuffix = "; the object remains unchanged."
        if detail.hasPrefix(ownershipPrefix), detail.hasSuffix(ownershipSuffix) {
            let ownership = String(detail.dropFirst(ownershipPrefix.count).dropLast(ownershipSuffix.count))
            return SkillsHubLocalization().localized(
                LocalizedMessage("Current ownership is %@; the object remains unchanged.", arguments: [ownership]),
                language: library.language
            )
        }
        let factsPrefix = "Current facts could not be verified: "
        if detail.hasPrefix(factsPrefix) {
            return SkillsHubLocalization().localized(
                LocalizedMessage("Current facts could not be verified: %@", arguments: [String(detail.dropFirst(factsPrefix.count))]),
                language: library.language
            )
        }
        return localized(detail)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(localized("Clear all managed links for")) \(plan.skillName)?")
                    .font(.title2.weight(.semibold))
                Text(localized("The Skill content, source, and stable link name will remain unchanged."))
                    .foregroundStyle(.secondary)

                if let result {
                    ForEach(result.items) { item in
                        resultRow(item)
                    }
                } else {
                    ForEach(plan.items) { item in
                        previewRow(item)
                    }
                    if plan.items.isEmpty {
                        Text(localized("No selected or managed Agent relationship exists for this Skill."))
                            .foregroundStyle(.secondary)
                    } else if plan.removableItems.isEmpty {
                        Text(localized("No relationship can be safely cleared. Resolve the blocked Agent items first."))
                            .foregroundStyle(.orange)
                    }
                }

                if let errorMessage {
                    Text(localized(errorMessage))
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("clear-managed-relations-sheet-error")
                }

                HStack {
                    Spacer()
                    if result == nil {
                        Button(localized("Cancel")) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("cancel-clear-managed-relations")
                        Button(localized("Clear managed links"), role: .destructive) {
                            clear()
                        }
                        .disabled(plan.removableItems.isEmpty || isClearing)
                        .accessibilityIdentifier("confirm-clear-managed-relations")
                    } else {
                        Button(localized("Done")) { dismiss() }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("done-clear-managed-relations")
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 520, minHeight: 340)
        .accessibilityIdentifier("clear-managed-relations-sheet")
    }

    private func previewRow(_ item: ManagedRelationClearItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.agentDisplayName).font(.headline)
            Text(localized(item.disposition == .removable ? "Will clear" : "Blocked"))
                .foregroundStyle(item.disposition == .removable ? Color.primary : Color.orange)
            Text(localizedDetail(item.detail))
            Text(item.linkPath)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clear-preview-\(item.relation.agentID)")
    }

    private func resultRow(_ item: ManagedRelationClearResultItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.agentDisplayName).font(.headline)
            Text(localized(item.outcome.rawValue))
            Text(localizedDetail(item.detail)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clear-result-\(item.relation.agentID)")
    }

    private func clear() {
        isClearing = true
        errorMessage = nil
        Task {
            do {
                result = try await library.clearAllManagedRelations(using: plan)
            } catch ManagedRelationClearError.planChanged {
                errorMessage = "The Skill or Agent scope changed after confirmation. Review a new preview before clearing."
            } catch {
                errorMessage = String(describing: error)
            }
            isClearing = false
        }
    }
}

private struct Phase1SourcesWorkspace: View {
    @FocusState private var listFocused: Bool
    @Bindable var library: SkillsHubLibraryController
    @Binding var selectedSourceID: UUID?
    @Binding var focusRequest: UUID?
    let kind: SkillSourceKind
    var addSource: () -> Void
    var openSkills: (SkillSource) -> Void
    var returnToSkills: (() -> Void)?
    @Binding var query: String
    @State private var removalPlan: SourceRemovalPlan?
    @State private var removalError: String?
    @State private var isPreparingPreview = false
    private var isGitHub: Bool { kind == .githubRepository }
    private var sources: [SkillSource] { isGitHub ? library.githubSourcesForPresentation : library.localSourcesForPresentation }
    private var visibleSources: [SkillSource] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sources.filter { trimmed.isEmpty || $0.name.localizedStandardContains(trimmed) || ($0.urlString?.localizedStandardContains(trimmed) ?? false) }
    }
    private var selectedSource: SkillSource? { visibleSources.first { $0.id == selectedSourceID } }
    private func localized(_ text: String) -> String { appLocalized(text, language: library.language) }

    var body: some View {
        NativeWorkspaceSplit(preferenceKey: "SkillsHub.sources-list.width", stateKey: "\(library.rootURL?.path ?? "")/sources/\(kind)", language: library.language) {
            List(selection: $selectedSourceID) {
                ForEach(visibleSources) { source in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(source.name).font(.headline).lineLimit(1).help(source.name)
                            if library.sourceHasPreparedUpdate(source.id) {
                                Image(systemName: "arrow.up.circle").accessibilityLabel(localized("Source Update Available"))
                            }
                            if source.registrationState != .registered {
                                Image(systemName: "exclamationmark.triangle").accessibilityLabel(localized("Needs Attention"))
                            }
                        }
                        Text(source.localPath ?? localized("Unknown managed path")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text("\(skills(in: source).count) \(localized("discovered Skills"))").font(.caption)
                    }
                    .padding(.vertical, 10)
                    .tag(source.id)
                    .listRowSeparator(source.id == visibleSources.last?.id ? .hidden : .visible, edges: .bottom)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("source-row-\(source.id.uuidString)")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay {
                if visibleSources.isEmpty {
                    ContentUnavailableView(localized("No matching sources"), systemImage: "folder")
                }
            }
            .accessibilityIdentifier("source-list")
            .focused($listFocused)
            .onAppear {
                if focusRequest != nil { listFocused = true; focusRequest = nil }
            }
        } right: {
            if let selectedSource { sourceDetail(selectedSource) }
            else { ContentUnavailableView(localized("Select a Source"), systemImage: "folder", description: Text(localized("Select an item to view its details."))) }
        }
        .toolbar {
            if let returnToSkills {
                ToolbarItem(placement: .navigation) {
                    Button(localized("Back"), systemImage: "chevron.left", action: returnToSkills).labelStyle(.iconOnly)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: addSource) { Image(systemName: "plus") }
                    .help(localized(isGitHub ? "Add GitHub Source" : "Add Local Source"))
                    .accessibilityLabel(localized(isGitHub ? "Add GitHub Source" : "Add Local Source"))
                    .disabled(!library.hasRoot)
                    .accessibilityIdentifier(isGitHub ? "add-github-source" : "add-local-source")
                if isGitHub {
                    Button { Task { await library.checkSourceUpdates(sources.map(\.id)) } } label: {
                        if !library.checkingSourceIDs.isEmpty { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.down.circle") }
                    }
                    .help(localized("Check for Updates…"))
                    .accessibilityLabel(localized("Check for Updates…"))
                    .disabled(sources.isEmpty || !library.checkingSourceIDs.isEmpty || isPreparingPreview)
                    .accessibilityIdentifier("check-all-source-updates")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                NativeWorkspaceSearch(text: $query, prompt: localized("Search Sources…"), identifier: "source-search").frame(width: 276, height: 36)
            }
        }
        .onChange(of: visibleSources.map(\.id), initial: true) { _, ids in
            if let selectedSourceID, !ids.contains(selectedSourceID) { self.selectedSourceID = nil }
        }
        .sheet(item: $removalPlan) { plan in
            Phase1SourceRemovalSheet(library: library, plan: plan) { result in if result.succeeded { selectedSourceID = nil } }
        }
        .sheet(item: $library.sourceUpdatePreview) { preview in
            Phase1SourceUpdateSheet(library: library, preview: preview, focusPath: library.sourceUpdateFocusPath)
        }
    }

    private func sourceDetail(_ source: SkillSource) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(source.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text(localized(source.registrationState == .registered ? "Imported · Readable" : "Imported · Needs Attention"))
                Text(source.localPath ?? localized("Unknown path")).textSelection(.enabled)
                if let externalPath = source.externalLocalPath { Text(externalPath).textSelection(.enabled) }
                if isGitHub {
                    Text(source.urlString ?? source.name).textSelection(.enabled)
                    Text("\(localized("Branch")): \(source.ref ?? localized("Unknown"))")
                    Text("\(localized("Commit")): \(source.resolvedVersion ?? localized("Unknown"))").textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button("\(localized("View this source’s Skills")) (\(skills(in: source).count))") { openSkills(source) }
                        .accessibilityIdentifier("view-source-skills")
                    Button(localized(library.recheckingSourceIDs.contains(source.id) ? "Checking…" : "Re-check")) {
                        Task { do { try await library.recheckSource(source.id) } catch { library.handle(error) } }
                    }
                    .disabled(library.recheckingSourceIDs.contains(source.id))
                    .accessibilityIdentifier("recheck-source")
                    if let result = library.sourceRecheckResults[source.id] {
                        Text(SkillsHubLocalization().localized(result, language: library.language))
                    }
                    if source.kind == .githubRepository || source.externalLocalPath != nil {
                        Button(localized(library.checkingSourceIDs.contains(source.id) ? "Checking…" : "Check for Updates…")) {
                            Task { await library.checkSourceUpdates([source.id]) }
                        }
                        .disabled(!library.checkingSourceIDs.isEmpty || isPreparingPreview)
                        .accessibilityIdentifier("check-source-update")
                        if library.sourceHasPreparedUpdate(source.id) {
                        Button(localized(isPreparingPreview ? "Preparing…" : "Preview Update…")) {
                            isPreparingPreview = true
                            Task {
                                defer { isPreparingPreview = false }
                                do { try await library.prepareSourceUpdate(sourceID: source.id) }
                                catch { library.recordSourceUpdateFailure(sourceID: source.id, error: error) }
                            }
                        }
                        .disabled(!library.checkingSourceIDs.isEmpty || isPreparingPreview)
                        .accessibilityIdentifier("preview-source-update")
                        }
                    }
                    Menu(localized("More")) {
                        Button(localized("Remove Source…"), role: .destructive) {
                            do { removalError = nil; removalPlan = try library.prepareLocalSourceRemoval(sourceID: source.id) }
                            catch { removalError = String(describing: error) }
                        }
                        .accessibilityIdentifier("remove-source")
                    }
                    .fixedSize().accessibilityIdentifier("source-more")
                }
                if let error = library.sourceUpdateFailures[source.id] {
                    Label(localized("Update check failed") + ": " + error, systemImage: "exclamationmark.triangle")
                } else if let available = library.sourceUpdateChecks[source.id] {
                    Text(localized(available ? "Source Update Available" : "No source update was found. Managed content and its success baseline are unchanged."))
                }
                if let date = library.sourceUpdateCheckDates[source.id] { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
                if let removalError { Text(removalError).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .accessibilityIdentifier("source-detail")
    }
    private func skills(in source: SkillSource) -> [Phase1SkillPresentation] {
        library.presentationService.phase1Items(
            availableSkills: library.availableSkills, installedSkills: library.installedSkills,
            sources: library.localSourcesForPresentation + library.githubSourcesForPresentation,
            enablementIntents: library.rootSnapshot?.metadata.enablementIntents ?? []
        ).filter { $0.source?.id == source.id }
    }
}

private struct Phase1SourceUpdateSheet: View {
    @Bindable var library: SkillsHubLibraryController
    let preview: SourceUpdatePreview
    let focusPath: String?
    @Environment(\.dismiss) private var dismiss
    @State private var isUpdating = false
    @State private var result: SourceUpdateResult?
    @State private var errorMessage: String?
    private func localized(_ text: String) -> String { appLocalized(text, language: library.language) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(preview.source.name).font(.title2.weight(.semibold))
                    if preview.hasUnknownBaseline {
                        Label(localized("The last successful baseline is unknown. Historical local changes cannot be classified."), systemImage: "questionmark.diamond")
                            .foregroundStyle(.orange)
                    } else if preview.hasLocalChanges {
                        Label(localized("The managed copy has local changes. Updating will replace them without merging."), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if let result {
                        GroupBox(localized(result.updateSucceeded ? "Update Applied" : "Update Needs Attention")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(localized(result.detail))
                                Text(localized(result.contentApplied ? "Content: prepared source is active" : "Content: not verified as applied"))
                                Text(localized(result.metadataCommitted ? "Metadata and baseline: committed" : "Metadata and baseline: not committed"))
                                Text(localized(result.oldContentMovedToTrash ? "Old content: moved to Trash" : "Old content: retained for recovery"))
                                if let retainedPath = result.retainedPath {
                                    Text(retainedPath)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                ForEach(result.relationResults) { item in
                                    Text("\(item.agentDisplayName): \(localized(item.outcome.rawValue)) — \(localized(item.detail))")
                                }
                            }
                        }
                    } else {
                        GroupBox(localized("Complete Content Changes")) { changeList(preview.incomingChanges) }
                        GroupBox(localized("Local Changes Since Last Success")) {
                            if preview.hasUnknownBaseline {
                                Text(localized("Unknown baseline — the managed copy is preserved unless you explicitly confirm entire replacement."))
                            } else {
                                changeList(preview.localChanges)
                            }
                        }
                        GroupBox(localized("Skills")) {
                            if preview.skillChanges.isEmpty {
                                Text(localized("No Skill entry changes were found. Shared source content may still affect enabled Skills."))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(preview.skillChanges) { change in
                                    Label("\(localized(change.kind.rawValue.capitalized)): \(change.name) · \(change.path)", systemImage: icon(for: change.kind))
                                        .font(change.path == focusPath ? .headline : .body)
                                }
                                Text(localized("A moved Skill appears as one deletion and one addition; enablement is not transferred by name."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        GroupBox(localized("Potential Shared Content and Agent Impact")) {
                            if preview.agentImpacts.isEmpty {
                                Text(localized("No enabled Agent relationships are in this source.")).foregroundStyle(.secondary)
                            } else {
                                Text(localized("Dependency boundaries are conservative. Every enabled Skill in this source is included."))
                                    .foregroundStyle(.secondary)
                                ForEach(preview.agentImpacts) { impact in
                                    Text("\(impact.skillName) · \(impact.skillPath) → \(impact.agentNames.joined(separator: ", "))")
                                        .font(impact.skillPath == focusPath ? .headline : .body)
                                        .accessibilityLabel("\(impact.skillName) · \(impact.skillPath) → \(impact.agentNames.joined(separator: ", "))")
                                        .accessibilityValue(impact.agentNames.joined(separator: ", "))
                                        .accessibilityIdentifier("source-update-agent-impact")
                                }
                            }
                        }
                        if let errorMessage { Text(localized(errorMessage)).foregroundStyle(.red) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .accessibilityIdentifier("source-update-preview")
            .navigationTitle(localized("Source Update Preview"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized(result == nil && preview.hasIncomingChanges ? "Cancel and Keep Current Content" : "Done")) {
                        if result == nil {
                            library.cancelSourceUpdatePreview(preview)
                        } else {
                            library.sourceUpdatePreview = nil
                            library.sourceUpdateResult = nil
                        }
                        dismiss()
                    }
                    .disabled(isUpdating)
                }
                if preview.hasIncomingChanges && result == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(localized(preview.confirmationKind.title)) {
                            isUpdating = true
                            Task {
                                defer { isUpdating = false }
                                do {
                                    result = try await library.applySourceUpdate(using: preview)
                                } catch {
                                    errorMessage = String(describing: error)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isUpdating)
                    }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func changeList(_ changes: [SourceUpdateFileChange]) -> some View {
        if changes.isEmpty {
            Text(localized("No changes found.")).foregroundStyle(.secondary)
        } else {
            ForEach(changes) { change in
                Label("\(localized(change.kind.rawValue.capitalized)): \(change.path)", systemImage: icon(for: change.kind))
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    private func icon(for kind: SourceUpdateChangeKind) -> String {
        switch kind {
        case .added: "plus.circle"
        case .modified: "pencil.circle"
        case .deleted: "minus.circle"
        }
    }
}

private struct Phase1SourceRemovalSheet: View {
    @Bindable var library: SkillsHubLibraryController
    let plan: SourceRemovalPlan
    var completed: (SourceRemovalResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var result: SourceRemovalResult?
    @State private var errorMessage: String?
    @State private var isRemoving = false
    private func localized(_ text: String) -> String { appLocalized(text, language: library.language) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(plan.source.name).font(.title2.weight(.semibold))
                    GroupBox(localized("Complete managed content")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(plan.source.localPath ?? localized("Unknown path"))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            ForEach(plan.skills, id: \.assetID) { skill in
                                Text(skill.name)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox(localized("Managed relationships")) {
                        if plan.affectedAgents.isEmpty {
                            Text(localized("No managed Agent relationships are currently recorded."))
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(plan.affectedAgents, id: \.self) { Text($0) }
                            }
                        }
                    }
                    Text(localized("Managed relationships are cleared first. The complete managed source then moves to the system Trash. External originals remain unchanged."))
                        .foregroundStyle(.secondary)
                    if let result {
                        GroupBox(localized("Actual result")) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(localized(result.detail))
                                if result.relationResults.isEmpty {
                                    Text(localized("Relationships: no managed relationships"))
                                } else {
                                    ForEach(result.relationResults, id: \.relation.id) { item in
                                        Text("\(item.agentDisplayName): \(localized(item.outcome.rawValue)) — \(localized(item.detail))")
                                    }
                                }
                                Text(localized(result.contentMovedToTrash ? "Content: moved to Trash" : "Content: not verified as moved; inspect current paths"))
                                Text(localized(result.metadataRemoved ? "Metadata: removed" : "Metadata: retained or needs verification"))
                                Text(localized(result.operationRecordCompleted ? "Operation record: completed" : "Operation record: needs attention"))
                                if let trashPath = result.trashPath {
                                    Text(trashPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let errorMessage { Text(localized(errorMessage)).foregroundStyle(.red) }
                }
                .padding(24)
            }
            .navigationTitle(localized(plan.source.kind == .githubRepository ? "Remove GitHub Source" : "Remove Local Source"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized(result == nil ? "Cancel" : "Done")) { dismiss() }
                        .disabled(isRemoving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("Remove Entire Source"), role: .destructive) { remove() }
                        .disabled(isRemoving || result != nil)
                        .accessibilityIdentifier("confirm-remove-source")
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .interactiveDismissDisabled(isRemoving)
    }

    private func remove() {
        isRemoving = true
        errorMessage = nil
        Task {
            do {
                let value = try await library.removeLocalSource(using: plan)
                result = value
                completed(value)
            } catch {
                errorMessage = String(describing: error)
            }
            isRemoving = false
        }
    }
}

private struct Phase1AgentWorkspace: View {
    @Bindable var library: SkillsHubLibraryController
    var descriptor: InstalledAgentDescriptor?
    var addLocalSource: () -> Void
    var openSource: (Phase1SkillPresentation) -> Void
    @Binding var query: String
    @Binding var ownership: AgentWorkspaceOwnershipFilter
    @Binding var needsAttentionOnly: Bool
    @Binding var selectedID: String?
    @State private var pendingBrokenLinkDeletion: BrokenLinkDeletionPlan?
    private func localized(_ text: String) -> String { appLocalized(text, language: library.language) }

    private var capability: AgentCapabilityPresentation? {
        descriptor.map(library.agentCapabilityPresentation)
    }

    private var relations: [AgentRelationPresentation] {
        guard let agentID = descriptor?.id else { return [] }
        return library.installedSkills.flatMap(library.relationPresentations).filter {
            $0.relation.agentID == agentID
        }
    }

    private var exactManagedRelations: [AgentRelationPresentation] {
        relations.filter { relation in
            relation.verification == .verifiedConsistent
                && relation.observation == .symbolicLink
                && library.rootSnapshot?.metadata.managedRelationEvidence.contains { $0.relation == relation.relation } == true
        }
    }

    private var managedRelations: [AgentRelationPresentation] {
        exactManagedRelations
        .filter(matches)
    }

    private var unverifiedRelations: [AgentRelationPresentation] {
        relations.filter { relation in
            (relation.intendedEnabled == true
                || library.rootSnapshot?.metadata.managedRelationEvidence.contains { $0.relation == relation.relation } == true)
                && !exactManagedRelations.contains(where: { $0.id == relation.id })
        }
        .filter(matches)
    }

    private var agentOwnedFindings: [AgentDirectoryFinding] {
        guard let agentID = descriptor?.id else { return [] }
        return library.agentFindings.filter {
            $0.agentID == agentID
                && ($0.type == .localDirectoryNotManaged || $0.type == .externalSymlinkNotManaged)
                && !hasManagedEvidence(for: $0)
        }
        .filter(matches)
    }

    private var indeterminateFindings: [AgentDirectoryFinding] {
        guard let agentID = descriptor?.id else { return [] }
        return library.agentFindings.filter {
            $0.agentID == agentID
                && (!($0.type == .localDirectoryNotManaged || $0.type == .externalSymlinkNotManaged)
                    || hasManagedEvidence(for: $0))
        }
        .filter(matches)
    }

    private var shownRelations: [AgentRelationPresentation] {
        (ownership == .all || ownership == .managed ? managedRelations : []) +
        (ownership == .all || ownership == .unknown ? unverifiedRelations : [])
    }
    private var shownFindings: [AgentDirectoryFinding] {
        (ownership == .all || ownership == .external ? agentOwnedFindings : []) +
        (ownership == .all || ownership == .unknown ? indeterminateFindings : [])
    }
    private var visibleIDs: [String] { shownRelations.map { "relation:" + $0.id } + shownFindings.map { "finding:" + $0.id } }
    var body: some View {
        NativeWorkspaceSplit(preferenceKey: "SkillsHub.skills-list.width", stateKey: "\(library.rootURL?.path ?? "")/agent/\(descriptor?.id ?? "")", language: library.language) {
            List(selection: $selectedID) {
                ForEach(shownRelations) { relation in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(relation.skillName).font(.headline).lineLimit(1)
                            if relation.hasPresentationIssue { Image(systemName: "exclamationmark.triangle") }
                        }
                        Text(localized(relation.verification == .verifiedConsistent ? "Managed by SkillsHub" : "Ownership needs verification")).font(.caption)
                        Text(localized(relation.verification.presentationLabel)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                    .tag("relation:" + relation.id)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("agent-row-\(relation.id)")
                }
                ForEach(shownFindings) { finding in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(finding.entryName).font(.headline).lineLimit(1)
                        Text(localized(finding.summary)).lineLimit(2).foregroundStyle(.secondary)
                        Text(localized(agentOwnedFindings.contains { $0.id == finding.id } ? "Not managed by SkillsHub" : "Ownership needs verification")).font(.caption)
                    }
                    .padding(.vertical, 10)
                    .tag("finding:" + finding.id)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("agent-row-\(finding.id)")
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(Color(nsColor: .windowBackgroundColor))
            .overlay {
                if visibleIDs.isEmpty { ContentUnavailableView(localized("No matching Skills"), systemImage: "square.stack.3d.up") }
            }
        } right: {
            if let relation = shownRelations.first(where: { "relation:" + $0.id == selectedID }),
               let skill = library.installedSkills.first(where: { $0.id == relation.skillID }),
               let item = library.presentationService.phase1Items(availableSkills: library.availableSkills, installedSkills: [skill], sources: library.localSourcesForPresentation + library.githubSourcesForPresentation, enablementIntents: library.rootSnapshot?.metadata.enablementIntents ?? []).first(where: { $0.managed?.id == skill.id }) {
                Phase1SkillDetail(library: library, item: item, openSource: { openSource(item) }, currentAgentID: descriptor?.id)
                    .id(item.id)
            } else if let finding = shownFindings.first(where: { "finding:" + $0.id == selectedID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(finding.entryName).font(.title2.bold())
                        Text(localized(finding.summary))
                        Phase1AgentFindingRow(finding: finding,
                            classification: agentOwnedFindings.contains { $0.id == finding.id } ? "Not managed by SkillsHub" : "Ownership needs verification",
                            selection: "See relationship evidence",
                            copyToHub: agentOwnedFindings.contains { $0.id == finding.id } ? addLocalSource : nil,
                            deleteBrokenLink: finding.type == .brokenSymlink ? {
                                do { pendingBrokenLinkDeletion = try library.prepareBrokenLinkDeletion(findingID: finding.id) }
                                catch { library.handle(error) }
                            } : nil)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
            } else {
                ContentUnavailableView(localized("Select a Skill"), systemImage: "square.stack.3d.up", description: Text(localized("Select an item to view its details.")))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    guard let id = descriptor?.id else { return }
                    do { try library.auditAgentDirectory(agentID: id) } catch { library.handle(error) }
                } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel(localized("Recheck Agent directory"))
                .help(localized("Recheck Agent directory"))
                .accessibilityIdentifier("recheck-agent-directory-\(descriptor?.id ?? "")")
                Picker(localized("Ownership"), selection: $ownership) {
                    ForEach(AgentWorkspaceOwnershipFilter.allCases) { value in Text(localized(value.title)).tag(value) }
                }.pickerStyle(.menu).frame(width: 170).accessibilityIdentifier("agent-ownership-filter")
                Menu {
                    Toggle(localized("Needs attention"), isOn: $needsAttentionOnly)
                } label: {
                    Label(localized(needsAttentionOnly ? "Needs attention" : "All"), systemImage: "line.3.horizontal.decrease")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 112, alignment: .leading)
                }.frame(width: 136)
                    .accessibilityIdentifier("agent-attention-filter")
            }
            ToolbarItem(placement: .primaryAction) {
                NativeWorkspaceSearch(text: $query, prompt: localized("Search this Agent’s Skills…"), identifier: "agent-workspace-search").frame(width: 240, height: 36)
            }
        }
        .onChange(of: visibleIDs, initial: true) { _, ids in if let selectedID, !ids.contains(selectedID) { self.selectedID = nil } }
        .accessibilityIdentifier("agent-workspace")
        .alert(localized("Delete this link node?"), item: $pendingBrokenLinkDeletion) { plan in
            Button(localized("Delete link node"), role: .destructive) {
                Task { do { _ = try await library.deleteBrokenLink(using: plan) } catch { library.handle(error) } }
            }
            Button(localized("Cancel"), role: .cancel) {}
        } message: { plan in
            Text("\(localized("Agent")): \(plan.facts.agentDisplayName)\n\(localized("Link")): \(plan.facts.linkPath)\n\(localized("Original target")): \(plan.facts.rawTarget)\n\(localized("Resolved target")): \(plan.facts.resolvedTargetPath)\n\n\(localized("Only the symbolic-link node will be deleted. Target content and enablement selections will not change."))")
        }
    }

    private func hasManagedEvidence(for finding: AgentDirectoryFinding) -> Bool {
        guard let path = finding.linkPath ?? finding.sourcePath else { return false }
        return library.rootSnapshot?.metadata.managedRelationEvidence.contains {
            $0.relation.agentID == finding.agentID
                && URL(fileURLWithPath: $0.linkPath).standardizedFileURL.path
                    == URL(fileURLWithPath: path).standardizedFileURL.path
        } == true
    }

    private func matches(_ finding: AgentDirectoryFinding) -> Bool {
        let textMatches = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || [finding.entryName, finding.summary, finding.sourcePath ?? "", finding.targetPath ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        return textMatches && (!needsAttentionOnly || finding.severity != .suggestion)
    }

    private func matches(_ relation: AgentRelationPresentation) -> Bool {
        let textMatches = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || relation.skillName.localizedCaseInsensitiveContains(query)
        return textMatches && (!needsAttentionOnly || relation.verification != .verifiedConsistent)
    }
}

private struct Phase1AgentFindingRow: View {
    var finding: AgentDirectoryFinding
    var classification: String
    var selection: String
    var copyToHub: (() -> Void)? = nil
    var deleteBrokenLink: (() -> Void)? = nil
    @Environment(\.appLanguage) private var language
    private func localized(_ text: String) -> String { appLocalized(text, language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                Text(localized(finding.summary))
                Text("\(localized("Node")): \(localized(finding.entryKind.presentationLabel))")
                Text("\(localized("Selection")): \(localized(selection))")
                ForEach(finding.evidence, id: \.self) { evidence in
                    Text(evidence)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text(localized("Evidence boundary: this entry remains read-only. Classification alone never grants write or delete authority."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(finding.entryName).font(.headline)
                    Text(localized(classification)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(finding.entryName)
            .accessibilityValue("\(localized(classification)). \(localized(finding.summary))")
            .accessibilityHint(localized("Expand to read current evidence and the read-only boundary."))
            .accessibilityIdentifier("agent-finding-\(finding.id)")
            if let copyToHub {
                Button(localized("Copy into SkillsHub…"), action: copyToHub)
                    .accessibilityHint(localized("Choose and authorize the exact external source folder. The original remains, and the managed copy is not enabled for any Agent."))
                    .accessibilityIdentifier("copy-agent-entry-\(finding.id)")
                Text(localized("Choose the exact external folder. The original stays in place, and the copy is not enabled for any Agent."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let deleteBrokenLink {
                Button(localized("Delete broken link…"), role: .destructive, action: deleteBrokenLink)
                    .accessibilityHint(localized("Confirms the Agent, link path, original target, and resolved target before deleting only this symbolic-link node."))
                    .accessibilityIdentifier("delete-broken-link-\(finding.id)")
            }
        }
    }
}

private enum AgentWorkspaceOwnershipFilter: String, CaseIterable, Identifiable {
    case all
    case managed
    case external
    case unknown

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All ownership"
        case .managed: "Managed by SkillsHub"
        case .external: "Not managed by SkillsHub"
        case .unknown: "Ownership needs verification"
        }
    }
}

private extension AgentSkillEntryKind {
    var presentationLabel: String {
        switch self {
        case .hubManagedSymlink: "Managed symbolic link"
        case .externalSymlink: "External symbolic link"
        case .brokenSymlink: "Broken symbolic link"
        case .localDirectory: "Directory"
        case .plainFile: "File"
        case .invalid: "Unsupported node"
        case .missing: "Missing node"
        }
    }
}

private struct AgentConfigurationDraft: Hashable {
    var displayName: String
    var iconMonogram: String
    var selectedTarget: URL?
    var proposedTarget: URL?
}

private struct Phase1SettingsWorkspace: View {
    @Bindable var library: SkillsHubLibraryController
    var establishRoot: () -> Void
    var connectRoot: () -> Void
    var chooseAgentTarget: (AgentKind?, @escaping (URL) -> Void) -> Void
    var openAgent: (String) -> Void
    var openTasks: () -> Void
    var openManagementDirectory: () -> Void
    var openOperation: (UUID) -> Void
    @Binding var configuredAgentID: String?
    @Binding var isAddingAgent: Bool
    @Binding var draft: AgentConfigurationDraft
    private func localized(_ text: String) -> String { appLocalized(text, language: library.language) }

    var body: some View {
        Form {
                Section(localized("General")) {
                    Picker(localized("Language"), selection: $library.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language == .system ? localized(language.displayName) : language.displayName).tag(language)
                        }
                    }
                }
                Section(localized("Agents")) {
                    ForEach(library.visibleInstalledAgentDescriptors) { descriptor in
                        Phase1AgentSettingsRow(
                            descriptor: descriptor,
                            capability: library.agentCapabilityPresentation(descriptor)
                        ) {
                            configuredAgentID = descriptor.id
                            isAddingAgent = false
                            draft = AgentConfigurationDraft(
                                displayName: descriptor.displayName,
                                iconMonogram: descriptor.iconMonogram ?? "",
                                selectedTarget: descriptor.skillsDirectory.map {
                                    URL(fileURLWithPath: $0, isDirectory: true)
                                },
                                proposedTarget: nil
                            )
                        }
                    }
                    Button(localized("Add Custom Agent…")) {
                        configuredAgentID = nil
                        isAddingAgent = true
                        draft = AgentConfigurationDraft(
                            displayName: "",
                            iconMonogram: "",
                            selectedTarget: nil,
                            proposedTarget: nil
                        )
                    }
                    .accessibilityIdentifier("add-custom-agent")
                    Text(localized("Saving Agent configuration never changes a Skill relationship."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isAddingAgent {
                    Phase1AgentConfigurationForm(
                        library: library,
                        configuration: nil,
                        draft: $draft,
                        chooseTarget: chooseAgentTarget,
                        openAgent: openAgent,
                        close: {
                            isAddingAgent = false
                        }
                    )
                    .id("new-agent")
                } else if let configuredAgentID,
                          let configuration = library.agentConfigurations.first(where: { $0.id == configuredAgentID }) {
                    Phase1AgentConfigurationForm(
                        library: library,
                        configuration: configuration,
                        draft: $draft,
                        chooseTarget: chooseAgentTarget,
                        openAgent: openAgent,
                        close: {
                            self.configuredAgentID = nil
                        }
                    )
                    .id(configuration.id)
                }
                Section(localized("Management Directory")) {
                    LabeledContent(localized("SkillsHub Root")) {
                        HStack {
                            Text(library.rootURL?.path ?? localized("Not authorized"))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .accessibilityLabel(localized("SkillsHub Root path"))
                                .accessibilityValue(library.rootURL?.path ?? localized("Not authorized"))
                            Button(localized("Manage Directory…"), action: openManagementDirectory)
                                .accessibilityIdentifier("manage-root-settings")
                        }
                    }
                }
                Section(localized("Operation and Recovery")) {
                    ForEach(library.phase1Tasks.sorted { $0.updatedAt > $1.updatedAt }) { task in
                        Button { openOperation(task.id) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(SkillsHubLocalization().localized(task.title, language: library.language))
                                Text(SkillsHubLocalization().localized(task.result, language: library.language)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("open-operation-\(task.id)")
                    }
                    Button {
                        openTasks()
                    } label: {
                        HStack {
                            Label(localized("Operation and Recovery"), systemImage: "checklist")
                            Spacer()
                            if library.phase1TaskBadgeCount > 0 {
                                Text(library.phase1TaskBadgeCount, format: .number)
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                    .accessibilityIdentifier("nav-tasks")
                }
            }
            .formStyle(.grouped)
            .padding(20)
        .accessibilityIdentifier("settings-workspace")
    }
}

private struct Phase1AgentSettingsRow: View {
    var descriptor: InstalledAgentDescriptor
    var capability: AgentCapabilityPresentation
    var configure: () -> Void
    @Environment(\.appLanguage) private var language
    private func localized(_ text: String) -> String { appLocalized(text, language: language) }

    var body: some View {
        HStack {
            Phase1AgentIcon(descriptor: descriptor, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(capability.displayName).font(.headline)
                Text(localized(descriptor.isCustom ? "Custom Agent" : "Built-in Agent"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(capability.targetPath ?? localized("No target configured"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(localized(capability.canManageRelations ? "Relationship management available" : capability.unavailableReason ?? "Unavailable"))
                    .font(.caption)
                    .foregroundStyle(capability.canManageRelations ? Color.secondary : Color.orange)
            }
            Spacer()
            Button(localized("Configure…"), action: configure)
                .accessibilityIdentifier("configure-agent-\(capability.agentID)")
        }
    }
}

private struct Phase1AgentConfigurationForm: View {
    @Bindable var library: SkillsHubLibraryController
    var configuration: AgentConfigurationRecord?
    @Binding var draft: AgentConfigurationDraft
    var chooseTarget: (AgentKind?, @escaping (URL) -> Void) -> Void
    var openAgent: (String) -> Void
    var close: () -> Void
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var isSavingDirectory = false
    @State private var showDiscardConfirmation = false
    @FocusState private var nameFocused: Bool
    private func localized(_ text: String) -> String { appLocalized(text, language: library.language) }

    var body: some View {
        Section(localized(configuration == nil ? "Add Custom Agent" : "Agent Configuration")) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized("Name"))
                    TextField(localized("Name"), text: $draft.displayName)
                        .focused($nameFocused)
                        .accessibilityHint(draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? localized("Agent name is required.") : "")
                        .accessibilityIdentifier("agent-name-field")
                    if draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label(localized("Agent name is required."), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if configuration?.agent == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localized("Icon abbreviation"))
                        HStack {
                            TextField(localized("1–4 visible characters"), text: $draft.iconMonogram)
                                .accessibilityHint(AgentPresentation.normalizedIconMonogram(draft.iconMonogram) == nil
                                    ? localized("Enter 1–4 visible characters for the icon abbreviation.") : "")
                                .accessibilityIdentifier("agent-monogram-field")
                            Phase1AgentIcon(
                                descriptor: InstalledAgentDescriptor(
                                    id: configuration?.id ?? "draft",
                                    displayName: draft.displayName,
                                    iconMonogram: AgentPresentation.normalizedIconMonogram(draft.iconMonogram),
                                    agent: nil,
                                    skillsDirectory: draft.selectedTarget?.path,
                                    isCustom: true,
                                    isDetected: false,
                                    isUnresolved: false,
                                    globalCapability: .unavailable(.missingSkillsDirectory)
                                ),
                                size: 36
                            )
                        }
                        Text(localized("1–4 visible characters"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if AgentPresentation.normalizedIconMonogram(draft.iconMonogram) == nil {
                            Label(localized("Enter 1–4 visible characters for the icon abbreviation."), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized(configuration == nil ? "Global skills directory" : "Current directory"))
                    Text(draft.selectedTarget?.path ?? localized("No target configured"))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if configuration == nil {
                        Button(localized("Choose directory…")) {
                            chooseTarget(nil) { draft.selectedTarget = $0.standardizedFileURL }
                        }
                        .accessibilityIdentifier("choose-custom-agent-target")
                    } else {
                        let blockers = library.agentDirectoryChangeBlockers(agentID: configuration!.id)
                        if blockers.isEmpty {
                            Button(localized("Change directory…")) {
                                chooseTarget(configuration!.agent) { draft.proposedTarget = $0.standardizedFileURL }
                            }
                            .accessibilityIdentifier("choose-agent-target-\(configuration!.id)")
                        } else {
                            Label(localized("Please resolve these relationships or unfinished operations first."), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            ForEach(blockers) { blocker in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(blocker.title).font(.callout.bold())
                                    Text(blocker.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                .accessibilityIdentifier("agent-directory-blocker-\(blocker.id)")
                            }
                            Button(localized("Go to process")) { openAgent(configuration!.id) }
                                .accessibilityIdentifier("process-agent-directory-blockers-\(configuration!.id)")
                        }
                        if let proposedTarget = draft.proposedTarget {
                            LabeledContent(localized("New directory")) {
                                Text(proposedTarget.path)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                            }
                            Button(localized("Save new directory"), action: saveDirectory)
                                .buttonStyle(.borderedProminent)
                                .disabled(isSavingDirectory || !blockers.isEmpty)
                                .accessibilityIdentifier("save-agent-directory-\(configuration!.id)")
                        }
                    }
                }
                Label(localized("Saving display fields never changes the target directory or any Skill relationship."), systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agent-configuration-relation-write-boundary")
                if let saveError {
                    Label(localized(saveError), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("agent-configuration-error")
                }
                HStack {
                    Spacer()
                    Button(localized("Cancel"), action: cancel)
                        .disabled(isSaving)
                        .keyboardShortcut(.cancelAction)
                    Button(localized(configuration == nil ? "Add Agent" : "Save name and abbreviation"), action: save)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSaving || isSavingDirectory || !displayFieldsAreValid
                            || (configuration == nil ? draft.selectedTarget == nil : !hasUnsavedDisplayChanges))
                        .accessibilityIdentifier("save-agent-display-fields")
                }
            }
            .padding(.vertical, 8)
        }
        .onAppear { nameFocused = true }
        .confirmationDialog(localized("Discard unsaved changes?"), isPresented: $showDiscardConfirmation) {
            Button(localized("Discard Changes"), role: .destructive, action: close)
            Button(localized("Stay Here"), role: .cancel) {}
        } message: {
            Text(localized("The saved Agent configuration will remain unchanged."))
        }
    }

    private var hasUnsavedDisplayChanges: Bool {
        draft.displayName != (configuration?.displayName ?? "")
            || draft.iconMonogram != (configuration?.iconMonogram ?? "")
    }

    private var hasUnsavedChanges: Bool {
        hasUnsavedDisplayChanges
            || (configuration == nil && draft.selectedTarget != nil)
            || draft.proposedTarget != nil
    }

    private var displayFieldsAreValid: Bool {
        !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (configuration?.agent != nil || AgentPresentation.normalizedIconMonogram(draft.iconMonogram) != nil)
    }

    private func cancel() {
        if hasUnsavedChanges {
            showDiscardConfirmation = true
        } else {
            close()
        }
    }

    private func save() {
        isSaving = true
        saveError = nil
        Task {
            do {
                if let configuration {
                    try await library.saveAgentDisplayFields(
                        agentID: configuration.id,
                        displayName: draft.displayName,
                        iconMonogram: draft.iconMonogram
                    )
                    draft.displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if configuration.agent == nil {
                        draft.iconMonogram = draft.iconMonogram.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    isSaving = false
                } else if let selectedTarget = draft.selectedTarget {
                    _ = try await library.addCustomAgent(
                        displayName: draft.displayName,
                        iconMonogram: draft.iconMonogram,
                        skillsDirectory: selectedTarget
                    )
                    close()
                }
            } catch {
                saveError = String(describing: error)
                isSaving = false
            }
        }
    }

    private func saveDirectory() {
        guard let configuration, let proposedTarget = draft.proposedTarget else { return }
        isSavingDirectory = true
        saveError = nil
        Task {
            do {
                try await library.saveAgentDirectory(agentID: configuration.id, newDirectory: proposedTarget)
                draft.selectedTarget = proposedTarget
                draft.proposedTarget = nil
                isSavingDirectory = false
            } catch {
                saveError = String(describing: error)
                isSavingDirectory = false
            }
        }
    }
}

private struct Phase1AgentIcon: View {
    var presentation: AgentPresentation
    var size: CGFloat
    var showsBackground = true
    @Environment(\.appLanguage) private var language

    init(descriptor: InstalledAgentDescriptor, size: CGFloat, showsBackground: Bool = true) {
        presentation = AgentPresentation(descriptor: descriptor)
        self.size = size
        self.showsBackground = showsBackground
    }

    init(presentation: AgentPresentation, size: CGFloat, showsBackground: Bool = true) {
        self.presentation = presentation
        self.size = size
        self.showsBackground = showsBackground
    }

    var body: some View {
        Group {
            if presentation.monogramRows.isEmpty == false {
                VStack(spacing: -2) {
                    ForEach(presentation.monogramRows.indices, id: \.self) { index in
                        Text(presentation.monogramRows[index])
                    }
                }
                .font(.system(size: size >= 24 ? 12 : 10, weight: .semibold))
                .frame(width: min(size, 24), height: min(size, 24))
            } else if let assetName = presentation.iconSpecification.assetName {
                agentAsset(assetName)
            } else {
                Image(systemName: presentation.iconSpecification.fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(size, 20), height: min(size, 20))
            }
        }
        .frame(width: size, height: size)
        .background(showsBackground ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(presentation.displayName) \(appLocalized("icon", language: language))")
    }

    @ViewBuilder
    private func agentAsset(_ name: String) -> some View {
        let specification = presentation.iconSpecification
        if specification.renderingMode == .original {
            Image(name)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: min(size, 20), height: min(size, 20))
                .scaleEffect(specification.opticalScale)
                .offset(y: size * specification.verticalOffset)
        } else {
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary)
                .frame(width: min(size, 20), height: min(size, 20))
                .scaleEffect(specification.opticalScale)
                .offset(y: size * specification.verticalOffset)
        }
    }
}

private struct Phase1RelationDetail: View {
    @Bindable var library: SkillsHubLibraryController
    var relation: AgentRelationPresentation
    private func localized(_ text: String) -> String { appLocalized(text, language: library.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    agentIdentity.fixedSize()
                    Spacer()
                    actions
                }
                VStack(alignment: .leading, spacing: 8) {
                    agentIdentity
                    actions
                }
            }
            Text("\(localized("Intent")): \(localized(relation.intendedEnabled.map { $0 ? "Enabled" : "Disabled" } ?? "Not set"))")
                .accessibilityLabel(localized("Intent"))
                .accessibilityValue(localized(relation.intendedEnabled.map { $0 ? "Enabled" : "Disabled" } ?? "Not set"))
                .accessibilityIdentifier("relation-intent-\(relation.relation.agentID)-\(relation.skillID)")
            Text("\(localized("Observed")): \(localized(relation.observation?.presentationLabel ?? "No current observation"))")
                .accessibilityLabel(localized("Observed"))
                .accessibilityValue(localized(relation.observation?.presentationLabel ?? "No current observation"))
                .accessibilityIdentifier("relation-observation-\(relation.relation.agentID)-\(relation.skillID)")
            Text("\(localized("Verification")): \(localized(relation.verification.presentationLabel))")
                .accessibilityLabel(localized("Verification"))
                .accessibilityValue(localized(relation.verification.presentationLabel))
                .accessibilityIdentifier("relation-verification-\(relation.relation.agentID)-\(relation.skillID)")
            if let outcome = relation.lastOutcome {
                Text("\(localized("Last result")): \(localized(outcome.rawValue))")
            }
            if let reason = relation.unavailableReason {
                Label(localized(reason), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("\(localized("Safe next")): \(localized(relation.safeNextStep))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(library.localized(LocalizedMessage("%@ relationship for %@", arguments: [relation.agentDisplayName, relation.skillName])))
        .accessibilityValue("\(localized("Intent")) \(localized(relation.intendedEnabled.map { $0 ? "Enabled" : "Disabled" } ?? "Not set")). \(localized("Observed")) \(localized(relation.observation?.presentationLabel ?? "None")). \(localized("Verification")) \(localized(relation.verification.presentationLabel)).")
        .accessibilityIdentifier("relation-detail-\(relation.relation.agentID)-\(relation.skillID)")
    }

    private var agentIdentity: some View {
        HStack {
            Phase1AgentIcon(presentation: relation.agentPresentation, size: 36)
            Text(relation.agentDisplayName).font(.headline)
        }
    }

    private var actions: some View {
        HStack {
            if relation.canReestablish {
                Phase1RelationActionButton(library: library, relation: relation, reestablish: true)
            }
            Phase1RelationActionButton(library: library, relation: relation)
        }
    }
}

private struct Phase1RelationActionButton: View {
    @Bindable var library: SkillsHubLibraryController
    var relation: AgentRelationPresentation
    var reestablish = false
    private func localized(_ text: String) -> String { appLocalized(text, language: library.language) }

    private var actionTitle: String {
        if relation.isInFlight { return localized("Working") }
        if reestablish { return localized("Re-establish Link") }
        return localized(relation.desiredEnabled ? "Enable" : "Disable")
    }

    var body: some View {
        Button {
            let agentID = relation.relation.agentID
            let skillID = relation.skillID
            let enabled = reestablish ? true : relation.desiredEnabled
            Task {
                do {
                    _ = try await library.setGlobalAgentEnablement(
                        agentID: agentID,
                        skillID: skillID,
                        enabled: enabled
                    )
                } catch {
                    library.handle(error)
                }
            }
        } label: {
            if relation.isInFlight {
                ProgressView().controlSize(.small)
            } else {
                Text(actionTitle)
            }
        }
        .buttonStyle(.bordered)
        .disabled(!relation.canPerformAction || relation.isInFlight)
        .help(relation.unavailableReason.map(localized) ?? localized("Changes only this Agent relationship."))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(localized(relation.isInFlight ? "Action in progress" : relation.verification.presentationLabel))
        .accessibilityHint(relation.unavailableReason.map(localized) ?? localized("Changes only this Agent relationship."))
        .accessibilityIdentifier("relation-action-\(relation.relation.agentID)-\(relation.skillID)-\(reestablish ? "reestablish" : "detail")")
    }

    /// One whole-sentence template per action so each language controls its own word order.
    static func accessibilityTemplate(isInFlight: Bool, reestablish: Bool, desiredEnabled: Bool) -> String {
        if isInFlight { return "Working on %@ relationship" }
        if reestablish { return "Re-establish Link %@ relationship" }
        return desiredEnabled ? "Enable %@ relationship" : "Disable %@ relationship"
    }

    private var accessibilityLabel: String {
        let template = Self.accessibilityTemplate(isInFlight: relation.isInFlight, reestablish: reestablish,
                                                  desiredEnabled: relation.desiredEnabled)
        return library.localized(LocalizedMessage(template, arguments: [relation.agentDisplayName]))
    }
}

private struct Phase1UnavailableWorkspace: View {
    var title: String
    var detail: String
    var systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(detail))
    }
}
