// Ed25519 keys and signatures for the update feed. Keys are base64.
//   swift scripts/feed-signing.swift generate                   prints "<private> <public>"
//   swift scripts/feed-signing.swift public                     private key on stdin
//   swift scripts/feed-signing.swift sign <version> <url> <sha256>   private key on stdin
// The message format must match UpdateFeed.signedMessage in MacStewardCore.
import CryptoKit
import Foundation

func privateKey() -> Curve25519.Signing.PrivateKey {
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        FileHandle.standardError.write(Data("Not a signing key\n".utf8)); exit(1)
    }
    return key
}

let arguments = CommandLine.arguments.dropFirst()
switch (arguments.first, arguments.count) {
case ("generate", 1):
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
case ("public", 1):
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())
case ("sign", 4):
    let parts = Array(arguments)
    let message = Data("artifloam-update-feed-v1\n\(parts[1])\n\(parts[2])\n\(parts[3])".utf8)
    print(try privateKey().signature(for: message).base64EncodedString())
default:
    FileHandle.standardError.write(Data("usage: feed-signing.swift generate | public | sign <version> <url> <sha256>\n".utf8)); exit(2)
}
