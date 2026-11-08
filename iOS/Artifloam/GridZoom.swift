import UIKit
import Photos
import SwiftUI

/// How much of each column count shows at a given picture size. Between two levels both show, cross-fading, like Photos.
enum ZoomLevels {
    static let iPhoneColumns = [7, 5, 3, 2, 1]
    static let spacing: CGFloat = 2
    /// Wider screens get more columns, so each level shows pictures about the size an iPhone does.
    /// The largest is two columns there: one picture across a whole iPad is what the viewer is for.
    static func columns(_ width: CGFloat) -> [Int] {
        let scale = width / 430
        guard scale > 1.25 else { return iPhoneColumns }
        return iPhoneColumns.dropLast().map { Int((CGFloat($0) * scale).rounded()) } + [2]
    }
    /// The two largest levels, where the pictures get the whole screen.
    static func large(_ count: Int, width: CGFloat) -> Bool {
        let levels = columns(width)
        return count <= levels[levels.count - 2]
    }
    /// The same level on a new width, after turning or unfolding, so the pictures stay about the same size.
    static func fitted(_ count: Int, from old: CGFloat, to new: CGFloat) -> Int {
        let before = columns(old), after = columns(new)
        let index = before.firstIndex(of: count) ?? before.indices.min { abs(before[$0] - count) < abs(before[$1] - count) } ?? 2
        return after[min(index, after.count - 1)]
    }

    static func side(columns: Int, width: CGFloat) -> CGFloat {
        (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    }
    /// The level to settle on after letting go.
    static func nearest(side: CGFloat, width: CGFloat) -> Int {
        columns(width).min { abs(log(self.side(columns: $0, width: width) / side)) < abs(log(self.side(columns: $1, width: width) / side)) } ?? 3
    }
    /// The two levels around a size, and how far it is from the first to the second, from 0 to 1.
    static func between(side: CGFloat, width: CGFloat) -> (from: Int, to: Int, progress: CGFloat) {
        let columns = columns(width)
        for (small, large) in zip(columns, columns.dropFirst()) {
            let low = self.side(columns: small, width: width), high = self.side(columns: large, width: width)
            if side <= high {
                let raw = max(0, log(side / low) / log(high / low))
                return (small, large, raw)
            }
        }
        return (columns[columns.count - 2], columns[columns.count - 1], 1)
    }
    /// Past the smallest or largest level the pictures still move, but less and less, then spring back.
    static func resisted(side: CGFloat, width: CGFloat) -> CGFloat {
        let columns = columns(width)
        let low = self.side(columns: columns[0], width: width), high = self.side(columns: columns[columns.count - 1], width: width)
        if side < low { return low * pow(side / low, 0.2) }
        if side > high { return high * pow(side / high, 0.2) }
        return side
    }
    /// Room the footer and tab bar take over the end of a list.
    static let bottomBars: CGFloat = 150
    /// Scrolling can't go past either end of a list, so the zoom doesn't either. A list shorter than the room stays at the top.
    static func offset(wanted: CGFloat, contentHeight: CGFloat, top: CGFloat, bottom: CGFloat) -> CGFloat {
        if contentHeight <= bottom - top { return top }
        return min(top, max(bottom - contentHeight, wanted))
    }
    /// Where every picture sits at a column count, top left of the grid being zero. Same spacing as the real grid.
    static func rects(groups: [Int], ratios: [CGFloat], columns: Int, width: CGFloat) -> [CGRect] {
        let side = self.side(columns: columns, width: width)
        var rects: [CGRect] = []
        rects.reserveCapacity(ratios.count)
        var y: CGFloat = 0, index = 0
        for count in groups {
            if columns == 1 {
                for _ in 0..<count {
                    let height = width / ratios[index]
                    rects.append(CGRect(x: 0, y: y, width: width, height: height))
                    y += height + spacing
                    index += 1
                }
            } else {
                for position in 0..<count {
                    rects.append(CGRect(x: CGFloat(position % columns) * (side + spacing), y: y + CGFloat(position / columns) * (side + spacing), width: side, height: side))
                    index += 1
                }
                y += CGFloat((count + columns - 1) / columns) * (side + spacing)
            }
        }
        return rects
    }
}

/// What's on screen during a pinch. The real grid can't change column count without a jump, so while fingers are down this draws instead.
@MainActor @Observable
final class GridZoom {
    private(set) var active = false
    var side: CGFloat = 0
    /// Where the grid starts on screen when scrolled to the top, under the page's header.
    var restTop: CGFloat?
    /// Goes up as pictures arrive, so the drawing picks them up.
    private(set) var arrivals = 0
    /// Where the scrolling area is on screen.
    var viewport = CGRect.zero

