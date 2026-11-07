import Photos
import SwiftUI

enum MediaSection {
    case photos, videos
    var theme: StewardTheme { self == .photos ? .cleanup : .files }
    var title: LocalizedStringKey { self == .photos ? "Photos" : "Videos" }
    var subtitle: LocalizedStringKey { self == .photos ? "Keep the best, lose the rest." : "Big memories, smaller files." }
    var categories: [PhotoCategory] { self == .photos ? [.duplicates, .similar, .blurred, .screenshots, .livePhotos] : [.largeVideos, .oldVideos, .screenRecordings] }
}

struct MediaSectionView: View {
    let section: MediaSection
    @Environment(Library.self) private var library

    var body: some View {
        StagePage(theme: section.theme, title: section.title, subtitle: section.subtitle, moving: library.working) {
            switch library.status {
            case .denied, .restricted:
                NoPhotoAccess()
            default:
                if library.status == .limited {
                    Text("You've given access to some photos, so only those are checked.").font(.footnote).foregroundStyle(.white.opacity(0.75))
                }
                if section == .videos {
                    NavigationLink { CompressView() } label: {
                        GlassCard { FeatureRow(icon: "category-done", title: "Compress videos", detail: Text("Keep them, at a smaller size.")) }
                    }
                    .buttonStyle(.plain)
                }
                GlassCard {
                    ForEach(section.categories) { category in
                        let items = library.items(category)
                        NavigationLink {
                            if category == .livePhotos {
                                LivePhotosView()
                            } else {
                                PhotoReviewView(title: category.title, note: category.note, theme: section.theme, groups: library.results[category] ?? [], category: category)
                            }
                        } label: {
                            FeatureRow(icon: category.icon, title: category.title, detail: Text("^[\(items.count) item](inflect: true)"), value: items.isEmpty ? nil : formatted(library.saving(category)))
                        }
                        .buttonStyle(.plain)
                        .disabled(items.isEmpty)
                        .opacity(items.isEmpty ? 0.5 : 1)
                    }
                }
                Text("Sizes are the full originals. If you use Optimize iPhone Storage, deleting may free less on this iPhone. Favourites are never listed.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
            }
        }
        .refreshable { await library.scan() }
    }
}

struct PhotoReviewView: View {
    let title: LocalizedStringKey
    let note: LocalizedStringKey
    let theme: StewardTheme
    let groups: [CleanupGroup]
    var category: PhotoCategory? = nil
    /// Starts with everything ticked, for the Recommended review.
    var preselected = false
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var dropped: Set<String> = []
    @State private var didPreselect = false

