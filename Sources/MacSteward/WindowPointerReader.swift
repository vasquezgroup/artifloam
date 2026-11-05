import AppKit
import SwiftUI

private struct StewardWindowPointerKey: EnvironmentKey { static let defaultValue: CGPoint? = nil }
extension EnvironmentValues {
    var stewardWindowPointer: CGPoint? {
        get { self[StewardWindowPointerKey.self] }
        set { self[StewardWindowPointerKey.self] = newValue }
    }
    /// True while pages slide: artwork shows its still poster, since effects like blur don't animate on AppKit views.
    var stewardPageSwitching: Bool {
        get { self[StewardPageSwitchingKey.self] }
        set { self[StewardPageSwitchingKey.self] = newValue }
    }
}
private struct StewardPageSwitchingKey: EnvironmentKey { static let defaultValue = false }

/// Only observes events delivered to this application's own window. No global
/// monitor, event tap, Accessibility access or Input Monitoring is involved.
struct WindowPointerReader: NSViewRepresentable {
    var enabled: Bool
    var changed: (CGPoint?) -> Void
    func makeNSView(context: Context) -> Reader { let view = Reader(); view.enabled = enabled; view.changed = changed; return view }
    func updateNSView(_ view: Reader, context: Context) { view.enabled = enabled; view.changed = changed }
    final class Reader: NSView {
        var enabled = true
        var changed: ((CGPoint?) -> Void)?
        private var area: NSTrackingArea?
        private var monitor: Any?
        private var lastDelivery: TimeInterval = 0
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard let window else { return }; window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown]) { [weak self] event in
                guard let self, self.window === event.window else { return event }
                self.report(event); return event
            }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas(); if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag], owner: self)
            addTrackingArea(area); self.area = area
        }
        private func report(_ event: NSEvent) {
            guard enabled else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { changed?(nil); return }
            guard event.timestamp - lastDelivery >= 1.0 / 30 || event.type == .leftMouseDown else { return }
            lastDelivery = event.timestamp
            changed?(CGPoint(x: min(1, max(-1, point.x / max(1, bounds.width) * 2 - 1)), y: min(1, max(-1, point.y / max(1, bounds.height) * 2 - 1))))
        }
        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { if enabled { changed?(nil) } }
        override func accessibilityIsIgnored() -> Bool { true }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
