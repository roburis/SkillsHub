import Foundation

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
    func thirdPartyNotices(bundle: Bundle = .main) throws -> String {
        guard let url = bundle.url(forResource: "ThirdPartyNotices", withExtension: "txt") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
