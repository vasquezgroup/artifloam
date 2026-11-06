import Photos
import SwiftUI

struct PhotoItem: Identifiable {
    let asset: PHAsset
    let bytes: Int64
    /// What removing it would free. Live Photos only give back their video part.
    var saving: Int64 { saves ?? bytes }
    var saves: Int64? = nil
    var id: String { asset.localIdentifier }
}

/// Items to review. `keep`, when present, is the copy that stays and isn't offered for deletion.
struct CleanupGroup: Identifiable {
    var keep: PhotoItem? = nil
    var items: [PhotoItem]
    var id: String { keep?.id ?? items.first?.id ?? "" }
}

enum PhotoCategory: CaseIterable, Identifiable {
    case duplicates, similar, blurred, screenshots, largeVideos, oldVideos, screenRecordings, livePhotos
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .duplicates: "Duplicates"
        case .similar: "Similar photos"
        case .blurred: "Blurred photos"
        case .screenshots: "Screenshots"
        case .largeVideos: "Large videos"
        case .oldVideos: "Old large videos"
        case .screenRecordings: "Screen recordings"
        case .livePhotos: "Live Photos"
        }
    }
    var icon: String {
        switch self {
        case .duplicates: "category-stack"
        case .similar: "category-sparkles"
        case .blurred: "category-cache"
        case .screenshots: "category-document"
        case .largeVideos: "category-drive"
        case .oldVideos: "category-hammer"
        case .screenRecordings: "category-globe"
        case .livePhotos: "category-branch"
        }
    }
    var note: LocalizedStringKey {
        switch self {
        case .duplicates: "Copies with the same name, dimensions and size. The oldest copy stays."
        case .similar: "Shots taken moments apart that look alike. The sharpest one stays."
        case .blurred: "Photos that look out of focus. Calm scenes like a clear sky can appear here, so check them."
        case .livePhotos: "Turning a Live Photo into a still removes its short video."
        default: "Largest first."
        }
    }
}

@MainActor @Observable
final class Library {
    enum Phase { case idle, reading, analysing, done }
    var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var phase = Phase.idle
    var checked = 0
    var total = 0
    var results: [PhotoCategory: [CleanupGroup]] = [:]
    var photoBytes: Int64 = 0
    var videoBytes: Int64 = 0
    var notice: LocalizedStringKey?
    var failure: String?

    var protected: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "protected") ?? [])

    var working: Bool { phase == .reading || phase == .analysing }
    func items(_ category: PhotoCategory) -> [PhotoItem] { (results[category] ?? []).flatMap(\.items) }
    func saving(_ category: PhotoCategory) -> Int64 { items(category).reduce(0) { $0 + $1.saving } }

    /// Safe, one-tap set: exact copies, and screenshots over 90 days old.
    var recommended: [PhotoItem] {
        let cutoff = Date(timeIntervalSinceNow: -90 * 86_400)
        let old = items(.screenshots).filter { ($0.asset.creationDate ?? .now) < cutoff }
        return unique(items(.duplicates) + old)
    }
    var everything: Int64 { unique(PhotoCategory.allCases.filter { $0 != .livePhotos }.flatMap(items)).reduce(0) { $0 + $1.bytes } }
    private func unique(_ items: [PhotoItem]) -> [PhotoItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    func start() async {
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        if phase == .idle { await scan() }
    }

    func scan() async {
        guard status == .authorized || status == .limited, !working else { return }
        phase = .reading
        checked = 0
        let hidden = protected
        let first = await Task.detached(priority: .userInitiated) { LibraryScan.read(excluding: hidden) { n, t in Task { @MainActor in self.checked = n; self.total = t } } }.value
        results = first.results
        photoBytes = first.photoBytes
        videoBytes = first.videoBytes
        phase = .analysing
        total = first.photos.count
        checked = 0
        let found = await Task.detached(priority: .utility) { LibraryScan.analyse(first.photos) { n in Task { @MainActor in self.checked = n } } }.value
        results[.similar] = found.similar
        results[.blurred] = found.blurred.isEmpty ? [] : [CleanupGroup(items: found.blurred)]
        phase = .done
    }

    /// iOS asks for confirmation. Cancelling there leaves everything in place.
    @discardableResult
    func delete(_ ids: Set<String>) async -> Bool {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            notice = "Moved to Recently Deleted. The space comes back when iOS empties it after about 30 days, or when you empty it in Photos."
            await scan()
            return true
        } catch {
            if (error as NSError).code != PHPhotosError.userCancelled.rawValue { failure = error.localizedDescription }
            return false
        }
    }

    func protect(_ item: PhotoItem) {
        protected.insert(item.id)
        UserDefaults.standard.set(Array(protected), forKey: "protected")
        for (key, groups) in results {
            results[key] = groups.map { CleanupGroup(keep: $0.keep, items: $0.items.filter { $0.id != item.id }) }.filter { !$0.items.isEmpty }
        }
    }

    func clearProtected() {
        protected = []
        UserDefaults.standard.removeObject(forKey: "protected")
        Task { await scan() }
    }
}

