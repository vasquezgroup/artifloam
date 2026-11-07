import AVFoundation
import SwiftUI

/// The Mac app's section colours and artwork (Sources/MacSteward/VisualLanguage.swift), for the sections the iPhone has.
enum StewardTheme: String {
    case care, cleanup, files, system, space, iphone

    var accent: Color {
        switch self {
        case .care: Color(red: 0.79, green: 0.59, blue: 1)
        case .cleanup: Color(red: 0.49, green: 0.91, blue: 0.65)
        case .files: Color(red: 1, green: 0.73, blue: 0.42)
        case .system: Color(red: 0.45, green: 0.78, blue: 1)
        case .space: Color(red: 1, green: 0.86, blue: 0.42)
        case .iphone: Color(red: 0.68, green: 0.67, blue: 1)
        }
    }
    var vivid: Color {
        switch self {
        case .care: Color(red: 0.74, green: 0.22, blue: 0.95)
        case .cleanup: Color(red: 0.10, green: 0.72, blue: 0.42)
        case .files: Color(red: 0.96, green: 0.52, blue: 0.10)
        case .system: Color(red: 0.16, green: 0.48, blue: 0.96)
        case .space: Color(red: 0.92, green: 0.70, blue: 0.06)
        case .iphone: Color(red: 0.34, green: 0.27, blue: 0.96)
        }
    }
    var backdrop: (deep: Color, mid: Color, bright: Color) {
        switch self {
        case .care: (Color(red: 0.10, green: 0.04, blue: 0.22), Color(red: 0.36, green: 0.11, blue: 0.62), Color(red: 0.84, green: 0.32, blue: 0.80))
        case .cleanup: (Color(red: 0.03, green: 0.14, blue: 0.07), Color(red: 0.10, green: 0.40, blue: 0.15), Color(red: 0.44, green: 0.74, blue: 0.16))
        case .files: (Color(red: 0.20, green: 0.06, blue: 0.03), Color(red: 0.58, green: 0.22, blue: 0.05), Color(red: 0.98, green: 0.64, blue: 0.20))
        case .system: (Color(red: 0.02, green: 0.08, blue: 0.22), Color(red: 0.07, green: 0.28, blue: 0.66), Color(red: 0.22, green: 0.70, blue: 0.96))
        case .space: (Color(red: 0.17, green: 0.12, blue: 0.02), Color(red: 0.54, green: 0.40, blue: 0.04), Color(red: 0.98, green: 0.86, blue: 0.30))
        case .iphone: (Color(red: 0.05, green: 0.03, blue: 0.26), Color(red: 0.19, green: 0.14, blue: 0.70), Color(red: 0.50, green: 0.46, blue: 1))
        }
    }
    var sculpture: String { self == .space ? "space-map-sculpture" : "sculpture-motion-\(rawValue)" }
}

/// The Mac's HEIC files, loaded as they are. `Image(name)` only finds files in an asset catalog.
enum Artwork {
    static func image(_ name: String) -> Image {
        let image = Bundle.main.path(forResource: name, ofType: "heic").flatMap(UIImage.init(contentsOfFile:))
        return image.map(Image.init(uiImage:)) ?? Image(systemName: "sparkles")
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = StewardTheme.care }
extension EnvironmentValues {
    var stewardTheme: StewardTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

struct AtmosphereView: View {
    let theme: StewardTheme
    var body: some View {
        let ramp = theme.backdrop
        ZStack {
            LinearGradient(stops: [.init(color: ramp.deep, location: 0), .init(color: ramp.mid, location: 0.55), .init(color: ramp.bright, location: 1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [ramp.bright.opacity(0.6), ramp.bright.opacity(0.12), .clear], center: UnitPoint(x: 0.8, y: 0.92), startRadius: 0, endRadius: 420)
            LinearGradient(colors: [.black.opacity(0.22), .clear], startPoint: .top, endPoint: .center)
            // Keeps white text readable where the ramp is brightest.
            LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The section's glass sculpture. Plays the Mac's scan movie while working, and shows its still otherwise or with Reduce Motion.
struct Sculpture: View {
    let theme: StewardTheme
    var moving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [theme.vivid.opacity(0.55), .clear], center: .center, startRadius: 10, endRadius: 130)).blur(radius: 20).scaleEffect(1.3)
            // The Space Map art is rendered purple. The Mac turns it gold the same way.
            Group {
                if moving && !reduceMotion && scenePhase == .active {
                    LoopingMovie(name: theme.sculpture + "-scan")
                } else {
                    Artwork.image(theme.sculpture + "-look-poster").resizable().scaledToFit()
                }
            }
            .hueRotation(.degrees(theme == .space ? 155 : 0))
        }
        .shadow(color: theme.vivid.opacity(0.45), radius: 26, y: 10)
        .accessibilityHidden(true)
    }
}

private struct LoopingMovie: UIViewRepresentable {
    let name: String

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var looper: AVPlayerLooper?
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .clear
        guard let url = Bundle.main.url(forResource: name, withExtension: "mov") else { return view }
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        view.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        let layer = view.layer as! AVPlayerLayer
        layer.player = player
        layer.videoGravity = .resizeAspect
        layer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}
}

/// Our round action button in liquid glass, tinted with the section's colour.
struct OrbAction: View {
    let title: LocalizedStringKey
    let icon: String
    let accent: Color
    var disabled = false
    /// Shows a ring around the button while something is running.
    var progress: Double? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(accent.opacity(0.5)).blur(radius: 18)
                if let progress {
                    Circle().stroke(.white.opacity(0.18), lineWidth: 6).padding(-7)
                    Circle().trim(from: 0, to: min(1, max(0, progress))).stroke(LinearGradient(colors: [accent, .white], startPoint: .bottomLeading, endPoint: .topTrailing), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(-7)
                }
                glass
                Circle().fill(RadialGradient(colors: [.white.opacity(0.34), .clear], center: UnitPoint(x: 0.5, y: 0.12), startRadius: 2, endRadius: 46))
                Circle().stroke(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.12), .white.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
                VStack(spacing: 2) {
                    Image(systemName: icon).font(.system(size: 23, weight: .medium)).shadow(color: .black.opacity(0.35), radius: 1, y: 2)
                    Text(title).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7).shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                }
                .foregroundStyle(.white).padding(8)
            }
            .frame(width: 92, height: 92)
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityValue(progress.map { Text("\(Int($0 * 100)) percent complete") } ?? Text(""))
    }

