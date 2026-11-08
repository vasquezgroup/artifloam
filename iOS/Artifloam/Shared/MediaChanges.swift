import AVFoundation
import Photos

/// Makes the smaller copy first. The original is only removed afterwards, with iOS's confirmation, so a failure can't lose anything.
public enum MediaChanges {
    public struct Failure: LocalizedError {
        public let errorDescription: String?
    }

    /// Below this, a re-encode isn't worth losing the original for.
    public static let minimumSaving = 0.1

    public static func isWorthKeeping(original: Int64, compressed: Int64) -> Bool {
        compressed > 0 && Double(compressed) <= Double(original) * (1 - minimumSaving)
    }

    /// The original may have to download from iCloud first, and the copy needs room too. Twice the size covers both.
    public static func hasRoom(for bytes: Int64, free: Int64) -> Bool { free >= bytes * 2 }

    private static func checkRoom(for item: PhotoItem) throws {
        let free = (try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        guard hasRoom(for: item.bytes, free: free) else {
            throw Failure(errorDescription: String(localized: "There isn't enough free space to do this safely. It needs about twice the item's size."))
        }
    }

    /// What a compression is busy with, for showing it.
    public enum Step: Sendable { case downloading, compressing }

    /// The original video, from iCloud if need be. `download` hears how far it has come down, from 0 to 1.
    /// Cancelling the task stops the download. Can run ahead of `compress`, so the next video downloads while one compresses.
    public static func original(_ asset: PHAsset, download: (@MainActor (Double) -> Void)? = nil) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.version = .original
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        if let download { options.progressHandler = { value, _, _, _ in Task { @MainActor in download(value) } } }
        let request = RequestID()
        let video: AVAsset? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.set(PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { result, _, _ in continuation.resume(returning: result) })
            }
        } onCancel: { request.cancel() }
        try Task.checkCancellation()
        guard let video else { throw Failure(errorDescription: String(localized: "This video can't be compressed.")) }
        return video
    }

    /// Returns the new copy's size, or nil if the saving was too small and nothing was added.
    /// `original` is the video already fetched, if it was. `progress` hears what it's doing and how far that is, from 0 to 1, a few times a second.
    /// Cancelling the task stops it and throws `CancellationError`, with nothing added.
    public static func compress(_ item: PhotoItem, original: AVAsset? = nil, progress: (@MainActor (Step, Double) -> Void)? = nil) async throws -> Int64? {
        try checkRoom(for: item)
        let video: AVAsset
        if let original { video = original } else { video = try await Self.original(item.asset, download: progress.map { report in { @MainActor in report(.downloading, $0) } }) }
        guard let session = AVAssetExportSession(asset: video, presetName: AVAssetExportPresetHEVC1920x1080) else {
            throw Failure(errorDescription: String(localized: "This video can't be compressed."))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        let watch = Task { @MainActor in
            while !Task.isCancelled, let progress {
                progress(.compressing, Double(session.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        await withTaskCancellationHandler { await session.export() } onCancel: { session.cancelExport() }
        watch.cancel()
        try Task.checkCancellation()
        guard session.status == .completed else {
            throw session.error ?? Failure(errorDescription: String(localized: "Compression stopped."))
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        guard isWorthKeeping(original: item.bytes, compressed: bytes) else { return nil }
        let before = try await video.load(.duration).seconds
        let after = try await AVURLAsset(url: url).load(.duration).seconds
        guard abs(before - after) < 1 else { throw Failure(errorDescription: String(localized: "The compressed copy didn't match the original.")) }
        let source = item.asset
        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) else { return }
            request.creationDate = source.creationDate
            request.location = source.location
            request.isFavorite = source.isFavorite
        }
        return bytes
    }

    /// The photo inside a Live Photo, as a file, from iCloud if need be. Several can download at once.
    /// The caller removes the file once `addStills` has used it.
    public static func stillFile(_ item: PhotoItem) async throws -> URL {
        try checkRoom(for: item)
        let resources = PHAssetResource.assetResources(for: item.asset)
        guard let photo = resources.first(where: { $0.type == .fullSizePhoto }) ?? resources.first(where: { $0.type == .photo }) else {
            throw Failure(errorDescription: String(localized: "This Live Photo can't be converted."))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + photo.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: photo, toFile: url, options: options)
        return url
    }

    /// Adds still copies of Live Photos, with their dates and places, in one change to the library.
    /// One change for many is much faster than one each.
    public static func addStills(_ stills: [(item: PhotoItem, file: URL)]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for (item, file) in stills {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: file, options: nil)
                request.creationDate = item.asset.creationDate
                request.location = item.asset.location
                request.isFavorite = item.asset.isFavorite
            }
        }
    }

    /// Adds a still copy of a Live Photo, with its date and place.
    public static func makeStill(_ item: PhotoItem) async throws {
        let file = try await stillFile(item)
        defer { try? FileManager.default.removeItem(at: file) }
        try await addStills([(item, file)])
    }
}

/// A Photos request that a cancelled task can stop, even from another thread.
private final class RequestID: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHImageRequestID?
    private var cancelled = false
    func set(_ new: PHImageRequestID) {
        lock.lock(); id = new; let stop = cancelled; lock.unlock()
        if stop { PHImageManager.default().cancelImageRequest(new) }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = id; lock.unlock()
        if let current { PHImageManager.default().cancelImageRequest(current) }
    }
}
