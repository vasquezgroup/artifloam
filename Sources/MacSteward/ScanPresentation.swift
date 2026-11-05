import SwiftUI
import AppKit
import AVFoundation
import MacStewardCore

/// Original Blender geometry, optical materials and lighting rendered into a
/// seamless HEVC-with-alpha loop. AVFoundation decodes it without a frame cache.
struct ScanMovieArtwork: View {
    var animated = false
    var asset = "sculpture-motion-cleanup"
    var interactive = true
    @State private var movieReady = false
    @State private var pose: Double = 0
    @State private var look = CGPoint.zero
    /// The player is attached once the page has settled: building it mid-slide stalled the page change.
    @State private var attached = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.stewardPageSwitching) private var switching
    var body: some View {
        let files = MovieFiles.find(asset, scanning: animated)
        let showMovie = !reduceMotion && (attached || animated) && !(switching && !animated)
        ZStack {
            // Trash has no rendered movie, so its glass icon moves with SculptureMotion; render one from design/ if this should spin like the others.
            if let image = files.poster ?? (asset.hasSuffix("-trash") ? CategoryArt.images["trash"] : nil) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .opacity(movieReady && showMovie ? 0 : 1)
            }
            if showMovie, let url = files.movie {
                let grid = files.grid
                ScanMovieSurface(url: url, grid: grid, playing: animated && scenePhase != .background, pose: pose, look: look, ready: { movieReady = true }).id(url)
            }
        }.modifier(SculptureMotion(strength: interactive ? 1 : 0, automatic: animated, interactive: interactive && !animated, onPointerChange: { point in
            guard !animated else { return }
            let angle = asin(Double(point?.x ?? 0))
            pose = angle >= 0 ? angle / (2 * .pi) : 1 + angle / (2 * .pi)
            look = point ?? .zero
        })).accessibilityHidden(true)
            .onChange(of: reduceMotion) { _, _ in movieReady = false }
            .onChange(of: asset) { _, _ in movieReady = false }
            .onChange(of: animated) { _, _ in movieReady = false }
            .onChange(of: switching) { _, value in if value { movieReady = false } }
            .task(id: asset) { try? await Task.sleep(for: .milliseconds(650)); attached = true }
    }
}
/// Bundle lookups and decoded posters, once per asset; page changes re-create these views often.
@MainActor private enum MovieFiles {
    struct Files { let movie: URL?; let grid: Bool; let poster: NSImage? }
    private static var cache: [String: Files] = [:]
    static func find(_ asset: String, scanning: Bool = false) -> Files {
        let bundle = StewardResources.bundle
        // While scanning, a rendered loop looks around in a circle; played straight through, it stays smooth.
        if scanning {
            if let files = cache[asset + "-scan"] { return files }
            if let loop = bundle.url(forResource: asset + "-scan", withExtension: "mov") {
                let files = Files(movie: loop, grid: false, poster: bundle.url(forResource: asset + "-scan-poster", withExtension: "heic").flatMap(NSImage.init(contentsOf:)))
                cache[asset + "-scan"] = files
                return files
            }
        }
        if let files = cache[asset] { return files }
        // A Blender yaw × pitch grid of the same sculpture, when rendered: real up/down views instead of a tilted flat video.
        let look = bundle.url(forResource: asset + "-look", withExtension: "mov")
        let poster = bundle.url(forResource: asset + (look == nil ? "" : "-look") + "-poster", withExtension: "heic").flatMap(NSImage.init(contentsOf:))
        let files = Files(movie: look ?? bundle.url(forResource: asset, withExtension: "mov"), grid: look != nil, poster: poster)
        cache[asset] = files
        return files
    }
}
private struct ScanMovieSurface: NSViewRepresentable {
    let url: URL
    var grid = false
    let playing: Bool
    let pose: Double
    /// Pointer in −1…1, y up. Only used with a look grid.
    var look = CGPoint.zero
    let ready: () -> Void
    func makeNSView(context: Context) -> MovieView { MovieView(url: url, grid: grid, ready: ready) }
    func updateNSView(_ view: MovieView, context: Context) {
        view.setPlaying(playing)
        if !playing { if grid { view.setLook(look) } else { view.setPose(pose) } }
    }
    static func dismantleNSView(_ view: MovieView, coordinator: ()) { view.setPlaying(false); view.stopTimer() }
    final class MovieView: NSView {
        /// Look grid layout from design/render-artwork-look.py: frame = row × columns + column. Rows from the top show
        /// the face tipping down, so a pointer above (y > 0) picks the bottom rows, where the artwork looks up at it.
        /// Taken from the video's length once loaded: 363 frames = 33 × 11, 225 frames = the earlier 25 × 9 grid.
        private var columns = 33, rows = 11
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var readyObservation: NSKeyValueObservation?
        private var poseTimer: Timer?
        private var currentPose = 0.0
        private var targetPose = 0.0
        private var requestedPose: Double?
        private var duration = 3.0
        private let grid: Bool
        override var isOpaque: Bool { false }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
        init(url: URL, grid: Bool, ready: @escaping () -> Void) {
            self.grid = grid
            super.init(frame: .zero)
            wantsLayer = true
            playerLayer.player = player; playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.clear.cgColor; playerLayer.isOpaque = false
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                if layer.isReadyForDisplay { DispatchQueue.main.async { ready() } }
            }
            player.isMuted = true; player.automaticallyWaitsToMinimizeStalling = false
            let asset = AVURLAsset(url: url)
            if !grid {
                // Loaded off the main thread; the synchronous read blocked page changes.
                Task { @MainActor [weak self] in
                    if let length = try? await asset.load(.duration).seconds, length.isFinite, length > 0 { self?.duration = length }
                }
            }
            if grid {
                // A grid is never played through; it starts on the straight-ahead view.
                player.insert(AVPlayerItem(asset: asset), after: nil)
                showCell(column: Double(columns / 2), row: Double(rows / 2))
                Task { @MainActor [weak self] in
                    guard let self, let length = try? await asset.load(.duration).seconds, Int((length * 24).rounded()) == 225 else { return }
                    columns = 25; rows = 9; shownFrame = -1
                    showCell(column: (currentLook.x + 1) / 2 * Double(columns - 1), row: (1 + currentLook.y) / 2 * Double(rows - 1))
                }
            } else {
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        private var playing = false
        func setPlaying(_ value: Bool) {
            guard playing != value else { return }; playing = value
            // A grid only follows the pointer; scans play their own loop (MovieFiles).
            guard !grid else { return }
            if value { poseTimer?.invalidate(); poseTimer = nil; player.play() }
            else { player.pause(); requestedPose = nil }
        }

        // MARK: Look grid

        private var currentLook = CGPoint.zero
        private var targetLook = CGPoint.zero
        private var shownFrame = -1
        func setLook(_ point: CGPoint) {
            targetLook = CGPoint(x: max(-1, min(1, point.x)), y: max(-1, min(1, point.y)))
            startLookTimer()
        }
        private func startLookTimer() {
            guard poseTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.advanceLook() }
            poseTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        private func advanceLook() {
            let dx = targetLook.x - currentLook.x, dy = targetLook.y - currentLook.y
            if abs(dx) < 0.004 && abs(dy) < 0.004 {
                currentLook = targetLook; poseTimer?.invalidate(); poseTimer = nil
            } else {
                // Ease toward the pointer, like a head turning (about a quarter second to settle).
                currentLook.x += dx * 0.09; currentLook.y += dy * 0.09
            }
            showCell(column: (currentLook.x + 1) / 2 * Double(columns - 1), row: (1 + currentLook.y) / 2 * Double(rows - 1))
        }
        private func showCell(column: Double, row: Double) {
            let frame = Int(row.rounded()) * columns + Int(column.rounded())
            guard frame != shownFrame else { return }; shownFrame = frame
            player.seek(to: CMTime(value: CMTimeValue(frame), timescale: 24), toleranceBefore: .zero, toleranceAfter: .zero)
        }

        // MARK: Turntable

        func setPose(_ value: Double) {
            guard !playing, requestedPose != value else { return }
            let initial = requestedPose == nil; requestedPose = value
            var delta = value - currentPose.truncatingRemainder(dividingBy: 1)
            if delta > 0.5 { delta -= 1 }; if delta < -0.5 { delta += 1 }
            targetPose = currentPose + delta
            if initial { currentPose = targetPose; seekPose(); return }
            guard poseTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 24, repeats: true) { [weak self] _ in self?.advancePose() }
            poseTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        private func advancePose() {
            let delta = targetPose - currentPose
            if abs(delta) < 0.001 {
                currentPose = targetPose; poseTimer?.invalidate(); poseTimer = nil
            } else { currentPose += delta * 0.25 }
            seekPose()
        }
        private func seekPose() {
            let wrapped = (currentPose.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
            let time = CMTime(seconds: wrapped * duration, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: CMTime(value: 1, timescale: 48), toleranceAfter: CMTime(value: 1, timescale: 48))
        }
        func stopTimer() { poseTimer?.invalidate(); poseTimer = nil }
        deinit { poseTimer?.invalidate(); player.pause() }
    }
}

struct ScanStage: View {
    let progress: String
    /// The page that started the scan keeps its colour and artwork while it runs.
    let theme: StewardTheme
    @Environment(\.stewardTextScale) private var textScale
    private var phase: Int {
        if progress.hasPrefix("Preparing") { return 0 }
        if progress.contains("system settings") || progress.contains("duplicate") { return 4 }
        if progress.contains("logs") { return 3 }
        if progress.contains("worktrees") { return 2 }
        if progress.contains("caches") || progress.contains("build") || progress.contains("Xcode") { return 1 }
        return 0
    }
    private var steps: some View {
        ForEach(Array(["Access", "Caches", "Worktrees", "Logs", "Tools"].enumerated()), id: \.offset) { index, name in
            HStack(spacing: 5) {
                Image(systemName: index < phase ? "checkmark.circle.fill" : index == phase ? "circle.inset.filled" : "circle")
                Text(name).fixedSize(horizontal: false, vertical: true)
            }.stewardFont(.caption).foregroundStyle(index <= phase ? theme.accent : .white.opacity(0.32))
        }
    }
    var body: some View {
        GeometryReader { geometry in
            // Leave room under the artwork for the title, progress and step row, so short windows don't need scrolling.
            let hero = max(120, min(350, geometry.size.height * 0.74, geometry.size.height - 175 * textScale))
            ScrollView {
                VStack(spacing: 10) {
                    ScanMovieArtwork(animated: true, asset: "sculpture-motion-" + theme.rawValue).frame(width: hero, height: hero)
                        .shadow(color: theme.accent.opacity(0.18), radius: 32, y: 10)
                    Text("Finding space for what’s next.").stewardFont(.title).multilineTextAlignment(.center)
                    Text(progress).stewardFont(.body).foregroundStyle(.white.opacity(0.60))
                        .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center).frame(maxWidth: 620)
                        .contentTransition(.opacity)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 13) { steps }
                        VStack(alignment: .leading, spacing: 6) { steps }
                    }.padding(.top, 8).accessibilityElement(children: .ignore).accessibilityLabel("Current inspection: \(["Access", "Caches", "Worktrees", "Logs", "Tools"][phase])")
                }.padding(.horizontal, 45).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }.scrollIndicators(.hidden)
        }
    }
}