    @ObservationIgnored private(set) var finger = CGPoint.zero
    @ObservationIgnored private(set) var width: CGFloat = 0
    @ObservationIgnored private(set) var anchorID: String?
    @ObservationIgnored private(set) var selection: Set<String> = []
    @ObservationIgnored private var anchorIndex = 0
    @ObservationIgnored private var anchorShare: CGFloat = 0.5
    @ObservationIgnored private var groups: [Int] = []
    @ObservationIgnored private var ratios: [CGFloat] = []
    @ObservationIgnored private(set) var assets: [PHAsset] = []
    @ObservationIgnored private(set) var ids: [String] = []
    @ObservationIgnored private var rects: [Int: [CGRect]] = [:]
    @ObservationIgnored private var asked = Set<Int>()
    @ObservationIgnored var startSide: CGFloat = 0

    func begin(groups list: [CleanupGroup], columns: Int, finger: CGPoint, anchorID: String, anchorFrame: CGRect, width: CGFloat, selection: Set<String>) {
        let all = list.flatMap { group in (group.keep.map { [$0] } ?? []) + group.items }
        guard let index = all.firstIndex(where: { $0.id == anchorID }) else { return }
        groups = list.map { $0.items.count + ($0.keep == nil ? 0 : 1) }
        assets = all.map(\.asset)
        ids = all.map(\.id)
        ratios = all.map { $0.asset.pixelHeight > 0 && $0.asset.pixelWidth > 0 ? CGFloat($0.asset.pixelWidth) / CGFloat($0.asset.pixelHeight) : 1 }
        rects = [:]
        asked = []
        self.finger = finger
        self.width = width
        self.anchorID = anchorID
        self.selection = selection
        anchorIndex = index
        anchorShare = anchorFrame.height > 0 ? min(1, max(0, (finger.y - anchorFrame.minY) / anchorFrame.height)) : 0.5
        startSide = ZoomLevels.side(columns: columns, width: width)
        side = columns == 1 ? width : startSide
        active = true
        // Ready before the fingers get there, so neighbouring sizes fade in as pictures rather than empty squares.
        for nearby in max(0, index - 80)..<min(assets.count, index + 160) { need(nearby) }
    }

    func end() { active = false; assets = []; ids = []; ratios = []; rects = [:] }

    func level(_ columns: Int) -> [CGRect] {
        if let known = rects[columns] { return known }
        let made = ZoomLevels.rects(groups: groups, ratios: ratios, columns: columns, width: width)
        rects[columns] = made
        return made
    }
    /// Keeps the picture under the fingers there at every column count, unless that would scroll past either end of the list.
    func offset(_ columns: Int) -> CGFloat {
        let rects = level(columns), rect = rects[anchorIndex]
        return ZoomLevels.offset(wanted: finger.y - (rect.minY + anchorShare * rect.height), contentHeight: rects.last?.maxY ?? 0,
                                 top: ZoomLevels.large(columns, width: width) ? 0 : (restTop ?? viewport.minY), bottom: viewport.maxY - (ZoomLevels.large(columns, width: width) ? 0 : ZoomLevels.bottomBars))
    }
    /// Where the pinched picture ends up on screen once settled, for placing the real grid under it.
    func settledTop(_ columns: Int) -> (top: CGFloat, height: CGFloat) {
        let rect = level(columns)[anchorIndex]
        return (rect.minY + offset(columns), rect.height)
    }
    func need(_ index: Int) {
        guard asked.count < 500, asked.insert(index).inserted, index < assets.count else { return }
        let asset = assets[index], id = ids[index]
        Task { await Thumbnails.load(asset, id: id, side: 200) { [weak self] _ in self?.arrivals += 1 } }
    }
}

/// Two grids at once while pinching: the one being left fades out as it grows, the next fades in over it, both held to the fingers.
struct ZoomCanvas: View, Animatable {
    let zoom: GridZoom
    var side: CGFloat
    var animatableData: CGFloat {
        get { side }
        set { side = newValue }
    }

