import SwiftUI

/// The language Artifloam speaks, chosen inside the app. The iPhone's own language stays as it is.
enum AppLanguage {
    static let key = "appLanguage"

    /// Nil follows the iPhone.
    static var chosen: String? { UserDefaults.standard.string(forKey: key) }

    /// Every language the app has, in its own name and alphabet.
    static var available: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }.sorted { name($0).localizedCompare(name($1)) == .orderedAscending }
    }

    static func name(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code).map { $0.prefix(1).uppercased(with: locale) + $0.dropFirst() } ?? code
    }

    /// Takes effect straight away for the app's own text. iOS uses it for permission prompts and the widget from the next launch.
    static func choose(_ code: String?) {
        if let code {
            UserDefaults.standard.set(code, forKey: key)
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        LanguageBundle.use(code)
    }
}

/// Answers the app's text lookups from the chosen language's folder, so a change needs no restart.
/// ponytail: swaps Bundle.main's class, a long-standing trick for in-app languages. If iOS ever stops honouring it, the choice still applies at the next launch.
final class LanguageBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) private(set) static var current: Bundle?

    static func use(_ code: String?) {
        if !(Bundle.main is LanguageBundle) { object_setClass(Bundle.main, LanguageBundle.self) }
        current = code.flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:))
    }

    override func localizedString(forKey key: String, value: String?, table: String?) -> String {
        if let current = Self.current { return current.localizedString(forKey: key, value: value, table: table) }
        return super.localizedString(forKey: key, value: value, table: table)
    }
}

struct LanguagePicker: View {
    @AppStorage(AppLanguage.key) private var chosen: String?

    var body: some View {
        DetailPage(theme: .care, title: "Language") {
            GlassCard {
                row(nil, title: Text("Same as iPhone"))
                ForEach(AppLanguage.available, id: \.self) { code in
                    Divider().overlay(.white.opacity(0.1))
                    row(code, title: Text(verbatim: AppLanguage.name(code)))
                }
            }
        }
    }

    private func row(_ code: String?, title: Text) -> some View {
        Button {
            AppLanguage.choose(code)
            chosen = code
        } label: {
            HStack {
                title.font(.body)
                Spacer()
                if chosen == code { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(StewardTheme.care.accent) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen == code ? .isSelected : [])
    }
}

extension String {
    /// Text built in code, in the language chosen in the app. Plain String(localized:) keeps the language the app was opened in.
    init(app key: String.LocalizationValue) {
        self.init(localized: key, bundle: LanguageBundle.current ?? .main)
    }
}
