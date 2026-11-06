import SwiftUI
import AppKit
import MacStewardCore

/// Shown before a scan that would miss protected folders. It only ever opens System Settings: the person grants access there.
struct FullDiskGate: View {
    let theme: StewardTheme
    @EnvironmentObject private var m: StewardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var waiting = false
    @State private var unlocked = false
    private var perks: [(String, String)] { [("trash", String(localized: "The whole Trash, folders included")), ("safari", String(localized: "Safari, Mail and other browser data")), ("lock.open", String(localized: "Protected app folders"))] }
    private var glow: Color { unlocked ? .mint : theme.accent }

    /// A slowly turning ring and sparks around the shield, like an item waiting to be unlocked.
    private var artwork: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().fill(RadialGradient(colors: [glow.opacity(0.55), theme.vivid.opacity(0.22), .clear], center: .center, startRadius: 30, endRadius: 150))
                    .frame(width: 300, height: 300).scaleEffect(1 + sin(time * 1.6) * 0.05)
                Circle().stroke(AngularGradient(colors: [glow, .clear, glow.opacity(0.6), .clear, glow], center: .center), lineWidth: 3)
                    .frame(width: 214, height: 214).rotationEffect(.radians(time * 0.7)).blur(radius: 0.5)
                Circle().stroke(AngularGradient(colors: [.white.opacity(0.7), .clear, .clear, .white.opacity(0.3), .clear], center: .center), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
                    .frame(width: 242, height: 242).rotationEffect(.radians(-time * 0.4))
                ForEach(0..<9, id: \.self) { index in
                    let angle = time * (0.35 + Double(index % 3) * 0.14) + Double(index) * 0.7
                    let reach = 108 + CGFloat(index % 3) * 17
                    Circle().fill(.white).frame(width: index % 3 == 0 ? 5 : 3, height: index % 3 == 0 ? 5 : 3)
                        .shadow(color: glow, radius: 6).opacity(0.55 + sin(time * 2 + Double(index)) * 0.4)
                        .offset(x: cos(angle) * reach, y: sin(angle) * reach)
                }
                if let shield = StewardArtwork.images["symbol-system"] {
                    Image(nsImage: shield).resizable().interpolation(.high).frame(width: 156, height: 156)
                        .shadow(color: glow.opacity(0.7), radius: 26).offset(y: sin(time * 1.1) * 4)
                }
                Image(systemName: unlocked ? "checkmark.circle.fill" : "lock.circle.fill").font(.system(size: 42)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, unlocked ? Color.mint : theme.vivid).shadow(color: .black.opacity(0.4), radius: 6, y: 3).offset(x: 62, y: 58)
                    .scaleEffect(unlocked ? 1.15 : 1).animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.55), value: unlocked)
            }.frame(width: 300, height: 280)
        }.accessibilityHidden(true)
    }
    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Text("\(number)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.black.opacity(0.8)).frame(width: 22, height: 22).background(glow, in: Circle())
            Text(text).stewardFont(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.backdrop.deep.opacity(0.96), theme.backdrop.mid.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                .contentShape(Rectangle()).onTapGesture { }
            ScrollView {
                HStack(alignment: .center, spacing: 34) {
                    artwork
                    VStack(alignment: .leading, spacing: 16) {
                        Text(unlocked ? "Full scan unlocked" : "Unlock the full scan").font(.system(size: 38, weight: .light)).tracking(-0.7).contentTransition(.opacity)
                        Text(unlocked ? "Starting now. Your files are still only read until you choose to remove something." : "macOS hides some folders from every app. With your OK, Artifloam can measure them. Your files and what it finds in them stay on this Mac. None of it is ever sent anywhere.")
                            .font(.system(size: 15)).foregroundStyle(.white.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(perks, id: \.1) { perk in
                                HStack(spacing: 10) {
                                    Image(systemName: perk.0).frame(width: 22).foregroundStyle(glow)
                                    Text(perk.1).stewardFont(.callout, weight: .medium)
                                    Spacer(minLength: 8)
                                    Image(systemName: unlocked ? "checkmark" : "lock.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(unlocked ? Color.mint : .white.opacity(0.5))
                                }.padding(.horizontal, 12).padding(.vertical, 8).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        if !unlocked {
                            if waiting {
                                VStack(alignment: .leading, spacing: 9) {
                                    step(1, "In System Settings, turn on Artifloam.")
                                    step(2, "If macOS offers Quit & Reopen, choose it.")
                                    HStack(spacing: 10) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)).resizable().frame(width: 34, height: 34)
                                            .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }.help("Drag into the Full Disk Access list")
                                        Text("Not in the list? Drag this icon into it.").stewardFont(.caption).foregroundStyle(.white.opacity(0.72))
                                    }
                                    Label("Watching for the change…", systemImage: "antenna.radiowaves.left.and.right").stewardFont(.caption).foregroundStyle(glow)
                                }
                            }
                            HStack(spacing: 10) {
                                Button(waiting ? "Open Settings again" : "Allow access") { waiting = true; NSWorkspace.shared.open(FullDiskAccess.settingsURL) }.buttonStyle(CleanupGlassButtonStyle()).keyboardShortcut(.defaultAction)
                                Button("Scan without it") { m.finishAccessGate() }.buttonStyle(CleanupGlassButtonStyle(secondary: true)).keyboardShortcut(.cancelAction)
                            }
                            Button("Don't ask again") { m.finishAccessGate(forever: true) }.buttonStyle(.plain).stewardFont(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                    }.frame(maxWidth: 440, alignment: .leading)
                }.padding(34).frame(maxWidth: .infinity, alignment: .center)
            }.scrollBounceBehavior(.basedOnSize).defaultScrollAnchor(.center)
        }
        .transition(.opacity)
        .task(id: waiting) {
            // macOS doesn't announce the change, so look until it shows up or the panel closes.
            while waiting, !unlocked, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                if FullDiskAccess.status() == .granted {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { unlocked = true }
                    try? await Task.sleep(for: .seconds(1.3))
                    m.finishAccessGate()
                }
            }
        }
    }
}

struct FullDiskGateHost: ViewModifier {
    let theme: StewardTheme
    @EnvironmentObject private var m: StewardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.overlay { if m.accessGate != nil { FullDiskGate(theme: theme) } }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: m.accessGate != nil)
    }
}