enum LibraryScan {
    struct First { var results: [PhotoCategory: [CleanupGroup]]; var photoBytes: Int64; var videoBytes: Int64; var photos: [PhotoItem] }
    private struct Identity: Hashable { let width, height: Int; let bytes: Int64; let name: String }
    /// ponytail: newest photos only keeps a scan to a couple of minutes. Raise it, or analyse in the background, if people ask.
    private static let analysisLimit = 5000

    /// ponytail: "fileSize" is undocumented, and the only way to get sizes without reading every file. Replace if App Review objects.
    static func size(of resource: PHAssetResource) -> Int64 { (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0 }

    nonisolated static func read(excluding protected: Set<String>, progress: @escaping @Sendable (Int, Int) -> Void) -> First {
        var out: [PhotoCategory: [PhotoItem]] = [:]
        var copies: [(item: PhotoItem, identity: Identity)] = []
        var photos: [PhotoItem] = []
        var photoBytes: Int64 = 0, videoBytes: Int64 = 0
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let all = PHAsset.fetchAssets(with: options)
        let oldCutoff = Date(timeIntervalSinceNow: -2 * 365 * 86_400)
        all.enumerateObjects { asset, index, _ in
            if index % 200 == 0 { progress(index, all.count) }
            let resources = PHAssetResource.assetResources(for: asset)
            let bytes = resources.reduce(Int64(0)) { $0 + size(of: $1) }
            if asset.mediaType == .video { videoBytes += bytes } else { photoBytes += bytes }
            // Favourites and protected items are counted but never suggested.
            guard !asset.isFavorite, !protected.contains(asset.localIdentifier) else { return }
            let item = PhotoItem(asset: asset, bytes: bytes)
            if asset.mediaType == .video {
                if bytes >= 100_000_000 {
                    out[.largeVideos, default: []].append(item)
                    if (asset.creationDate ?? .now) < oldCutoff { out[.oldVideos, default: []].append(item) }
                }
                if asset.mediaSubtypes.contains(.videoScreenRecording) { out[.screenRecordings, default: []].append(item) }
            } else if asset.mediaSubtypes.contains(.photoScreenshot) {
                out[.screenshots, default: []].append(item)
            } else if photos.count < analysisLimit {
                photos.append(item)
            }
            if asset.mediaSubtypes.contains(.photoLive) {
                let video = resources.filter { $0.type == .pairedVideo }.reduce(Int64(0)) { $0 + size(of: $1) }
                if video > 0 { out[.livePhotos, default: []].append(PhotoItem(asset: asset, bytes: bytes, saves: video)) }
            }
            if bytes > 0, let name = resources.first?.originalFilename {
                copies.append((item, Identity(width: asset.pixelWidth, height: asset.pixelHeight, bytes: bytes, name: name)))
            }
        }
        var results = out.mapValues { [CleanupGroup(items: $0.sorted { $0.saving > $1.saving })] }
        results[.duplicates] = Dictionary(grouping: copies, by: \.identity).values.compactMap { group -> CleanupGroup? in
            let sorted = group.map(\.item).sorted { ($0.asset.creationDate ?? .distantPast) < ($1.asset.creationDate ?? .distantPast) }
            guard sorted.count > 1 else { return nil }
            return CleanupGroup(keep: sorted[0], items: Array(sorted.dropFirst()))
        }.sorted { $0.items.count > $1.items.count }
        return First(results: results, photoBytes: photoBytes, videoBytes: videoBytes, photos: photos)
    }

    nonisolated static func analyse(_ photos: [PhotoItem], progress: @escaping @Sendable (Int) -> Void) -> (similar: [CleanupGroup], blurred: [PhotoItem]) {
        var sharpness: [String: Double] = [:]
        var blurred: [PhotoItem] = []
        var hashes: [String: UInt64] = [:]
        let dated = photos.compactMap { p in p.asset.creationDate.map { (p, $0) } }
        let clusters = timeClusters(dated.map(\.1), gap: 30)
        let clustered = Set(clusters.joined())
        for (index, item) in photos.enumerated() {
            autoreleasepool {
                if index % 20 == 0 { progress(index) }
                guard let image = thumbnail(item.asset) else { return }
                let score = sharpnessOf(image)
                sharpness[item.id] = score
                if score < blurThreshold { blurred.append(item) }
                if let at = dated.firstIndex(where: { $0.0.id == item.id }), clustered.contains(at) { hashes[item.id] = differenceHash(of: image) }
            }
        }
        var similar: [CleanupGroup] = []
        for cluster in clusters {
            let members = cluster.map { dated[$0].0 }
            var left = members
            while let seed = left.first {
                guard let seedHash = hashes[seed.id] else { left.removeFirst(); continue }
                var group = [seed]
                for other in left.dropFirst() {
                    if let hash = hashes[other.id], (seedHash ^ hash).nonzeroBitCount <= similarBits { group.append(other) }
                }
                let ids = Set(group.map(\.id))
                left.removeAll { ids.contains($0.id) }
                if group.count > 1 {
                    let ordered = group.sorted { (sharpness[$0.id] ?? 0) > (sharpness[$1.id] ?? 0) }
                    similar.append(CleanupGroup(keep: ordered[0], items: Array(ordered.dropFirst())))
                }
            }
        }
        return (similar.sorted { $0.items.count > $1.items.count }, blurred.sorted { $0.bytes > $1.bytes })
    }

    // ponytail: starting values, not tuned on real libraries. Calibrate both on a real iPhone.
    // Blur: a blurred test image scored 8, Simulator sample photos 680 to 3200.
    static let blurThreshold = 12.0
    /// Of 64 bits. Only photos taken within 30 seconds are compared, so this can stay simple.
    /// Vision's feature prints returned all zeros in the Simulator, which would call every photo similar, so they aren't used.
    static let similarBits = 8

    /// Thumbnails iOS already has. Never downloads from iCloud during a scan.
    nonisolated static func thumbnail(_ asset: PHAsset, side: CGFloat = 256) -> CGImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        var result: CGImage?
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: options) { image, _ in result = image?.cgImage }
        return result
    }

    nonisolated static func sharpnessOf(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        var gray = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return .infinity }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return laplacianVariance(gray, width: width, height: height)
    }
}

