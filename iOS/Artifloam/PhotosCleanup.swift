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
        StagePage(theme: section.theme, title: section.title, subtitle: section.subtitle, moving: library.working, orb: AnyView(ScanOrb(theme: section.theme)), summary: library.scanSummary) {
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
    @State private var saved: Saving?
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
                Label("Tap a photo to see it. Tap the circle to choose it.", systemImage: "hand.tap").font(.footnote.weight(.medium))
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
                let bytes = selectedBytes
                Task {
                    if await library.delete(chosen) {
                        dropped.formUnion(chosen)
                        selection = []
                        saved = Saving(before: bytes, count: chosen.count)
                    }
                }
            }
        }
        .savedStage($saved, theme: theme, note: "Moved to Recently Deleted. The space comes back when iOS empties it after about 30 days, or when you empty it in Photos.", detail: { Text("^[\($0.count) item](inflect: true)") }) {
            if items.isEmpty { dismiss() }
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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var zoom = GridZoom()

    /// While pinching this follows the fingers, so the bars come and go during the gesture rather than after it.
    private var fullScreen: Bool { zoom.active ? darkness > 0.5 : ZoomLevels.large(columns, width: zoom.viewport.width) }
    /// How far the background has gone dark while pinching towards large pictures.
    private var darkness: Double {
        guard zoom.active, zoom.width > 0 else { return fullScreen ? 1 : 0 }
        let (from, to, progress) = ZoomLevels.between(side: zoom.side, width: zoom.width)
        if !ZoomLevels.large(to, width: zoom.width) { return 0 }
        return ZoomLevels.large(from, width: zoom.width) ? 1 : Double(progress)
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
            // Sides stay inside the safe area, so an iPad's sidebar never covers pictures.
            .ignoresSafeArea(.container, edges: fullScreen ? .top : [])
            .opacity(zoom.active ? 0 : 1)
            .scrollDisabled(zoom.active)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                // Turning, unfolding or resizing keeps the pictures about the same size, with more or fewer columns.
                if frame.width != zoom.viewport.width { columns = ZoomLevels.fitted(columns, from: zoom.viewport.width, to: frame.width) }
                zoom.viewport = frame
            }
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
        // iPhone only. On iPad, the bar with the tabs didn't always move back below the status bar once it returned, so they overlapped.
        .statusBarHidden(fullScreen && sizeClass == .compact)
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
    /// A tap on the picture opens it. Without this, the tap chooses it instead, as on pages that only list pictures.
    var open: (() -> Void)? = nil
    var toggle: () -> Void = {}
    var protect: (() -> Void)? = nil
    @State private var image: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: Bool { state == .selected }

    var body: some View {
        Group {
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
                    if state != .picture && showsSize { Text(state == .keeps ? String(app: "Stays") : formatted(item.saving)).font(.caption2.bold()).foregroundStyle(.white).padding(4)
                        .background(state == .keeps ? AnyShapeStyle(StewardTheme.cleanup.vivid) : AnyShapeStyle(.black.opacity(0.6)), in: .rect(cornerRadius: 4)).padding(4) }
                }
                .overlay(alignment: .topTrailing) {
                    if state == .available || state == .selected {
                        // The circle chooses. Its tap area is far bigger than it looks, so it's easy to hit.
                        Button(action: toggle) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .contentTransition(.symbolEffect(.replace))
                                .symbolEffect(.bounce, value: selected)
                                // A dark disc instead of a shadow, which costs an extra drawing pass for every picture on screen.
                                .font(.title3).foregroundStyle(selected ? StewardTheme.care.vivid : .white).background { Circle().fill(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.black.opacity(0.22))).padding(selected ? 3 : 1) }
                                .padding(4)
                                .frame(minWidth: 48, minHeight: 48, alignment: .topTrailing)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(selected ? Text("Deselect") : Text("Select"))
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.58), value: selected)
        }
        .contentShape(Rectangle())
        .onTapGesture { if let open { open() } else { toggle() } }
        .allowsHitTesting(state == .available || state == .selected || open != nil)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(open == nil ? Text("Chooses it") : Text("Opens it"))
        .accessibilityAction(named: "Select") { toggle() }
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
        let kind = item.asset.mediaType == .video ? String(app: "Video") : String(app: "Photo")
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
            if asset.mediaSubtypes.contains(.photoLive) { LivePhotoView(asset: asset, autoplay: true) }
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

