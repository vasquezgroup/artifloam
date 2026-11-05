import Foundation
public enum StewardPreferences {
    public static let domain = "com.vasquezgroup.artifloam"
    /// The bundle identifier up to version 0.18.
    public static let legacyDomain = "local.macsteward.app"
    public static let migratedKey = "migratedFromLegacyDomain"
    // macOS rejects a suite whose identifier is the current app's own bundle ID.
    // Use the normal app domain in the GUI; the separate CLI joins that domain.
    public static let defaults: UserDefaults = {
        if Bundle.main.bundleIdentifier == domain {
            migrate(from: UserDefaults.standard.persistentDomain(forName: legacyDomain), into: .standard)
            return .standard
        }
        return UserDefaults(suiteName: domain) ?? .standard
    }()
    /// Keep lists and folder choices carry over once. A value already set in the new domain wins.
    static func migrate(from old: [String: Any]?, into defaults: UserDefaults) {
        guard let old, defaults.object(forKey: migratedKey) == nil else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: migratedKey)
    }
    public static var projectPaths: [String] { defaults.stringArray(forKey: "projectRoots") ?? [] }
    public static var ignoredPaths: [String] { (defaults.stringArray(forKey: "ignoredPaths") ?? []) + (defaults.stringArray(forKey: "excludedDetectedProjects") ?? []) }
}
