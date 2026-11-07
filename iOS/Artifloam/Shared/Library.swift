import Photos
import SwiftUI

public struct PhotoItem: Identifiable {
    public let asset: PHAsset
    public let bytes: Int64
    /// What removing it would free. Live Photos only give back their video part.
    public var saving: Int64 { saves ?? bytes }
    public var saves: Int64?
    /// Kept, because asking Photos for it each time is what made long lists slow.
    public let id: String

    public init(asset: PHAsset, bytes: Int64, saves: Int64? = nil) {
        self.asset = asset
        self.bytes = bytes
        self.saves = saves
        id = asset.localIdentifier
    }
}

/// Items to review. `keep`, when present, is the copy that stays and isn't offered for deletion.
public struct CleanupGroup: Identifiable {
    public var keep: PhotoItem? = nil
    public var items: [PhotoItem]
    public var id: String { keep?.id ?? items.first?.id ?? "" }
}

public enum PhotoCategory: CaseIterable, Identifiable {
    case duplicates, similar, blurred, screenshots, largeVideos, oldVideos, screenRecordings, livePhotos
    public var id: Self { self }
    public var title: LocalizedStringKey {
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
    public var icon: String {
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
    public var note: LocalizedStringKey {
        switch self {
        case .duplicates: "Copies with the same name, dimensions and size. The oldest copy stays."
        case .similar: "Shots taken moments apart that look alike. The sharpest one stays."
        case .blurred: "Photos that look out of focus. Calm scenes like a clear sky can appear here, so check them."
        case .livePhotos: "Turning a Live Photo into a still removes its short video."
        case .largeVideos, .oldVideos: "Largest first. Videos in iCloud may free less on this device."
        default: "Largest first."
        }
    }
}

/// What's in the library. Counts come from Photos' own index and are instant. Sizes only come from what an earlier scan remembered.
public struct LibraryCounts: Equatable {
    public var photos = 0, videos = 0, screenshots = 0, livePhotos = 0
    public var photoBytes: Int64?, videoBytes: Int64?, screenshotBytes: Int64?, livePhotoBytes: Int64?

    /// Up to this many new items are measured on the spot. At about 3 ms each, it stays unnoticeable.
    public static let newItemsToMeasure = 200

    public nonisolated static func read() -> LibraryCounts {
        func count(_ subtype: PHAssetMediaSubtype) -> Int {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", subtype.rawValue)
            return PHAsset.fetchAssets(with: .image, options: options).count
        }
        let screenshots = count(.photoScreenshot)
        return LibraryCounts(photos: PHAsset.fetchAssets(with: .image, options: nil).count - screenshots, videos: PHAsset.fetchAssets(with: .video, options: nil).count, screenshots: screenshots, livePhotos: count(.photoLive))
    }

    public mutating func add(_ facts: ScanFacts, video: Bool, screenshot: Bool) {
        if video { videoBytes = (videoBytes ?? 0) + facts.bytes }
        else if screenshot { screenshotBytes = (screenshotBytes ?? 0) + facts.bytes }
        else { photoBytes = (photoBytes ?? 0) + facts.bytes }
        // What removing them frees is the video part, which is also why this doesn't double count with photos above.
        if facts.pairedVideo > 0 { livePhotoBytes = (livePhotoBytes ?? 0) + facts.pairedVideo }
    }

    /// Adds sizes if an earlier scan knows nearly everything. Otherwise leaves them empty rather than understating them.
    public nonisolated func withSizes(from cache: ScanCache) -> LibraryCounts {
        guard !cache.isEmpty else { return self }
        var result = self
        var unknown = 0
        let all = PHAsset.fetchAssets(with: nil)
        all.enumerateObjects { asset, _, stop in
            autoreleasepool {
                var facts = cache.facts(for: asset)
                if facts == nil {
                    unknown += 1
                    if unknown > Self.newItemsToMeasure { stop.pointee = true; return }
                    facts = LibraryScan.facts(of: asset)
                    cache.store(facts!, for: asset)
                }
                result.add(facts!, video: asset.mediaType == .video, screenshot: asset.mediaSubtypes.contains(.photoScreenshot))
            }
        }
        cache.save()
        return unknown > Self.newItemsToMeasure ? self : result
    }
}

@MainActor @Observable
public final class Library {
    public enum Phase { case idle, reading, analysing, done, stopped }
    public var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    public var phase = Phase.idle
    public var checked = 0
    public var total = 0
    public var results: [PhotoCategory: [CleanupGroup]] = [:] { didSet { resultsVersion += 1 } }
    /// Tells a screen the lists changed, without it having to compare them.
    public private(set) var resultsVersion = 0
    public var photoBytes: Int64 = 0
    public var videoBytes: Int64 = 0
    /// What's really on this iPhone rather than only in iCloud. Nil if iOS doesn't say.
    public var localPhotoBytes: Int64?
    public var localVideoBytes: Int64?
    public var bytesByYear: [Int: Int64] = [:]
    public var biggest: [PhotoItem] = []
    /// Filled by the scan only if Contacts access was already given. The scan never asks for it.
    public var duplicateContactGroups: Int?
    /// Nil until Photos access has been given. Asking for it stays with the Scan button.
    public var counts: LibraryCounts?
    public var notice: LocalizedStringKey?
    public var failure: String?

    private var stopFlag = StopFlag()
    /// Gone this session, so a scan still running can't offer them again.
    private var deleted = Set<String>()

    public var protected: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "protected") ?? [])

