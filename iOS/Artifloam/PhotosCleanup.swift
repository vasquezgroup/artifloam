import AVKit
import Photos
import SwiftUI

enum MediaSection {
    case photos, videos
    var theme: StewardTheme { self == .photos ? .cleanup : .files }
    var title: LocalizedStringKey { self == .photos ? "Photos" : "Videos" }
    var subtitle: LocalizedStringKey { self == .photos ? "Keep the best, lose the rest." : "Big memories, smaller files." }
    var categories: [PhotoCategory] { self == .photos ? [.duplicates, .similar, .blurred, .screenshots] : [.largeVideos, .oldVideos, .screenRecordings] }
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
                if section == .photos {
                    NavigationLink { LivePhotosView() } label: {
                        GlassCard { FeatureRow(icon: "category-branch", title: "Turn off Live Photos", detail: Text("Keep the photo, remove its short video."), value: library.items(.livePhotos).isEmpty ? nil : formatted(library.saving(.livePhotos))) }
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
        .orbFooter(summary: library.scanSummary) { ScanOrb(theme: section.theme) }
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
    @State private var columns = 3

    private var liveGroups: [CleanupGroup] {
        (category.flatMap { library.results[$0] } ?? groups).map { CleanupGroup(keep: $0.keep, items: $0.items.filter { !dropped.contains($0.id) }) }.filter { !$0.items.isEmpty }
    }
    private var items: [PhotoItem] { liveGroups.flatMap(\.items) }
    private var selectedBytes: Int64 { items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        PhotoPage(theme: theme, title: title, columns: $columns) {
            VStack(alignment: .leading, spacing: 10) {
                Text(note).font(.subheadline)
                Text("Deleted items stay in Recently Deleted for about 30 days. With iCloud Photos they leave all your devices.").font(.footnote).foregroundStyle(.white.opacity(0.7))
                NavigationLink { SwipeReviewView(items: items, theme: theme) } label: {
                    Label("Swipe through them", systemImage: "hand.draw").fontWeight(.medium)
                }
            }
        } grid: {
            PhotoGrid(groups: liveGroups, selection: $selection, columnCount: $columns) { item in
                library.protect(item)
                dropped.insert(item.id)
                selection.remove(item.id)
            }
        }
        .onAppear { if preselected && !didPreselect { selection = Set(items.map(\.id)); didPreselect = true } }
        .toolbar {
            Button(selection.count == items.count ? "Select None" : "Select All") {
                selection = selection.count == items.count ? [] : Set(items.map(\.id))
            }
        }
        .orbFooter(summary: selection.isEmpty ? nil : Text("\(formatted(selectedBytes))\n^[\(selection.count) item](inflect: true)")) {
            OrbAction(title: "Delete", icon: "trash", accent: theme.vivid, disabled: selection.isEmpty) {
                let chosen = selection
                Task {
                    if await library.delete(chosen) {
                        dropped.formUnion(chosen)
                        selection = []
                        if items.isEmpty { dismiss() }
                    }
                }
            }
        }
    }
}

/// A page of photos, edge to edge. Once pictures are large, everything else fades away so they get the whole screen.
struct PhotoPage<Header: View, Grid: View>: View {
    let theme: StewardTheme
    let title: LocalizedStringKey
    @Binding var columns: Int
    @ViewBuilder let header: Header
    @ViewBuilder let grid: Grid
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fullScreen: Bool { columns <= 2 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AtmosphereView(theme: theme)
            if fullScreen { Color.black.ignoresSafeArea().transition(.opacity) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !fullScreen { header.padding(.horizontal, 16).transition(.opacity) }
                    grid
                }
            }
            .ignoresSafeArea(.container, edges: fullScreen ? [.top, .horizontal] : .horizontal)
            if fullScreen {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.backward").font(.body.weight(.semibold)).foregroundStyle(.white).frame(width: 40, height: 40).background(.ultraThinMaterial, in: .circle)
                }
                .accessibilityLabel("Back").padding(.leading, 14).padding(.top, 6).transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: fullScreen)
        .navigationTitle(fullScreen ? "" : title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(fullScreen)
        .toolbar(fullScreen ? .hidden : .automatic, for: .navigationBar)
        .toolbar(fullScreen ? .hidden : .automatic, for: .tabBar)
        .statusBarHidden(fullScreen)
        .environment(\.stewardTheme, theme)
        .tint(theme.accent)
    }
}

struct PhotoCell: View {
    enum CellState { case available, selected, keeps, picture }
    let item: PhotoItem
    let state: CellState
    var side: CGFloat = 320
    /// One column shows the whole picture instead of a square crop.
    var whole = false
    var showsSize = true
    var toggle: () -> Void = {}
    var protect: (() -> Void)? = nil
    @State private var image: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: Bool { state == .selected }

