import Foundation

enum AppLanguage: String, Equatable, Sendable {
    case japanese = "ja"
    case english = "en"

    static func resolve(preferredLanguages: [String]) -> AppLanguage {
        guard let primaryLanguage = preferredLanguages.first?.lowercased() else {
            return .english
        }

        return primaryLanguage == "ja"
            || primaryLanguage.hasPrefix("ja-")
            || primaryLanguage.hasPrefix("ja_")
            ? .japanese
            : .english
    }

    static var current: AppLanguage {
        resolve(preferredLanguages: Locale.preferredLanguages)
    }

    var locale: Locale {
        switch self {
        case .japanese:
            return Locale(identifier: "ja_JP")
        case .english:
            return Locale(identifier: "en_US")
        }
    }
}

enum AppLanguagePreference: String, CaseIterable, Equatable, Sendable {
    case automatic
    case japanese
    case english

    private static let defaultsKey = "appLanguagePreference"

    static func saved(in defaults: UserDefaults = .standard) -> AppLanguagePreference {
        guard
            let rawValue = defaults.string(forKey: defaultsKey),
            let preference = AppLanguagePreference(rawValue: rawValue)
        else {
            return .automatic
        }
        return preference
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    func resolve(preferredLanguages: [String]) -> AppLanguage {
        switch self {
        case .automatic:
            return AppLanguage.resolve(preferredLanguages: preferredLanguages)
        case .japanese:
            return .japanese
        case .english:
            return .english
        }
    }
}

enum L10n {
    static var languagePreference: AppLanguagePreference {
        AppLanguagePreference.saved()
    }

    static var systemLanguage: AppLanguage {
        AppLanguage.current
    }

    static var language: AppLanguage {
        languagePreference.resolve(preferredLanguages: Locale.preferredLanguages)
    }

    private static let englishBundle: Bundle? = {
        guard
            let path = Bundle.main.path(forResource: AppLanguage.english.rawValue, ofType: "lproj")
        else {
            return nil
        }
        return Bundle(path: path)
    }()

    static func text(
        _ key: String,
        fallback: String,
        replacing replacements: [String: String] = [:]
    ) -> String {
        let template: String
        switch language {
        case .japanese:
            template = fallback
        case .english:
            template = englishBundle?.localizedString(
                forKey: key,
                value: fallback,
                table: nil
            ) ?? fallback
        }

        return replacements.reduce(template) { result, replacement in
            result.replacingOccurrences(
                of: "{\(replacement.key)}",
                with: replacement.value
            )
        }
    }

    static func setLanguagePreference(_ preference: AppLanguagePreference) {
        preference.save()
    }

    static func accountCount(_ count: Int) -> String {
        guard count > 0 else {
            return text("accounts.count.empty", fallback: "未登録")
        }
        let key = count == 1 ? "accounts.count.one" : "accounts.count.other"
        return text(
            key,
            fallback: "{count}件",
            replacing: ["count": "\(count)"]
        )
    }

    static func resetCreditCount(_ count: Int) -> String {
        let key = count == 1
            ? "usage.reset-credits.count.one"
            : "usage.reset-credits.count.other"
        return text(
            key,
            fallback: "上限リセット{count}件",
            replacing: ["count": "\(count)"]
        )
    }
}
