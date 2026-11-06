import XCTest
@testable import MacStewardCore

/// Fails when a language lacks a string or a translation's placeholders don't match its English key.
final class LocalizationTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Localization")
    /// The plural forms each language needs (CLDR) beyond "other", for numbers an app shows.
    private static let requiredPlurals: [String: Set<String>] = [
        "ar": ["zero", "one", "two", "few", "many"], "hr": ["one", "few"], "sr-Cyrl": ["one", "few"], "sr-Latn": ["one", "few"],
        "pl": ["one", "few", "many"], "lv": ["zero", "one"], "ja": [], "ko": [], "zh-Hans": []
    ]
    private func catalog(_ name: String) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: Self.folder.appendingPathComponent(name + ".xcstrings"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }
    /// Value types in argument order: "%2$@ of %1$lld" is ["lld", "@"]. Nil when a string mixes numbered and plain placeholders.
    static func arguments(_ text: String) -> [String]? {
        let pattern = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(?:\.\d+)?(%|@|lld|ld|lf|d|f|llu|lu|u)"#)
        var plain = [String](), numbered = [Int: String]()
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let type = String(text[Range(match.range(at: 2), in: text)!])
            if type == "%" { continue }
            if let range = Range(match.range(at: 1), in: text) { numbered[Int(text[range])!] = type } else { plain.append(type) }
        }
        if !numbered.isEmpty && !plain.isEmpty { return nil }
        return plain.isEmpty ? numbered.keys.sorted().map { numbered[$0]! } : plain
    }
    /// Plain text in a string unit, or the forms of a plural.
    private func forms(_ localization: [String: Any]?) -> (text: String?, plural: [String: String]?) {
        if let unit = localization?["stringUnit"] as? [String: Any] { return (unit["value"] as? String, nil) }
        guard let plural = (localization?["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] else { return (nil, nil) }
        return (nil, plural.compactMapValues { ($0["stringUnit"] as? [String: Any])?["value"] as? String })
    }
    func testEveryLanguageHasEveryStringWithMatchingPlaceholders() throws {
        let strings = try catalog("Localizable")
        XCTAssertGreaterThan(strings.count, 100)
        var problems = [String]()
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false {
            // Keys with no words, such as "%lld%%" or "·", are the same everywhere; a translation is optional.
            let wordless = key.replacingOccurrences(of: #"%(\d+\$)?(lld|@|lf|d|%)"#, with: "", options: .regularExpression).allSatisfy { !$0.isLetter }
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            let english = forms(localizations["en"])
            let expected = Self.arguments(key)
            for language in AppLanguage.all.map(\.code) where !(language == "en" && english.text == nil && english.plural == nil) {
                let found = forms(localizations[language])
                if found.text == nil && found.plural == nil { if !wordless { problems.append("\(language) is missing \"\(key)\"") }; continue }
                if let text = found.text, text.isEmpty { problems.append("\(language) has an empty \"\(key)\"") }
                if let text = found.text, Self.arguments(text) != expected { problems.append("\(language) \"\(key)\": placeholders differ in \"\(text)\"") }
                if english.plural != nil && found.plural == nil { problems.append("\(language) \"\(key)\" needs plural forms") }
                guard let plural = found.plural else { continue }
                if plural["other"] == nil { problems.append("\(language) \"\(key)\" has no \"other\" form") }
                let needed = Self.requiredPlurals[language] ?? ["one"]
                for form in needed where plural[form] == nil { problems.append("\(language) \"\(key)\" has no \"\(form)\" form") }
                for (form, text) in plural {
                    let arguments = Self.arguments(text)
                    // "one" may spell out its number ("a file", "ملف واحد"), but nothing else may go missing or change.
                    let spelledOut = ["zero", "one", "two"].contains(form) && arguments?.isEmpty == true && expected?.count == 1
                    if arguments != expected && !spelledOut { problems.append("\(language) \"\(key)\" \(form): placeholders differ in \"\(text)\"") }
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, "\(problems.count) problems:\n" + problems.sorted().prefix(60).joined(separator: "\n"))
    }
    func testInfoPlistStringsExistInEveryLanguage() throws {
        let strings = try catalog("InfoPlist")
        XCTAssertEqual(Set(strings.keys), ["NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription", "NSDownloadsFolderUsageDescription", "NSAppleEventsUsageDescription"])
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for language in AppLanguage.all.map(\.code) { XCTAssertNotNil(forms(localizations[language]).text, "\(language) is missing \(key)") }
        }
    }
    func testChosenLanguageFollowsAppSetting() {
        XCTAssertNil(AppLanguage.chosen(in: [:]))
        XCTAssertEqual(AppLanguage.chosen(in: ["AppleLanguages": ["de"]]), "de")
        XCTAssertEqual(AppLanguage.chosen(in: ["AppleLanguages": AppLanguage.preference(for: "gsw")]), "gsw")
        XCTAssertEqual(AppLanguage.chosen(in: ["AppleLanguages": ["es-MX"]]), "es-419")
        XCTAssertEqual(AppLanguage.chosen(in: ["AppleLanguages": ["sr-Latn-RS"]]), "sr-Latn")
    }
    func testPlaceholderParser() {
        XCTAssertEqual(Self.arguments("%lld of %@ · 5%%"), ["lld", "@"])
        XCTAssertEqual(Self.arguments("%2$@ of %1$lld"), ["lld", "@"])
        XCTAssertNil(Self.arguments("%1$@ and %@"))
    }
}