    var body: some View {
        Button(action: toggle) {
            Color.white.opacity(0.08)
                .aspectRatio(whole && item.asset.pixelHeight > 0 ? CGFloat(item.asset.pixelWidth) / CGFloat(item.asset.pixelHeight) : 1, contentMode: .fit)
                .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
                .clipped()
                .overlay { if selected { Rectangle().fill(.black.opacity(0.22)).overlay { Rectangle().stroke(.white, lineWidth: 2) } } }
                // Smaller inset on large pictures, or it would leave wide borders.
                .scaleEffect(selected && !reduceMotion ? (whole ? 0.985 : 0.93) : 1)
                .overlay(alignment: .bottomLeading) {
                    if state != .picture && showsSize { Text(state == .keeps ? String(localized: "Stays") : formatted(item.saving)).font(.caption2.bold()).foregroundStyle(.white).padding(4)
                        .background(state == .keeps ? AnyShapeStyle(StewardTheme.cleanup.vivid) : AnyShapeStyle(.black.opacity(0.6)), in: .rect(cornerRadius: 4)).padding(4) }
                }
                .overlay(alignment: .topTrailing) {
                    if state == .available || state == .selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: selected)
                            .font(.title3).foregroundStyle(selected ? StewardTheme.care.vivid : .white).background { if selected { Circle().fill(.white).padding(3) } }
                            .shadow(radius: 2).padding(4)
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.58), value: selected)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(state == .available || state == .selected)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Hold to see it larger")
        .contextMenu {
            Text(item.asset.creationDate?.formatted(date: .long, time: .shortened) ?? "")
            Text(formatted(item.saving))
            if let protect { Button("Never suggest this", systemImage: "lock", action: protect) }
        } preview: {
            PhotoPreview(asset: item.asset, placeholder: image)
        }
        .task(id: "\(item.id)-\(Int(side))") { image = await Thumbnails.load(item.asset, side: side) }
    }

    private var label: Text {
        let kind = item.asset.mediaType == .video ? String(localized: "Video") : String(localized: "Photo")
        let date = item.asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? ""
        return state == .keeps ? Text("\(kind), \(date), stays") : Text("\(kind), \(formatted(item.saving)), \(date)")
    }
}

/// Shown while holding a photo: the whole picture, large, or the video playing without sound.
private struct PhotoPreview: View {
    let asset: PHAsset
    let placeholder: UIImage?
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    private var ratio: CGFloat { asset.pixelHeight > 0 ? CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight) : 1 }
    /// Exactly the picture's shape, so there are no empty bars around it.
    private var previewSize: CGSize {
        let maxWidth: CGFloat = 370, maxHeight: CGFloat = 600
        return ratio >= maxWidth / maxHeight ? CGSize(width: maxWidth, height: maxWidth / ratio) : CGSize(width: maxHeight * ratio, height: maxHeight)
    }

    var body: some View {
        ZStack {
            Color.black
            if let picture = image ?? placeholder { Image(uiImage: picture).resizable().scaledToFit() }
            if let player { VideoPlayer(player: player).disabled(true) }
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .task {
            image = await Thumbnails.load(asset, side: 1200)
            guard asset.mediaType == .video else { return }
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .fastFormat
            let playerItem: AVPlayerItem? = await withCheckedContinuation { continuation in
                PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { result, _ in continuation.resume(returning: result) }
            }
            guard let playerItem else { return }
            let video = AVPlayer(playerItem: playerItem)
            video.isMuted = true
            video.play()
            player = video
        }
        .onDisappear { player?.pause() }
    }
}

/// What a swipe leaves selected: the range it crossed is set, everything outside stays as it was before the swipe.
func swipeSelection(base: Set<String>, ids: [String], anchor: Int, current: Int, selecting: Bool) -> Set<String> {
    let low: Int = Swift.min(anchor, current), high: Int = Swift.max(anchor, current)
    let range = Set(ids[low...high])
    return selecting ? base.union(range) : base.subtracting(range)
}

