import MacStewardCore
import Photos
import PhotoEngine
import SwiftUI

/// The Mac's Photos library, through the same scan as the iPhone app. MainView reaches it only through here,
/// because importing PhotoEngine there would make its CleanupGroup clash with the Mac's own.
@MainActor enum PhotosModule {
    static let library = Library()
    static var working: Bool { library.working }
    /// The start screen until a scan has something to say. No access has its own message on the page.
    static var onStage: Bool {
        if library.working { return true }
        if library.status == .denied || library.status == .restricted { return false }
        return library.phase == .idle
    }
    static var progress: String {
        library.total == 0 ? String(localized: "Reading your library") : String(localized: "\(library.checked) of \(library.total) checked")
    }
    static func start() { Task { await library.start() } }
    static func stop() { library.stop() }
}

private func size(_ bytes: Int64) -> String { bytes <= 0 ? "0" : formattedBytes(UInt64(bytes)) }

struct PhotosModuleView: View {
    private enum Page: Equatable {
        case recommended
        case category(PhotoCategory)
    }
    private var library: Library { PhotosModule.library }
    @State private var page: Page?
    @State private var selection: Set<String> = []
    @State private var running = false
    @State private var result: LocalizedStringKey?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if library.status == .denied || library.status == .restricted {
                noAccess
            } else if let page {
                detail(page)
            } else {
                list
            }
            if let result { Text(result).stewardFont(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)) }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { failure != nil || library.failure != nil }, set: { if !$0 { failure = nil; library.failure = nil } })) { Button("OK", role: .cancel) {} } message: { Text(failure ?? library.failure ?? "") }
    }

    private var noAccess: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No access to Photos").stewardFont(.title3, weight: .semibold)
            Text("Allow access in Settings so Artifloam can find large videos, screenshots and duplicates.").stewardFont(.callout).foregroundStyle(.secondary)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") { Link("Open Settings", destination: url) }
        }
    }

    // MARK: - Everything the scan found

    private var found: [PhotoCategory] {
        PhotoCategory.allCases.filter { !library.items($0).isEmpty }.sorted { library.saving($0) > library.saving($1) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your library at full size, including iCloud: photos \(size(library.photoBytes)), videos \(size(library.videoBytes))").stewardFont(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Scan") { PhotosModule.start() }
            }
            let picks = library.recommended
            if !picks.isEmpty {
                row(icon: "category-sparkles", title: Text("Recommended"), detail: Text("^[\(picks.count) item](inflect: true)"), value: size(picks.reduce(0) { $0 + $1.bytes })) { open(.recommended) }
            }
            ForEach(found) { category in
                row(icon: category.icon, title: Text(category.title), detail: Text("^[\(library.items(category).count) item](inflect: true)"), value: size(library.saving(category))) { open(.category(category)) }
            }
            if found.isEmpty && picks.isEmpty { Label("Nothing to clean", systemImage: "checkmark.seal.fill").stewardFont(.headline) }
        }
    }

    private func row(icon: String, title: Text, detail: Text, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let url = StewardResources.bundle.url(forResource: icon, withExtension: "heic"), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 36, height: 36).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    title.stewardFont(.body, weight: .medium)
                    detail.stewardFont(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(value).stewardFont(.callout).monospacedDigit()
                Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ destination: Page) {
        result = nil
        page = destination
        // Recommended starts ticked. Nothing goes until the person has seen them and pressed Delete.
        selection = destination == .recommended ? Set(library.recommended.map(\.id)) : []
    }

    // MARK: - One list to review

    private func groups(_ page: Page) -> [PhotoEngine.CleanupGroup] {
        switch page {
        case .recommended: return library.recommendedGroups
        case .category(let category): return library.results[category] ?? []
        }
    }

    private func detail(_ page: Page) -> some View {
        let groups = groups(page)
        let items = groups.flatMap(\.items)
        let chosen = items.filter { selection.contains($0.id) }
        return VStack(alignment: .leading, spacing: 12) {
            Button { self.page = nil; selection = [] } label: { Label("Back", systemImage: "chevron.backward") }.buttonStyle(.plain)
            Text(pageNote(page)).stewardFont(.callout).foregroundStyle(.secondary)
            Text("Deleted items stay in Recently Deleted for about 30 days. With iCloud Photos they leave all your devices.").stewardFont(.caption).foregroundStyle(.secondary)
            BulkBar(title: String(localized: "Select all"), isOn: Binding(get: { !items.isEmpty && chosen.count == items.count }, set: { selection = $0 ? Set(items.map(\.id)) : [] }), enabled: !running, summary: String(localized: "\(chosen.count) chosen · \(size(chosen.reduce(0) { $0 + $1.saving }))")) {
                if running { ProgressView().controlSize(.small) }
                if page == .category(.largeVideos) || page == .category(.oldVideos) {
                    Button("Compress") { Task { await compress(chosen) } }.disabled(chosen.isEmpty || running)
                }
                if page == .category(.livePhotos) {
                    Button("Convert") { Task { await convert(chosen) } }.buttonStyle(.borderedProminent).disabled(chosen.isEmpty || running)
                } else {
                    Button("Delete", role: .destructive) { Task { await remove(chosen) } }.buttonStyle(.borderedProminent).disabled(chosen.isEmpty || running)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(groups) { group in
                    if let keep = group.keep { PhotoTile(item: keep, selected: nil) }
                    ForEach(group.items) { item in
                        PhotoTile(item: item, selected: Binding(get: { selection.contains(item.id) }, set: { if $0 { selection.insert(item.id) } else { selection.remove(item.id) } }))
                    }
                }
            }
        }
    }

    private func pageNote(_ page: Page) -> LocalizedStringKey {
        switch page {
        case .recommended: return "Exact copies, and screenshots over 90 days old. Untick anything to keep. Items in iCloud may free less on this device."
        case .category(.livePhotos): return "Keeps the photo with its date and place, and removes the short video. Sizes show what you'd save."
        case .category(let category): return category.note
        }
    }

    // MARK: - Actions. macOS asks for confirmation before anything leaves the library.

    private func remove(_ items: [PhotoItem]) async {
        running = true
        defer { running = false }
        if await library.delete(Set(items.map(\.id))) { selection = []; if groups(page ?? .recommended).isEmpty { page = nil } }
    }

    /// The smaller copy comes first, so a failure can't lose anything.
    private func compress(_ items: [PhotoItem]) async {
        running = true
        defer { running = false }
        var done: Set<String> = []
        var saved: Int64 = 0
        var skipped = 0
        for item in items {
            do {
                if let bytes = try await MediaChanges.compress(item) {
                    done.insert(item.id)
                    saved += item.bytes - bytes
                } else {
                    skipped += 1
                }
            } catch {
                failure = error.localizedDescription
                break
            }
        }
        selection = []
        guard !done.isEmpty else {
            result = skipped > 0 ? "The saving would be too small, so nothing changed." : nil
            return
        }
        if await library.delete(done) {
            result = "Saved about \(size(saved)). Originals are in Recently Deleted."
        } else {
            result = "Kept your originals as well as the smaller copies. Nothing was removed."
            await library.scan()
        }
    }

    private func convert(_ items: [PhotoItem]) async {
        running = true
        defer { running = false }
        var done: Set<String> = []
        for item in items {
            do {
                try await MediaChanges.makeStill(item)
                done.insert(item.id)
            } catch {
                failure = error.localizedDescription
                break
            }
        }
        selection = []
        guard !done.isEmpty else { return }
        result = await library.delete(done) ? "Converted. The originals are in Recently Deleted." : "You have both versions now. Nothing was removed."
    }
}

