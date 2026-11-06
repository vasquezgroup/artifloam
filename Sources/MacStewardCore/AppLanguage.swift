import Foundation

/// The languages Artifloam ships, each named in itself. English is the source and the fallback.
public enum AppLanguage {
    public static let all: [(code: String, name: String)] = [
        ("ar", "العربية"), ("ca", "Català"), ("de", "Deutsch"),
        ("en", "English"), ("en-AU", "English (Australia)"), ("en-CA", "English (Canada)"), ("en-GB", "English (UK)"),
        ("es", "Español"), ("es-419", "Español (Latinoamérica)"), ("fr", "Français"), ("gsw", "Schwiizertüütsch"),
        ("hi", "हिन्दी"), ("hr", "Hrvatski"), ("it", "Italiano"), ("ja", "日本語"), ("ko", "한국어"), ("lv", "Latviešu"),
        ("pl", "Polski"), ("pt", "Português"), ("sq", "Shqip"), ("sr-Cyrl", "Српски"), ("sr-Latn", "Srpski"),
        ("sv", "Svenska"), ("tr", "Türkçe"), ("zh-Hans", "简体中文")
    ]
    /// The app's own `AppleLanguages`, the same setting System Settings › Language & Region › Applications writes.
    /// macOS reads it at launch, so a change applies after a restart. Nil: follow the system.
    public static func chosen(in defaults: [String: Any]?) -> String? {
        guard let preferred = defaults?["AppleLanguages"] as? [String], !preferred.isEmpty else { return nil }
        return Bundle.preferredLocalizations(from: all.map(\.code), forPreferences: preferred).first
    }
    /// macOS has no Swiss German system language, so choosing it here is the way in; `de` backs it up for anything macOS itself draws.
    public static func preference(for code: String) -> [String] { code == "gsw" ? ["gsw", "de"] : [code] }
}