/// Which way to scroll while a swipe holds near the top or bottom of the screen: -1 up, 1 down, 0 not at all.
/// The bottom zone is taller because the footer and tab bar cover that part.
func edgeDirection(y: CGFloat, height: CGFloat) -> Int {
    y < 130 ? -1 : y > height - 210 ? 1 : 0
}

/// Keeps a picture the same size on screen while the grid swaps to the column count closest to it,
/// so a pinch feels continuous. Returns the columns to show and the scale still left to apply.
func zoomStep(columns: Int, scale: CGFloat) -> (columns: Int, scale: CGFloat) {
    let share = scale / CGFloat(columns)
    let ideal = Int((1 / share).rounded())
    let next = Swift.min(Swift.max(ideal, PhotoGrid.columnRange.lowerBound), PhotoGrid.columnRange.upperBound)
    return (next, Swift.min(Swift.max(share * CGFloat(next), 0.78), 1.3))
}

private struct CellFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

private struct CellFrameReader: View {
    let id: String
    var body: some View {
        GeometryReader { geometry in
            let frame: CGRect = geometry.frame(in: .named("photoGrid"))
            Color.clear.preference(key: CellFrames.self, value: [id: frame])
        }
    }
}

/// Selection that behaves like Photos: tap to select, swipe across to select many, pinch to resize smoothly, hold to see it large.
struct PhotoGrid: View {
    static let columnRange = 1...7
    let groups: [CleanupGroup]
    @Binding var selection: Set<String>
    @Binding var columnCount: Int
    var protect: ((PhotoItem) -> Void)? = nil
    @State private var frames: [String: CGRect] = [:]
    @State private var liveScale: CGFloat = 1
    @State private var lastMagnification: CGFloat = 1
    @State private var zoomAnchor = UnitPoint.center
    @State private var anchorID: String?
    @State private var swipe: (anchor: Int, selecting: Bool, base: Set<String>)?
    @State private var locked = false
    @State private var swipeCurrent = 0
    @State private var fingerY: CGFloat = 0
    @State private var gridTop: CGFloat = 0
    @State private var edgeScroll: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ids: [String] { groups.flatMap(\.items).map(\.id) }
    /// In steps, so resizing doesn't reload every picture at each column.
    private var side: CGFloat { columnCount == 1 ? 1400 : columnCount == 2 ? 800 : 360 }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 2) {
                ForEach(groups) { group in
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount), spacing: 2) {
                        if let keep = group.keep { PhotoCell(item: keep, state: .keeps, side: side, whole: columnCount == 1).id(keep.id) }
                        ForEach(group.items) { item in
                            PhotoCell(item: item, state: selection.contains(item.id) ? .selected : .available, side: side, whole: columnCount == 1, showsSize: columnCount <= 4) {
                                if !selection.insert(item.id).inserted { selection.remove(item.id) }
                            } protect: { protect?(item) }
                            .id(item.id)
                            .background(CellFrameReader(id: item.id))
                        }
                    }
                }
            }
            .coordinateSpace(.named("photoGrid"))
            .onPreferenceChange(CellFrames.self) { frames = $0 }
            .scaleEffect(liveScale, anchor: zoomAnchor)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { gridTop = $0 }
            .simultaneousGesture(swipeGesture(proxy))
            .simultaneousGesture(pinchGesture(proxy))
            .scrollDisabled(locked)
            .accessibilityAction(named: "Bigger pictures") { columnCount = Swift.max(columnCount - 1, Self.columnRange.lowerBound) }
            .accessibilityAction(named: "Smaller pictures") { columnCount = Swift.min(columnCount + 1, Self.columnRange.upperBound) }
        }
    }

    /// A swipe that starts sideways selects. One that starts up or down is left to scroll, as in Photos.
    private func swipeGesture(_ proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .named("photoGrid"))
            .onChanged { drag in
                if swipe == nil {
                    guard abs(drag.translation.width) > abs(drag.translation.height), let anchor = index(at: drag.startLocation) else { return }
                    swipe = (anchor, !selection.contains(ids[anchor]), selection)
                    swipeCurrent = anchor
                    locked = true
                    startEdgeScroll(proxy)
                }
                fingerY = gridTop + drag.location.y
                guard let swipe, let current = index(at: drag.location) else { return }
                swipeCurrent = current
                selection = swipeSelection(base: swipe.base, ids: ids, anchor: swipe.anchor, current: current, selecting: swipe.selecting)
            }
            .onEnded { _ in
                swipe = nil
                locked = false
                edgeScroll?.cancel()
            }
    }

    /// While a swipe holds at the screen's edge, moves a row at a time and keeps selecting, because the finger has nowhere further to go.
    private func startEdgeScroll(_ proxy: ScrollViewProxy) {
        edgeScroll?.cancel()
        edgeScroll = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(140))
                guard let swipe, !Task.isCancelled else { return }
                let direction = edgeDirection(y: fingerY, height: UIScreen.main.bounds.height)
                let all = ids
                let next = Swift.min(Swift.max(swipeCurrent + direction * columnCount, 0), all.count - 1)
                guard direction != 0, next != swipeCurrent else { continue }
                swipeCurrent = next
                selection = swipeSelection(base: swipe.base, ids: all, anchor: swipe.anchor, current: next, selecting: swipe.selecting)
                if reduceMotion {
                    proxy.scrollTo(all[next], anchor: direction > 0 ? .bottom : .top)
                } else {
                    withAnimation(.linear(duration: 0.14)) { proxy.scrollTo(all[next], anchor: direction > 0 ? .bottom : .top) }
                }
            }
        }
    }

    /// The pictures follow the fingers exactly. When they get close to another column count the grid changes
    /// underneath at the same visual size, with no animation, so nothing jumps. Letting go settles it.
    private func pinchGesture(_ proxy: ScrollViewProxy) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0)
            .onChanged { value in
                if lastMagnification == 1 && liveScale == 1 {
                    zoomAnchor = value.startAnchor
                    anchorID = frames.first { $0.value.contains(value.startLocation) }?.key
                }
                let total = liveScale * value.magnification / lastMagnification
                lastMagnification = value.magnification
                let step = zoomStep(columns: columnCount, scale: total)
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) {
                    if step.columns != columnCount {
                        columnCount = step.columns
                        if let anchorID { proxy.scrollTo(anchorID, anchor: zoomAnchor) }
                    }
                    liveScale = step.scale
                }
            }
            .onEnded { _ in
                lastMagnification = 1
                if reduceMotion { liveScale = 1 } else { withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { liveScale = 1 } }
            }
    }

    private func index(at point: CGPoint) -> Int? {
        guard let hit = frames.first(where: { $0.value.contains(point) })?.key else { return nil }
        return ids.firstIndex(of: hit)
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
    @State private var total = 0
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
        .orbFooter(summary: running ? Text("\(progress) of \(total)") : selection.isEmpty ? nil : Text("^[\(selection.count) video](inflect: true)")) {
            OrbAction(title: "Compress", icon: "arrow.down.right.and.arrow.up.left", accent: StewardTheme.files.vivid, disabled: selection.isEmpty || running) { Task { await run() } }
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
        total = selection.count
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
    @State private var columns = 3

    private var items: [PhotoItem] { library.items(.livePhotos) }

    var body: some View {
        PhotoPage(theme: .cleanup, title: "Turn off Live Photos", columns: $columns) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Keeps the photo with its date and place, and removes the short video. Sizes show what you'd save.").font(.subheadline)
                if items.isEmpty { GlassCard { Text(library.phase == .idle ? "Press Scan first to find your Live Photos." : "No Live Photos found.") } }
                if let result { GlassCard { Text(result) } }
            }
        } grid: {
            PhotoGrid(groups: items.isEmpty ? [] : [CleanupGroup(items: items)], selection: $selection, columnCount: $columns)
        }
        .toolbar { Button(selection.count == items.count ? "Select None" : "Select All") { selection = selection.count == items.count ? [] : Set(items.map(\.id)) } }
        .orbFooter(summary: selection.isEmpty ? nil : Text("^[\(selection.count) photo](inflect: true)")) {
            OrbAction(title: "Convert", icon: "livephoto.slash", accent: StewardTheme.cleanup.vivid, disabled: selection.isEmpty || running, progress: running ? nil : nil) { Task { await run() } }
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