/// A 64-bit fingerprint: whether each pixel is brighter than the next, on a 9 by 8 version of the image.
func differenceHash(of image: CGImage) -> UInt64 {
    var gray = [UInt8](repeating: 0, count: 72)
    guard let context = CGContext(data: &gray, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
    var hash: UInt64 = 0
    for y in 0..<8 {
        for x in 0..<8 {
            hash = hash << 1 | (gray[y * 9 + x] > gray[y * 9 + x + 1] ? 1 : 0)
        }
    }
    return hash
}

/// How much fine detail an image has. Low means soft or flat.
func laplacianVariance(_ gray: [UInt8], width: Int, height: Int) -> Double {
    guard width > 2, height > 2 else { return 0 }
    var sum = 0.0, squares = 0.0, count = 0.0
    for y in 1..<(height - 1) {
        for x in 1..<(width - 1) {
            let i = y * width + x
            let value = Double(gray[i - 1]) + Double(gray[i + 1]) + Double(gray[i - width]) + Double(gray[i + width]) - 4 * Double(gray[i])
            sum += value
            squares += value * value
            count += 1
        }
    }
    return squares / count - (sum / count) * (sum / count)
}

/// Runs of neighbouring indexes whose dates are within `gap` seconds. Input must be sorted.
func timeClusters(_ dates: [Date], gap: TimeInterval) -> [[Int]] {
    var clusters: [[Int]] = []
    var current: [Int] = []
    for index in dates.indices {
        if let last = current.last, abs(dates[last].timeIntervalSince(dates[index])) > gap {
            if current.count > 1 { clusters.append(current) }
            current = []
        }
        current.append(index)
    }
    if current.count > 1 { clusters.append(current) }
    return clusters
}
