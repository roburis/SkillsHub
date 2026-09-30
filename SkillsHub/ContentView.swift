import AppKit
import SwiftUI

struct ContentView: View {
    @State private var phase1Selection: Phase1NavigationDestination = .allSkills
    @State private var selectedLocalSourceID: UUID?
    @State private var selectedGitHubSourceID: UUID?
    @State private var library: SkillsHubLibraryController
    @State private var pendingLocalSourceURL: URL?
    @State private var isAddingLocalSource = false
    @State private var isShowingGitHubSourceSheet = false
    @State private var gitHubSourceInput = ""
    @State private var isAddingGitHubSource = false
    @State private var gitHubSourceTask: Task<Void, Never>?

    init(library: SkillsHubLibraryController? = nil) {
        if let library {
            _library = State(initialValue: library)
            return
        }
        _library = State(initialValue: Self.makeLibrary())
    }

    @MainActor
    static func makeLibrary() -> SkillsHubLibraryController {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let controller: SkillsHubLibraryController
        if arguments.contains("--skillshub-ui-empty-fixture")
            || arguments.contains("--skillshub-ui-fixture") {
            let preferences = Self.fixturePreferences(from: arguments)
            WorkspaceLayoutPreferences.defaults = preferences
            let languagePreferences = AppLanguagePreferences(defaults: preferences)
            do {
                let configuration = try Phase1UITestFixtureConfiguration(arguments: arguments)
                if arguments.contains("--skillshub-ui-empty-fixture") {
                    controller = try SkillsHubLibraryController.emptyUIFixture(
                        configuration: configuration,
                        languagePreferences: languagePreferences
                    )
                } else {
                    controller = try SkillsHubLibraryController.uiFixture(
                        configuration: configuration,
                        languagePreferences: languagePreferences
                    )
                }
            } catch {
                controller = SkillsHubLibraryController(
                    languagePreferences: languagePreferences,
                    agentHomeDirectory: URL(fileURLWithPath: "/dev/null", isDirectory: true)
                )
                controller.errorMessage = "Invalid Phase 1 UI fixture: \(error.localizedDescription)"
            }
        } else {
            let languagePreferences = arguments.contains("--skillshub-home")
                ? AppLanguagePreferences(defaults: Self.fixturePreferences(from: arguments))
                : AppLanguagePreferences()
            let agentHomeDirectory = Self.debugHomeDirectory(from: arguments)
                ?? UserHomeDirectoryResolver.currentHomeDirectory()
            let streamFactory: () -> any FilesystemEventStreaming = arguments.contains("--skillshub-ui-observation-failure")
                ? { InertFilesystemEventStream(startResult: false) }
                : { SystemFilesystemEventStream() }
            if let appSupportURL = Self.debugAppSupportDirectory(from: arguments) {
                controller = SkillsHubLibraryController(
                    languagePreferences: languagePreferences,
                    appSupportURL: appSupportURL,
                    agentHomeDirectory: agentHomeDirectory,
                    filesystemEventStreamFactory: streamFactory
                )
            } else {
                controller = SkillsHubLibraryController(
                    languagePreferences: languagePreferences,
                    agentHomeDirectory: agentHomeDirectory,
                    filesystemEventStreamFactory: streamFactory
                )
            }
        }
        if let language = Self.debugLanguage(from: arguments) {
            controller.language = language
        }
        return controller
        #else
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--skillshub-ui-fixture-run-id"),
           let home = Self.debugHomeDirectory(from: arguments),
           let support = Self.debugAppSupportDirectory(from: arguments) {
            let preferences = Self.fixturePreferences(from: arguments)
            WorkspaceLayoutPreferences.defaults = preferences
            return SkillsHubLibraryController(
                languagePreferences: AppLanguagePreferences(defaults: preferences),
                appSupportURL: support,
                agentHomeDirectory: home,
                filesystemEventStreamFactory: { SystemFilesystemEventStream() }
            )
        }
        return SkillsHubLibraryController(
            languagePreferences: AppLanguagePreferences(),
            filesystemEventStreamFactory: { SystemFilesystemEventStream() }
        )
        #endif
    }

