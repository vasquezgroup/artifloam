import SwiftUI
import AppKit

/// Original artwork rendered from design/steward-illustration.blend.
/// Motion is native, pauses in the background, and respects Reduce Motion.
/// The page colours for views deep inside a page (progress bars, buttons, cleaning screen), set once in the root view.
private struct StewardThemeKey: EnvironmentKey { static let defaultValue = StewardTheme.cleanup }
extension EnvironmentValues {
    var stewardTheme: StewardTheme {
        get { self[StewardThemeKey.self] }
        set { self[StewardThemeKey.self] = newValue }
    }
}

enum StewardTheme: String {
    case care, cleanup, system, files, worktrees, browsers, space, trash, iphone, photos
    var accent: Color {
        switch self {
        case .care: return Color(red: 0.79, green: 0.59, blue: 1)
        case .cleanup: return Color(red: 0.49, green: 0.91, blue: 0.65)
        case .system: return Color(red: 0.45, green: 0.78, blue: 1)
        case .files: return Color(red: 1, green: 0.73, blue: 0.42)
        case .worktrees: return Color(red: 0.43, green: 0.94, blue: 0.9)
        case .browsers: return Color(red: 1, green: 0.64, blue: 0.80)
        case .space: return Color(red: 1, green: 0.86, blue: 0.42)
        case .trash: return Color(red: 1, green: 0.62, blue: 0.74)
        case .iphone: return Color(red: 0.68, green: 0.67, blue: 1)
        // Chartreuse: the widest gap between the other sections' hues, between Space Map's gold and Cleanup's green.
        case .photos: return Color(red: 0.84, green: 0.98, blue: 0.42)
        }
    }
    /// Saturated twin of `accent` for the main round button, so the primary action stands out.
    var vivid: Color {
        switch self {
        case .care: return Color(red: 0.74, green: 0.22, blue: 0.95)
        case .cleanup: return Color(red: 0.10, green: 0.72, blue: 0.42)
        case .system: return Color(red: 0.16, green: 0.48, blue: 0.96)
        case .files: return Color(red: 0.96, green: 0.52, blue: 0.10)
        case .worktrees: return Color(red: 0.08, green: 0.68, blue: 0.74)
        case .browsers: return Color(red: 0.92, green: 0.22, blue: 0.52)
        case .space: return Color(red: 0.92, green: 0.70, blue: 0.06)
        case .trash: return Color(red: 0.84, green: 0.11, blue: 0.40)
        case .iphone: return Color(red: 0.34, green: 0.27, blue: 0.96)
        case .photos: return Color(red: 0.52, green: 0.76, blue: 0.04)
        }
    }
    var symbol: String {
        switch self {
        case .care: return "sparkles"
        case .cleanup: return "sparkles"
        case .system: return "checkmark.shield.fill"
        case .files: return "folder.fill"
        case .worktrees: return "arrow.triangle.branch"
        case .browsers: return "globe"
        case .space: return "chart.pie.fill"
        case .trash: return "trash.fill"
        case .iphone: return "iphone"
        case .photos: return "photo.on.rectangle"
        }
    }
    /// Background ramp: deep (top left), the module colour, then a brighter neighbouring hue (bottom right).
    var backdrop: (deep: Color, mid: Color, bright: Color) {
        switch self {
        case .care: return (Color(red: 0.10, green: 0.04, blue: 0.22), Color(red: 0.36, green: 0.11, blue: 0.62), Color(red: 0.84, green: 0.32, blue: 0.80))
        case .cleanup: return (Color(red: 0.03, green: 0.14, blue: 0.07), Color(red: 0.10, green: 0.40, blue: 0.15), Color(red: 0.44, green: 0.74, blue: 0.16))
        case .system: return (Color(red: 0.02, green: 0.08, blue: 0.22), Color(red: 0.07, green: 0.28, blue: 0.66), Color(red: 0.22, green: 0.70, blue: 0.96))
        case .files: return (Color(red: 0.20, green: 0.06, blue: 0.03), Color(red: 0.58, green: 0.22, blue: 0.05), Color(red: 0.98, green: 0.64, blue: 0.20))
        case .worktrees: return (Color(red: 0.02, green: 0.14, blue: 0.16), Color(red: 0.04, green: 0.40, blue: 0.42), Color(red: 0.32, green: 0.84, blue: 0.68))
        case .browsers: return (Color(red: 0.20, green: 0.03, blue: 0.12), Color(red: 0.58, green: 0.10, blue: 0.36), Color(red: 0.98, green: 0.44, blue: 0.52))
        case .space: return (Color(red: 0.17, green: 0.12, blue: 0.02), Color(red: 0.54, green: 0.40, blue: 0.04), Color(red: 0.98, green: 0.86, blue: 0.30))
        case .trash: return (Color(red: 0.17, green: 0.02, blue: 0.08), Color(red: 0.52, green: 0.05, blue: 0.24), Color(red: 0.92, green: 0.22, blue: 0.40))
        case .iphone: return (Color(red: 0.05, green: 0.03, blue: 0.26), Color(red: 0.19, green: 0.14, blue: 0.70), Color(red: 0.50, green: 0.46, blue: 1))
        case .photos: return (Color(red: 0.07, green: 0.14, blue: 0.02), Color(red: 0.32, green: 0.50, blue: 0.04), Color(red: 0.80, green: 0.94, blue: 0.30))
        }
    }
    var glow: Color {
        switch self {
        case .care: return Color(red: 0.35, green: 0.10, blue: 0.66)
        case .cleanup: return Color(red: 0.07, green: 0.36, blue: 0.19)
        case .system: return Color(red: 0.05, green: 0.22, blue: 0.49)
        case .files: return Color(red: 0.43, green: 0.20, blue: 0.06)
        case .worktrees: return Color(red: 0.025, green: 0.32, blue: 0.34)
        case .browsers: return Color(red: 0.42, green: 0.06, blue: 0.24)
        case .space: return Color(red: 0.40, green: 0.29, blue: 0.03)
        case .trash: return Color(red: 0.40, green: 0.03, blue: 0.17)
        case .iphone: return Color(red: 0.15, green: 0.11, blue: 0.52)
        case .photos: return Color(red: 0.24, green: 0.38, blue: 0.04)
        }
    }
}

