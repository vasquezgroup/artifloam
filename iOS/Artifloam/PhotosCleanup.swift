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
    /// Rebuilt only when the lists change. Doing it on every update made zooming and selecting slow on long lists.
    @State private var liveGroups: [CleanupGroup] = []
    @State private var items: [PhotoItem] = []

    private func rebuild() {
        liveGroups = (category.flatMap { library.results[$0] } ?? groups).map { CleanupGroup(keep: $0.keep, items: $0.items.filter { !dropped.contains($0.id) }) }.filter { !$0.items.isEmpty }
        items = liveGroups.flatMap(\.items)
    }
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
        .onAppear {
            rebuild()
            if preselected && !didPreselect { selection = Set(items.map(\.id)); didPreselect = true }
        }
        .onChange(of: library.resultsVersion) { _, _ in rebuild() }
        .onChange(of: dropped) { _, _ in rebuild() }
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
    @State private var zoom = GridZoom()

    /// While pinching this follows the fingers, so the bars come and go during the gesture rather than after it.
    private var fullScreen: Bool { zoom.active ? darkness > 0.5 : columns <= 2 }
    /// How far the background has gone dark while pinching towards large pictures.
    private var darkness: Double {
        guard zoom.active, zoom.width > 0 else { return fullScreen ? 1 : 0 }
        let (from, to, progress) = ZoomLevels.between(side: zoom.side, width: zoom.width)
        if to > 2 { return 0 }
        return from <= 2 ? 1 : Double(progress)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AtmosphereView(theme: theme)
            Color.black.ignoresSafeArea().opacity(darkness)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !fullScreen { header.padding(.horizontal, 16).transition(.opacity) }
                    // The page's fade is for what's around the pictures. Animating the grid's layout too made cells overlap mid-zoom.
                    grid.animation(nil, value: fullScreen)
                }
            }
            .ignoresSafeArea(.container, edges: fullScreen ? [.top, .horizontal] : .horizontal)
            .opacity(zoom.active ? 0 : 1)
            .scrollDisabled(zoom.active)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { zoom.viewport = $0 }
            if zoom.active { ZoomCanvas(zoom: zoom, side: zoom.side).ignoresSafeArea() }
            if fullScreen {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.backward").font(.body.weight(.semibold)).foregroundStyle(.white).frame(width: 40, height: 40).background(.ultraThinMaterial, in: .circle)
                }
                .accessibilityLabel("Back").padding(.leading, 14).padding(.top, 6).transition(.opacity)
            }
        }
        .environment(zoom)
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

struct PhotoCell: View, Equatable {
    /// Only what's drawn. So selecting one picture doesn't redo every other one on screen.
    static func == (a: PhotoCell, b: PhotoCell) -> Bool {
        a.item.id == b.item.id && a.state == b.state && a.side == b.side && a.whole == b.whole && a.showsSize == b.showsSize && (a.protect == nil) == (b.protect == nil)
    }
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
                .overlay {
                    // Pictures fade in as they arrive, instead of popping.
                    if let picture = image ?? Thumbnails.cached(item.id) { Image(uiImage: picture).resizable().scaledToFill().transition(.opacity) }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: image == nil)
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
                            // A dark disc instead of a shadow, which costs an extra drawing pass for every picture on screen.
                            .font(.title3).foregroundStyle(selected ? StewardTheme.care.vivid : .white).background { Circle().fill(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.black.opacity(0.22))).padding(selected ? 3 : 1) }
                            .padding(4)
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
        .task(id: "\(item.id)-\(Int(side))") {
            await Thumbnails.load(item.asset, id: item.id, side: side) { image = $0 }
        }
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
            await Thumbnails.load(asset, id: asset.localIdentifier, side: 1200) { image = $0 }
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

/// Where cells are, for finding what's under a finger. Not SwiftUI state: updating state from every cell redid the whole grid constantly.
private final class GridLayout {
    var frames: [String: CGRect] = [:]
    private(set) var ids: [String] = []
    private var positions: [String: Int] = [:]

    func use(_ groups: [CleanupGroup]) {
        let all = groups.flatMap(\.items).map(\.id)
        guard all != ids else { return }
        ids = all
        positions = Dictionary(all.enumerated().map { ($1, $0) }) { first, _ in first }
    }
    func index(at point: CGPoint) -> Int? {
        frames.first { $0.value.contains(point) }.flatMap { positions[$0.key] }
    }
}