    var body: some View {
        Phase1ProductShell(
            library: library,
            selection: $phase1Selection,
            selectedLocalSourceID: $selectedLocalSourceID,
            selectedGitHubSourceID: $selectedGitHubSourceID,
            establishRoot: establishRoot,
            connectRoot: connectRoot,
            addLocalSource: addLocalSource,
            addGitHubSource: showGitHubSourceSheet,
            chooseAgentTarget: chooseAgentTarget,
            chooseExactAgentTarget: chooseExactAgentTarget
        )
        .task {
            bootstrapDefaultRoot()
        }
        .sheet(item: $library.pendingPhase1OperationPlan) { plan in
            Phase1OperationConfirmationSheet(
                plan: plan,
                language: library.language,
                confirm: {
                    Task {
                        await library.confirmPendingPhase1Operation()
                    }
                },
                cancel: {
                    Task {
                        await library.cancelPendingPhase1Operation()
                    }
                }
            )
            .interactiveDismissDisabled()
        }
        .sheet(
            isPresented: Binding(
                get: { pendingLocalSourceURL != nil },
                set: { if !$0 && !isAddingLocalSource { pendingLocalSourceURL = nil } }
            )
        ) {
            if let pendingLocalSourceURL {
                LocalSourceImportSheet(
                    directory: pendingLocalSourceURL,
                    isSubmitting: isAddingLocalSource,
                    errorMessage: library.errorMessage.map(library.localized),
                    add: submitLocalSource,
                    cancel: { self.pendingLocalSourceURL = nil }
                )
                .interactiveDismissDisabled(isAddingLocalSource)
            }
        }
        .sheet(isPresented: $isShowingGitHubSourceSheet) {
            GitHubSourceImportSheet(
                input: $gitHubSourceInput,
                isSubmitting: isAddingGitHubSource,
                errorMessage: library.errorMessage.map(library.localized),
                add: submitGitHubSource,
                cancel: cancelGitHubSource
            )
            .interactiveDismissDisabled(isAddingGitHubSource)
        }
        .environment(\.appLanguage, library.language)
    }

    /// UI fixtures keep language and layout preferences out of the user's domain.
    /// One suite is reused and cleared whenever a new fixture run starts, so relaunches within a run persist.
    private static func fixturePreferences(from arguments: [String]) -> UserDefaults {
        let suiteName = "me.ledar.SkillsHub.ui-fixture"
        let runKey = "fixtureRunID"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return UserDefaults() }
        let runID = arguments.firstIndex(of: "--skillshub-ui-fixture-run-id")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        if defaults.string(forKey: runKey) != runID {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(runID, forKey: runKey)
        }
        return defaults
    }

    private static func debugHomeDirectory(from arguments: [String]) -> URL? {
        guard let flagIndex = arguments.firstIndex(of: "--skillshub-home"),
              arguments.indices.contains(arguments.index(after: flagIndex)) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[arguments.index(after: flagIndex)], isDirectory: true)
    }

    private static func debugAppSupportDirectory(from arguments: [String]) -> URL? {
        guard let flagIndex = arguments.firstIndex(of: "--skillshub-app-support"),
              arguments.indices.contains(arguments.index(after: flagIndex)) else {
            return nil
        }
        let directoryName = arguments[arguments.index(after: flagIndex)]
        guard directoryName.isEmpty == false,
              directoryName.contains("/") == false,
              let baseDirectory = FileManager.default.urls(
                  for: .applicationSupportDirectory,
                  in: .userDomainMask
              ).first else {
            return nil
        }
        return baseDirectory.appending(path: directoryName, directoryHint: .isDirectory)
    }

    #if DEBUG
    private static func debugLanguage(from arguments: [String]) -> AppLanguage? {
        guard let flagIndex = arguments.firstIndex(of: "--skillshub-ui-fixture-language"),
              arguments.indices.contains(arguments.index(after: flagIndex)) else {
            return nil
        }
        let value = arguments[arguments.index(after: flagIndex)]
        switch value {
        case AppLanguage.english.rawValue, "english":
            return .english
        case AppLanguage.chinese.rawValue, "chinese", "zh":
            return .chinese
        case AppLanguage.japanese.rawValue, "japanese":
            return .japanese
        default:
            return nil
        }
    }
    #endif

    private func bootstrapDefaultRoot() {
        do {
            try library.bootstrapDefaultRootIfPresent()
        } catch {
            // A missing default Root or a lost permission is a silent no-op (handled
            // inside bootstrap); any other failure surfaces to the user.
            library.handle(error)
        }
    }

    private func establishRoot() {
        chooseDirectory(
            defaultDirectoryURL: library.suggestedRootURL,
            action: { url in
                Task {
                    await library.establishSelectedRoot(url)
                }
            },
            onCancel: {
                _ = library.cancelRootSelection()
            }
        )
    }

    private func connectRoot() {
        chooseDirectory(
            defaultDirectoryURL: library.suggestedRootURL,
            action: library.connectSelectedRoot,
            onCancel: {
                _ = library.cancelRootSelection()
            }
        )
    }

    private func addLocalSource() {
        chooseDirectory { url in
            library.errorMessage = nil
            pendingLocalSourceURL = url
        }
    }

    private func submitLocalSource() {
        guard let pendingLocalSourceURL, !isAddingLocalSource else { return }
        let previousIDs = Set(library.localSourcesForPresentation.map(\.id))
        isAddingLocalSource = true
        Task {
            await library.addLocalSource(from: pendingLocalSourceURL)
            isAddingLocalSource = false
            if library.errorMessage == nil {
                selectedLocalSourceID = library.localSourcesForPresentation.first { !previousIDs.contains($0.id) }?.id
                phase1Selection = .localSources
                self.pendingLocalSourceURL = nil
            }
        }
    }

    private func showGitHubSourceSheet() {
        library.errorMessage = nil
        isShowingGitHubSourceSheet = true
    }

    private func submitGitHubSource() {
        let input = gitHubSourceInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isAddingGitHubSource else { return }
        let previousIDs = Set(library.githubSourcesForPresentation.map(\.id))
        isAddingGitHubSource = true
        gitHubSourceTask = Task {
            await library.addGitHubSource(input)
            isAddingGitHubSource = false
            gitHubSourceTask = nil
            if library.errorMessage == nil {
                selectedGitHubSourceID = library.githubSourcesForPresentation.first { !previousIDs.contains($0.id) }?.id
                phase1Selection = .githubSources
                isShowingGitHubSourceSheet = false
                gitHubSourceInput = ""
            }
        }
    }

    private func cancelGitHubSource() {
        if isAddingGitHubSource {
            gitHubSourceTask?.cancel()
        } else {
            isShowingGitHubSourceSheet = false
        }
    }

    private func chooseAgentTarget(
        agent: AgentKind?,
        selected: @escaping (URL) -> Void
    ) {
        chooseDirectory(
            defaultDirectoryURL: agent.map(library.resolvedAgentSkillsDirectory),
            action: selected
        )
    }

    private func chooseExactAgentTarget(
        agent: AgentKind,
        selected: @escaping () -> Void
    ) {
        let target = library.agentPathResolver.globalSkillsDirectory(
            for: agent, environment: library.agentEnvironment, homeDirectory: library.agentHomeDirectory
        ).standardizedFileURL
        chooseDirectory(defaultDirectoryURL: target, requiredDirectoryURL: target, allowCreation: false) { _ in
            selected()
        }
    }

    private func chooseDirectory(
        defaultDirectoryURL: URL? = nil,
        requiredDirectoryURL: URL? = nil,
        allowCreation: Bool = true,
        action: @escaping (URL) throws -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = allowCreation
        panel.resolvesAliases = true
        panel.directoryURL = defaultDirectoryURL
        NSApp.activate(ignoringOtherApps: true)

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                onCancel()
                return
            }
            if let requiredDirectoryURL, url.standardizedFileURL != requiredDirectoryURL {
                library.handle(SkillsHubLibraryFailure.invalidSource("Choose the exact default Agent skills directory."))
                return
            }
            handleSelectedURL(url, action: action)
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func handleSelectedURL(_ url: URL, action: (URL) throws -> Void) {
        do {
            try library.rememberUserSelectedAccess(to: url)
            try action(url)
        } catch {
            library.handle(error)
        }
    }

}

