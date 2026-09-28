import Foundation

extension SkillsHubLibraryController {
    var settingsState: AppSettingsState {
        settingsService.state(
            rootPath: settingsRootPathDisplay,
            defaultRootPath: defaultRootURL.path,
            language: language,
            cachePolicyName: cachePolicyName
        )
    }

    func handle(_ error: Error) {
        errorMessage = errorPresentation(for: error)
    }

    func setStatus(_ englishTemplate: String, _ arguments: CVarArg...) {
        statusMessage = LocalizedMessage(englishTemplate, arguments: arguments.map { String(describing: $0) })
    }

    func clearStatus() {
        statusMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }

    func localizedMessage(_ englishTemplate: String, _ arguments: [CVarArg] = []) -> String {
        localization.localized(
            LocalizedMessage(englishTemplate, arguments: arguments.map { String(describing: $0) }),
            language: language
        )
    }

    func localizedErrorMessage(for error: Error) -> String {
        localization.localized(errorPresentation(for: error), language: language)
    }

    func localized(_ message: LocalizedMessage) -> String {
        localization.localized(message, language: language)
    }

    private func errorPresentation(for error: Error) -> LocalizedMessage {
        guard let failure = error as? SkillsHubLibraryFailure else {
            return .verbatim(String(describing: error))
        }
        switch failure {
        case .missingRoot:
            return "Choose a root before continuing."
        case .missingSkill(let skillID):
            return LocalizedMessage("Skill not found: %@.", arguments: [skillID])
        case .invalidSource(let detail):
            return detail
        case .missingAgentPath(let agent):
            return LocalizedMessage("Choose a directory for %@ before creating links.", arguments: [agent.displayName])
        }
    }

    func sourceName(for skill: InstalledSkill) -> String {
        if let sourceID = skill.sourceID, let source = sources.first(where: { $0.id == sourceID }) {
            return presentationService.sourceName(for: source)
        }
        switch skill.sourceKind {
        case .githubRepository:
            return "GitHub"
        case .npmPackage:
            return "npm"
        case .localDirectory:
            return "Local"
        case .manualFilesystem:
            return "Local"
        }
    }

    func sourceName(forSourceID sourceID: UUID) -> String {
        guard let source = sources.first(where: { $0.id == sourceID }) else {
            return "Unknown Source"
        }
        return presentationService.sourceName(for: source)
    }
}
