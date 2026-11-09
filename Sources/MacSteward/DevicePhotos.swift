import Foundation
import ImageCaptureCore
import Observation
import UniformTypeIdentifiers

/// A photo or video stored on a connected iPhone or iPad, as Image Capture lists it.
struct DeviceMedia: Identifiable {
    let id: ObjectIdentifier
    let file: ICCameraFile
    let name: String
    let video: Bool
    let bytes: Int64
    let date: Date
    /// Seconds, for videos.
    let duration: Double
    init(_ file: ICCameraFile) {
        self.file = file
        id = ObjectIdentifier(file)
        name = file.name ?? ""
        video = file.uti.flatMap { UTType($0) }?.conforms(to: .movie) ?? false
        bytes = Int64(file.fileSize)
        date = file.creationDate ?? file.modificationDate ?? .distantPast
        duration = file.duration
    }
}

/// The photos and videos on an iPhone or iPad connected by cable, through Image Capture, the way Apple's Image Capture app reads them.
/// Read-only unless the device itself allows deleting. iOS shares only what is stored on the device: with iCloud Photos
/// and Optimize Storage, most of the library stays in iCloud and isn't listed.
@MainActor @Observable final class DevicePhotos: NSObject {
    static let shared = DevicePhotos()
    private(set) var device: ICCameraDevice?
    /// Waiting for the person to unlock the device and tap Trust.
    private(set) var locked = false
    /// The device has listed everything it shares.
    private(set) var ready = false
    private(set) var items = [DeviceMedia]()
    var failure: String?
    @ObservationIgnored private let browser = ICDeviceBrowser()
    @ObservationIgnored private var watching = false

    var name: String { device?.name ?? DeviceWord.text }
    /// The device lets the Mac delete what it lists. Most say no while iCloud Photos is on.
    var canDelete: Bool { device?.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue) ?? false }

    /// Looks for a connected iPhone or iPad while Photos is open.
    func watch() {
        guard !watching else { return }
        watching = true
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }
    func stopWatching() {
        guard watching else { return }
        watching = false
        browser.stop()
        device?.requestCloseSession()
        reset()
    }
    private func reset() { device = nil; locked = false; ready = false; items = [] }

    /// A small picture for the grid. The device makes it, so nothing large is copied.
    nonisolated static func thumbnail(_ file: ICCameraFile) async -> Data? {
        await withCheckedContinuation { continuation in
            file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: 320]) { data, _ in continuation.resume(returning: data) }
        }
    }

    /// Copies one item into `folder`, with a new name if the file is already there. Returns where it went.
    /// The copy is compared with the size the device reported, so a broken transfer doesn't count as done.
    nonisolated static func copy(_ media: DeviceMedia, to folder: URL) async throws -> URL {
        let name = available(media.name, in: folder)
        let path: String = try await withCheckedThrowingContinuation { continuation in
            let progress = media.file.requestDownload(options: [.downloadsDirectoryURL: folder, .saveAsFilename: name, .overwrite: false, .sidecarFiles: true]) { file, error in
                if let file { continuation.resume(returning: file) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
            if progress == nil { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
        }
        let url = folder.appendingPathComponent((path as NSString).lastPathComponent)
        let copied = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        guard copied == media.bytes else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
    /// "IMG_0001.HEIC", or "IMG_0001 2.HEIC" when that's taken, like Finder.
    nonisolated static func available(_ name: String, in folder: URL) -> String {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name, number = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"; number += 1
        }
        return candidate
    }

    /// Only when the device allows it; iOS then removes them from the device's library itself.
    func delete(_ chosen: [DeviceMedia]) async -> Bool {
        guard let device, canDelete, !chosen.isEmpty else { return false }
        let failed: Bool = await withCheckedContinuation { continuation in
            var refused = false
            let progress = device.requestDeleteFiles(chosen.map(\.file), deleteFailed: { refusals in refused = !refusals.isEmpty }) { _, error in
                continuation.resume(returning: refused || error != nil)
            }
            if progress == nil { continuation.resume(returning: true) }
        }
        if failed { failure = String(localized: "\(name) didn't delete everything. Check it, then try again.") }
        refresh()
        return !failed
    }

    private func refresh() {
        items = (device?.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }.map(DeviceMedia.init)
    }
}

extension DevicePhotos: ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        MainActor.assumeIsolated {
            // Only iPhones and iPads. A camera or card reader is something else.
            guard self.device == nil, let camera = device as? ICCameraDevice, ["iPhone", "iPad"].contains(where: { (camera.productKind ?? "").contains($0) }) else { return }
            self.device = camera
            camera.delegate = self
            camera.requestOpenSession()
        }
    }
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        MainActor.assumeIsolated { if device === self.device { self.reset() } }
    }
    nonisolated func didRemove(_ device: ICDevice) {
        MainActor.assumeIsolated { if device === self.device { self.reset() } }
    }
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        MainActor.assumeIsolated { self.locked = (device as? ICCameraDevice)?.isAccessRestrictedAppleDevice ?? false }
    }
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { MainActor.assumeIsolated { self.locked = true } }
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) { MainActor.assumeIsolated { self.locked = false } }
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        MainActor.assumeIsolated { self.ready = true; self.locked = false; self.refresh() }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) { MainActor.assumeIsolated { if self.ready { self.refresh() } } }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { MainActor.assumeIsolated { if self.ready { self.refresh() } } }
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    nonisolated func deviceDidBecomeReady(_ device: ICDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
}
