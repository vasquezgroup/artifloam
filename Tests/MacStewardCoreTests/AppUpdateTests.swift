import XCTest
import Security
@testable import MacStewardCore

final class AppUpdateTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func app(_ path: String, version: String, id: String = "test.update", body: String = "new") throws -> URL {
        let bundle = root.appendingPathComponent(path), binary = bundle.appendingPathComponent("Contents/MacOS/x")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n# \(body)\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "x", "CFBundleIdentifier": id, "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version], format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(MacStewardCore.run("/usr/bin/codesign", ["--sign", "-", "--identifier", id, bundle.path]).code, 0)
        return bundle
    }
    private func zip(_ app: URL) throws -> URL {
        let out = root.appendingPathComponent(UUID().uuidString + ".zip")
        XCTAssertEqual(MacStewardCore.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, out.path]).code, 0)
        return out
    }
    private var requirement: SecRequirement {
        var value: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(#"identifier "test.update""# as CFString, [], &value), errSecSuccess)
        return value!
    }
    private func version(_ app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }
    func testGoodUpdateReplacesTheApp() throws {
        let current = try app("Applications/Artifloam.app", version: "1.0", body: "old")
        let archive = try zip(app("build/Artifloam.app", version: "2.0"))
        try AppUpdate.install(archive: archive, version: "2.0", over: current, requirement: requirement, notarized: { _ in true })
        XCTAssertEqual(try version(current), "2.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: current.deletingLastPathComponent().path), ["Artifloam.app"], "no leftovers beside the app")
    }
    func testEveryFailedCheckLeavesTheAppUntouched() throws {
        let current = try app("Applications/Artifloam.app", version: "1.0", body: "old")
        func refuses(_ archive: URL, version: String = "2.0", notarized: Bool = true, _ why: String) {
            XCTAssertThrowsError(try AppUpdate.install(archive: archive, version: version, over: current, requirement: requirement, notarized: { _ in notarized }), why)
            XCTAssertEqual(try self.version(current), "1.0", why)
        }
        let good = try zip(app("good/Artifloam.app", version: "2.0"))
        refuses(good, version: "3.0", "not the version the feed promised")
        refuses(good, notarized: false, "Apple's check rejected it")
        refuses(try zip(app("other/Artifloam.app", version: "2.0", id: "someone.else")), "signed by someone else")
        let tampered = try app("bad/Artifloam.app", version: "2.0")
        try Data("#!/bin/sh\n# changed after signing\n".utf8).write(to: tampered.appendingPathComponent("Contents/MacOS/x"))
        refuses(try zip(tampered), "changed after signing")
        let unsigned = root.appendingPathComponent("notzip.zip"); try Data("not an archive".utf8).write(to: unsigned)
        refuses(unsigned, "not an archive")
        let twoApps = root.appendingPathComponent("two"); try FileManager.default.createDirectory(at: twoApps, withIntermediateDirectories: true)
        for name in ["A.app", "B.app"] { try FileManager.default.copyItem(at: root.appendingPathComponent("good/Artifloam.app"), to: twoApps.appendingPathComponent(name)) }
        let twoZip = root.appendingPathComponent("two.zip")
        XCTAssertEqual(MacStewardCore.run("/usr/bin/ditto", ["-c", "-k", twoApps.path, twoZip.path]).code, 0)
        refuses(twoZip, "more than one app")
    }
}
