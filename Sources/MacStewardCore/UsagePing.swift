import CryptoKit
import Foundation

/// Opt-in monthly count of active installs. There is no identifier: the Mac remembers which month it
/// last counted itself in, and the server only adds one. Every field sent is in `Payload`.
public enum UsagePing {
    public static let enabledKey = "sendUsagePing"
    public static let lastPeriodKey = "usagePingLastPeriod"
    /// Shared by our apps; the contract is under "Usage counts" in the vasquezgroup.ch README.
    public static let endpoint = URL(string: "https://vasquezgroup.ch/usage/ping.php")!
    /// About a second of work per ping, so faking counts in bulk costs real computing time. Must match the server.
    public static let proofBits = 22

    public struct Payload: Encodable, Equatable, Sendable {
        public let app: String, period: String, version: String, os: String, arch: String
        public private(set) var nonce = ""

        public init(version: String, date: Date = Date(), osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
            app = "artifloam"
            period = UsagePing.period(for: date)
            self.version = version
            os = "macos-\(osMajor)"
            #if arch(arm64)
            arch = "arm64"
            #else
            arch = "x86_64"
            #endif
        }

        public var summary: String { "\(app), \(period), \(version), \(os), \(arch)" }

        /// Finds a nonce whose hash starts with `bits` zero bits. It starts at random, so it identifies nothing.
        public mutating func solve(bits: Int = UsagePing.proofBits) {
            var prefix = SHA256()
            prefix.update(data: Data("\(app)|\(period)|\(version)|\(os)|\(arch)|".utf8))
            var counter = UInt64.random(in: .min ... .max)
            while true {
                let hex = String(counter, radix: 16)
                var hash = prefix
                hash.update(data: Data(hex.utf8))
                if UsagePing.hasLeadingZeroBits(hash.finalize(), bits) { nonce = hex; return }
                counter &+= 1
            }
        }
    }

    public static func hasLeadingZeroBits(_ digest: SHA256.Digest, _ bits: Int) -> Bool {
        digest.withUnsafeBytes { bytes in
            var remaining = bits, index = 0
            while remaining > 0 {
                let mask: UInt8 = remaining >= 8 ? 0xFF : 0xFF << UInt8(8 - remaining)
                if bytes[index] & mask != 0 { return false }
                remaining -= 8; index += 1
            }
            return true
        }
    }

    /// UTC, so the month boundary says nothing about the Mac's time zone.
    public static func period(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    public static func isDue(enabled: Bool, lastSent: String?, period: String) -> Bool { enabled && lastSent != period }
}
