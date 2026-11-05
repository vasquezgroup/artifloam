import CryptoKit
import XCTest
@testable import MacStewardCore

final class UsagePingTests: XCTestCase {
    func testPayloadSendsOnlyTheDocumentedFields() throws {
        let data = try JSONEncoder().encode(UsagePing.Payload(version: "0.18.0"))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(Set(fields.keys), ["app", "period", "version", "os", "arch", "nonce"])
    }

    func testPeriodIsTheUTCMonth() {
        XCTAssertEqual(UsagePing.period(for: Date(timeIntervalSince1970: 1_798_761_599)), "2026-12") // 2026-12-31 23:59:59 UTC
        XCTAssertEqual(UsagePing.period(for: Date(timeIntervalSince1970: 1_798_761_600)), "2027-01")
    }

    func testSendsOncePerMonthAndNeverWhenOff() {
        XCTAssertFalse(UsagePing.isDue(enabled: false, lastSent: nil, period: "2026-11"))
        XCTAssertTrue(UsagePing.isDue(enabled: true, lastSent: nil, period: "2026-11"))
        XCTAssertFalse(UsagePing.isDue(enabled: true, lastSent: "2026-11", period: "2026-11"))
        XCTAssertTrue(UsagePing.isDue(enabled: true, lastSent: "2026-10", period: "2026-11"))
    }

    func testSolvedNonceProvesTheWorkAndVaries() {
        var first = UsagePing.Payload(version: "0.18.0"), second = first
        first.solve(bits: 10); second.solve(bits: 10)
        XCTAssertNotEqual(first.nonce, second.nonce)
        let message = "\(first.app)|\(first.period)|\(first.version)|\(first.os)|\(first.arch)|\(first.nonce)"
        XCTAssertTrue(UsagePing.hasLeadingZeroBits(SHA256.hash(data: Data(message.utf8)), 10))
    }
}

final class SignedUpdateFeedTests: XCTestCase {
    // Made by scripts/feed-signing.swift with a throwaway key, so this also proves the script and the app agree.
    let key = "Qru8cNftXV1fCpA41MpoV0qPbk/+bYlEjjqAz3zXHsk="
    let signature = "ml4SEUsd1KMiweQ5LTk0/RXdXn41KrOcwyzSPSRcJoybv9VdYajHk96olLU0bd1g/XrEUwUN4T+KI/uBJUnVBg=="
    let digest = "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"
    let url = URL(string: "https://vasquezgroup.ch/downloads/Artifloam-9.9.9.zip")!

    func testAcceptsOnlyWhatOurKeySigned() {
        XCTAssertTrue(UpdateFeed.verified(version: "9.9.9", url: url, sha256: digest, signature: signature, publicKey: key))
        // Changing anything the signature covers must fail, which is what taking over the website would need.
        XCTAssertFalse(UpdateFeed.verified(version: "9.9.10", url: url, sha256: digest, signature: signature, publicKey: key))
        XCTAssertFalse(UpdateFeed.verified(version: "9.9.9", url: URL(string: "https://vasquezgroup.ch/downloads/Evil.zip")!, sha256: digest, signature: signature, publicKey: key))
        XCTAssertFalse(UpdateFeed.verified(version: "9.9.9", url: url, sha256: String(repeating: "0", count: 64), signature: signature, publicKey: key))
        XCTAssertFalse(UpdateFeed.verified(version: "9.9.9", url: url, sha256: digest, signature: "", publicKey: key))
        XCTAssertFalse(UpdateFeed.verified(version: "9.9.9", url: url, sha256: digest, signature: "not base64!", publicKey: key))
    }

    func testKeyFromAnotherSignerIsRejected() {
        XCTAssertFalse(UpdateFeed.verified(version: "9.9.9", url: url, sha256: digest, signature: signature))
    }

    func testAValidSignatureStillNeedsATrustedLink() throws {
        let attacker = Curve25519.Signing.PrivateKey()
        let evil = URL(string: "https://evil.example/downloads/a.zip")!
        let signed = try attacker.signature(for: UpdateFeed.signedMessage(version: "9.9.9", url: evil, sha256: digest)).base64EncodedString()
        XCTAssertFalse(UpdateFeed.verified(version: "9.9.9", url: evil, sha256: digest, signature: signed, publicKey: attacker.publicKey.rawRepresentation.base64EncodedString()))
    }

    func testFileHash() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(try UpdateFeed.sha256(ofFile: file), digest)
    }
}
