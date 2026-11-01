import Foundation

/// Interface language. `system` follows the Mac's preferred language.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case zh
    case en

    var id: String { rawValue }

    static let defaultsKey = "language"

    /// The language chosen in the app's settings. The widget reads it from the snapshot instead.
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

    /// The concrete language once `system` is resolved.
    var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("zh") ? .zh : .en
    }

    var isEnglish: Bool { resolved == .en }

    /// Returns the Chinese or the English string.
    func pick(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }

    var locale: Locale { Locale(identifier: isEnglish ? "en_GB" : "zh_CN") }
}

/// Picks a string in the language set in the app's settings (app code only).
func tr(_ zh: String, _ en: String) -> String { AppLanguage.current.pick(zh, en) }
