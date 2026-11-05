import SwiftUI
import AppKit
import MacStewardCore

/// The uninstall from first look to goodbye. Nothing changes until the person presses Uninstall.
struct UninstallFlow: Equatable {
    enum Phase: Equatable { case confirm, working, finished }
    var phase = Phase.confirm
    var items = [UninstallItem]()
    /// nil when this copy isn't an installed one; the person then removes it.
    var app: URL?
    var appBytes: UInt64 = 0
    var scheduled = false
    var steps = [String]()
    /// How many steps are done.
    var completed = 0
    var failures = [String]()
    var holdsFullDisk = false
    var bytes: UInt64 { items.reduce(appBytes) { $0 + $1.bytes } }
}

extension StewardModel {
    func requestUninstall() {
        guard !welcoming, uninstall == nil, !busy, !scanning, cleaning == nil, removal == nil, !keeper.running else { return }
        busy = true // Holds off Keep space free and every other task for as long as this is open.
        let bundle = Bundle.main.bundleURL
        Task {
            var flow = await Task.detached(priority: .userInitiated) { () -> UninstallFlow in
                var flow = UninstallFlow(items: Uninstaller.items())
                if Uninstaller.removableApp(bundle) { flow.app = bundle; flow.appBytes = Uninstaller.size(of: bundle) }
                return flow
            }.value
            flow.scheduled = Scheduler.isInstalled
            flow.holdsFullDisk = FullDiskAccess.status() == .granted
            uninstall = flow
        }
    }
    func cancelUninstall() { uninstall = nil; busy = false }
    func confirmUninstall() {
        guard var flow = uninstall, flow.phase == .confirm else { return }
        let steps = Uninstaller.plan(items: flow.items, app: flow.app)
        flow.phase = .working; flow.steps = steps.map(\.title)
        uninstall = flow
        StewardSound.start.play()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Task {
            for step in steps {
                let failures = await Task.detached(priority: .userInitiated) { step.perform() }.value
                // each step takes milliseconds; the pause lets a person see what is happening.
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 850))
                uninstall?.failures += failures
                uninstall?.completed += 1
            }
            uninstall?.phase = .finished
            StewardSound.done.play()
            // Leave by itself, so nothing writes settings back. With a failure the person needs time to read it.
            if uninstall?.failures.isEmpty == true, uninstall?.app != nil {
                try? await Task.sleep(for: .seconds(8))
                NSApp.terminate(nil)
            }
        }
    }
}

struct UninstallStage: View {
    let flow: UninstallFlow
    let theme: StewardTheme
    @EnvironmentObject private var m: StewardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var finishedAt: Date?
    private var finished: Bool { flow.phase == .finished }
    private var glow: Color { finished ? .mint : theme.accent }
    /// 0 waiting above the bin, 1 inside it.
    private var fall: Double {
        switch flow.phase {
        case .confirm: return 0
        case .working: return Double(flow.completed) / Double(max(1, flow.steps.count))
        case .finished: return 1
        }
    }
    private static let bin: NSImage? = StewardResources.bundle.url(forResource: "category-trash", withExtension: "heic").flatMap { NSImage(contentsOf: $0) }

