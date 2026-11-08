import CryptoKit
import Foundation

/// Carries the app list from the Mac to the iPhone over Wi-Fi. Both know one value without talking: the ID of the iPhone app's
/// data folder. The Mac reads it over the cable, and the app knows its own. So nobody else on the network can find or read the list,
/// and it can't reach anyone else's iPhone, with no pairing code to type.
public enum AppListLink {
    public static let serviceType = "_artifloam-list._tcp"
    public static let maximumBytes = 4_000_000

    /// Nil unless the folder ends in a real ID, so a guessable value can never become the key.
    public static func secret(fromContainer path: String) -> String? {
        let last = (path as NSString).lastPathComponent
        return UUID(uuidString: last)?.uuidString.lowercased()
    }

    public static func serviceName(secret: String) -> String {
        SHA256.hash(data: Data("name:\(secret)".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func key(secret: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("key:\(secret)".utf8)))
    }

    public static func seal(_ data: Data, secret: String) -> Data? {
        try? AES.GCM.seal(data, using: key(secret: secret)).combined
    }

    public static func open(_ data: Data, secret: String) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key(secret: secret))
    }
}
