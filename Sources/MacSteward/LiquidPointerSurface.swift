import AppKit
import SwiftUI

/// An explicit macOS tracking area keeps decorative parallax responsive in
/// inactive windows and during drags, without stealing focus or changing state.
struct LiquidPointerSurface: NSViewRepresentable {
    var onMove: (CGPoint?) -> Void
    func makeNSView(context: Context) -> TrackingSurface {
        let view = TrackingSurface(); view.onMove = onMove; return view
    }
    func updateNSView(_ nsView: TrackingSurface, context: Context) { nsView.onMove = onMove }
    final class TrackingSurface: NSView {
        var onMove: ((CGPoint?) -> Void)?
        private var area: NSTrackingArea?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Receive every mouse-moved event, not only entry/click positions.
            window?.acceptsMouseMovedEvents = true
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag], owner: self)
            addTrackingArea(next); area = next
        }
        private func report(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onMove?(bounds.contains(point) ? point : nil)
        }
        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseDragged(with event: NSEvent) { report(event) }
        override func mouseDown(with event: NSEvent) { report(event) }
        override func mouseUp(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { onMove?(nil) }
        override func accessibilityIsIgnored() -> Bool { true }
    }
}

/// Hover from an AppKit tracking area. SwiftUI's `onHover` stays silent for buttons deep inside the review lists;
/// a tracking area always reports, in active and inactive windows alike.
private struct HoverTracker: NSViewRepresentable {
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> Tracker { let view = Tracker(); view.changed = changed; return view }
    func updateNSView(_ view: Tracker, context: Context) { view.changed = changed }
    final class Tracker: NSView {
        var changed: ((Bool) -> Void)?
        private var area: NSTrackingArea?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
            addTrackingArea(next); area = next
        }
        override func mouseEntered(with event: NSEvent) { changed?(true) }
        override func mouseExited(with event: NSEvent) { changed?(false) }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { changed?(false) } }
        override func accessibilityIsIgnored() -> Bool { true }
    }
}
extension View {
    /// Like `onHover`, but reliable inside nested scroll views.
    func trackingHover(_ changed: @escaping (Bool) -> Void) -> some View { background(HoverTracker(changed: changed)) }
}
