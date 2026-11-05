import XCTest
@testable import MacStewardCore

final class AppInstallTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func app(_ name: String, signed: Bool) throws -> URL {
        let bundle = root.appendingPathComponent(name), binary = bundle.appendingPathComponent("Contents/MacOS/x")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "x", "CFBundleIdentifier": "test.x", "CFBundlePackageType": "APPL"], format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        if signed { XCTAssertEqual(MacStewardCore.run("/usr/bin/codesign", ["--sign", "-", bundle.path]).code, 0) }
        return bundle
    }
    func testOffersOnlyWhenNotInstalledAndNothingWouldBeReplaced() throws {
        let free = root.appendingPathComponent("free.app"), taken = try app("taken.app", signed: false)
        XCTAssertTrue(AppInstall.shouldOffer(URL(fileURLWithPath: "/Users/x/Downloads/Artifloam.app"), home: root, destination: free))
        XCTAssertTrue(AppInstall.shouldOffer(URL(fileURLWithPath: "/private/var/folders/a/AppTranslocation/b/d/Artifloam.app"), home: root, destination: free))
        XCTAssertFalse(AppInstall.shouldOffer(URL(fileURLWithPath: "/Users/x/Downloads/Artifloam.app"), home: root, destination: taken), "never over an existing copy")
        XCTAssertFalse(AppInstall.shouldOffer(URL(fileURLWithPath: "/Applications/Artifloam.app"), home: root, destination: free))
        XCTAssertFalse(AppInstall.shouldOffer(root.appendingPathComponent("Applications/Artifloam.app"), home: root, destination: free))
        XCTAssertFalse(AppInstall.shouldOffer(URL(fileURLWithPath: "/Users/x/.build/debug"), home: root, destination: free), "a bare executable isn't an app")
    }
    func testCopiesASignedAppAndRefusesAnUnsignedOne() throws {
        let signed = try app("signed.app", signed: true), target = root.appendingPathComponent("target.app")
        try AppInstall.copy(signed, to: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/Info.plist").path))
        let unsigned = try app("unsigned.app", signed: false), other = root.appendingPathComponent("other.app")
        XCTAssertThrowsError(try AppInstall.copy(unsigned, to: other))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }
}
