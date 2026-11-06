import SwiftUI
import AppKit
import MacStewardCore

/// Where Overview's sculpture and words really are, measured while the page sits hidden, so the welcome can land on them exactly.
struct WelcomeFrames: PreferenceKey {
    static let space = "stewardWindow"
    static let defaultValue = [String: CGRect]()
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}
extension View {
    func reportingWelcomeFrame(_ name: String, enabled: Bool) -> some View {
        background { if enabled { GeometryReader { Color.clear.preference(key: WelcomeFrames.self, value: [name: $0.frame(in: .named(WelcomeFrames.space))]) } } }
    }
}

/// First launch: the app builds itself on the bare desktop. Glass tiles float with no window behind them and fly together into
/// the Overview sculpture, a line of light draws the window's outline, and the sculpture flies to its exact place as the window
/// fills. Short steps, including permissions, follow beside it. The animation plays once; the steps show until they're finished.
/// Replay it with the launch arguments `-firstLaunchSeen NO -firstLaunchAnimationSeen NO -migratedFromLegacyDomain NO`.
struct WelcomeStage: View {
    private static let seenKey = "firstLaunchSeen", animationKey = "firstLaunchAnimationSeen"
    /// Only a packaged app, and not someone updating from an older version.
    @MainActor static var shouldShow: Bool {
        let defaults = StewardPreferences.defaults
        return Bundle.main.bundleURL.pathExtension == "app" && !defaults.bool(forKey: seenKey) && !defaults.bool(forKey: StewardPreferences.migratedKey)
    }
    let theme: StewardTheme
    let frames: [String: CGRect]
    @EnvironmentObject private var m: StewardModel
    @Environment(\.stewardTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Phase: Int { case empty, floating, gathering, formed }
    private enum Step { case welcome, move, permissions }
    @State private var phase = Phase.empty
    @State private var flash = false
    @State private var trace: CGFloat = 0
    @State private var placed = false
    /// The steps are done: the sculpture goes to its exact place on Overview.
    @State private var settling = false
    @State private var step = Step.welcome
    @State private var copyShown = false
    @State private var finished = false
    @State private var moveError: String?
    @State private var fullDisk = FullDiskAccess.Status.unknown
    @State private var finder: Bool?
    /// They've been sent to System Settings for Full Disk Access.
    @State private var askedFullDisk = false
    private let offerMove = AppInstall.shouldOffer(Bundle.main.bundleURL)

    /// Placed by eye, large to small, in fractions of the window. Name, x, y, size in points, starting tilt.
    private static let tiles: [(name: String, x: CGFloat, y: CGFloat, size: CGFloat, tilt: Double)] = [
        ("stack", -0.34, -0.24, 148, -9), ("sparkles", 0.31, -0.27, 128, 8), ("document", -0.13, 0.31, 112, 6),
        ("drive", 0.2, 0.3, 124, -7), ("globe", -0.42, 0.2, 92, 10), ("branch", 0.42, 0.06, 96, -10),
        ("cache", -0.1, -0.36, 84, 5), ("hammer", 0.09, -0.06, 70, -5), ("done", -0.17, 0.0, 62, 7), ("trash", 0.13, -0.38, 62, -12)
    ]

    var body: some View {
        GeometryReader { geometry in
            let shape = CGSize(width: geometry.size.width, height: geometry.size.height - 72)
            let origin = geometry.frame(in: .named(WelcomeFrames.space)).origin
            let middle = CGPoint(x: shape.width / 2, y: shape.height / 2)
            let side = min(300, shape.height * 0.55)
            let target = frames["hero"]
            let heroSide = placed ? min(target?.width ?? side, target?.height ?? side) : side
            // During the steps there's no sidebar yet, so the sculpture and words sit together in the middle of the window.
            let block = target.flatMap { hero in frames["copy"].map { hero.union($0) } }
            let centring = settling ? .zero : block.map { CGSize(width: middle.x - ($0.midX - origin.x), height: middle.y - (target!.midY - origin.y)) } ?? .zero
            let heroSpot = placed ? target.map { CGPoint(x: $0.midX - origin.x + centring.width, y: $0.midY - origin.y + centring.height) } ?? middle : middle
            ZStack {
                // The outline of the window, drawn from two ends that meet.
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).trim(from: 0, to: trace / 2).stroke(lineColor, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    RoundedRectangle(cornerRadius: 14, style: .continuous).trim(from: 1 - trace / 2, to: 1).stroke(lineColor, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
                .shadow(color: theme.accent, radius: 9).shadow(color: .white.opacity(0.6), radius: 2)
                .frame(width: shape.width - 2, height: shape.height - 2)
                .position(middle)
                .opacity(placed ? 0 : 1)
                // A soft burst of light where the tiles meet.
                Circle().fill(RadialGradient(colors: [.white.opacity(0.9), theme.accent.opacity(0.45), .clear], center: .center, startRadius: 4, endRadius: side * 0.72))
                    .frame(width: side * 1.5, height: side * 1.5).scaleEffect(flash ? 1.25 : 0.3).opacity(flash ? 0 : phase == .formed ? 0.9 : 0)
                    .position(middle)
                // The pose and size Overview shows, so nothing changes when it takes over.
                ScanMovieArtwork(animated: false, asset: "sculpture-motion-" + theme.rawValue, interactive: false)
                    .frame(width: heroSide, height: heroSide)
                    .scaleEffect(phase == .formed ? 1 : 0.25).opacity(phase == .formed ? 1 : 0)
                    .position(heroSpot)
                ForEach(Array(Self.tiles.enumerated()), id: \.offset) { index, tile in
                    if let image = CategoryArt.images[tile.name] { tileView(image, tile: tile, index: index, shape: shape) }
                }
                if let words = frames["copy"], let hero = target {
                    Group {
                        switch step {
                        case .welcome: welcome
                        case .move: move
                        case .permissions: permissions
                        }
                    }
                    .id(step)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .offset(y: 14).combined(with: .opacity), removal: .opacity))
                    .frame(width: words.width, alignment: .leading)
                    .position(x: words.midX - origin.x + centring.width, y: hero.midY - origin.y + centring.height)
                    .opacity(copyShown && !finished ? 1 : 0)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                Button("Skip") { finish() }.buttonStyle(.plain).stewardFont(.callout).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 5).background(.ultraThinMaterial, in: Capsule()).environment(\.colorScheme, .dark)
                    .keyboardShortcut(.cancelAction).padding(.trailing, 18).padding(.top, 14)
                    .opacity(phase == .empty || finished ? 0 : 1)
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .task { await play() }
        .task(id: step) {
            // macOS doesn't announce a change of permission, so look until the step closes.
            while step == .permissions, !Task.isCancelled {
                fullDisk = await Task.detached { FullDiskAccess.status() }.value
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
    private var lineColor: LinearGradient { LinearGradient(colors: [.white, theme.accent, .white], startPoint: .topLeading, endPoint: .bottomTrailing) }
    private func tileView(_ image: NSImage, tile: (name: String, x: CGFloat, y: CGFloat, size: CGFloat, tilt: Double), index: Int, shape: CGSize) -> some View {
        WelcomeTile(image: image, size: tile.size, tilt: tile.tilt, seed: Double(index), gathered: phase.rawValue >= Phase.gathering.rawValue)
            .scaleEffect(phase == .empty ? 0.2 : phase.rawValue >= Phase.gathering.rawValue ? 0.12 : 1)
            .opacity(phase == .empty || phase == .formed ? 0 : 1)
            .position(x: shape.width / 2 + (phase.rawValue >= Phase.gathering.rawValue ? 0 : tile.x * shape.width),
                      y: shape.height / 2 + (phase.rawValue >= Phase.gathering.rawValue ? 0 : tile.y * shape.height))
            // A little earlier or later for each, so they don't move as one sheet.
            .animation(.spring(response: phase == .floating ? 0.75 : 0.62, dampingFraction: phase == .floating ? 0.62 : 0.8).delay(Double(index) * (phase == .floating ? 0.055 : 0.03)), value: phase)
    }
    private func play() async {
        // Back after a move to Applications or a restart for permissions: straight to the steps.
        if reduceMotion || StewardPreferences.defaults.bool(forKey: Self.animationKey) {
            phase = .formed; flash = true; trace = 1; placed = true; m.welcomeReveal = 1
            if StewardPreferences.defaults.bool(forKey: Self.animationKey) { step = .permissions } // They've read the welcome.
            withAnimation(.easeOut(duration: 0.4)) { copyShown = true }
            return
        }
        func wait(_ seconds: Double) async -> Bool { try? await Task.sleep(for: .seconds(seconds)); return !finished }
        guard await wait(0.25) else { return }
        phase = .floating
        StewardSound.start.play()
        guard await wait(1.9) else { return }
        phase = .gathering
        guard await wait(0.72) else { return }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.62)) { phase = .formed }
        withAnimation(.easeOut(duration: 0.8)) { flash = true }
        guard await wait(0.75) else { return }
        withAnimation(.easeInOut(duration: 0.95)) { trace = 1 }
        guard await wait(0.8) else { return }
        // The sculpture flies to its exact place as the window fills around it.
        withAnimation(.spring(response: 0.85, dampingFraction: 0.86)) { placed = true; m.welcomeReveal = 1 }
        StewardPreferences.defaults.set(true, forKey: Self.animationKey)
        guard await wait(0.8) else { return }
        withAnimation(.easeOut(duration: 0.5)) { copyShown = true }
    }
    private func advance(to next: Step) { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { step = next } }
    private func finish() {
        guard !finished else { return }
        finished = true
        let defaults = StewardPreferences.defaults
        defaults.set(true, forKey: Self.seenKey); defaults.set(true, forKey: Self.animationKey)
        StewardSound.done.play()
        // The sculpture lands first, then the app appears around it.
        withAnimation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.88)) { phase = .formed; placed = true; settling = true; trace = 1; m.welcomeReveal = 1 }
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 620))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) { m.welcoming = false }
        }
    }
    private func moveToApplications() {
        do {
            try AppInstall.copy(Bundle.main.bundleURL)
            StewardPreferences.defaults.set(true, forKey: Self.animationKey)
            try UpdateChecker.reopen(AppInstall.destination)
        } catch { moveError = error.localizedDescription }
    }
    private func heading(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 44 * textScale, weight: .light)).tracking(-0.8).fixedSize(horizontal: false, vertical: true)
    }
    private func line(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 17 * textScale)).foregroundStyle(.white.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
    }
    private func primary(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(CleanupGlassButtonStyle()).stewardFont(.body, weight: .semibold).keyboardShortcut(.defaultAction).padding(.top, 8)
    }
    /// macOS doesn't always list a new app, and a running app may not get access until it reopens. Apple offers no API for either.
    private var fullDiskHelp: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)).resizable().frame(width: 34, height: 34)
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }.help("Drag into the Full Disk Access list")
            Text("Turn on \(Bundle.main.bundleURL.deletingPathExtension().lastPathComponent). Not in the list? Drag this icon into it.").stewardFont(.caption).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("Reopen") { try? UpdateChecker.reopen(Bundle.main.bundleURL) }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)).stewardFont(.callout, weight: .semibold)
                .help("Already turned it on? macOS may need Artifloam to reopen first.")
        }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Welcome to Artifloam")
            line("Room to breathe, for your Mac.")
            VStack(alignment: .leading, spacing: 14) {
                GlossyPoint(icon: "hand.raised.fill", text: String(localized: "Nothing is removed until you choose it"), accent: theme.accent)
                GlossyPoint(icon: "lock.fill", text: String(localized: "Your files stay on this Mac"), accent: theme.accent)
            }.padding(.top, 6)
            primary("Continue") { advance(to: offerMove ? .move : .permissions) }.disabled(!copyShown) // Someone still typing must not press it unseen.
        }
    }
    private var move: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Move to Applications")
            line("Artifloam works best from your Applications folder. macOS keeps its permissions there, and the daily cleanup and uninstall expect it.")
            if let moveError { Label(moveError, systemImage: "exclamationmark.triangle").stewardFont(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 10) {
                Button("Move and Reopen") { moveToApplications() }.buttonStyle(CleanupGlassButtonStyle()).keyboardShortcut(.defaultAction)
                Button("Not Now") { advance(to: .permissions) }.buttonStyle(CleanupGlassButtonStyle(secondary: true))
            }.stewardFont(.body, weight: .semibold).padding(.top, 8)
        }
    }
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Permissions")
            line("macOS asks you first. Both are optional, and you can change them later in System Settings.")
            VStack(spacing: 12) {
                WelcomePermissionCard(icon: "lock.shield.fill", title: String(localized: "Full Disk Access"), detail: String(localized: "Measures protected folders like the Trash."), accent: theme.accent, granted: fullDisk == .granted, actionTitle: askedFullDisk ? String(localized: "Settings", comment: "Button: open System Settings") : String(localized: "Allow", comment: "Button: allow this permission")) {
                    // Trying a protected folder first is what puts this app in the list. There's no API for this.
                    _ = FullDiskAccess.status()
                    askedFullDisk = true
                    NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                }
                WelcomePermissionCard(icon: "trash.fill", title: "Finder", detail: String(localized: "Lists and empties the Trash when you ask."), accent: theme.accent, granted: finder == true) {
                    Task { finder = await Task.detached { TrashBins.requestFinderAccess() }.value }
                }
            }.padding(.top, 6)
            if askedFullDisk && fullDisk != .granted { fullDiskHelp }
            primary("Open Artifloam") { finish() }
        }
    }
}