    public init() {}

    public var working: Bool { phase == .reading || phase == .analysing }
    public func items(_ category: PhotoCategory) -> [PhotoItem] { (results[category] ?? []).flatMap(\.items) }
    public func saving(_ category: PhotoCategory) -> Int64 { items(category).reduce(0) { $0 + $1.saving } }

    /// Safe, one-tap set: exact copies, and screenshots over 90 days old.
    public var recommended: [PhotoItem] {
        let cutoff = Date(timeIntervalSinceNow: -90 * 86_400)
        let old = items(.screenshots).filter { ($0.asset.creationDate ?? .now) < cutoff }
        return unique(items(.duplicates) + old)
    }
    /// The same items for review. Copies show the one that stays next to them.
    public var recommendedGroups: [CleanupGroup] {
        let copies = results[.duplicates] ?? []
        let copyIDs = Set(copies.flatMap(\.items).map(\.id))
        let rest = recommended.filter { !copyIDs.contains($0.id) }
        return copies + (rest.isEmpty ? [] : [CleanupGroup(items: rest)])
    }
    public var everything: Int64 { unique(PhotoCategory.allCases.filter { $0 != .livePhotos }.flatMap(items)).reduce(0) { $0 + $1.bytes } }
    private func unique(_ items: [PhotoItem]) -> [PhotoItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Only ever from the person pressing Scan. Photos access is asked for at that moment too, so the reason is clear.
    public func start() async {
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        await scan()
    }

    public func scan() async {
        guard status == .authorized || status == .limited, !working else { return }
        let stop = StopFlag()
        stopFlag = stop
        phase = .reading
        checked = 0
        let hidden = protected
        let cache = ScanCache()
        // Videos are a sixth of the items and most of the bytes, so the big numbers show within seconds.
        // A rescan keeps what's on screen until it has the whole picture.
        let showPartial = results.isEmpty
        let first = await Task.detached(priority: .userInitiated) {
            LibraryScan.read(excluding: hidden, cache: cache, stop: stop) { partial in
                if showPartial { Task { @MainActor in self.apply(partial) } }
            } progress: { n, t in Task { @MainActor in self.checked = n; self.total = t } }
        }.value
        if stop.value {
            // A part-read library would understate everything, so anything shown before stays. A first scan shows what it reached.
            if showPartial { apply(first) }
            phase = .stopped
            return
        }
        apply(first)
        phase = .analysing
        total = first.photos.count
        checked = 0
        let found = await Task.detached(priority: .userInitiated) { LibraryScan.analyse(first.photos, cache: cache, stop: stop) { n in Task { @MainActor in self.checked = n } } }.value
        results[.similar] = found.similar
        results[.blurred] = found.blurred.isEmpty ? [] : [CleanupGroup(items: found.blurred)]
        removeDeleted()
        #if os(iOS)
        duplicateContactGroups = await Task.detached(priority: .utility) { ContactsCleanup.groupCountIfAllowed() }.value
        #endif
        phase = stop.value ? .stopped : .done
    }

    public func stop() { stopFlag.value = true }

    public func loadCounts() async {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let quick = await Task.detached(priority: .userInitiated) { LibraryCounts.read() }.value
        counts = quick
        guard !working else { return }
        counts = await Task.detached(priority: .userInitiated) { quick.withSizes(from: ScanCache()) }.value
    }

    private func apply(_ first: LibraryScan.First) {
        results = first.results
        photoBytes = first.photoBytes
        videoBytes = first.videoBytes
        localPhotoBytes = first.localPhotoBytes
        localVideoBytes = first.localVideoBytes
        bytesByYear = first.bytesByYear
        biggest = first.biggest
        removeDeleted()
    }

    private func removeDeleted() {
        for (key, groups) in results {
            results[key] = groups.map { CleanupGroup(keep: $0.keep, items: $0.items.filter { !deleted.contains($0.id) }) }.filter { !$0.items.isEmpty }
        }
    }

    /// iOS asks for confirmation. Cancelling there leaves everything in place.
    /// Only takes what was deleted off the lists: rescanning a large library after every delete would take minutes.
    @discardableResult
    public func delete(_ ids: Set<String>) async -> Bool {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            notice = "Moved to Recently Deleted. The space comes back when iOS empties it after about 30 days, or when you empty it in Photos."
            deleted.formUnion(ids)
            removeDeleted()
            return true
        } catch {
            if (error as NSError).code != PHPhotosError.userCancelled.rawValue { failure = error.localizedDescription }
            return false
        }
    }

