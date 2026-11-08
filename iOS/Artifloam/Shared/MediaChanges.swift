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

    public static func exportSession(for asset: PHAsset) async throws -> (AVAssetExportSession, AVAsset) {
        let options = PHVideoRequestOptions()
        options.version = .original
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        let video: AVAsset? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { result, _, _ in continuation.resume(returning: result) }
        }
        guard let video, let session = AVAssetExportSession(asset: video, presetName: AVAssetExportPresetHEVC1920x1080) else {
            throw Failure(errorDescription: String(localized: "This video can't be compressed."))
        }
        return (session, video)
    }

    /// Returns the new copy's size, or nil if the saving was too small and nothing was added.
    /// `progress` hears how far the export is, from 0 to 1, a few times a second.
    public static func compress(_ item: PhotoItem, progress: (@MainActor (Double) -> Void)? = nil) async throws -> Int64? {
        try checkRoom(for: item)
        let (session, original) = try await exportSession(for: item.asset)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        let watch = Task { @MainActor in
            while !Task.isCancelled, let progress {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        await session.export()
        watch.cancel()
        guard session.status == .completed else {
            throw session.error ?? Failure(errorDescription: String(localized: "Compression stopped."))
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        guard isWorthKeeping(original: item.bytes, compressed: bytes) else { return nil }
        let before = try await original.load(.duration).seconds
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

    /// Adds a still copy of a Live Photo, with its date and place.
    public static func makeStill(_ item: PhotoItem) async throws {
        try checkRoom(for: item)
        let resources = PHAssetResource.assetResources(for: item.asset)
        guard let photo = resources.first(where: { $0.type == .fullSizePhoto }) ?? resources.first(where: { $0.type == .photo }) else {
            throw Failure(errorDescription: String(localized: "This Live Photo can't be converted."))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + photo.originalFilename)
        defer { try? FileManager.default.removeItem(at: url) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: photo, toFile: url, options: options)
        let source = item.asset
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
            request.creationDate = source.creationDate
            request.location = source.location
            request.isFavorite = source.isFavorite
        }
    }
}