/// Selection that behaves like Photos: tap to select, swipe across to select many, pinch to resize smoothly, hold to see it large.
struct PhotoGrid: View {
    let groups: [CleanupGroup]
    @Binding var selection: Set<String>
    @Binding var columnCount: Int
    var protect: ((PhotoItem) -> Void)? = nil
    @State private var layout = GridLayout()
    @Environment(GridZoom.self) private var zoom
    @State private var swipe: (anchor: Int, selecting: Bool, base: Set<String>)?
    @State private var locked = false
    @State private var swipeCurrent = 0
    @State private var fingerY: CGFloat = 0
    @State private var gridTop: CGFloat = 0
    @State private var edgeScroll: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// In steps, so resizing doesn't reload every picture at each column.
    private var side: CGFloat { columnCount == 1 ? 1400 : columnCount == 2 ? 800 : columnCount <= 4 ? 360 : 200 }

    var body: some View {
        ScrollViewReader { proxy in
            // Lazy here as well: one list of similar photos can hold over a thousand small groups.
            LazyVStack(spacing: 2) {
                ForEach(groups) { group in
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount), spacing: 2) {
                        if let keep = group.keep {
                            PhotoCell(item: keep, state: .keeps, side: side, whole: columnCount == 1).equatable().id(keep.id)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("photoGrid")) } action: { layout.frames[keep.id] = $0 }
                        }
                        ForEach(group.items) { item in
                            PhotoCell(item: item, state: selection.contains(item.id) ? .selected : .available, side: side, whole: columnCount == 1, showsSize: columnCount <= 4) {
                                if !selection.insert(item.id).inserted { selection.remove(item.id) }
                            } protect: { protect?(item) }
                            .equatable()
                            .id(item.id)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("photoGrid")) } action: { layout.frames[item.id] = $0 }
                        }
                    }
                }
            }
            .coordinateSpace(.named("photoGrid"))
            .onAppear { layout.use(groups) }
            .onChange(of: groups.count) { _, _ in layout.use(groups) }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                gridTop = $0
                // The page opens scrolled to the top, so the first reading is where the grid rests.
                if zoom.restTop == nil, columnCount > 2 { zoom.restTop = $0 }
            }
            .simultaneousGesture(swipeGesture(proxy))
            .simultaneousGesture(pinchGesture(proxy))
            .scrollDisabled(locked)
            .accessibilityAction(named: "Bigger pictures") { columnCount = ZoomLevels.columns.last { $0 < columnCount } ?? columnCount }
            .accessibilityAction(named: "Smaller pictures") { columnCount = ZoomLevels.columns.first { $0 > columnCount } ?? columnCount }
        }
    }

    /// A swipe that starts sideways selects. One that starts up or down is left to scroll, as in Photos.
    private func swipeGesture(_ proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .named("photoGrid"))
            .onChanged { drag in
                // A pinch is two fingers, and either one alone looks like a swipe. It must never select anything.
                guard !zoom.active else { return }
                if swipe == nil {
                    layout.use(groups)
                    guard abs(drag.translation.width) > abs(drag.translation.height), let anchor = layout.index(at: drag.startLocation) else { return }
                    swipe = (anchor, !selection.contains(layout.ids[anchor]), selection)
                    swipeCurrent = anchor
                    locked = true
                    startEdgeScroll(proxy)
                }
                fingerY = gridTop + drag.location.y
                guard let swipe, let current = layout.index(at: drag.location), current != swipeCurrent else { return }
                swipeCurrent = current
                selection = swipeSelection(base: swipe.base, ids: layout.ids, anchor: swipe.anchor, current: current, selecting: swipe.selecting)
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
                let all = layout.ids
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

    /// The pictures follow the fingers exactly, on a drawing over the grid. Letting go settles it on the nearest size,
    /// and the real grid takes over underneath at the same place, so nothing jumps.
    private func pinchGesture(_ proxy: ScrollViewProxy) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0)
            .onChanged { value in
                if !zoom.active {
                    // A swipe may have started in the moment before the second finger landed. Undo what it selected.
                    if let swipe { selection = swipe.base }
                    swipe = nil
                    locked = false
                    edgeScroll?.cancel()
                    let point = value.startLocation
                    guard let hit = layout.frames.first(where: { $0.value.contains(point) }) ?? layout.frames.min(by: { distance($0.value, point) < distance($1.value, point) }) else { return }
                    let global = hit.value.offsetBy(dx: 0, dy: gridTop)
                    zoom.begin(groups: groups, columns: columnCount, finger: CGPoint(x: point.x, y: point.y + gridTop), anchorID: hit.key, anchorFrame: global, width: zoom.viewport.width, selection: selection)
                }
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) { zoom.side = ZoomLevels.resisted(side: zoom.startSide * value.magnification, width: zoom.width) }
            }
            .onEnded { _ in
                guard zoom.active else { return }
                let target = ZoomLevels.nearest(side: zoom.side, width: zoom.width)
                let settled = target == 1 ? zoom.width : ZoomLevels.side(columns: target, width: zoom.width)
                if reduceMotion {
                    zoom.side = settled
                    takeOver(target, proxy)
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { zoom.side = settled } completion: { takeOver(target, proxy) }
                }
            }
    }

    private func distance(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        hypot(frame.midX - point.x, frame.midY - point.y)
    }

    /// Puts the real grid exactly under the drawing, then removes the drawing.
    private func takeOver(_ columns: Int, _ proxy: ScrollViewProxy) {
        guard let anchor = zoom.anchorID else { selection = zoom.selection; zoom.end(); return }
        let place = zoom.settledTop(columns)
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { columnCount = columns }
        Task { @MainActor in
            // Once for the new columns, and again for the page's bars, which come and go with large pictures.
            try? await Task.sleep(for: .milliseconds(30))
            @MainActor func align() {
                let room = zoom.viewport.height - place.height
                let share = room != 0 ? (place.top - zoom.viewport.minY) / room : 0
                withTransaction(quiet) { proxy.scrollTo(anchor, anchor: UnitPoint(x: 0.5, y: share)) }
            }
            align()
            try? await Task.sleep(for: .milliseconds(60))
            align()
            try? await Task.sleep(for: .milliseconds(30))
            // Lifting a finger can count as a tap on the picture under it. A pinch never changes what's selected.
            selection = zoom.selection
            withTransaction(quiet) { zoom.end() }
        }
    }
}