struct ScanCategoryCard: View {
    let summary: CleanupCategorySummary
    var compact = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    private var theme: StewardTheme {
        switch summary.group {
        case .worktrees: return .worktrees
        case .projectCaches, .developerCaches, .xcode: return .files
        case .agentBuilds: return .cleanup
        default: return .system
        }
    }
    private var value: String { formattedBytes(summary.foundBytes > 0 ? summary.foundBytes : summary.totalBytes) }
    private var status: String {
        let ready = summary.automaticCount, choose = summary.choosableCount
        if ready > 0 && choose > 0 { return "\(ready) ready · \(choose) to choose" }
        if ready > 0 { return "\(ready) ready \(ready == 1 ? "cache" : "caches")" }
        if choose > 0 { return "\(choose) \(choose == 1 ? "item" : "items") to choose" }
        if summary.foundBytes > 0 { return "\(summary.count) \(summary.count == 1 ? "item" : "items") to review" }
        return summary.count > 0 ? "\(summary.count) \(summary.count == 1 ? "item" : "items") · kept" : "Nothing found"
    }
    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(summary.group.title).stewardFont(.body, weight: .medium).foregroundStyle(.white.opacity(0.8))
                    Text(value).stewardFont(compact ? .headline : .title2, weight: .semibold)
                        .foregroundStyle(summary.foundBytes > 0 ? theme.accent : .white)
                    Text(status)
                        .stewardFont(.caption).foregroundStyle(.white.opacity(0.52))
                }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                if !compact { StewardIllustration(theme: theme).frame(width: 76, height: 76).allowsHitTesting(false) }
                Image(systemName: "arrow.up.right").stewardFont(.caption).foregroundStyle(.white.opacity(hovered ? 0.9 : 0.35))
            }.padding(compact ? 16 : 19).frame(maxWidth: .infinity, minHeight: compact ? 90 : 108, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 19)
                        .fill(LinearGradient(colors: [theme.accent.opacity(hovered ? 0.22 : 0.13), .white.opacity(0.045)], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay { RoundedRectangle(cornerRadius: 19).stroke(.white.opacity(hovered ? 0.24 : 0.07), lineWidth: 0.8) }
                .offset(y: hovered && !reduceMotion ? -2 : 0)
        }.buttonStyle(.plain).onHover { value in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { hovered = value }
        }.accessibilityLabel("\(summary.group.title), \(value), review category")
    }
}