    private var liveGroups: [CleanupGroup] {
        (category.flatMap { library.results[$0] } ?? groups).map { CleanupGroup(keep: $0.keep, items: $0.items.filter { !dropped.contains($0.id) }) }.filter { !$0.items.isEmpty }
    }
    private var items: [PhotoItem] { liveGroups.flatMap(\.items) }
    private var selectedBytes: Int64 { items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        DetailPage(theme: theme, title: title) {
            Text(note).font(.subheadline)
            Text("Deleted items stay in Recently Deleted for about 30 days. With iCloud Photos they leave all your devices.").font(.footnote).foregroundStyle(.white.opacity(0.7))
            NavigationLink { SwipeReviewView(items: items, theme: theme) } label: {
                Label("Swipe through them", systemImage: "hand.draw").fontWeight(.medium)
            }
            ForEach(liveGroups) { group in
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 3)], spacing: 3) {
                    if let keep = group.keep { PhotoCell(item: keep, state: .keeps) }
                    ForEach(group.items) { item in
                        PhotoCell(item: item, state: selection.contains(item.id) ? .selected : .available) {
                            if !selection.insert(item.id).inserted { selection.remove(item.id) }
                        } protect: {
                            library.protect(item)
                            dropped.insert(item.id)
                            selection.remove(item.id)
                        }
                    }
                }
            }
        }
        .onAppear { if preselected && !didPreselect { selection = Set(items.map(\.id)); didPreselect = true } }
        .toolbar {
            Button(selection.count == items.count ? "Select None" : "Select All") {
                selection = selection.count == items.count ? [] : Set(items.map(\.id))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                Button(role: .destructive) {
                    let chosen = selection
                    Task {
                        if await library.delete(chosen) {
                            dropped.formUnion(chosen)
                            selection = []
                            if items.isEmpty { dismiss() }
                        }
                    }
                } label: {
                    Text("Delete \(selection.count), up to \(formatted(selectedBytes))").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(.red).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }
}

struct PhotoCell: View {
    enum CellState { case available, selected, keeps, picture }
    let item: PhotoItem
    let state: CellState
    var toggle: () -> Void = {}
    var protect: (() -> Void)? = nil
    @State private var image: UIImage?

    var body: some View {
        Button(action: toggle) {
            Color.white.opacity(0.08)
                .aspectRatio(1, contentMode: .fit)
                .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    if state != .picture { Text(state == .keeps ? String(localized: "Stays") : formatted(item.saving)).font(.caption2.bold()).foregroundStyle(.white).padding(4)
                        .background(state == .keeps ? AnyShapeStyle(StewardTheme.cleanup.vivid) : AnyShapeStyle(.black.opacity(0.6)), in: .rect(cornerRadius: 4)).padding(4) }
                }
                .overlay(alignment: .topTrailing) {
                    if state == .available || state == .selected {
                        Image(systemName: state == .selected ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(state == .selected ? Color.accentColor : .white).shadow(radius: 2).padding(4)
                    }
                }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(state == .available || state == .selected)
        .accessibilityLabel(label)
        .accessibilityAddTraits(state == .selected ? .isSelected : [])
        .contextMenu {
            Text(item.asset.creationDate?.formatted(date: .long, time: .shortened) ?? "")
            if let protect { Button("Never suggest this", systemImage: "lock", action: protect) }
        } preview: {
            if let image { Image(uiImage: image).resizable().scaledToFit().frame(width: 320) }
        }
        .task(id: item.id) { image = await Thumbnails.load(item.asset, side: 320) }
    }

    private var label: Text {
        let kind = item.asset.mediaType == .video ? String(localized: "Video") : String(localized: "Photo")
        let date = item.asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? ""
        return state == .keeps ? Text("\(kind), \(date), stays") : Text("\(kind), \(formatted(item.saving)), \(date)")
    }
}

enum Thumbnails {
    static func load(_ asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

/// One at a time: swipe left to delete, right to keep. Nothing is removed until the end, and iOS confirms it.
struct SwipeReviewView: View {
    let items: [PhotoItem]
    let theme: StewardTheme
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var marked: [String] = []
    @State private var image: UIImage?
    @State private var drag = CGSize.zero

    var body: some View {
        DetailPage(theme: theme, title: "Swipe") {
            if index < items.count {
                let item = items[index]
                Text("\(index + 1) of \(items.count)").font(.footnote).frame(maxWidth: .infinity)
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.08))
                    if let image { Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 20)) }
                }
                .frame(height: 420)
                .overlay(alignment: .bottomLeading) { Text(formatted(item.saving)).font(.caption.bold()).padding(6).background(.black.opacity(0.6), in: .rect(cornerRadius: 6)).padding(10) }
                .offset(drag)
                .rotationEffect(.degrees(drag.width / 24))
                .gesture(DragGesture().onChanged { drag = $0.translation }.onEnded { value in
                    if value.translation.width < -110 { decide(delete: true) } else if value.translation.width > 110 { decide(delete: false) }
                    withAnimation(.spring) { drag = .zero }
                })
                HStack {
                    Button { decide(delete: true) } label: { Label("Delete", systemImage: "trash").frame(maxWidth: .infinity) }.buttonStyle(.bordered).tint(.red)
                    Button { decide(delete: false) } label: { Label("Keep", systemImage: "checkmark").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .task(id: item.id) { image = nil; image = await Thumbnails.load(item.asset, side: 900) }
            } else {
                Text("All done").font(.title2.weight(.semibold))
                Text("\(marked.count) marked to delete.")
            }
            if !marked.isEmpty {
                Button {
                    Task { if await library.delete(Set(marked)) { dismiss() } }
                } label: {
                    Text("Delete \(marked.count) now").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
        }
    }

    private func decide(delete: Bool) {
        guard index < items.count else { return }
        if delete { marked.append(items[index].id) }
        index += 1
    }
}

struct CompressView: View {
    @Environment(Library.self) private var library
    @State private var estimates: [String: Int64] = [:]
    @State private var selection: Set<String> = []
    @State private var running = false
    @State private var progress = 0
    @State private var result: LocalizedStringKey?
    @State private var failure: String?

    private var videos: [PhotoItem] { library.items(.largeVideos) }

    var body: some View {
        DetailPage(theme: .files, title: "Compress videos") {
            Text("Makes a smaller copy with the same date and place, then asks to remove the original. If the saving is under 10%, the video is left as it is. Quality can drop slightly, and videos over 1080p become 1080p.").font(.subheadline)
            if videos.isEmpty { GlassCard { Text("No large videos found.") } }
            ForEach(videos) { item in
                Button {
                    if !selection.insert(item.id).inserted { selection.remove(item.id) }
                } label: {
                    GlassCard {
                        HStack(spacing: 12) {
                            PhotoCell(item: item, state: .picture).frame(width: 64, height: 64).allowsHitTesting(false)
                            VStack(alignment: .leading) {
                                Text(formatted(item.bytes)).font(.headline)
                                if let estimate = estimates[item.id], estimate > 0, estimate < item.bytes {
                                    Text("About \(formatted(estimate)) after").font(.footnote).foregroundStyle(.white.opacity(0.75))
                                }
                            }
                            Spacer()
                            Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle").font(.title2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .task { await estimate(item) }
            }
            if let result { GlassCard { Text(result) } }
        }
        .safeAreaInset(edge: .bottom) {
            if running {
                ProgressView("Compressing \(progress) of \(selection.count)").tint(.white).foregroundStyle(.white).padding(12).frame(maxWidth: .infinity)
            } else if !selection.isEmpty {
                Button { Task { await run() } } label: { Text("Compress \(selection.count)").fontWeight(.semibold).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(StewardTheme.files.vivid).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .alert("Couldn't compress", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) {} } message: { Text(failure ?? "") }
    }

    private func estimate(_ item: PhotoItem) async {
        guard estimates[item.id] == nil, let (session, _) = try? await MediaChanges.exportSession(for: item.asset) else { return }
        session.outputFileType = .mp4
        session.estimateOutputFileLength { bytes, _ in
            Task { @MainActor in estimates[item.id] = bytes }
        }
    }

    private func run() async {
        running = true
        progress = 0
        var done: Set<String> = []
        var saved: Int64 = 0
        var skipped = 0
        for item in videos where selection.contains(item.id) {
            progress += 1
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
        running = false
        selection = []
        guard !done.isEmpty else {
            result = skipped > 0 ? "The saving would be too small, so nothing changed." : nil
            return
        }
        if await library.delete(done) {
            result = "Saved about \(formatted(saved)). Originals are in Recently Deleted."
        } else {
            result = "Kept your originals as well as the smaller copies. Nothing was removed."
            await library.scan()
        }
    }
}

struct LivePhotosView: View {
    @Environment(Library.self) private var library
    @State private var selection: Set<String> = []
    @State private var running = false
    @State private var result: LocalizedStringKey?
    @State private var failure: String?

    private var items: [PhotoItem] { library.items(.livePhotos) }

    var body: some View {
        DetailPage(theme: .cleanup, title: "Live Photos") {
            Text("Keeps the photo with its date and place, and removes the short video. Sizes show what you'd save.").font(.subheadline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 3)], spacing: 3) {
                ForEach(items) { item in
                    PhotoCell(item: item, state: selection.contains(item.id) ? .selected : .available) {
                        if !selection.insert(item.id).inserted { selection.remove(item.id) }
                    }
                }
            }
            if let result { GlassCard { Text(result) } }
        }
        .toolbar { Button(selection.count == items.count ? "Select None" : "Select All") { selection = selection.count == items.count ? [] : Set(items.map(\.id)) } }
        .safeAreaInset(edge: .bottom) {
            if running {
                ProgressView("Converting").tint(.white).foregroundStyle(.white).padding(12).frame(maxWidth: .infinity)
            } else if !selection.isEmpty {
                Button { Task { await run() } } label: { Text("Convert \(selection.count)").fontWeight(.semibold).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(StewardTheme.cleanup.vivid).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .alert("Couldn't convert", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) {} } message: { Text(failure ?? "") }
    }

    private func run() async {
        running = true
        var done: Set<String> = []
        for item in items where selection.contains(item.id) {
            do {
                try await MediaChanges.makeStill(item)
                done.insert(item.id)
            } catch {
                failure = error.localizedDescription
                break
            }
        }
        running = false
        selection = []
        guard !done.isEmpty else { return }
        result = await library.delete(done) ? "Converted. The originals are in Recently Deleted." : "You have both versions now. Nothing was removed."
    }
}