private struct LocalSourceImportSheet: View {
    let directory: URL
    let isSubmitting: Bool
    let errorMessage: String?
    @Environment(\.appLanguage) private var language
    let add: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized("Add Local Source"))
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("local-source-import-sheet")
            Text(localized("The complete selected folder will be copied into the current Root. The external original remains unchanged, and no Agent is enabled."))
                .foregroundStyle(.secondary)
            GroupBox(localized("Selected folder")) {
                Text(directory.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if isSubmitting {
                ProgressView(localized("Checking and importing…"))
                    .accessibilityIdentifier("local-source-import-progress")
            }
            HStack {
                Spacer()
                Button(localized("Cancel"), action: cancel)
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("cancel-local-source-import")
                Button(localized("Add"), action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("confirm-local-source-import")
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func localized(_ text: String) -> String {
        SkillsHubLocalization().localized(text, language: language)
    }
}

private struct GitHubSourceImportSheet: View {
    @Binding var input: String
    let isSubmitting: Bool
    let errorMessage: String?
    @Environment(\.appLanguage) private var language
    let add: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized("Add GitHub Source"))
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("github-source-import-sheet")
            Text(localized("Enter a public repository root. Skills Hub verifies and keeps the complete repository at one commit; no Agent is enabled."))
                .foregroundStyle(.secondary)
            TextField("https://github.com/owner/repository", text: $input)
                .textFieldStyle(.roundedBorder)
                .disabled(isSubmitting)
                .accessibilityIdentifier("github-source-input")
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if isSubmitting {
                ProgressView(localized("Fetching, checking, and adding…"))
                    .accessibilityIdentifier("github-source-import-progress")
            }
            HStack {
                Spacer()
                Button(localized(isSubmitting ? "Cancel Fetch" : "Cancel"), action: cancel)
                    .accessibilityIdentifier("cancel-github-source-import")
                Button(localized("Add"), action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("confirm-github-source-import")
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func localized(_ text: String) -> String {
        SkillsHubLocalization().localized(text, language: language)
    }
}

#Preview {
    ContentView()
}