    @ViewBuilder private var glass: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(accent.opacity(0.75)).interactive(), in: .circle)
        } else {
            Circle().fill(.ultraThinMaterial).overlay { Circle().fill(accent.opacity(0.62)) }
        }
    }
}

extension View {
    /// The main action, fixed above the tab bar while the page scrolls behind it, with a short summary beside it.
    func orbFooter<Orb: View>(summary: Text? = nil, @ViewBuilder orb: () -> Orb) -> some View {
        let button = orb()
        return safeAreaInset(edge: .bottom, spacing: 0) {
            // Equal space on both sides keeps the button centred, with or without a summary.
            HStack(spacing: 12) {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                button
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1).overlay(alignment: .leading) {
                    if let summary {
                        summary.font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.white).multilineTextAlignment(.leading).lineLimit(2).minimumScaleFactor(0.8).fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 7).background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Darker than the Mac's cards, because a phone's gradient runs brighter behind the text.
            .background(.black.opacity(0.24), in: .rect(cornerRadius: 20))
            .background(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.14), lineWidth: 0.5) }
    }
}

/// One of the Mac's glass category icons.
struct CategoryIcon: View {
    let name: String
    var body: some View {
        Artwork.image(name).resizable().scaledToFit().frame(width: 44, height: 44).accessibilityHidden(true)
    }
}

/// Full-bleed page: atmosphere behind, sculpture and title on top, then the content. Same stage as the Mac sections.
struct StagePage<Content: View>: View {
    let theme: StewardTheme
    var title: LocalizedStringKey? = nil
    var subtitle: LocalizedStringKey? = nil
    var moving = false
    /// A picture of its own instead of the section's sculpture, for when the art itself has something to say.
    var artwork: String? = nil
    var sculptureSize: CGFloat = 170
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            AtmosphereView(theme: theme)
            ScrollView {
                VStack(spacing: 18) {
                    if let artwork {
                        Artwork.image(artwork).resizable().scaledToFit().frame(width: 240, height: 240).shadow(color: theme.vivid.opacity(0.45), radius: 26, y: 10).padding(.top, 8).accessibilityHidden(true)
                    } else {
                        Sculpture(theme: theme, moving: moving).frame(width: sculptureSize, height: sculptureSize).padding(.top, 8)
                    }
                    if let title, let subtitle {
                        VStack(spacing: 4) {
                            Text(title).font(.largeTitle.weight(.light)).accessibilityAddTraits(.isHeader)
                            Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                        }
                    }
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
        }
        .environment(\.stewardTheme, theme)
        .tint(theme.accent)
    }
}

/// How full something is: a glowing, glass-topped bar in the section's colours.
struct GlassMeter: View {
    let fraction: Double
    let theme: StewardTheme

    var body: some View {
        GeometryReader { box in
            let width = Swift.max(box.size.height, box.size.width * Swift.min(1, Swift.max(0, fraction)))
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.28))
                    .overlay { Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5) }
                Capsule().fill(LinearGradient(colors: [theme.vivid, theme.accent, .white], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width)
                    .overlay(alignment: .top) {
                        // The highlight along the top is what makes it read as glass.
                        Capsule().fill(.white.opacity(0.45)).frame(height: box.size.height * 0.28).padding(.horizontal, box.size.height * 0.4).padding(.top, 1.5)
                    }
                    .shadow(color: theme.accent.opacity(0.8), radius: 8)
                    .animation(.smooth(duration: 0.6), value: fraction)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

/// A plain page in the section's colours, for detail screens.
struct DetailPage<Content: View>: View {
    let theme: StewardTheme
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            AtmosphereView(theme: theme)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }.padding(16)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.stewardTheme, theme)
        .tint(theme.accent)
    }
}

/// A navigation row with the Mac's glass chip, used on every section.
struct FeatureRow: View {
    let icon: String
    let title: LocalizedStringKey
    var detail: Text? = nil
    var value: String? = nil
    var chevron = true

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(name: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                if let detail { detail.font(.footnote).foregroundStyle(.white.opacity(0.7)) }
            }
            Spacer(minLength: 8)
            if let value { Text(value).font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.85)) }
            if chevron { Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.4)) }
        }
        .contentShape(Rectangle())
    }
}

/// The one round button for starting and stopping a scan, on every section.
struct ScanOrb: View {
    let theme: StewardTheme
    @Environment(Library.self) private var library
    var body: some View {
        if library.working {
            OrbAction(title: "Stop", icon: "stop.fill", accent: theme.vivid, progress: Double(library.checked) / Double(max(library.total, 1))) { library.stop() }
        } else {
            OrbAction(title: "Scan", icon: "magnifyingglass", accent: theme.vivid) { Task { await library.start() } }
        }
    }
}

extension Library {
    var scanSummary: Text? { working ? Text("\(checked) of \(total)") : nil }
}
