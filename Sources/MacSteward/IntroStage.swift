import SwiftUI
import MacStewardCore

struct IntroStage: View {
    let theme: StewardTheme
    /// The module's name, shown large and light.
    var heading: String? = nil
    let title: String
    let subtitle: String
    let points: [(String, String)]
    let scanning: Bool
    let progress: String
    /// Overview only: live health. Issues replace bullets, one for one, at the same row height.
    var health: MacHealth? = nil
    var fix: (MacIssue) -> Void = { _ in }
    /// Replaces the scan headline while something other than a scan runs on this stage.
    var workingTitle: String? = nil
    /// Overview during first launch: says where the sculpture and words are, so the welcome can land on them.
    var reportsFrames = false
    @Environment(\.stewardTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            // The page runs 60 pt under the floating Scan controls (MainView), so centred content must stay 120 pt shorter
            // than the page to clear them. Shrinks a little in short windows (down to 240); below that it scrolls.
            let illustrationWidth = scanning ? min(325, geo.size.height * 0.66) : min(345, geo.size.width * 0.42, max(240, geo.size.height - 120))
            let illustrationHeight = scanning ? min(300, geo.size.height * 0.62) : illustrationWidth
            let copyWidth = scanning ? min(580, geo.size.width - 50) : min(380, geo.size.width - illustrationWidth - 62)
            // A scroll view only when the window is too short: it is an AppKit view, and blur doesn't animate on it mid-slide.
            ViewThatFits(in: .vertical) {
            stage(illustrationWidth: illustrationWidth, illustrationHeight: illustrationHeight, copyWidth: copyWidth, height: geo.size.height)
            ScrollView { stage(illustrationWidth: illustrationWidth, illustrationHeight: illustrationHeight, copyWidth: copyWidth, height: geo.size.height).overlayScrollers() }
                .scrollIndicators(.hidden).scrollClipDisabled() // the artwork's glow reaches past the page edges
            }
        }
    }
    private func stage(illustrationWidth: CGFloat, illustrationHeight: CGFloat, copyWidth: CGFloat, height: CGFloat) -> some View {
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                let layout = scanning ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(alignment: .center, spacing: 30))
                layout {
                    StewardIllustration(theme: theme, scanning: scanning)
                        .id(theme)
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.96)))
                        // Never size it by window height: a short window scrolls instead of shrinking or cropping the artwork.
                        .frame(width: illustrationWidth, height: illustrationHeight)
                        .reportingWelcomeFrame("hero", enabled: reportsFrames)
                    VStack(alignment: scanning ? .center : .leading, spacing: 12) {
                        if scanning {
                            Text(workingTitle ?? (theme == .trash ? "Looking through your Trash…" : "Finding a little more room…")).stewardFont(.title).tracking(-0.6).multilineTextAlignment(.center)
                            Text(progress).stewardFont(.body).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
                                .lineLimit(nil).fixedSize(horizontal: false, vertical: true).frame(minHeight: 32)
                        } else {
                            Text(heading ?? title).font(.system(size: 44 * textScale, weight: .light)).tracking(-0.8)
                                .fixedSize(horizontal: false, vertical: true).contentTransition(.opacity)
                            let issues = Array((health?.issues ?? []).prefix(2))
                            if issues.isEmpty {
                                Text(heading == nil ? subtitle : (subtitle.hasPrefix("Last cleanup") ? subtitle : title))
                                    .font(.system(size: 17 * textScale)).foregroundStyle(.white.opacity(0.72))
                                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            } else {
                                let count = health?.issues.count ?? 0
                                Text("\(count) \(count == 1 ? "thing is" : "things are") slowing your Mac")
                                    .font(.system(size: 17 * textScale, weight: .medium)).foregroundStyle(Color(red: 0.98, green: 0.78, blue: 0.46))
                            }
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(issues) { issue in IssuePoint(issue: issue, fix: { fix(issue) }) }
                                ForEach(Array(points.dropFirst(issues.count).enumerated()), id: \.offset) { _, point in GlossyPoint(icon: point.0, text: point.1, accent: theme.accent) }
                            }.padding(.top, 18).transition(.opacity)
                            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: issues.map(\.id))
                        }
                    }.frame(width: copyWidth, alignment: scanning ? .center : .leading)
                        .reportingWelcomeFrame("copy", enabled: reportsFrames)
                }
                .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.88), value: scanning)
                Spacer(minLength: 12)

            }.frame(maxWidth: .infinity, minHeight: height)
    }
}

/// A warning in the same glossy-row style: amber squircle, the problem, what fixing it is worth, and the fix.
struct IssuePoint: View {
    let issue: MacIssue
    let fix: () -> Void
    @Environment(\.stewardTextScale) private var textScale
    @State private var hovered = false
    private var icon: String {
        switch issue.kind {
        case .storage: return "internaldrive.fill"
        case .memory: return "memorychip.fill"
        case .cpu: return "cpu.fill"
        case .heat: return "thermometer.high"
        case .battery: return "battery.25"
        case .restart: return "arrow.clockwise"
        case .network: return "wifi.slash"
        }
    }
    var body: some View {
        Group {
            // The whole row is the fix; hovering lights it up so it reads as clickable.
            if issue.fixLabel != nil {
                Button(action: fix) { row }.buttonStyle(.plain)
                    .onHover { inside in
                        hovered = inside
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
            } else { row }
        }.transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .scale(scale: 0.9).combined(with: .opacity)))
    }
    private var row: some View {
        HStack(spacing: 14) {
            GlossyPoint(icon: icon, text: "", accent: .orange).fixedSize()
            // One line, like the bullets it replaces, so the copy never grows into the controls below.
            Text(issue.title).font(.system(size: 16 * textScale, weight: .semibold)).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                .help(issue.flag)
            Text("+\(issue.points)").font(.system(size: 12 * textScale, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Color(red: 0.98, green: 0.78, blue: 0.46)).padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.orange.opacity(0.18), in: Capsule()).help("Health points you get back by fixing this")
            if let label = issue.fixLabel {
                Spacer(minLength: 8)
                Text(label).font(.system(size: 13 * textScale, weight: .semibold))
                    .foregroundStyle(Color(red: 0.02, green: 0.2, blue: 0.17)).padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Color.mint.opacity(hovered ? 1 : 0.88), in: Capsule())
            }
        }
        // The hover plate reaches past the row without moving it out of line with the bullets.
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovered ? 0.12 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, -10).padding(.vertical, -6)
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

/// A start-screen feature row: filled glossy squircle (accent gradient, white symbol, soft top light) and a bold label.
struct GlossyPoint: View {
    let icon: String
    let text: String
    let accent: Color
    @Environment(\.stewardTextScale) private var textScale
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 15 * textScale, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                        .overlay(alignment: .top) { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.22)).frame(height: 14).padding(2).blur(radius: 1.5) }
                        .shadow(color: accent.opacity(0.4), radius: 6, y: 2)
                }
            if !text.isEmpty { Text(text).font(.system(size: 16 * textScale, weight: .semibold)).foregroundStyle(.white.opacity(0.92)) }
        }
    }
}