/// Shows what Photos has at hand straight away, then the sharper version. Stops asking when a picture leaves the screen.
enum Thumbnails {
    /// The sharpest seen so far of each picture, so nothing goes blank while zooming or scrolling back.
    private static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 150_000_000
        return cache
    }()
    private static let manager = PHCachingImageManager()

    static func cached(_ id: String) -> UIImage? { memory.object(forKey: id as NSString) }

    static func load(_ asset: PHAsset, id: String, side: CGFloat, onImage: @escaping @MainActor (UIImage) -> Void) async {
        if let known = cached(id), max(known.size.width, known.size.height) * known.scale >= side { await onImage(known); return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        // Only a picture shown large is worth a download. Small ones use what's on the iPhone.
        options.isNetworkAccessAllowed = side >= 800
        let request = RequestBox()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                request.begin(continuation) {
                    manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: options) { image, info in
                        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                        if let image {
                            if !degraded { memory.setObject(image, forKey: id as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4)) }
                            Task { @MainActor in onImage(image) }
                        }
                        if !degraded { request.finish() }
                    }
                }
            }
        } onCancel: {
            request.cancel(manager)
        }
    }

    /// Photos calls back more than once and may not call back after a cancel, but the waiting code must resume exactly once.
    private final class RequestBox: @unchecked Sendable {
        private var id: PHImageRequestID?
        private var continuation: CheckedContinuation<Void, Never>?
        private var cancelled = false
        private let lock = NSLock()

        func begin(_ waiting: CheckedContinuation<Void, Never>, request: () -> PHImageRequestID) {
            lock.lock()
            if cancelled { lock.unlock(); waiting.resume(); return }
            continuation = waiting
            lock.unlock()
            let started = request()
            lock.lock(); id = started; lock.unlock()
        }
        func finish() {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume()
        }
        func cancel(_ manager: PHImageManager) {
            lock.lock()
            cancelled = true
            let started = id
            lock.unlock()
            if let started { manager.cancelImageRequest(started) }
            finish()
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
                .task(id: item.id) { image = nil; await Thumbnails.load(item.asset, id: item.id, side: 900) { image = $0 } }
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