    var body: some View {
        let _ = zoom.arrivals
        Canvas(rendersAsynchronously: false) { context, size in
            let (from, to, progress) = ZoomLevels.between(side: side, width: zoom.width)
            // The fade happens in the middle of the way, so at each level only one grid shows, sharp.
            let mix = min(1, max(0, (progress - 0.2) / 0.6)), share = mix * mix * (3 - 2 * mix)
            if share < 1 { draw(columns: from, opacity: 1, in: &context, size: size) }
            if share > 0 { draw(columns: to, opacity: share, in: &context, size: size) }
        }
        .allowsHitTesting(false)
    }

    private func draw(columns: Int, opacity: CGFloat, in context: inout GraphicsContext, size: CGSize) {
        let rects = zoom.level(columns), scale = side / ZoomLevels.side(columns: columns, width: zoom.width)
        let finger = zoom.finger, offset = zoom.offset(columns)
        // Which pictures reach the screen, by turning its edges back into grid positions.
        let top = finger.y + (0 - finger.y) / scale - offset, bottom = finger.y + (size.height - finger.y) / scale - offset
        var low = 0, high = rects.count
        while low < high {
            let middle = (low + high) / 2
            if rects[middle].maxY < top { low = middle + 1 } else { high = middle }
        }
        var layer = context
        layer.opacity = opacity
        var index = low
        while index < rects.count, rects[index].minY <= bottom {
            let rect = rects[index]
            let frame = CGRect(x: finger.x + (rect.minX - finger.x) * scale, y: finger.y + (rect.minY + offset - finger.y) * scale, width: rect.width * scale, height: rect.height * scale)
            if frame.maxX >= 0, frame.minX <= size.width {
                var cell = layer
                cell.clip(to: Path(frame))
                if let image = Thumbnails.cached(zoom.ids[index]) {
                    let fill = max(frame.width / image.size.width, frame.height / image.size.height)
                    let drawn = CGSize(width: image.size.width * fill, height: image.size.height * fill)
                    cell.draw(Image(uiImage: image), in: CGRect(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
                } else {
                    cell.fill(Path(frame), with: .color(.white.opacity(0.08)))
                    zoom.need(index)
                }
                if zoom.selection.contains(zoom.ids[index]) {
                    cell.fill(Path(frame), with: .color(.black.opacity(0.22)))
                    cell.stroke(Path(frame), with: .color(.white), lineWidth: 4)
                }
            }
            index += 1
        }
    }
}

/// Counts the fingers really on the screen. A pinch ends when one finger lifts, but the other can still be down, moving,
/// and to everything else it then looks like a swipe or a tap. So once two fingers have touched, nothing selects until all have left.
struct FingerCount: Equatable {
    private(set) var down = 0
    private(set) var sawTwo = false

    mutating func began(_ count: Int) {
        if down == 0 { sawTwo = false }
        down += count
        if down >= 2 { sawTwo = true }
    }
    mutating func ended(_ count: Int) { down = max(0, down - count) }
}

/// Watches every touch in the window without taking any away from the views underneath.
private final class FingerWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    @MainActor static var isMultiTouch = false
    private var count = FingerCount()

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        count.began(touches.count)
        // Set from the count on every touch, so it can never stay stuck and stop selecting for good.
        Self.isMultiTouch = count.sawTwo
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches.count) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches.count) }
    override func reset() { count = FingerCount() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func lift(_ number: Int) {
        count.ended(number)
        guard count.down == 0 else { return }
        let hadTwo = count.sawTwo
        state = .failed
        // A button acts as the finger lifts, in this same moment, so this stays set just long enough to stop it.
        // Unless fingers are down again by then: a quick second pinch must stay a pinch, or its moving finger swiped photos into the selection.
        if hadTwo { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if self.count.down == 0 { Self.isMultiTouch = false } } }
    }
}

enum Fingers {
    @MainActor static var multiTouch: Bool { FingerWatcher.isMultiTouch }
}

/// Puts the watcher on the window while a photo grid is on screen.
struct FingerWatcherInstaller: UIViewRepresentable {
    final class Host: UIView {
        private let watcher = FingerWatcher()
        override func didMoveToWindow() {
            super.didMoveToWindow()
            watcher.view?.removeGestureRecognizer(watcher)
            window?.addGestureRecognizer(watcher)
        }
    }
    func makeUIView(context: Context) -> Host {
        let host = Host()
        host.isUserInteractionEnabled = false
        return host
    }
    func updateUIView(_ view: Host, context: Context) {}
}
