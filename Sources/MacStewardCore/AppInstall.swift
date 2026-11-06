import Foundation
import Security

/// Offers to copy a downloaded app into Applications. macOS runs a quarantined app from a temporary
/// read-only location until it is moved, and the daily cleanup and uninstall need the installed path.
public enum AppInstall {
    public static let destination = URL(fileURLWithPath: "/Applications/Artifloam.app")
    /// Never over an existing copy: replacing an installed app is the person's decision.
    public static func shouldOffer(_ bundle: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, destination: URL = destination) -> Bool {
        let app = bundle.standardizedFileURL
        let parent = app.deletingLastPathComponent().path
        guard app.pathExtension == "app", parent != "/Applications", parent != home.standardizedFileURL.appendingPathComponent("Applications").path else { return false }
        return !FileManager.default.fileExists(atPath: destination.path)
    }
    /// The copy must pass the same signature check as this app before macOS's quarantine mark comes off it;
    /// a copy that doesn't is removed again.
    public static func copy(_ bundle: URL, to destination: URL = destination) throws {
        var source: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &source) == errSecSuccess, let source,
              SecCodeCopyDesignatedRequirement(source, [], &requirement) == errSecSuccess, let requirement else {
            throw StewardError.blocked(String(localized: "This copy of Artifloam isn't signed, so it wasn't moved."))
        }
        try FileManager.default.copyItem(at: bundle, to: destination)
        var copied: SecStaticCode?
        guard SecStaticCodeCreateWithPath(destination as CFURL, [], &copied) == errSecSuccess, let copied,
              SecStaticCodeCheckValidity(copied, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), requirement) == errSecSuccess else {
            try? FileManager.default.removeItem(at: destination)
            throw StewardError.blocked(String(localized: "The copy in Applications failed its signature check, so it was removed."))
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path], timeout: 30)
    }
}
