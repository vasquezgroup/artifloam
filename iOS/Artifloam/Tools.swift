import BackgroundTasks
import Charts
import Photos
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import Vision

struct ToolsView: View {
    var body: some View {
        StagePage(theme: .space, title: "Tools", subtitle: "Everything else that frees up room.") {
            GlassCard {
                row(CompressView(), "category-done", "Compress videos", "Keep them, at a smaller size.")
                row(LivePhotosView(), "category-branch", "Turn off Live Photos", "Keep the photo, remove its short video.")
                row(StorageSummaryView(), "category-drive", "Storage summary", "What's on this iPhone, and what could go.")
                row(SpaceHistoryView(), "category-sparkles", "Space history")
                row(AlbumsView(), "category-stack", "Albums by size", "Includes albums apps create when saving media.")
                row(CategoriesView(), "category-globe", "Library categories", "Food, pets, documents and more.")
                row(LargeFilesView(), "category-document", "Large files", "Choose a folder from Files.")
                row(ContactsCleanupView(), "category-stack", "Merge contacts", "Same name and a shared number or email.")
                row(HealthView(), "category-done", "Device health")
            }
        }
    }

    private func row<D: View>(_ destination: D, _ icon: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey? = nil) -> some View {
        NavigationLink { destination } label: { FeatureRow(icon: icon, title: title, detail: detail.map { Text($0) }) }.buttonStyle(.plain)
    }
}

// MARK: - Space history

struct SpacePoint: Codable, Equatable, Identifiable {
    var date: Date
    var free: Int64
    var id: Date { date }
}

enum SpaceHistory {
    private static let key = "spaceHistory"
    static func load() -> [SpacePoint] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([SpacePoint].self, from: $0) } ?? []
    }
    static func record(_ space: DiskSpace) {
        let updated = adding(SpacePoint(date: .now, free: space.free), to: load())
        UserDefaults.standard.set(try? JSONEncoder().encode(updated), forKey: key)
    }
    /// One point a day, the latest reading winning, for about a year.
    /// Days until free space runs out at the recent rate. Nil without a week of readings, or if space isn't shrinking.
    static func daysUntilFull(_ points: [SpacePoint]) -> Int? {
        guard let first = points.first, let last = points.last else { return nil }
        let days = last.date.timeIntervalSince(first.date) / 86_400
        guard days >= 7, last.free < first.free else { return nil }
        return Int(Double(last.free) / (Double(first.free - last.free) / days))
    }
    static func adding(_ point: SpacePoint, to points: [SpacePoint], calendar: Calendar = .current) -> [SpacePoint] {
        var result = points
        if let last = result.last, calendar.isDate(last.date, inSameDayAs: point.date) { result.removeLast() }
        result.append(point)
        return Array(result.suffix(370))
    }
}

private struct SpaceHistoryView: View {
    private let points = SpaceHistory.load()
    var body: some View {
        DetailPage(theme: .space, title: "Space history") {
            GlassCard {
                if points.count < 2 {
                    Text("Artifloam adds a point each day you open it. Come back in a few days to see a trend.")
                } else {
                    Chart(points) { point in
                        LineMark(x: .value("Date", point.date), y: .value("Free", Double(point.free) / 1e9)).foregroundStyle(StewardTheme.space.accent)
                    }
                    .chartYAxisLabel("GB free")
                    .frame(height: 240)
                    if let first = points.first, let last = points.last {
                        let change = last.free - first.free
                        Text(change >= 0 ? "\(formatted(change)) more free than on \(first.date.formatted(date: .abbreviated, time: .omitted))" : "\(formatted(-change)) less free than on \(first.date.formatted(date: .abbreviated, time: .omitted))").font(.footnote)
                    }
                }
            }
        }
    }
}

// MARK: - Low-space reminder