struct ScanTotal: View {
    @Environment(\.stewardTheme) private var theme
    let overview: ScanOverview
    var compact = false
    @Environment(\.stewardTextScale) private var textScale
    var body: some View {
        VStack(alignment: compact ? .leading : .center, spacing: 8) {
            Text(formattedBytes(overview.foundBytes))
                .font(.system(size: (compact ? 28 : 36) * textScale, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.accent).contentTransition(.numericText())
            Text(overview.foundBytes > 0 ? "can be freed. \(formattedBytes(overview.eligibleBytes)) is ready; you choose the rest." : "Nothing to clean in this scan.")
                .stewardFont(.body).foregroundStyle(.white.opacity(0.7))
            if compact {
                Text("\(overview.automaticCount) ready · \(overview.categories.reduce(0) { $0 + $1.choosableCount }) to choose · \(overview.reviewCount) to review")
                    .stewardFont(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
    }
}

struct ScanResultsStage: View {
    @Environment(\.stewardTheme) private var theme
    let overview: ScanOverview
    let noteCount: Int
    let review: (CleanupGroup?) -> Void
    let showNotes: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    private var highlights: [CleanupCategorySummary] {
        let populated = overview.categories.filter { $0.count > 0 }.sorted { $0.eligibleBytes > $1.eligibleBytes }
        if populated.count >= 4 { return Array(populated.prefix(4)) }
        let defaults: [CleanupGroup] = [.projectCaches, .developerCaches, .xcode, .worktrees]
        return Array((populated + defaults.filter { group in !populated.contains { $0.group == group } }.compactMap { group in overview.categories.first { $0.group == group } }).prefix(4))
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    Label("Scan complete", systemImage: "checkmark.seal.fill").stewardFont(.caption, weight: .medium).foregroundStyle(theme.accent)
                    ScanTotal(overview: overview)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 13)], spacing: 13) {
                        ForEach(Array(highlights.enumerated()), id: \.element.id) { index, summary in
                            ScanCategoryCard(summary: summary) { review(summary.group) }
                                .opacity(revealed ? 1 : 0)
                                .offset(y: revealed || reduceMotion ? 0 : 14)
                                .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.85).delay(Double(index) * 0.07), value: revealed)
                        }
                    }.frame(maxWidth: 780)
                    if noteCount > 0 {
                        Button(action: showNotes) { Label("\(noteCount) scan \(noteCount == 1 ? "note" : "notes")", systemImage: "info.circle").stewardFont(.caption) }
                            .buttonStyle(.plain).foregroundStyle(.orange)
                    }
                }.padding(.horizontal, 60).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }.scrollIndicators(.hidden)
        }.onAppear { revealed = true }
    }
}
