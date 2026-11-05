import SwiftUI

/// A small float shared by rendered sculptures and video artwork; the turning itself is rendered.
struct SculptureMotion: ViewModifier {
    var strength: Double = 1
    var automatic = false
    var interactive = true
    var onPointerChange: ((CGPoint?) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @Environment(\.stewardWindowPointer) private var windowPointer
    @State private var pointer = CGPoint.zero
    @State private var engaged = false
    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !automatic || reduceMotion || phase == .background)) { timeline in
            let moving = !reduceMotion && (automatic && phase != .background || engaged)
            let time = automatic && !reduceMotion && phase != .background ? timeline.date.timeIntervalSinceReferenceDate : 0
            let idle = engaged ? 0.0 : 1.0
            // Turning happens inside the rendered artwork (look grid or turntable). Flat 3D tilts are left out:
            // they bend the glass like a card. Only a small float follows the pointer, or drifts while scanning.
            let drift = (x: sin(time * 0.61) * 7 + sin(time * 0.29) * 4, y: sin(time * 0.83) * 6 + sin(time * 0.41) * 3)
            content
                .offset(x: moving ? (pointer.x * 8 + drift.x * idle) * strength : 0,
                        y: moving ? (-pointer.y * 9 + drift.y * idle) * strength - (engaged ? 3 : 0) : 0)
                .scaleEffect(moving && engaged ? 1.02 : 1)
        }
        .onChange(of: windowPointer, initial: true) { _, point in
            guard !reduceMotion, interactive else { return }
            withAnimation(.interactiveSpring(response: point == nil ? 0.8 : 0.45, dampingFraction: 0.86)) {
                engaged = point != nil; pointer = point ?? .zero
            }
            onPointerChange?(point)
        }
        .onChange(of: reduceMotion) { _, _ in pointer = .zero; engaged = false; onPointerChange?(nil) }
        .onChange(of: phase) { _, value in if value != .active { pointer = .zero; engaged = false; onPointerChange?(nil) } }
    }
}
