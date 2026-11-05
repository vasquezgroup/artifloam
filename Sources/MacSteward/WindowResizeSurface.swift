import AppKit
import SwiftUI

/// The visible window ends above the transparent action margin, so native
/// borderless-window resize zones alone don't follow the edge the user sees.
struct StewardWindowResizeSurface: NSViewRepresentable {
    var bottomInset: CGFloat
    var actionHorizontalOffset: CGFloat = 0
    /// Width at the top-right kept free for buttons, so the drag strip and its hand cursor stop before them.
    var topTrailingClearance: CGFloat = 0
    func makeNSView(context: Context) -> ResizeView { ResizeView() }
    func updateNSView(_ view: ResizeView, context: Context) {
        view.bottomInset = bottomInset
        view.actionHorizontalOffset = actionHorizontalOffset
        view.topTrailingClearance = topTrailingClearance
        view.window?.invalidateCursorRects(for: view)
    }
    final class ResizeView: NSView {
        struct Edges: OptionSet {
            let rawValue: Int
            static let left = Edges(rawValue: 1)
            static let right = Edges(rawValue: 2)
            static let top = Edges(rawValue: 4)
            static let bottom = Edges(rawValue: 8)
        }
        var bottomInset: CGFloat = 0
        var actionHorizontalOffset: CGFloat = 0
        var topTrailingClearance: CGFloat = 0
        private var startFrame: NSRect?
        private var startPointer = NSPoint.zero
        private var activeEdges: Edges = []
        private var movingWindow = false
        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }
        private var monitors: [Any] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitors.forEach(NSEvent.removeMonitor); monitors = []
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            // two monitors cover both cases — global while the click falls through to another app, local while ours gets it.
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.updatePassThrough() }) { monitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.updatePassThrough(); return event }) { monitors.append(local) }
        }
        /// The strip under the visible window is see-through: let clicks there reach the window behind, except on the action orb.
        private func updatePassThrough() {
            guard let window else { return }
            let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let overAction = abs(local.x - (bounds.width / 2 + actionHorizontalOffset)) < 76
            let inMargin = bottomInset > 0 && startFrame == nil && bounds.contains(local) && local.y > bottom + 14 && !overAction
            if window.ignoresMouseEvents != inMargin { window.ignoresMouseEvents = inMargin }
        }
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private var bottom: CGFloat { bounds.height - bottomInset }
        static let rightRim: CGFloat = 4
        private func edges(at point: NSPoint) -> Edges {
            // Retain AppKit's outer perimeter and supplement it with a generous
            // inward grip, so users do not have to find the exact outline.
            guard window?.styleMask.contains(.fullScreen) != true,
                  bounds.contains(point) else { return [] }
            let raised = bottomInset > 0 && abs(point.y - bottom) <= 14
            let outerBottom = point.y >= bounds.height - 14
            let nearBottom = raised || outerBottom
            let corner = (point.x < 26 || point.x > bounds.width - 26) && (point.y < 26 || nearBottom)
            let reach: CGFloat = corner ? 26 : 14
            var result: Edges = []
            if point.x < reach { result.insert(.left) }
            // The right side holds scroll bars, so only its outer rim (and the corners) resize.
            if point.x > bounds.width - (corner ? reach : Self.rightRim) { result.insert(.right) }
            if point.y < reach { result.insert(.top) }
            let overAction = bottomInset > 0 && abs(point.x - (bounds.width / 2 + actionHorizontalOffset)) < 76
            if nearBottom && !overAction { result.insert(.bottom) }
            return result
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard window?.styleMask.contains(.fullScreen) != true else { return nil }
            let local = convert(point, from: superview)
            return !edges(at: local).isEmpty || (local.y >= 8 && local.y < 48 && local.x > 110 && local.x < bounds.width - max(24, topTrailingClearance)) ? self : nil
        }
        override func resetCursorRects() {
            guard window?.styleMask.contains(.fullScreen) != true else { return }
            addCursorRect(NSRect(x: 110, y: 14, width: max(0, bounds.width - 110 - max(26, topTrailingClearance)), height: 34), cursor: .openHand)
            addCursorRect(NSRect(x: 0, y: 0, width: 14, height: bounds.height), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: bounds.width - Self.rightRim, y: 0, width: Self.rightRim, height: bounds.height), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: 14), cursor: .resizeUpDown)
            let center = bounds.width / 2 + actionHorizontalOffset
            for edge in bottomInset > 0 ? [bottom, bounds.height] : [bounds.height] {
                let gap: CGFloat = bottomInset > 0 ? 76 : 0
                addCursorRect(NSRect(x: 0, y: edge - 14, width: max(0, center - gap), height: 28), cursor: .resizeUpDown)
                addCursorRect(NSRect(x: center + gap, y: edge - 14, width: max(0, center - gap), height: 28), cursor: .resizeUpDown)
                addCursorRect(NSRect(x: 0, y: edge - 14, width: 26, height: 28), cursor: Self.risingCursor)
                addCursorRect(NSRect(x: bounds.width - 26, y: edge - 14, width: 26, height: 28), cursor: Self.fallingCursor)
            }
            addCursorRect(NSRect(x: 0, y: 0, width: 26, height: 26), cursor: Self.fallingCursor)
            addCursorRect(NSRect(x: bounds.width - 26, y: 0, width: 26, height: 26), cursor: Self.risingCursor)
        }
        override func mouseDown(with event: NSEvent) {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            activeEdges = edges(at: convert(event.locationInWindow, from: nil))
            movingWindow = activeEdges.isEmpty && convert(event.locationInWindow, from: nil).y < 50
            if movingWindow && event.clickCount == 2 { window.performZoom(nil); movingWindow = false; return }
            startFrame = window.frame
            startPointer = window.convertPoint(toScreen: event.locationInWindow)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let startFrame, movingWindow || !activeEdges.isEmpty else { return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            let dx = point.x - startPointer.x, dy = point.y - startPointer.y
            if movingWindow {
                window.setFrameOrigin(NSPoint(x: startFrame.minX + dx, y: startFrame.minY + dy))
                return
            }
            var frame = startFrame
            if activeEdges.contains(.left) { frame.origin.x += dx; frame.size.width -= dx }
            if activeEdges.contains(.right) { frame.size.width += dx }
            if activeEdges.contains(.bottom) { frame.origin.y += dy; frame.size.height -= dy }
            if activeEdges.contains(.top) { frame.size.height += dy }
            let minimum = window.contentMinSize
            if frame.width < minimum.width {
                frame.size.width = minimum.width
                if activeEdges.contains(.left) { frame.origin.x = startFrame.maxX - minimum.width }
            }
            if frame.height < minimum.height {
                frame.size.height = minimum.height
                if activeEdges.contains(.bottom) { frame.origin.y = startFrame.maxY - minimum.height }
            }
            window.setFrame(frame, display: true)
        }
        override func mouseUp(with event: NSEvent) {
            startFrame = nil; activeEdges = []; movingWindow = false
            window?.invalidateCursorRects(for: self)
            if let window { window.saveFrame(usingName: window.frameAutosaveName) }
        }
        private static let risingCursor = diagonalCursor(falling: false)
        private static let fallingCursor = diagonalCursor(falling: true)
        private static func diagonalCursor(falling: Bool) -> NSCursor {
            let image = NSImage(size: NSSize(width: 16, height: 16))
            image.lockFocus()
            let path = NSBezierPath()
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: falling ? 16 - y : y) }
            path.move(to: p(3, 3)); path.line(to: p(13, 13))
            path.move(to: p(3, 7)); path.line(to: p(3, 3)); path.line(to: p(7, 3))
            path.move(to: p(9, 13)); path.line(to: p(13, 13)); path.line(to: p(13, 9))
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            NSColor.black.setStroke(); path.lineWidth = 3; path.stroke()
            NSColor.white.setStroke(); path.lineWidth = 1.2; path.stroke()
            image.unlockFocus()
            return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
        }
    }
}