/// One picture. Without `selected`, it's the copy that stays and can't be chosen.
private struct PhotoTile: View {
    let item: PhotoItem
    let selected: Binding<Bool>?
    @State private var image: NSImage?

    var body: some View {
        // A square that the picture fills and is cropped to. Sizing to the picture let wide videos spill over their neighbours.
        Color.white.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomLeading) {
            Group { if selected == nil { Text("Stays") } else { Text(size(item.saving)) } }
                .stewardFont(.caption, weight: .semibold).padding(.horizontal, 6).padding(.vertical, 2)
                .background(selected == nil ? AnyShapeStyle(.green) : AnyShapeStyle(.black.opacity(0.6)), in: RoundedRectangle(cornerRadius: 5)).padding(6)
        }
        .overlay(alignment: .topTrailing) {
            if let selected { Toggle("Select", isOn: selected).toggleStyle(.stewardCheckboxOnly).padding(6) }
        }
        .overlay { if selected?.wrappedValue == true { RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2) } }
        .contentShape(Rectangle())
        .onTapGesture { selected?.wrappedValue.toggle() }
        .task(id: item.id) { image = await load() }
    }

    /// Whatever Photos has at hand. A grid never downloads originals, because this Mac may be short of space.
    private func load() async -> NSImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: item.asset, targetSize: CGSize(width: 320, height: 320), contentMode: .aspectFill, options: options) { result, _ in
                continuation.resume(returning: result)
            }
        }
    }
}