    public func protect(_ item: PhotoItem) {
        protected.insert(item.id)
        UserDefaults.standard.set(Array(protected), forKey: "protected")
        for (key, groups) in results {
            results[key] = groups.map { CleanupGroup(keep: $0.keep, items: $0.items.filter { $0.id != item.id }) }.filter { !$0.items.isEmpty }
        }
    }

    public func clearProtected() {
        protected = []
        UserDefaults.standard.removeObject(forKey: "protected")
        Task { await scan() }
    }
}

public final class StopFlag: @unchecked Sendable {
    public var value = false
}

/// What a scan learned about one asset.
public struct ScanFacts: Codable, Equatable {
    public var modified: Date?
    public var bytes: Int64
    public var local: Int64?
    public var pairedVideo: Int64
    public var name: String?
    public var sharpness: Double?
    public var hash: UInt64?
}

/// Remembers facts between scans, so only new or edited items cost anything. Lives in Caches: iOS may clear it, and it's never backed up.
public final class ScanCache: @unchecked Sendable {
    /// On a Mac, Caches is shared with other apps, so the name says whose it is.
    #if os(iOS)
    public static let defaultFile = URL.cachesDirectory.appending(path: "scan-cache.plist")
    #else
    public static let defaultFile = URL.cachesDirectory.appending(path: "Artifloam-photo-scan-cache.plist")
    #endif
    private let file: URL
    private let lock = NSLock()
    private var entries: [String: ScanFacts]
    private var changed = false

    public init(file: URL = ScanCache.defaultFile) {
        self.file = file
        entries = (try? Data(contentsOf: file)).flatMap { try? PropertyListDecoder().decode([String: ScanFacts].self, from: $0) } ?? [:]
    }

    public var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return entries.isEmpty }

    /// Nil once the item has been edited since.
    private func fresh(_ id: String, modified: Date?) -> ScanFacts? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[id], entry.modified == modified else { return nil }
        return entry
    }
    public func facts(id: String, modified: Date?) -> ScanFacts? { fresh(id, modified: modified) }
    public func facts(for asset: PHAsset) -> ScanFacts? { fresh(asset.localIdentifier, modified: asset.modificationDate) }
    public func look(for asset: PHAsset) -> (sharpness: Double, hash: UInt64)? {
        guard let entry = fresh(asset.localIdentifier, modified: asset.modificationDate), let sharpness = entry.sharpness, let hash = entry.hash else { return nil }
        return (sharpness, hash)
    }
    public func store(_ facts: ScanFacts, id: String) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = facts
        changed = true
    }
    public func store(_ facts: ScanFacts, for asset: PHAsset) { store(facts, id: asset.localIdentifier) }
    public func store(look: (sharpness: Double, hash: UInt64), for asset: PHAsset) {
        lock.lock(); defer { lock.unlock() }
        entries[asset.localIdentifier]?.sharpness = look.sharpness
        entries[asset.localIdentifier]?.hash = look.hash
        changed = true
    }
    public func save() {
        lock.lock(); defer { lock.unlock() }
        guard changed else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? encoder.encode(entries).write(to: file, options: .atomic)
        changed = false
    }
}

public enum LibraryScan {
    public struct First {
        var results: [PhotoCategory: [CleanupGroup]]
        var photoBytes: Int64
        var videoBytes: Int64
        var photos: [PhotoItem]
        var localPhotoBytes: Int64?
        var localVideoBytes: Int64?
        var bytesByYear: [Int: Int64]
        var biggest: [PhotoItem]
    }
    public struct Identity: Hashable { let width, height: Int; let bytes: Int64; let name: String }