struct AtmosphereView: View {
    let theme: StewardTheme
    var scanning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !scanning || reduceMotion || scenePhase == .background)) { timeline in
            let time = scanning && !reduceMotion && scenePhase != .background ? timeline.date.timeIntervalSinceReferenceDate : 0
            GeometryReader { geo in
                ZStack {
                    // One colour family that shifts hue across the window, near-black at the top left,
                    // the module colour through the middle, a lighter neighbouring hue glowing at the bottom right.
                    let ramp = theme.backdrop
                    LinearGradient(stops: [.init(color: ramp.deep, location: 0), .init(color: ramp.mid, location: 0.55), .init(color: ramp.bright, location: 1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [ramp.bright.opacity(scanning ? 0.8 : 0.65), ramp.bright.opacity(0.15), .clear],
                        center: .init(x: 0.80 + sin(time * 0.20) * 0.10, y: 0.92 + cos(time * 0.17) * 0.06), startRadius: 0, endRadius: geo.size.width * 0.62)
                    if scanning {
                        RadialGradient(colors: [theme.accent.opacity(0.22), .clear], center: .init(x: 0.65 + cos(time * 0.24) * 0.18, y: 0.62 + sin(time * 0.18) * 0.15), startRadius: 0, endRadius: geo.size.width * 0.50)
                            .blendMode(.screen)
                    }
                    // A darker top band, so the title area and window buttons sit on the deep end of the ramp.
                    LinearGradient(colors: [.black.opacity(0.22), .clear], startPoint: .top, endPoint: .center)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

enum StewardArtwork {
    static let images: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for name in ["overview", "cleanup", "system", "files", "worktrees", "automation", "activity", "memory", "tools", "settings", "space-map", "browsers", "iphone", "photos"] {
            if let url = StewardResources.bundle.url(forResource: "symbol-" + name, withExtension: "heic"), let image = NSImage(contentsOf: url) { images["symbol-" + name] = image }
        }
        return images
    }()
}

struct StewardIllustration: View {
    let theme: StewardTheme
    var scanning = false
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                // A wide, soft halo behind the artwork, like the reference's lit stage.
                Circle().fill(RadialGradient(colors: [theme.vivid.opacity(0.55), theme.glow.opacity(0.22), .clear], center: .center, startRadius: side * 0.1, endRadius: side * 0.62))
                    .frame(width: side * 1.35, height: side * 1.35).blur(radius: 30)
                Ellipse().fill(theme.glow.opacity(0.5)).frame(width: side * 0.7, height: side * 0.12).blur(radius: 20).offset(y: side * 0.37)
                ScanMovieArtwork(animated: scanning, asset: "sculpture-motion-" + theme.rawValue)
                    .frame(width: side, height: side)

            }.frame(width: geometry.size.width, height: geometry.size.height)
                .shadow(color: theme.vivid.opacity(0.45), radius: 34, y: 12)
        }.accessibilityHidden(true)
    }
}

struct OrbAction: View {
    let title: String
    let icon: String
    let accent: Color
    var disabled = false
    var showingProgress = false
    var progress: Double? = nil
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            ZStack {
                // Vivid and energetic: a saturated accent body with a strong glow instead of dark glass.
                Circle().fill(accent.opacity(hovered ? 0.75 : 0.55)).blur(radius: hovered ? 26 : 20)
                Circle().fill(accent)
                Circle().fill(LinearGradient(colors: [.white.opacity(0.28), .clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                Circle().fill(RadialGradient(colors: [.white.opacity(hovered ? 0.30 : 0.18), .clear], center: UnitPoint(x: 0.5, y: 0.2), startRadius: 2, endRadius: 50))
                Circle().stroke(LinearGradient(colors: [.white.opacity(0.95), accent.opacity(0.5), .white.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.8)
                Circle().stroke(AngularGradient(colors: [.clear, .white.opacity(hovered ? 0.9 : 0.38), accent.opacity(0.15), .clear], center: .center), lineWidth: 1.2)
                    .padding(3).rotationEffect(.degrees(hovered && !reduceMotion ? 100 : -35))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.65), value: hovered)
                Ellipse().fill(.white.opacity(hovered ? 0.3 : 0.19)).frame(width: 57, height: 16).blur(radius: 9)
                    .offset(x: hovered && !reduceMotion ? 8 : -9, y: -32)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: hovered)
                VStack(spacing: 3) {
                    Image(systemName: icon).font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 1, x: 1, y: 3)
                        .shadow(color: accent.opacity(0.6), radius: 5, y: -1)
                        .rotation3DEffect(.degrees(hovered && !reduceMotion ? -12 : 0), axis: (x: 0, y: 1, z: 0))
                        .offset(y: hovered && !reduceMotion ? -1.5 : 0)
                    Text(title).stewardFont(.headline, weight: .medium).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                }
                if showingProgress {
                    Circle().stroke(.white.opacity(0.16), lineWidth: 8).padding(-8)
                    if let progress, progress > 0 {
                        Circle().trim(from: 0, to: min(1, max(0, progress)))
                            .stroke(LinearGradient(colors: [accent, .white.opacity(0.95)], startPoint: .bottomLeading, endPoint: .topTrailing), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(-8)
                            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: progress)
                    }
                    // Keeps the ring visibly alive while measured progress pauses: a glint sweeps
                    // along the filled arc, or circles the ring before the first measurement.
                    if !reduceMotion {
                        // Capped and paused in the background like the other loops; uncapped it redraws at up to 120 Hz.
                        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: scenePhase == .background)) { context in
                            let filled = min(1, max(0, progress ?? 0))
                            let time = context.date.timeIntervalSinceReferenceDate
                            let span = filled > 0.02 ? filled : 1.0
                            ZStack {
                                // Two streaks, half a cycle apart, race along the filled arc every 0.9 s.
                                ForEach(0..<2, id: \.self) { index in
                                    let phase = (time / 0.9 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
                                    let head = span * phase
                                    Circle().trim(from: max(0, head - 0.09), to: head)
                                        .stroke(AngularGradient(colors: [.white.opacity(0), accent.opacity(0.6), .white], center: .center, startAngle: .degrees(360 * (head - 0.09)), endAngle: .degrees(360 * head)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                }
                                // A pulsing glow keeps the leading edge alive even when the measured value pauses.
                                if filled > 0.02 {
                                    let pulse = 0.5 + 0.5 * sin(time * 7)
                                    Circle().fill(.white).frame(width: 9 + 5 * pulse, height: 9 + 5 * pulse)
                                        .shadow(color: accent, radius: 6 + 6 * pulse)
                                        // Trim starts at 3 o'clock inside the rotated ring.
                                        .offset(x: 60).rotationEffect(.degrees(360 * filled))
                                }
                            }.rotationEffect(.degrees(-90)).padding(-8).blendMode(.plusLighter)
                        }.allowsHitTesting(false)
                    }
                }
            }.frame(width: 104, height: 104).contentShape(Circle())
                .shadow(color: .black.opacity(0.3), radius: 9, y: 7)

        }.buttonStyle(OrbPressStyle(reduceMotion: reduceMotion))
            .scaleEffect(hovered && !reduceMotion ? 1.07 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: hovered)
            .onHover { hovered = $0 }.disabled(disabled).opacity(disabled ? 0.45 : 1)
            .accessibilityLabel(title).accessibilityValue(showingProgress ? progress.map { String(localized: "\(Int($0 * 100)) percent complete") } ?? String(localized: "Preparing scan") : "")
    }
}
private struct OrbPressStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// Lets the shared atmosphere continue behind the native traffic lights.
struct StewardWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ nsView: WindowView, context: Context) { nsView.configure() }
    final class WindowView: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        func configure() {
            guard let window else { return }
            // Keep AppKit's titled/resizable frame for native resize hit testing.
            // The transparent titlebar shares our dedicated drag strip.
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.hasShadow = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(type)?.isHidden = true
            }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
        }
    }
}

