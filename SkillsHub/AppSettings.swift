import Foundation

nonisolated struct AppSettingsState: Equatable {
    var rootPath: String
    var language: AppLanguage
    var cachePolicyName: String
    var customRootWarning: String?
}

nonisolated final class AppLanguagePreferences {
    private static let key = "appLanguage"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var language: AppLanguage {
        get {
            defaults.string(forKey: Self.key).flatMap(AppLanguage.init(rawValue:)) ?? .system
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }
}

nonisolated final class AppSettingsService {
    func state(rootPath: String, defaultRootPath: String = UserHomeDirectoryResolver.currentHomeDirectory().appendingPathComponent("skills-hub").path, language: AppLanguage, cachePolicyName: String) -> AppSettingsState {
        AppSettingsState(
            rootPath: rootPath,
            language: language,
            cachePolicyName: cachePolicyName,
            customRootWarning: rootPath == defaultRootPath ? nil : "Custom root is only applied inside Skills Hub."
        )
    }

}