    /// ponytail: "fileSize" is undocumented, and the only way to get sizes without reading every file. Replace if App Review objects.
    public static func size(of resource: PHAssetResource) -> Int64 { (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0 }

    /// Undocumented, like "fileSize", so it's checked before asking. Nil means unknown, never a guess.
    public static func isOnThisIPhone(_ resource: PHAssetResource) -> Bool? {
        guard resource.responds(to: NSSelectorFromString("locallyAvailable")) else { return nil }
        return (resource.value(forKey: "locallyAvailable") as? NSNumber)?.boolValue
    }

    /// Runs `body` for every index on several threads. Stops early with `stop`.
    public nonisolated static func parallel(_ count: Int, stop: StopFlag, body: @escaping (Int) -> Void) {
        let threads = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        DispatchQueue.concurrentPerform(iterations: threads) { thread in
            for index in stride(from: thread, to: count, by: threads) {
                if stop.value { return }
                autoreleasepool { body(index) }
            }
        }
    }

    /// What one asset's resources say. iOS takes about 3 ms per item to answer, so this is what the cache keeps.
    public nonisolated static func facts(of asset: PHAsset) -> ScanFacts {
        let resources = PHAssetResource.assetResources(for: asset)
        var local: Int64? = 0
        for resource in resources {
            guard let here = isOnThisIPhone(resource) else { local = nil; continue }
            if here { local = local.map { $0 + size(of: resource) } }
        }
        return ScanFacts(modified: asset.modificationDate, bytes: resources.reduce(0) { $0 + size(of: $1) }, local: local,
                         pairedVideo: resources.filter { $0.type == .pairedVideo }.reduce(0) { $0 + size(of: $1) }, name: resources.first?.originalFilename)
    }

    /// `partial` gets the videos as soon as they're read, before the much longer photo pass.
    public nonisolated static func read(excluding protected: Set<String>, cache: ScanCache, stop: StopFlag, partial: (First) -> Void = { _ in }, progress: @escaping @Sendable (Int, Int) -> Void) -> First {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let all = PHAsset.fetchAssets(with: options)
        let assets = all.objects(at: IndexSet(integersIn: 0..<all.count))
        let videos = assets.indices.filter { assets[$0].mediaType == .video }
        let others = assets.indices.filter { assets[$0].mediaType != .video }
        var found = [ScanFacts?](repeating: nil, count: assets.count)
        let lock = NSLock()
        var done = 0
        func readFacts(_ indexes: [Int]) {
            parallel(indexes.count, stop: stop) { position in
                let index = indexes[position], asset = assets[index]
                let known = cache.facts(for: asset)
                let facts = known ?? Self.facts(of: asset)
                if known == nil { cache.store(facts, for: asset) }
                lock.lock()
                found[index] = facts
                done += 1
                if done % 200 == 0 { progress(done, assets.count) }
                lock.unlock()
            }
        }
        readFacts(videos)
        if !stop.value { partial(assemble(assets, found, excluding: protected)) }
        readFacts(others)
        cache.save()
        return assemble(assets, found, excluding: protected)
    }

    /// Everything the scan reports, from facts already read. Newest first, like `assets`.
    public nonisolated static func assemble(_ assets: [PHAsset], _ found: [ScanFacts?], excluding protected: Set<String>) -> First {
        var out: [PhotoCategory: [PhotoItem]] = [:]
        var copies: [(item: PhotoItem, identity: Identity)] = []
        var photos: [PhotoItem] = []
        var photoBytes: Int64 = 0, videoBytes: Int64 = 0
        var localPhotos: Int64 = 0, localVideos: Int64 = 0, localKnown = true
        var years: [Int: Int64] = [:]
        var biggest: [PhotoItem] = []
        let oldCutoff = Date(timeIntervalSinceNow: -2 * 365 * 86_400)
        for (asset, facts) in zip(assets, found) {
            guard let facts else { continue }
            let bytes = facts.bytes
            if asset.mediaType == .video { videoBytes += bytes } else { photoBytes += bytes }
            if let local = facts.local {
                if asset.mediaType == .video { localVideos += local } else { localPhotos += local }
            } else { localKnown = false }
            if let date = asset.creationDate { years[Calendar.current.component(.year, from: date), default: 0] += bytes }
            // Favourites and protected items are counted but never suggested.
            guard !asset.isFavorite, !protected.contains(asset.localIdentifier) else { continue }
            let item = PhotoItem(asset: asset, bytes: bytes)
            if biggest.count < 12 || bytes > (biggest.last?.bytes ?? 0) {
                biggest.append(item)
                biggest.sort { $0.bytes > $1.bytes }
                if biggest.count > 12 { biggest.removeLast() }
            }
            if asset.mediaType == .video {
                if bytes >= 100_000_000 {
                    out[.largeVideos, default: []].append(item)
                    if (asset.creationDate ?? .now) < oldCutoff { out[.oldVideos, default: []].append(item) }
                }
                if asset.mediaSubtypes.contains(.videoScreenRecording) { out[.screenRecordings, default: []].append(item) }
            } else if asset.mediaSubtypes.contains(.photoScreenshot) {
                out[.screenshots, default: []].append(item)
            } else {
                photos.append(item)
            }
            if asset.mediaSubtypes.contains(.photoLive), facts.pairedVideo > 0 {
                out[.livePhotos, default: []].append(PhotoItem(asset: asset, bytes: bytes, saves: facts.pairedVideo))
            }
            if bytes > 0, let name = facts.name {
                copies.append((item, Identity(width: asset.pixelWidth, height: asset.pixelHeight, bytes: bytes, name: name)))
            }
        }
        var results = out.mapValues { [CleanupGroup(items: $0.sorted { $0.saving > $1.saving })] }
        results[.duplicates] = Dictionary(grouping: copies, by: \.identity).values.compactMap { group -> CleanupGroup? in
            let sorted = group.map(\.item).sorted { ($0.asset.creationDate ?? .distantPast) < ($1.asset.creationDate ?? .distantPast) }
            guard sorted.count > 1 else { return nil }
            return CleanupGroup(keep: sorted[0], items: Array(sorted.dropFirst()))
        }.sorted { $0.items.count > $1.items.count }
        return First(results: results, photoBytes: photoBytes, videoBytes: videoBytes, photos: photos, localPhotoBytes: localKnown ? localPhotos : nil, localVideoBytes: localKnown ? localVideos : nil, bytesByYear: years, biggest: biggest)
    }

    public nonisolated static func analyse(_ photos: [PhotoItem], cache: ScanCache, stop: StopFlag, progress: @escaping @Sendable (Int) -> Void) -> (similar: [CleanupGroup], blurred: [PhotoItem]) {
        let ids = photos.map(\.id)
        var sharpness: [String: Double] = [:]
        var hashes: [String: UInt64] = [:]
        let lock = NSLock()
        var done = 0
        parallel(photos.count, stop: stop) { index in
            let asset = photos[index].asset
            var look = cache.look(for: asset)
            if look == nil, let image = thumbnail(asset) {
                look = (sharpnessOf(image), differenceHash(of: image))
                cache.store(look: look!, for: asset)
            }
            lock.lock()
            if let look { sharpness[ids[index]] = look.sharpness; hashes[ids[index]] = look.hash }
            done += 1
            if done % 20 == 0 { progress(done) }
            lock.unlock()
        }
        cache.save()
        let blurred = photos.indices.filter { (sharpness[ids[$0]] ?? .infinity) < blurThreshold }.map { photos[$0] }
        let dated = photos.compactMap { p in p.asset.creationDate.map { (p, $0) } }
        let clusters = timeClusters(dated.map(\.1), gap: 30)
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
    public static let blurThreshold = 12.0
    /// Of 64 bits. Only photos taken within 30 seconds are compared, so this can stay simple.
    /// Vision's feature prints returned all zeros in the Simulator, which would call every photo similar, so they aren't used.
    public static let similarBits = 8

    /// Thumbnails iOS already has. Never downloads from iCloud during a scan.
    public nonisolated static func thumbnail(_ asset: PHAsset, side: CGFloat = 256) -> CGImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        var result: CGImage?
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: options) { image, _ in
            #if os(iOS)
            result = image?.cgImage
            #else
            result = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            #endif
        }
        return result
    }

    public nonisolated static func sharpnessOf(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        var gray = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return .infinity }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return laplacianVariance(gray, width: width, height: height)
    }
}

/// A 64-bit fingerprint: whether each pixel is brighter than the next, on a 9 by 8 version of the image.
public func differenceHash(of image: CGImage) -> UInt64 {
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
public func laplacianVariance(_ gray: [UInt8], width: Int, height: Int) -> Double {
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
public func timeClusters(_ dates: [Date], gap: TimeInterval) -> [[Int]] {
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