/// A drag selects only if it starts sideways, on the screen. Decided once, at the start, as in Photos.
func swipeStarts(_ translation: CGSize) -> Bool {
    abs(translation.width) > abs(translation.height)
}

/// Where cells are, for finding what's under a finger. Not SwiftUI state: updating state from every cell redid the whole grid constantly.
private final class GridLayout {
    var frames: [String: CGRect] = [:]
    /// Where the grid is on screen. Changes on every frame of a scroll, so not state either: that redrew the grid the whole time.
    var origin = CGPoint.zero
    /// The current drag started up or down, so it stays a scroll even if the thumb drifts sideways.
    var scrolling = false
    private(set) var ids: [String] = []
    private var positions: [String: Int] = [:]

    func use(_ groups: [CleanupGroup]) {
        let all = groups.flatMap(\.items).map(\.id)
        guard all != ids else { return }
        ids = all
        positions = Dictionary(all.enumerated().map { ($1, $0) }) { first, _ in first }
        // Deleted pictures leave their old place behind. Finding one of those first stopped swipes from starting after a delete.
        frames = frames.filter { positions[$0.key] != nil }
    }
    func index(atScreen point: CGPoint) -> Int? { index(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y)) }
    func index(at point: CGPoint) -> Int? {
        frames.first { positions[$0.key] != nil && $0.value.contains(point) }.flatMap { positions[$0.key] }
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
    @State private var viewing: ViewerStart?
    private struct ViewerStart: Identifiable { let id: String }
    @State private var swipe: (anchor: Int, selecting: Bool, base: Set<String>)?
    @State private var locked = false
    @State private var swipeCurrent = 0
    @State private var fingerY: CGFloat = 0
    @GestureState private var dragging = false
    @State private var edgeScroll: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// In steps, so resizing doesn't reload every picture at each column.
    /// Pixels to ask for, from how big a cell is on screen, so a wide iPad grid doesn't ask for more than it shows.
    /// One picture's width in points.
    private var cellWidth: CGFloat { (zoom.viewport.width > 0 ? zoom.viewport.width : 402) / CGFloat(columnCount) }
    private var side: CGFloat {
        let cell = cellWidth
        return cell > 300 ? 1400 : cell > 170 ? 800 : cell > 100 ? 360 : 200
    }

    var body: some View {
        ScrollViewReader { proxy in
            // Lazy here as well: one list of similar photos can hold over a thousand small groups.
            LazyVStack(spacing: 2) {
                ForEach(groups) { group in
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount), spacing: 2) {
                        if let keep = group.keep {
                            PhotoCell(item: keep, state: .keeps, side: side, whole: columnCount == 1, open: { open(keep.id) }).equatable().id(keep.id)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("photoGrid")) } action: { layout.frames[keep.id] = $0 }
                        }
                        ForEach(group.items) { item in
                            PhotoCell(item: item, state: selection.contains(item.id) ? .selected : .available, side: side, whole: columnCount == 1, showsSize: cellWidth >= 70, open: { open(item.id) }) {
                                guard !Fingers.multiTouch else { return }
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
            .background(FingerWatcherInstaller())
            .fullScreenCover(item: $viewing) { start in
                PhotoViewer(items: groups.flatMap { ($0.keep.map { [$0] } ?? []) + $0.items }, keeps: Set(groups.compactMap(\.keep?.id)), selection: $selection, start: start.id)
            }
            .onAppear { layout.use(groups) }
            .onChange(of: groups.reduce(0) { $0 + $1.items.count }) { _, _ in layout.use(groups) }
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: {
                layout.origin = $0
                // The page opens scrolled to the top, so the first reading is where the grid rests.
                if zoom.restTop == nil, columnCount > 2 { zoom.restTop = $0.y }
            }
            .simultaneousGesture(swipeGesture(proxy))
            // Runs when a drag ends and also when it's cancelled, which skips onEnded and once left scrolling switched off.
            .onChange(of: dragging) { _, now in
                guard !now else { return }
                layout.scrolling = false
                swipe = nil
                locked = false
                edgeScroll?.cancel()
            }
            .simultaneousGesture(pinchGesture(proxy))
            .scrollDisabled(locked)
            .accessibilityAction(named: "Bigger pictures") { columnCount = ZoomLevels.columns(zoom.viewport.width).last { $0 < columnCount } ?? columnCount }
            .accessibilityAction(named: "Smaller pictures") { columnCount = ZoomLevels.columns(zoom.viewport.width).first { $0 > columnCount } ?? columnCount }
        }
    }

    /// A swipe that starts sideways selects. One that starts up or down is left to scroll, as in Photos.
    private func swipeGesture(_ proxy: ScrollViewProxy) -> some Gesture {
        // Measured on the screen. In the grid's own space the pictures move with the finger while scrolling,
        // so a scroll barely moved at all there, a little sideways drift looked like a swipe, and it stopped the scroll.
        DragGesture(minimumDistance: 14, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { drag in
                // A pinch is two fingers, and either one alone looks like a swipe. It must never select anything.
                guard !zoom.active, !Fingers.multiTouch else {
                    cancelSwipe()
                    return
                }
                if layout.scrolling { return }
                if swipe == nil {
                    layout.use(groups)
                    guard swipeStarts(drag.translation), let anchor = layout.index(atScreen: drag.startLocation) else {
                        layout.scrolling = true
                        return
                    }
                    swipe = (anchor, !selection.contains(layout.ids[anchor]), selection)
                    swipeCurrent = anchor
                    locked = true
                    startEdgeScroll(proxy)
                }
                fingerY = drag.location.y
                guard let swipe, let current = layout.index(atScreen: drag.location), current != swipeCurrent else { return }
                swipeCurrent = current
                selection = swipeSelection(base: swipe.base, ids: layout.ids, anchor: swipe.anchor, current: current, selecting: swipe.selecting)
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
                    let before = swipe?.base ?? selection
                    cancelSwipe()
                    let point = value.startLocation
                    guard let hit = layout.frames.first(where: { $0.value.contains(point) }) ?? layout.frames.min(by: { distance($0.value, point) < distance($1.value, point) }) else { return }
                    let global = hit.value.offsetBy(dx: 0, dy: layout.origin.y)
                    zoom.begin(groups: groups, columns: columnCount, finger: CGPoint(x: point.x, y: point.y + layout.origin.y), anchorID: hit.key, anchorFrame: global, width: zoom.viewport.width, selection: before)
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

    private func open(_ id: String) {
        guard !Fingers.multiTouch, !zoom.active else { return }
        viewing = ViewerStart(id: id)
    }

    /// A swipe may have started in the moment before the second finger landed. This undoes what it selected.
    private func cancelSwipe() {
        if let swipe { selection = swipe.base }
        swipe = nil
        locked = false
        edgeScroll?.cancel()
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
    @State private var saved: Saving?
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
                    let chosen = Set(marked)
                    let bytes = items.filter { chosen.contains($0.id) }.reduce(0) { $0 + $1.bytes }
                    Task { if await library.delete(chosen) { saved = Saving(before: bytes, count: chosen.count) } }
                } label: {
                    Text("Delete \(marked.count) now").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .savedStage($saved, theme: theme, note: "Moved to Recently Deleted. The space comes back when iOS empties it after about 30 days, or when you empty it in Photos.", detail: { Text("^[\($0.count) item](inflect: true)") }) { dismiss() }
    }

    private func decide(delete: Bool) {
        guard index < items.count else { return }
        if delete { marked.append(items[index].id) }
        index += 1
    }
}

struct CompressView: View {
    @Environment(Library.self) private var library
    @State private var selection: Set<String> = []
    @State private var running = false
    @State private var staged = false
    @State private var progress = 0
    @State private var total = 0
    @State private var fraction = 0.0
    @State private var result: LocalizedStringKey?
    @State private var saving: Saving?
    @State private var failure: String?
    /// Compressed, with their originals still there until the person says to delete them.
    @State private var originals: Set<String> = []
    @State private var sizes = Saving()
    @State private var columns = 3
    @State private var work: Task<Void, Never>?
    @State private var step = MediaChanges.Step.compressing
    /// How far each video has come down from iCloud, by its place in the run. Only those that needed it are here.
    @State private var downloads: [Int: Double] = [:]
    @State private var currentBytes: Int64 = 0
    /// iOS lets it carry on after the person leaves the app.
    @State private var background = false

    private var videos: [PhotoItem] { library.items(.largeVideos) }

    var body: some View {
        PhotoPage(theme: .files, title: "Compress videos", columns: $columns) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Makes a smaller copy with the same date and place, then asks to remove the original. If the saving is under 10%, the video is left as it is. Quality can drop slightly, and videos over 1080p become 1080p.").font(.subheadline)
                if videos.isEmpty { GlassCard { Text("No large videos found.") } }
                if let result { GlassCard { Text(result) } }
            }
        } grid: {
            // The same grid as every photo list: tap to watch, tap the circle to choose, pinch to resize.
            PhotoGrid(groups: videos.isEmpty ? [] : [CleanupGroup(items: videos)], selection: $selection, columnCount: $columns)
        }
        .toolbar { Button(selection.count == videos.count ? "Select None" : "Select All") { selection = selection.count == videos.count ? [] : Set(videos.map(\.id)) } }
        .orbFooter(summary: selection.isEmpty ? nil : Text("^[\(selection.count) video](inflect: true)")) {
            OrbAction(title: "Compress", icon: "arrow.down.right.and.arrow.up.left", accent: StewardTheme.files.vivid, disabled: selection.isEmpty || running) { work = Task { await run() } }
        }
        .fullScreenCover(isPresented: $staged) {
            let ready = !running && !originals.isEmpty
            WorkStage(theme: .files, title: running ? "Compressing videos…" : ready ? "Your smaller videos are ready" : failure != nil ? "Couldn't compress" : "All done",
                      detail: running ? Text("\(progress) of \(total)") + Text(verbatim: " · " + formatted(currentBytes)) : outcome(ready ? Text("^[\(originals.count) video](inflect: true)") : saving.map { Text("^[\($0.count) video](inflect: true)") } ?? result.map { Text($0) }, failure),
                      fraction: fraction, saving: saving, note: stageNote(running: running, background: background, ready: ready, saved: saving != nil),
                      choice: ready ? StageChoice(title: "Delete originals", action: { Task { await removeOriginals() } }, skip: "Keep both") {
                          originals = []
                          result = "Kept your originals as well as the smaller copies. Nothing was removed."
                          Task { await library.scan() }
                      } : nil,
                      // A video only in iCloud comes down first, which can take a while, so that gets its own line.
                      status: step == .downloading ? Text("Downloading from iCloud…") + Text(verbatim: " ") + Text(downloads[progress - 1] ?? 0, format: .percent.precision(.fractionLength(0))) : nil,
                      stop: { work?.cancel() },
                      done: running || ready ? nil : { staged = false; failure = nil })
        }
    }

    private func run() async {
        running = true
        staged = true
        result = nil
        saving = nil
        progress = 0
        fraction = 0
        downloads = [:]
        let picked = videos.filter { selection.contains($0.id) }
        total = picked.count
        background = BackgroundWork.shared.begin(title: String(localized: "Compressing videos…"), subtitle: String(localized: "\(1) of \(total)")) { work?.cancel() }
        var done: Set<String> = []
        var sizes = Saving()
        var skipped = 0
        // The next video downloads from iCloud while this one compresses, so the two waits overlap instead of adding up.
        var next: Task<AVAsset, Error>? = picked.isEmpty ? nil : fetch(picked, 0)
        for (index, item) in picked.enumerated() {
            guard !Task.isCancelled, let current = next else { break }
            next = index + 1 < picked.count ? fetch(picked, index + 1) : nil
            progress = index + 1
            currentBytes = item.bytes
            // Waiting for the original means it's still coming down. One already on the phone passes in a moment.
            step = .downloading
            show(index, exported: nil)
            do {
                let original = try await withTaskCancellationHandler { try await current.value } onCancel: { current.cancel() }
                step = .compressing
                let compressed = try await MediaChanges.compress(item, original: original) { now, value in
                    if now == .compressing { show(index, exported: value) }
                }
                if let bytes = compressed {
                    done.insert(item.id)
                    sizes.before += item.bytes
                    sizes.after += bytes
                    sizes.count += 1
                } else {
                    skipped += 1
                }
            } catch {
                // Stopping isn't a failure. What's done so far stays, and goes on to the choice.
                if !Task.isCancelled { failure = error.localizedDescription }
                break
            }
        }
        next?.cancel()
        running = false
        BackgroundWork.shared.end(success: !Task.isCancelled && failure == nil)
        // Stopped before anything was made: nothing to show, and the choice stays ticked to start again.
        if Task.isCancelled && done.isEmpty { staged = false; return }
        fraction = 1
        selection = []
        if done.isEmpty { result = skipped > 0 ? "The saving would be too small, so nothing changed." : nil }
        originals = done
        self.sizes = sizes
    }

    private func fetch(_ picked: [PhotoItem], _ index: Int) -> Task<AVAsset, Error> {
        Task {
            try await MediaChanges.original(picked[index].asset) { value in
                downloads[index] = value
                if progress == index + 1 && step == .downloading { show(index, exported: nil) }
            }
        }
    }

    /// One bar for the whole run. A video that came from iCloud gives its first 30% to the download,
    /// so the bar, and iOS's own progress, keep moving while it comes down.
    private func show(_ index: Int, exported: Double?) {
        let fetched = downloads[index]
        let share = exported.map { fetched == nil ? $0 : 0.3 + 0.7 * $0 } ?? 0.3 * (fetched ?? 0)
        fraction = (Double(index) + share) / Double(max(total, 1))
        BackgroundWork.shared.update(fraction, subtitle: String(localized: "\(index + 1) of \(total)"))
    }

    /// Only when asked, so iOS's Delete prompt comes after the explanation, not as a surprise.
    /// Cancelling it leaves the choice on screen.
    private func removeOriginals() async {
        guard await library.delete(originals) else { return }
        result = "Saved about \(formatted(sizes.before - sizes.after)). Originals are in Recently Deleted."
        saving = sizes
        originals = []
    }
}

/// What a finished stage says: the result, and what went wrong if something did.
private func outcome(_ result: Text?, _ failure: String?) -> Text? {
    switch (result, failure) {
    case let (result?, failure?): result + Text("\n\n") + Text(failure)
    case let (result?, nil): result
    case let (nil, failure?): Text(failure)
    case (nil, nil): nil
    }
}

/// The only way to free the space is to delete the original, and iOS confirms that with its own Delete prompt: this says so first.
/// Apps can't empty Recently Deleted, so afterwards it says where the space is.
private func stageNote(running: Bool, background: Bool, ready: Bool, saved: Bool) -> LocalizedStringKey? {
    // While working, whether leaving the app is safe: only when iOS has agreed to carry on in the background.
    running ? (background ? "You can switch apps. It carries on in the background, and iOS shows how far it is." : "Keep Artifloam open until it's done.")
        : ready ? "Delete the originals to free the space. iOS asks you to confirm, and the new versions stay."
        : saved ? "Moved to Recently Deleted. The space comes back when iOS empties it after about 30 days, or when you empty it in Photos." : nil
}

struct LivePhotosView: View {
    @Environment(Library.self) private var library
    @State private var selection: Set<String> = []
    @State private var running = false
    @State private var staged = false
    @State private var progress = 0
    @State private var total = 0
    @State private var result: LocalizedStringKey?
    @State private var saving: Saving?
    @State private var failure: String?
    @State private var columns = 3
    /// Saved as normal photos, with the Live originals still there until the person says to delete them.
    @State private var originals: Set<String> = []
    @State private var sizes = Saving()
    @State private var work: Task<Void, Never>?
    @State private var background = false

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
            OrbAction(title: "Turn off", icon: "livephoto.slash", accent: StewardTheme.cleanup.vivid, disabled: selection.isEmpty || running) { work = Task { await run() } }
        }
        .fullScreenCover(isPresented: $staged) {
            let ready = !running && !originals.isEmpty
            WorkStage(theme: .cleanup, title: running ? "Turning off Live Photos…" : ready ? "Your normal photos are ready" : failure != nil ? "Couldn't convert" : "All done",
                      detail: running ? Text("\(progress) of \(total)") : outcome(ready ? Text("^[\(originals.count) photo](inflect: true)") : saving.map { Text("^[\($0.count) photo](inflect: true)") } ?? result.map { Text($0) }, failure),
                      fraction: Double(progress) / Double(max(total, 1)), saving: saving, note: stageNote(running: running, background: background, ready: ready, saved: saving != nil),
                      choice: ready ? StageChoice(title: "Delete originals", action: { Task { await removeOriginals() } }, skip: "Keep both") {
                          originals = []
                          result = "You have both versions now. Nothing was removed."
                      } : nil,
                      stop: { work?.cancel() },
                      done: running || ready ? nil : { staged = false; failure = nil })
        }
    }

    private func run() async {
        running = true
        staged = true
        result = nil
        saving = nil
        progress = 0
        let picked = items.filter { selection.contains($0.id) }
        total = picked.count
        background = BackgroundWork.shared.begin(title: String(localized: "Turning off Live Photos…"), subtitle: String(localized: "\(0) of \(total)")) { work?.cancel() }
        var done: Set<String> = []
        var sizes = Saving()
        var waiting: [(item: PhotoItem, file: URL)] = []
        /// Saves the downloaded photos in one change to the library: far faster than one change each.
        func save() async throws {
            guard !waiting.isEmpty else { return }
            defer { for still in waiting { try? FileManager.default.removeItem(at: still.file) }; waiting = [] }
            try await MediaChanges.addStills(waiting)
            for (item, _) in waiting {
                done.insert(item.id)
                // The still keeps the photo. What goes is the short video.
                sizes.before += item.bytes
                sizes.after += item.bytes - item.saving
                sizes.count += 1
            }
        }
        do {
            // A few at once: most of the time goes on waiting for iCloud, and several downloads overlap well.
            try await withThrowingTaskGroup(of: (PhotoItem, URL).self) { group in
                var queue = picked.makeIterator()
                for _ in 0..<4 { if let item = queue.next() { group.addTask { (item, try await MediaChanges.stillFile(item)) } } }
                while let (item, file) = try await group.next() {
                    waiting.append((item, file))
                    progress += 1
                    BackgroundWork.shared.update(Double(progress) / Double(max(total, 1)), subtitle: String(localized: "\(progress) of \(total)"))
                    if waiting.count >= 20 { try await save() }
                    // Stops between photos: those already on their way finish, so nothing is left half done.
                    if !Task.isCancelled, let item = queue.next() { group.addTask { (item, try await MediaChanges.stillFile(item)) } }
                }
            }
            try await save()
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
            // What came down before the problem or the Stop is kept.
            try? await save()
        }
        running = false
        BackgroundWork.shared.end(success: !Task.isCancelled && failure == nil)
        if Task.isCancelled && done.isEmpty { staged = false; return }
        selection = []
        originals = done
        self.sizes = sizes
    }

    /// Only when asked, so iOS's Delete prompt comes after the explanation. Cancelling it leaves the choice on screen.
    private func removeOriginals() async {
        guard await library.delete(originals) else { return }
        result = "Saved about \(formatted(sizes.before - sizes.after)). Originals are in Recently Deleted."
        saving = sizes
        originals = []
    }
}
