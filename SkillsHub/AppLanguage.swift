import Foundation

nonisolated enum AppLanguage: String, CaseIterable, Codable, Hashable {
    case system
    case english = "en"
    case chinese = "zh-Hans"
    case japanese = "ja"

    /// Picker option names. Concrete languages are shown in their own language in every UI language;
    /// only the "follow system" option is translated by the caller.
    var displayName: String {
        switch self {
        case .system:
            return "Follow System"
        case .english:
            return "English"
        case .chinese:
            return "简体中文"
        case .japanese:
            return "日本語"
        }
    }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else {
            return self
        }
        for preferredLanguage in preferredLanguages {
            let normalized = preferredLanguage.lowercased()
            if normalized.hasPrefix("zh") {
                return .chinese
            }
            if normalized.hasPrefix("ja") {
                return .japanese
            }
            if normalized.hasPrefix("en") {
                return .english
            }
        }
        return .english
    }
}