/// A whole card you can press, not just its button. Once allowed it only shows the check.
private struct WelcomePermissionCard: View {
    /// The green of the leaf in the app icon.
    private static let leafGreen = Color(red: 0.30, green: 0.76, blue: 0.36)
    let icon: String, title: String, detail: String, accent: Color, granted: Bool
    var actionTitle = String(localized: "Allow", comment: "Button: allow this permission")
    let allow: () -> Void
    @Environment(\.stewardTextScale) private var textScale
    @State private var hovered = false
    var body: some View {
        Button(action: allow) {
            HStack(spacing: 14) {
                GlossyPoint(icon: icon, text: "", accent: accent).fixedSize()
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15 * textScale, weight: .semibold))
                    Text(detail).font(.system(size: 12.5 * textScale)).foregroundStyle(.white.opacity(0.68)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if granted { Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).symbolRenderingMode(.palette).foregroundStyle(.white, Self.leafGreen).shadow(color: Self.leafGreen.opacity(0.6), radius: 6) }
                else {
                    Text(actionTitle).font(.system(size: 13 * textScale, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                        .background(.white.opacity(hovered ? 0.28 : 0.16), in: Capsule())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(granted ? 0.05 : hovered ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(hovered && !granted ? 0.3 : 0.14), lineWidth: 0.8) }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!granted) // Not `.disabled`: that would also fade the check.
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .accessibilityLabel(String(localized: "\(title). \(detail)"))
        .accessibilityValue(granted ? "Allowed" : "Not allowed")
    }
}

/// One glass tile, drifting and turning a little in the air.
private struct WelcomeTile: View {
    let image: NSImage, size: CGFloat, tilt: Double, seed: Double, gathered: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: gathered)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
                .shadow(color: .black.opacity(0.28), radius: size * 0.14, y: size * 0.09)
                .rotationEffect(.degrees(gathered ? tilt * 2.4 : tilt + sin(time * 0.7 + seed) * 2.5))
                .offset(x: gathered ? 0 : sin(time * 0.53 + seed * 1.9) * 6, y: gathered ? 0 : cos(time * 0.61 + seed * 1.3) * 7)
        }
    }
}

