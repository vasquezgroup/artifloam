import Foundation
import Security

/// Who actually signed an app, as opposed to what its Info.plist says.
public enum AppleCode {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers = [String: Bool]()
    /// Apple's own code, including its Mac App Store apps. Third-party Developer ID certificates also chain to Apple, so they are excluded.
    public static func signedByApple(_ url: URL) -> Bool {
        lock.lock(); let known = answers[url.path]; lock.unlock()
        if let known { return known }
        var code: SecStaticCode?, requirement: SecRequirement?
        let source = "anchor apple or (anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists)" as CFString
        var result = false
        if SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code, SecRequirementCreateWithString(source, [], &requirement) == errSecSuccess {
            result = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSDoNotValidateExecutable), requirement) == errSecSuccess
        }
        lock.lock(); answers[url.path] = result; lock.unlock()
        return result
    }
    /// Signed by a named developer. Unsigned and ad-hoc apps have no Team ID, so nothing says who made them.
    public static func hasDeveloper(_ url: URL) -> Bool {
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return false }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] != nil
    }
    /// Apple's apps, and this very copy of Artifloam, can't be removed here.
    public static func isProtectedApp(_ url: URL, identifier: String) -> Bool {
        url.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path || (identifier.hasPrefix("com.apple.") && signedByApple(url))
    }
}

extension String {
    /// For showing a name that someone else chose. Control and invisible formatting characters (newlines, right-to-left
    /// overrides) could fake a second row or hide an extension. Never use the result as a path.
    public var displaySafe: String {
        String(String.UnicodeScalarView(unicodeScalars.map { [.control, .format].contains($0.properties.generalCategory) ? "\u{FFFD}" : $0 }))
    }
}
