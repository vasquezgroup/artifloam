import CryptoKit
import Foundation

/// The update feed is remote input and its URL gets opened by the system, so a tampered feed
/// must not reach another site, a file:// path or a custom app scheme, or put its own text in the alert.
public enum UpdateFeed {
    /// The private key is in the release Mac's Keychain, never on the website, so taking over the
    /// website can't publish an update. See scripts/create-feed-key.sh.
    public static let signingPublicKey = "eT7KOX2N4YWz8CQ1bgqABmsNnVgpTNNt9ae2w2kSDF0="

    public static func trusted(version: String, url: URL) -> Bool {
        guard !version.isEmpty, version.count <= 32, version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return false }
        return url.scheme == "https" && url.host == "vasquezgroup.ch" && url.port == nil && url.user == nil
            && url.path.hasPrefix("/downloads/") && !url.path.contains("..") && url.pathExtension == "zip"
    }

    /// Must match scripts/feed-signing.swift.
    public static func signedMessage(version: String, url: URL, sha256: String) -> Data {
        Data("artifloam-update-feed-v1\n\(version)\n\(url.absoluteString)\n\(sha256)".utf8)
    }

    /// A feed counts only if our key signed this version, link and download hash together.
    public static func verified(version: String, url: URL, sha256: String, signature: String, publicKey: String = signingPublicKey) -> Bool {
        guard trusted(version: version, url: url), sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let keyData = Data(base64Encoded: publicKey), let signatureData = Data(base64Encoded: signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(signatureData, for: signedMessage(version: version, url: url, sha256: sha256))
    }

    public static func sha256(ofFile url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