    /// The app icon floats above the glass bin, sinks into it step by step, and the bin answers with a burst of light.
    private var artwork: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let since = finishedAt.map { timeline.date.timeIntervalSince($0) } ?? 0
            ZStack {
                Circle().fill(RadialGradient(colors: [glow.opacity(0.5), theme.vivid.opacity(0.2), .clear], center: .center, startRadius: 30, endRadius: 170))
                    .frame(width: 340, height: 340).scaleEffect(1 + sin(time * 1.5) * 0.04).offset(y: 30)
                Circle().stroke(AngularGradient(colors: [glow, .clear, glow.opacity(0.6), .clear, glow], center: .center), lineWidth: 3)
                    .frame(width: 262, height: 262).rotationEffect(.radians(time * 0.7)).blur(radius: 0.5).offset(y: 30)
                Circle().stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
                    .frame(width: 292, height: 292).rotationEffect(.radians(-time * 0.4)).offset(y: 30)
                ForEach(0..<10, id: \.self) { index in
                    let angle = time * (0.3 + Double(index % 3) * 0.13) + Double(index) * 0.63
                    let reach = 130 + CGFloat(index % 3) * 16
                    Circle().fill(.white).frame(width: index % 3 == 0 ? 5 : 3, height: index % 3 == 0 ? 5 : 3).shadow(color: glow, radius: 6)
                        .opacity(0.5 + sin(time * 2 + Double(index)) * 0.4).offset(x: cos(angle) * reach, y: sin(angle) * reach + 30)
                }
                if let bin = Self.bin {
                    Image(nsImage: bin).resizable().interpolation(.high).scaledToFit().frame(width: 210, height: 210).offset(y: 52)
                        .shadow(color: glow.opacity(0.7), radius: 26)
                        .scaleEffect(finished && !reduceMotion ? 1.06 : 1).animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.45), value: finished)
                }
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
                    .rotationEffect(.degrees(fall * 14 + (fall == 0 ? sin(time * 0.9) * 3 : 0)))
                    .scaleEffect(1 - fall * 0.72)
                    .offset(y: -92 + fall * 142 + (fall == 0 ? sin(time * 1.2) * 6 : 0))
                    .opacity(finished ? 0 : 1)
                    .animation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.72), value: fall)
                    .animation(reduceMotion ? nil : .easeIn(duration: 0.25), value: finished)
                // One burst when the last step lands.
                if finished, !reduceMotion, since < 1.6 {
                    ForEach(0..<22, id: \.self) { index in
                        let angle = Double(index) / 22 * 2 * .pi + Double(index % 3) * 0.2
                        let distance = since * (130 + Double(index % 5) * 34) * (1 - since * 0.22)
                        Circle().fill(index % 2 == 0 ? Color.mint : .white).frame(width: index % 3 == 0 ? 7 : 4, height: index % 3 == 0 ? 7 : 4)
                            .shadow(color: .mint, radius: 5).opacity(max(0, 1 - since / 1.6))
                            .offset(x: cos(angle) * distance, y: sin(angle) * distance + 30)
                    }
                }
                if finished {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 42)).symbolRenderingMode(.palette).foregroundStyle(.white, Color.mint)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3).offset(x: 72, y: 112).transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }.frame(width: 340, height: 360)
        }.accessibilityHidden(true)
    }
    private func line(_ title: String, _ detail: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(glow)
            Text(title).stewardFont(.callout, weight: .medium).lineLimit(1)
            Spacer(minLength: 8)
            Text(detail).stewardFont(.caption).foregroundStyle(.white.opacity(0.6)).monospacedDigit().lineLimit(1)
        }.padding(.horizontal, 12).padding(.vertical, 8).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
    /// Identical locations for several app identifiers read as one row.
    private var rows: [(title: String, bytes: UInt64)] {
        var seen = [String: UInt64](), order = [String]()
        for item in flow.items { if seen[item.title] == nil { order.append(item.title) }; seen[item.title, default: 0] += item.bytes }
        return order.map { ($0, seen[$0] ?? 0) }
    }
    private var confirm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Uninstall Artifloam?").font(.system(size: 38, weight: .light)).tracking(-0.7)
            Text("Your own files stay exactly where they are. This removes only what Artifloam created, and the Trash keeps it until you empty the Trash.")
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                if flow.app != nil { line("Artifloam app", formattedBytes(flow.appBytes) + " · Trash", icon: "app.dashed") }
                ForEach(rows, id: \.title) { line($0.title, formattedBytes($0.bytes) + " · Trash", icon: "folder") }
                if flow.scheduled { line("Daily cleanup", "Turned off", icon: "calendar.badge.minus") }
                line("Settings and permissions", "Cleared for good", icon: "slider.horizontal.3")
            }
            if flow.app == nil { Label("This copy isn't in Applications. Drag it to the Trash yourself afterwards.", systemImage: "info.circle").stewardFont(.caption).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 10) {
                Button("Uninstall", role: .destructive) { m.confirmUninstall() }.buttonStyle(CleanupGlassButtonStyle())
                Button("Keep Artifloam") { m.cancelUninstall() }.buttonStyle(CleanupGlassButtonStyle(secondary: true)).keyboardShortcut(.cancelAction)
            }.padding(.top, 4)
        }
    }
    private var working: some View {
        VStack(alignment: .leading, spacing: 16) {
            let complete = flow.failures.isEmpty && flow.app != nil
            Text(finished ? (complete ? "Artifloam is gone" : "Almost done") : "Uninstalling…").font(.system(size: 38, weight: .light)).tracking(-0.7).contentTransition(.opacity)
            if finished {
                Text(complete ? "Everything is in the Trash if you change your mind. Thank you for trying it." : "One last part needs your hand. Everything else is in the Trash.")
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(flow.steps.enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 10) {
                        Group {
                            if index < flow.completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.mint).transition(.scale.combined(with: .opacity)) }
                            else if index == flow.completed { ProgressView().controlSize(.small) }
                            else { Image(systemName: "circle").foregroundStyle(.white.opacity(0.3)) }
                        }.frame(width: 22)
                        Text(title).stewardFont(.callout).foregroundStyle(.white.opacity(index <= flow.completed ? 0.95 : 0.5))
                    }
                }
            }.animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6), value: flow.completed)
            ForEach(flow.failures, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").stewardFont(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if finished {
                if flow.app == nil { Label("Drag this copy of Artifloam to the Trash to finish.", systemImage: "info.circle").stewardFont(.caption).foregroundStyle(.white.opacity(0.75)) }
                // Apple doesn't let an app remove this grant itself.
                if flow.holdsFullDisk { Label("macOS may still list Artifloam under Full Disk Access. You can remove that row in System Settings.", systemImage: "lock.shield").stewardFont(.caption).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true) }
                Button("Close Artifloam") { NSApp.terminate(nil) }.buttonStyle(CleanupGlassButtonStyle()).keyboardShortcut(.defaultAction).padding(.top, 4)
            }
        }
    }
    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.backdrop.deep, theme.backdrop.mid], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                .contentShape(Rectangle()).onTapGesture { }
            ScrollView {
                HStack(alignment: .center, spacing: 34) {
                    artwork
                    Group { if flow.phase == .confirm { confirm } else { working } }.frame(maxWidth: 440, alignment: .leading)
                }.padding(34).frame(maxWidth: .infinity, alignment: .center)
            }.scrollBounceBehavior(.basedOnSize).defaultScrollAnchor(.center)
        }
        .onChange(of: finished) { _, done in if done { finishedAt = Date() } }
    }
}