/// The window's shape while it fills, opening from the middle out to its full size.
struct WelcomeReveal: Shape {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func path(in rect: CGRect) -> Path {
        guard progress > 0 else { return Path() }
        let width = rect.width * progress, height = rect.height * progress
        let opening = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        return Path(roundedRect: opening, cornerRadius: min(14 + (1 - min(progress, 1)) * 48, min(width, height) / 2), style: .continuous)
    }
}

/// The whole-window stages that replace the app: first launch and uninstall.
struct OnceStages: ViewModifier {
    let theme: StewardTheme
    @EnvironmentObject private var m: StewardModel
    @State private var frames = [String: CGRect]()
    func body(content: Content) -> some View {
        content
            .onPreferenceChange(WelcomeFrames.self) { frames = $0 }
            .overlay { if m.welcoming { WelcomeStage(theme: theme, frames: frames).transition(.opacity) } }
            .overlay { if let flow = m.uninstall { UninstallStage(flow: flow, theme: theme).transition(.opacity) } }
            .animation(.easeOut(duration: 0.25), value: m.uninstall != nil)
            .coordinateSpace(name: WelcomeFrames.space)
    }
}
/// The real page sits measured but unseen until the welcome hands over to it.
struct WelcomeHidden: ViewModifier {
    @EnvironmentObject private var m: StewardModel
    func body(content: Content) -> some View {
        content.opacity(m.welcoming ? 0 : 1).allowsHitTesting(!m.welcoming)
    }
}
/// The traffic lights have nothing to sit on until the window has filled.
struct WelcomeControlsFade: ViewModifier {
    @EnvironmentObject private var m: StewardModel
    func body(content: Content) -> some View {
        content.opacity(m.welcomeReveal >= 1 ? 1 : 0).animation(.easeOut(duration: 0.3).delay(0.35), value: m.welcomeReveal)
    }
}
