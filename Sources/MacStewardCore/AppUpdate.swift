import Foundation
import Security

/// Installs a downloaded update over this app. The caller has already checked the signed feed and the archive's hash.
/// Everything here happens on a copy beside the app, which only replaces it once every check has passed.
public enum AppUpdate {
    public static func install(archive: URL, version: String, over current: URL) throws {
        var source: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(current as CFURL, [], &source) == errSecSuccess, let source,
              SecCodeCopyDesignatedRequirement(source, [], &requirement) == errSecSuccess, let requirement else {
            throw StewardError.blocked("This copy of Artifloam isn't signed, so it can't update itself.")
        }
        try install(archive: archive, version: version, over: current, requirement: requirement, notarized: notarized)
    }
    static func notarized(_ app: URL) -> Bool {
        run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], timeout: 60).code == 0
    }
    static func install(archive: URL, version: String, over current: URL, requirement: SecRequirement, notarized: (URL) -> Bool) throws {
        let files = FileManager.default
        // Beside the app, so the final swap is one atomic step on the same volume.
        guard let folder = try? files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true) else {
            throw StewardError.blocked("Artifloam can't write to its own folder. Move it to Applications, or download the update from vasquezgroup.ch/artifloam.")
        }
        defer { try? files.removeItem(at: folder) }
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path], timeout: 300).code == 0 else {
            throw StewardError.blocked("The update couldn't be unpacked. Nothing was changed.")
        }
        // Exactly one real app. Anything else in the archive isn't what was released.
        let found = (try? files.contentsOfDirectory(atPath: folder.path))?.filter { !$0.hasPrefix(".") && $0 != "__MACOSX" } ?? []
        let candidate = folder.appendingPathComponent(found.first ?? "")
        guard found.count == 1, candidate.pathExtension == "app",
              (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else {
            throw StewardError.blocked("The update didn't contain the expected app. Nothing was changed.")
        }
        try verify(candidate, version: version, requirement: requirement, notarized: notarized)
        do { _ = try files.replaceItemAt(current, withItemAt: candidate) }
        catch { throw StewardError.blocked("Artifloam couldn't replace itself, so nothing was changed. You can download the update from vasquezgroup.ch/artifloam.") }
    }
    /// The app is intact, signed by the same developer as this one, approved by Apple, and the version the signed feed promised.
    static func verify(_ app: URL, version: String, requirement: SecRequirement, notarized: (URL) -> Bool) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw StewardError.blocked("The update isn't signed by Artifloam's developer. Nothing was changed.")
        }
        let info = BoundedFile.read(app.appendingPathComponent("Contents/Info.plist")).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
        guard info?["CFBundleShortVersionString"] as? String == version else {
            throw StewardError.blocked("The update isn't the promised version. Nothing was changed.")
        }
        guard notarized(app) else { throw StewardError.blocked("Apple's check rejected the update. Nothing was changed.") }
    }
}