/// Native AppKit buttons in a dedicated content strip remain visible when macOS
/// places its screen-sharing indicator over the frame's traffic-light area.
struct StewardWindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ nsView: ControlsView, context: Context) { }
    final class ControlsView: NSView {
        private var area: NSTrackingArea?
        var hovered = false { didSet { subviews.forEach { $0.needsDisplay = true } } }
        /// AppKit asks the buttons' superview this to decide whether to draw the hover symbols.
        @objc func _mouseInGroup(_ button: NSButton) -> Bool { hovered }
        override init(frame: NSRect) {
            super.init(frame: frame)
            // The system's own buttons: identical to Notes in size, colour, inactive grey and hover symbols.
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, type) in types.enumerated() {
                guard let button = NSWindow.standardWindowButton(type, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
                // Right to left, macOS keeps close nearest the window's corner.
                button.setFrameOrigin(NSPoint(x: CGFloat(appLayoutDirection == .rightToLeft ? 2 - index : index) * 20, y: 0))
                button.target = self
                button.action = index == 0 ? #selector(closeWindow(_:)) : index == 1 ? #selector(minimizeWindow(_:)) : #selector(zoomWindow(_:))
                addSubview(button)
            }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas(); if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag], owner: self)
            addTrackingArea(area); self.area = area
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true }
        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseMoved(with event: NSEvent) { hovered = true }
        override func mouseDown(with event: NSEvent) { hovered = true }
        override func mouseDragged(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func closeWindow(_ sender: Any?) { window?.performClose(sender) }
        @objc private func minimizeWindow(_ sender: Any?) { window?.performMiniaturize(sender) }
        @objc private func zoomWindow(_ sender: Any?) { window?.toggleFullScreen(sender) }
    }
}