enum SpaceReminder {
    private static let id = "com.vasquezgroup.artifloam.iphone.space"
    private static let key = "spaceReminder"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    static func isLow(free: Int64, total: Int64) -> Bool { total > 0 && Double(free) / Double(total) < 0.1 }

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            schedule()
            let space = DiskSpace.current
            if isLow(free: space.free, total: space.total) {
                let content = UNMutableNotificationContent()
                content.title = String(localized: "Your iPhone is running low on space")
                content.body = String(localized: "\(formatted(space.free)) left. Open Artifloam to see what can go.")
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lowSpace", content: content, trigger: nil))
            }
            task.setTaskCompleted(success: true)
        }
        if enabled { schedule() }
    }

    private static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 86_400)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func set(_ on: Bool) async -> Bool {
        var allowed = on
        if on { allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false }
        UserDefaults.standard.set(allowed, forKey: key)
        if allowed { schedule() } else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id) }
        return allowed
    }
}

// MARK: - Albums

private struct AlbumsView: View {
    struct Album: Identifiable {
        let id: String
        let title: String
        let items: [PhotoItem]
        var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }
    @State private var albums: [Album]?

    var body: some View {
        DetailPage(theme: .space, title: "Albums by size") {
            Text("Apps that save media, such as WhatsApp when set to save to Photos, may have their own album. This can't show which chat something came from.").font(.subheadline)
            if let albums {
                if albums.isEmpty { GlassCard { Text("No albums found.") } }
                GlassCard {
                    ForEach(albums) { album in
                        NavigationLink {
                            PhotoReviewView(title: LocalizedStringKey(album.title), note: "Deleting removes these from your whole library, not just this album.", theme: .space, groups: [CleanupGroup(items: album.items)])
                        } label: {
                            FeatureRow(icon: "category-stack", title: LocalizedStringKey(album.title), detail: Text("^[\(album.items.count) item](inflect: true)"), value: formatted(album.bytes))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task {
            albums = await Task.detached(priority: .userInitiated) {
                var found: [Album] = []
                PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { collection, _, _ in
                    var items: [PhotoItem] = []
                    PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                        guard !asset.isFavorite else { return }
                        items.append(PhotoItem(asset: asset, bytes: PHAssetResource.assetResources(for: asset).reduce(0) { $0 + LibraryScan.size(of: $1) }))
                    }
                    if !items.isEmpty { found.append(Album(id: collection.localIdentifier, title: collection.localizedTitle ?? "", items: items)) }
                }
                return found.sorted { $0.bytes > $1.bytes }
            }.value
        }
    }
}

// MARK: - Categories

enum LibraryBucket: String, CaseIterable, Identifiable {
    case people, pets, food, documents, nature, travel, other
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .people: "People"
        case .pets: "Pets"
        case .food: "Food"
        case .documents: "Documents"
        case .nature: "Nature"
        case .travel: "Travel and places"
        case .other: "Other"
        }
    }
    /// Maps Vision's labels. The first bucket with a confident label wins.
    static func bucket(for labels: [String]) -> LibraryBucket {
        func any(_ words: [String]) -> Bool { labels.contains { label in words.contains { label.contains($0) } } }
        if any(["people", "portrait", "selfie", "adult", "child"]) { return .people }
        if any(["animal", "cat", "dog", "pet"]) { return .pets }
        if any(["food", "drink", "fruit", "dessert", "meal"]) { return .food }
        if any(["document", "text", "receipt", "paper"]) { return .documents }
        if any(["outdoor", "sky", "mountain", "plant", "tree", "beach", "water", "flower"]) { return .nature }
        if any(["structure", "building", "vehicle", "city", "road", "landmark"]) { return .travel }
        return .other
    }
}

private struct CategoriesView: View {
    @State private var buckets: [LibraryBucket: [PhotoItem]]?
    @State private var checked = 0
    private static let limit = 1000

    var body: some View {
        DetailPage(theme: .space, title: "Library categories") {
            Text("Sorted on this iPhone, from your newest \(Self.limit) photos. Categories can be wrong, so look before deleting.").font(.subheadline)
            if let buckets {
                GlassCard {
                    ForEach(LibraryBucket.allCases.filter { !(buckets[$0] ?? []).isEmpty }) { bucket in
                        let items = buckets[bucket] ?? []
                        NavigationLink {
                            PhotoReviewView(title: bucket.title, note: "Deleting removes these from your library.", theme: .space, groups: [CleanupGroup(items: items)])
                        } label: {
                            FeatureRow(icon: "category-sparkles", title: bucket.title, detail: Text("^[\(items.count) item](inflect: true)"), value: formatted(items.reduce(0) { $0 + $1.bytes }))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ProgressView("Checked \(checked)")
            }
        }
        .task {
            buckets = await Task.detached(priority: .userInitiated) {
                var out: [LibraryBucket: [PhotoItem]] = [:]
                let options = PHFetchOptions()
                options.fetchLimit = Self.limit
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                PHAsset.fetchAssets(with: options).enumerateObjects { asset, index, _ in
                    autoreleasepool {
                        if index % 25 == 0 { Task { @MainActor in checked = index } }
                        guard !asset.isFavorite, let image = LibraryScan.thumbnail(asset) else { return }
                        let request = VNClassifyImageRequest()
                        #if targetEnvironment(simulator)
                        request.usesCPUOnly = true
                        #endif
                        try? VNImageRequestHandler(cgImage: image).perform([request])
                        let labels = (request.results ?? []).filter { $0.confidence > 0.5 }.map(\.identifier)
                        let bytes = PHAssetResource.assetResources(for: asset).reduce(Int64(0)) { $0 + LibraryScan.size(of: $1) }
                        out[LibraryBucket.bucket(for: labels), default: []].append(PhotoItem(asset: asset, bytes: bytes))
                    }
                }
                return out
            }.value
        }
    }
}

// MARK: - Large files

struct FileRow: Identifiable, Equatable {
    let url: URL
    let bytes: Int64
    var id: URL { url }
}

func largestFiles(in folder: URL, limit: Int) -> [FileRow] {
    guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return [] }
    var rows: [FileRow] = []
    for case let url as URL in files {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
        rows.append(FileRow(url: url, bytes: Int64(values.totalFileAllocatedSize ?? 0)))
    }
    return Array(rows.sorted { $0.bytes > $1.bytes }.prefix(limit))
}

private struct LargeFilesView: View {
    @State private var choosing = false
    @State private var folder: URL?
    @State private var files: [FileRow] = []
    @State private var pending: FileRow?
    @State private var failure: String?

    var body: some View {
        DetailPage(theme: .space, title: "Large files") {
            Text("Choose a folder, like On My iPhone or iCloud Drive. Apps that share files there have their own folder. Most apps don't, and iOS keeps those private.").font(.subheadline)
            Button("Choose a folder") { choosing = true }.buttonStyle(.borderedProminent).controlSize(.large)
            if !files.isEmpty {
                GlassCard {
                    ForEach(files) { file in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(file.url.lastPathComponent).lineLimit(1)
                                Text(formatted(file.bytes)).font(.footnote).foregroundStyle(.white.opacity(0.7))
                            }
                            Spacer()
                            Button("Delete", systemImage: "trash") { pending = file }.labelStyle(.iconOnly)
                        }
                    }
                }
            } else if folder != nil {
                GlassCard { Text("No files found here.") }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            folder = url
            let access = url.startAccessingSecurityScopedResource()
            files = largestFiles(in: url, limit: 100)
            if access { url.stopAccessingSecurityScopedResource() }
        }
        .confirmationDialog("Delete this file for good?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible, presenting: pending) { file in
            Button("Delete \(file.url.lastPathComponent)", role: .destructive) { remove(file) }
        } message: { _ in
            Text("It can't be restored from Artifloam.")
        }
        .alert("Couldn't delete", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) {} } message: { Text(failure ?? "") }
    }

    private func remove(_ file: FileRow) {
        guard let folder else { return }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.removeItem(at: file.url)
            files.removeAll { $0.id == file.id }
        } catch {
            failure = error.localizedDescription
        }
    }
}
