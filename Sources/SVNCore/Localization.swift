import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"

    public static let preferenceKey = "appLanguage"
    public var id: String { rawValue }
    public var locale: Locale { Locale(identifier: rawValue) }

    // Keep language names recognizable regardless of the active interface language.
    public var displayName: String {
        switch self {
        case .chinese: "中文"
        case .english: "English"
        }
    }

    /// Save only this app's preference; AppKit reads AppleLanguages at next launch.
    public func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
        defaults.set([rawValue], forKey: "AppleLanguages")
    }
}

public enum L10n {
    /// Pin the language for this session so existing operations and native panels stay consistent.
    public static let language = AppLanguage(
        rawValue: UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) ?? "zh-Hans"
    ) ?? .chinese

    private static let bundle = Bundle(
        path: Bundle.module.path(forResource: language.rawValue, ofType: "lproj")!
    )!

    /// Translate before substituting values, keeping paths, diagnostics and user text verbatim.
    public static func text(_ key: String, _ arguments: Any...) -> String {
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        guard !arguments.isEmpty else { return format }
        let values = arguments.map { String(describing: $0) }
        return String(format: format, locale: language.locale, arguments: values)
    }
}