/// SwiftUI supplies its own window material unless the window container is clear.
struct StewardClearWindowBackground: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(.clear, for: .window)
        } else {
            content
        }
    }
}

struct StewardNavigationArtwork: View {
    let name: String
    let fallback: String
    var size: CGFloat = 24
    private var symbol: String {
        switch name {
        case "Overview": return "overview"
        case "Cleanup", "Junk cleanup", "Trash bins": return "cleanup"
        case "Browsers", "Browser data": return "browsers"
        case "Worktrees": return "worktrees"
        case "Duplicates", "Large & old files", "My Clutter": return "files"
        case "Space Map": return "space-map"
        case "System", "Applications": return "system"
        case "iPhone": return "iphone"
        case "Photos": return "photos"
        case "Tools", "App removal", "Leftovers": return "tools"
        case "Memory", "Performance": return "memory"
        case "Status": return "activity"
        case "Automation", "Login & background items": return "automation"
        case "Activity": return "activity"
        case "Settings": return "settings"
        default: return "tools"
        }
    }
    var body: some View {
        Group {
            if let image = StewardArtwork.images["symbol-" + symbol] {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else { Image(systemName: fallback).font(.system(size: size, weight: .semibold)) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Which way the language macOS chose for this launch reads. Set on every hosting root, because this window's
/// SwiftUI otherwise stays left to right. Keys follow the same choice, so text and layout always agree.
let appLayoutDirection: LayoutDirection = Locale.Language(identifier: Bundle.main.preferredLocalizations.first ?? "en").characterDirection == .rightToLeft ? .rightToLeft : .leftToRight

enum StewardResources {
    static let bundle: Bundle = {
        // Not Bundle.module: SwiftPM's accessor writes this Mac's build path into the shipped binary.
        // The packaged app keeps the bundle in Resources; `swift run` keeps it beside the executable.
        let places = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0?.appendingPathComponent("MacSteward_MacSteward.bundle") }
        return places.lazy.compactMap { Bundle(url: $0) }.first ?? .main
    }()
}

/// A tactile glass action with a material base, specular rim and restrained motion.
/// Small buttons under a list row (Finder, Keep…): quiet at rest, clearly lit on hover, so it's plain which one you're on.
struct RowActionButtonStyle: ButtonStyle {
    /// Red, for the one row action that removes something.
    var destructive = false
    func makeBody(configuration: Configuration) -> some View { RowAction(configuration: configuration, tint: destructive ? .red : .white) }
    private struct RowAction: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            let lit = hovered && enabled
            configuration.label
                .padding(.horizontal, 11).padding(.vertical, 4)
                .foregroundStyle(lit ? Color.white : Color.white.opacity(enabled ? 0.82 : 0.4))
                .background(tint.opacity(configuration.isPressed ? 0.34 : lit ? 0.24 : tint == .white ? 0.10 : 0.55), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(lit ? 0.35 : 0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .trackingHover { inside in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { hovered = inside } }
        }
    }
}
struct CleanupGlassButtonStyle: ButtonStyle {
    var compact = false
    /// Same glass and shape without the mint fill, so a secondary action sits beside the primary one.
    var secondary = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        GlassActionLabel(label: configuration.label, pressed: configuration.isPressed, reduceMotion: reduceMotion, compact: compact, secondary: secondary)
            .opacity(isEnabled ? 1 : 0.42)
    }
    private struct GlassActionLabel<Label: View>: View {
        let label: Label
        let pressed: Bool
        let reduceMotion: Bool
        let compact: Bool
        let secondary: Bool
        @Environment(\.stewardTheme) private var theme
        @State private var hovered = false
        var body: some View {
            // A fixed height per size, so buttons side by side line up whether or not their label has an icon.
            label.padding(.horizontal, compact ? 14 : 20).frame(height: compact ? 34 : 44)
                .foregroundStyle(.white)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))
                .background {
                    RoundedRectangle(cornerRadius: 17)
                        .fill(secondary ? AnyShapeStyle(Color.white.opacity(hovered ? 0.16 : 0.08)) : AnyShapeStyle(LinearGradient(colors: [theme.accent.opacity(hovered ? 0.68 : 0.48), .white.opacity(0.08), theme.accent.opacity(0.30)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 17)
                        .stroke(LinearGradient(colors: [.white.opacity(secondary ? 0.5 : 0.85), (secondary ? Color.white : theme.accent).opacity(0.15), .white.opacity(secondary ? 0.25 : 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                }
                .overlay(alignment: .top) {
                    Capsule().fill(.white.opacity(0.35)).frame(height: 1).padding(.horizontal, 18).padding(.top, 2)
                }
                .shadow(color: (secondary ? Color.black : theme.accent).opacity(hovered ? 0.28 : 0.12), radius: hovered ? 16 : 9, y: 5)
                .scaleEffect(reduceMotion ? 1 : pressed ? 0.97 : hovered ? 1.015 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72), value: pressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// Page change like the reference: the old page fades out under a blur, the new one sharpens in, slightly scaled.
private struct BlurFade: ViewModifier {
    let active: Bool
    let scale: CGFloat
    var offset: CGFloat = 0
    var blur: CGFloat = 14
    func body(content: Content) -> some View {
        content.padding(glowRoom).blur(radius: active ? blur : 0).padding(-glowRoom)
            .opacity(active ? 0 : 1).scaleEffect(active ? scale : 1).offset(y: active ? offset : 0)
    }
}
extension AnyTransition {
    static func blurFade(scale: CGFloat = 0.96) -> AnyTransition {
        .modifier(active: BlurFade(active: true, scale: scale), identity: BlurFade(active: false, scale: scale))
    }
}
extension Animation {
    /// Page changes and their background: moving from the first frame (no slow spring start), settling softly.
    /// A steeper start reached half the travel in 90 ms and read as a jump.
    static let pagePush = Animation.timingCurve(0.3, 0.55, 0.25, 1, duration: 0.6)
}
/// A blur renders only inside its view's frame, which cropped the artwork glow into a box at the page edges.
/// Padding before the blur (and removing it after) gives the glow room without changing layout.
private let glowRoom: CGFloat = 140
/// Offset toward `offset` as the page moves away (progress 1 = in place), with a light blur and fade.
/// A plain offset, not visualEffect: visualEffect only shifts the drawing, so AppKit-backed parts (every page's
/// scroll view, the artwork player) stayed put mid-slide and the pages froze, then jumped at the end.
struct PageSlide: ViewModifier, Animatable {
    var progress: Double
    let offset: CGFloat
    /// The leaving page fades out completely; the arriving one is already visible while it moves in.
    var leaving = false
    var animatableData: Double { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let away = 1 - progress
        content.padding(glowRoom).blur(radius: 10 * away).padding(-glowRoom)
            .opacity(1 - away * (leaving ? 1 : 0.4))
            .offset(y: offset * away)
    }
}


/// The one bulk row for every page that lists things to remove: select all, what is selected, then the page's action.
/// Ticks only what is certain to be safe on this list and unticks the rest. Every list uses the same one.
struct SmartSelectButton: View {
    var enabled = true
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label("Smart select", systemImage: "wand.and.stars") }
            .buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)).disabled(!enabled).help(help)
    }
}

struct BulkBar<Actions: View>: View {
    let title: String
    @Binding var isOn: Bool
    var enabled = true
    var help = String(localized: "Select or deselect everything listed")
    let summary: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $isOn) { Text(title).stewardFont(.callout, weight: .semibold) }.toggleStyle(.stewardCheckbox).disabled(!enabled).help(help)
            Text(summary).stewardFont(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            Spacer(minLength: 8)
            actions()
        }.padding(.horizontal, 14).padding(.vertical, 8).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The one checkbox Artifloam uses everywhere: same size, same mint fill, same white check, on every page.
/// The system checkbox takes its colour from the system accent and its surroundings, so it looked different per view.
struct StewardCheckboxStyle: ToggleStyle {
    /// false: only the box is drawn; the label still names it for VoiceOver (what `.labelsHidden()` did before).
    var showsLabel = true
    /// Some, not all, of what it stands for is ticked: drawn filled with a dash. Clicking ticks all of it.
    var mixed = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(configuration.isOn || mixed ? AnyShapeStyle(Color.mint) : AnyShapeStyle(Color.white.opacity(0.08)))
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(configuration.isOn || mixed ? Color.clear : Color.white.opacity(0.5), lineWidth: 1.2)
                    if configuration.isOn || mixed {
                        Image(systemName: configuration.isOn ? "checkmark" : "minus").font(.system(size: 10.5, weight: .heavy)).foregroundStyle(Color(red: 0.02, green: 0.2, blue: 0.17))
                    }
                }
                .frame(width: 18, height: 18)
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
                if showsLabel { configuration.label }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        // VoiceOver sees a real checkbox with its label, even when only the box is drawn.
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox) }
    }
}
extension ToggleStyle where Self == StewardCheckboxStyle {
    static var stewardCheckbox: StewardCheckboxStyle { StewardCheckboxStyle() }
    static var stewardCheckboxOnly: StewardCheckboxStyle { StewardCheckboxStyle(showsLabel: false) }
    static func stewardCheckboxOnly(mixed: Bool) -> StewardCheckboxStyle { StewardCheckboxStyle(showsLabel: false, mixed: mixed) }
}
