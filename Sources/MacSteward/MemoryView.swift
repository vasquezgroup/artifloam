import SwiftUI
import AppKit
import MacStewardCore

@MainActor
final class MemoryMonitor: ObservableObject {
    @Published var reading: MemoryReading?
    @Published var selected = Set<Int32>()
    @Published var message: String?
    @Published var error: String?
    /// Per-app CPU percent between the last two readings (100% = one full core, as Activity Monitor shows it).
    @Published private(set) var cpu = [Int32: Double]()
    private var previousCPU = [Int32: UInt64](), previousAt: TimeInterval = 0
    /// Memory released by the last quit, shown as a "+X" moment, and the running total for this month.
    @Published private(set) var lastFreed: (bytes: UInt64, at: Date)?
    @Published private(set) var freedThisMonth = UserDefaults.standard.object(forKey: MemoryMonitor.monthKey) as? UInt64 ?? 0
    /// When each app was last frontmost, seen since Artifloam opened. in-memory only, resets on relaunch.
    private(set) var lastActive = [Int32: Date]()
    private var quitting = [Int32: UInt64]()
    /// When each app was asked to quit; still running 10 s later means it ignored the request.
    private var quitAskedAt = [Int32: Date]()
    private var refreshing = false
    private var observers = [NSObjectProtocol]()
    private static var monthKey: String { "memoryFreed-" + Date().formatted(.iso8601.year().month()) }
    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
                MainActor.assumeIsolated { self?.lastActive[pid] = Date() }
            })
        }
    }
    func refresh() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }.compactMap { app -> MemoryAppDescriptor? in
            guard let path = app.bundleURL?.path else { return nil }
            return MemoryAppDescriptor(pid: app.processIdentifier, name: app.localizedName ?? "Application", bundlePath: path)
        }
        do {
            reading = try await Task.detached(priority: .utility) { try MemoryReading.capture(apps: apps) }.value
            let now = ProcessInfo.processInfo.systemUptime, rows = reading?.apps ?? []
            cpu = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                previousCPU[row.id].flatMap { MemoryAppUsage.cpuPercent(now: row.cpuNanoseconds, before: $0, seconds: now - previousAt) }.map { (row.id, $0) }
            })
            previousCPU = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.cpuNanoseconds) }); previousAt = now
            selected.formIntersection(Set(reading?.apps.map(\.id) ?? []))
            quitAskedAt = quitAskedAt.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
            settleQuits()
        } catch { self.error = error.localizedDescription }
    }
    /// Counts an app's footprint as released once it has actually quit.
    private func settleQuits() {
        let gone = quitting.filter { NSRunningApplication(processIdentifier: $0.key) == nil }
        guard !gone.isEmpty else { return }
        let bytes = gone.values.reduce(0, +)
        gone.keys.forEach { quitting[$0] = nil }
        lastFreed = (bytes, Date())
        freedThisMonth = (UserDefaults.standard.object(forKey: Self.monthKey) as? UInt64 ?? 0) + bytes
        UserDefaults.standard.set(freedThisMonth, forKey: Self.monthKey)
    }
    /// Apps in use within the last ten minutes, plus whatever is frontmost.
    var recentlyUsed: Set<Int32> {
        var pids = Set(lastActive.filter { $0.value > Date().addingTimeInterval(-600) }.keys)
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier { pids.insert(front) }
        return pids
    }
    var selectedBytes: UInt64 { reading?.apps.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes } ?? 0 }
    func canQuit(_ row: MemoryAppUsage) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: row.id) else { return false }
        return app.bundleURL?.path == row.app.bundlePath && app.activationPolicy == .regular && app.bundleIdentifier != "com.apple.finder" && row.id != getpid()
    }
    /// Apps ordered by CPU use, busiest first. Empty until two readings exist.
    var topCPU: [MemoryAppUsage] { (reading?.apps ?? []).filter { (cpu[$0.id] ?? 0) >= 0.1 }.sorted { cpu[$0.id]! > cpu[$1.id]! } }
    @discardableResult func quit(_ row: MemoryAppUsage) -> Bool {
        guard canQuit(row), NSRunningApplication(processIdentifier: row.id)?.terminate() == true else { return false }
        quitting[row.id] = row.bytes; quitAskedAt[row.id] = quitAskedAt[row.id] ?? Date()
        message = "Asked \(row.app.name) to quit. Save any changes if it asks."
        Task { await refresh() }
        return true
    }
    /// Waits up to 8 s for an app to go, then reads memory again. An app showing a save prompt simply outlasts this.
    func waitForQuit(_ pid: Int32) async {
        for _ in 0..<32 where NSRunningApplication(processIdentifier: pid) != nil { try? await Task.sleep(for: .milliseconds(250)) }
        await refresh()
    }
    /// True once an app has ignored a normal Quit for 10 seconds; only then is Force quit offered.
    /// a frozen app that also uses no CPU drops out of the CPU lists; it still shows in the Memory list.
    func ignoredQuit(_ pid: Int32) -> Bool {
        guard let asked = quitAskedAt[pid], Date().timeIntervalSince(asked) >= 10 else { return false }
        return NSRunningApplication(processIdentifier: pid) != nil
    }
    /// Ends an app that ignored Quit. Asks first, because its unsaved changes are lost.
    @discardableResult func forceQuit(_ row: MemoryAppUsage) -> Bool {
        guard canQuit(row), let app = NSRunningApplication(processIdentifier: row.id) else { return false }
        let alert = NSAlert()
        alert.messageText = "Force quit \(row.app.name.displaySafe)?"
        alert.informativeText = "\(row.app.name.displaySafe) didn't respond to Quit. Unsaved changes in it will be lost."
        alert.addButton(withTitle: "Force Quit"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn, app.forceTerminate() else { return false }
        quitting[row.id] = row.bytes
        message = "Force quit \(row.app.name)."
        Task { await refresh() }
        return true
    }
    func quitSelected() {
        let rows = reading?.apps.filter { selected.contains($0.id) } ?? []
        var requested = 0
        for row in rows where canQuit(row) {
            if NSRunningApplication(processIdentifier: row.id)?.terminate() == true { requested += 1; quitting[row.id] = row.bytes; quitAskedAt[row.id] = quitAskedAt[row.id] ?? Date() }
        }
        selected.removeAll()
        message = "Requested normal quit for \(requested) \(requested == 1 ? "app" : "apps"). Save any changes when prompted. Memory updates as apps finish quitting."
        Task { await refresh() }
    }
}

struct MemoryView: View {
    @ObservedObject var monitor: MemoryMonitor
    var compact = false
    var openWindow: (() -> Void)?
    /// Login items count for the score and the startup card; nil until scanned.
    var loginItems: Int?
    var reviewStartup: (() -> Void)?
    @State private var confirmingQuit = false
    @State private var showAllApps = false
    @State private var showDetails = false
    private var accent: Color { monitor.reading?.pressure == .critical ? .red : monitor.reading?.pressure == .warning ? .orange : .mint }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                ToolHeading(title: "Memory", detail: "See at a glance whether your Mac has room, and choose what to close.")
                Spacer()
                if !compact {
                    Button { (NSApp.delegate as? StewardApplicationDelegate)?.openMemoryMonitor() } label: { Image(systemName: "menubar.rectangle") }.help("Open the Mac dashboard")
                }
                Button { Task { await monitor.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh memory readings")
            }
            if let reading = monitor.reading {
                let verdict = MemoryVerdict.evaluate(pressure: reading.pressure, swap: reading.swap, total: reading.total, loginItems: loginItems)
                let suggested = MemoryVerdict.suggestions(reading.apps, recentlyUsed: monitor.recentlyUsed, canQuit: monitor.canQuit)
                hero(reading, verdict, suggested)
                progressRow(verdict)
                appList(reading)
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 14) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 26) { ring(reading); metrics(reading) }
                            VStack(alignment: .leading, spacing: 20) { ring(reading); metrics(reading) }
                        }
                        Text("Swap is memory macOS has moved to disk. A large swap means the Mac ran short earlier; it shrinks slowly after apps quit. App footprints include measurable helpers and can share pages, so they are estimates, not a promise of RAM recovered. macOS reuses cached memory automatically.").stewardFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 10)
                } label: { Text("Memory details").stewardFont(.headline) }
            } else { StewardProgressBar(title: "Reading macOS memory…").frame(maxWidth: 280) }
            if let error = monitor.error { Text(error).stewardFont(.body).foregroundStyle(.orange) }
            HStack {
                Button("Activity Monitor") { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") { NSWorkspace.shared.open(url) } }
                if let openWindow { Spacer(); Button("Open Artifloam", action: openWindow) }
            }
        }
        .confirmationDialog("Quit \(monitor.selected.count == 1 ? "this app" : "these apps") to release memory?", isPresented: $confirmingQuit, titleVisibility: .visible) {
            Button("Quit \(quitNames)") { monitor.quitSelected() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Apps receive a normal Quit request and may ask you to save. Nothing is force-quit. Memory recovered varies and swap may not shrink immediately.") }
        .task {
            while !Task.isCancelled { await monitor.refresh(); do { try await Task.sleep(for: .seconds(3)) } catch { break } }
        }
    }
    private var quitNames: String { names(monitor.reading?.apps.filter { monitor.selected.contains($0.id) } ?? []) }
    private func names(_ rows: [MemoryAppUsage]) -> String {
        let list = rows.map(\.app.name)
        return list.count <= 1 ? list.first ?? "" : list.dropLast().joined(separator: ", ") + " & " + list.last!
    }
    /// The answer first: one verdict, one action.
    private func hero(_ reading: MemoryReading, _ verdict: MemoryVerdict, _ suggested: [MemoryAppUsage]) -> some View {
        let color: Color = verdict.state == .tight ? accent : verdict.state == .busy ? .yellow : .mint
        let swap = reading.swap.map(formattedMemory) ?? ""
        let (headline, detail): (String, String) = switch verdict.state {
        case .fine: ("Your Mac has room to spare", "\(formattedMemory(reading.available)) free for new apps. Nothing to do.")
        case .busy: ("Running fine, leaning on the disk", "\(swap) has spilled to disk earlier. Quitting idle apps helps it shrink over time.")
        case .tight: ("Memory is tight", "Apps may slow down. Quit an app you are not using; save your work first.")
        }
        let freeing = suggested.reduce(0) { $0 + $1.bytes }
        return HStack(alignment: .center, spacing: 22) {
            ZStack {
                Circle().stroke(.white.opacity(0.08), lineWidth: 9)
                Circle().trim(from: 0, to: CGFloat(verdict.score) / 100).stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(verdict.score)").stewardFont(.title2, weight: .semibold).monospacedDigit().contentTransition(.numericText())
                    Text("health").stewardFont(.caption).foregroundStyle(.secondary)
                }
            }.frame(width: 84, height: 84).animation(.smooth, value: verdict.score)
            .help("Health starts at 100. Memory pressure lowers it most, then a large swap, then many apps opening at login.")
            VStack(alignment: .leading, spacing: 8) {
                Text(headline).stewardFont(.title3, weight: .semibold)
                Text(detail).stewardFont(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let freed = monitor.lastFreed, Date().timeIntervalSince(freed.at) < 30 {
                    Label("+\(formattedMemory(freed.bytes)) released", systemImage: "sparkles").stewardFont(.headline).foregroundStyle(.mint).transition(.scale.combined(with: .opacity))
                } else if verdict.state != .fine, !suggested.isEmpty {
                    // Only ticks them: which apps to close is the person's call, so they untick any below, then quit.
                    Button {
                        monitor.selected = Set(suggested.map(\.id))
                        if suggested.contains(where: { row in !reading.apps.prefix(5).contains { $0.id == row.id } }) { showAllApps = true } // So every ticked app can be seen.
                    } label: {
                        Label("Select \(suggested.count) idle \(suggested.count == 1 ? "app" : "apps") · ~\(formattedMemory(freeing))", systemImage: "memorychip").fixedSize(horizontal: false, vertical: true)
                    }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: verdict.state == .busy))
                    .help("Ticks the largest apps you have not used in the last ten minutes. Nothing quits until you confirm below.")
                }
            }
            Spacer(minLength: 0)
        }.padding(18).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.25), lineWidth: 0.7) }
        .animation(.smooth, value: monitor.lastFreed?.at)
    }
    /// What the user has done, and the one lasting fix left.
    @ViewBuilder private func progressRow(_ verdict: MemoryVerdict) -> some View {
        let startup = loginItems.map { "\($0) \($0 == 1 ? "app opens" : "apps open") at login" }
        if monitor.freedThisMonth > 0 || startup != nil {
            HStack(spacing: 10) {
                if monitor.freedThisMonth > 0 {
                    chip("trophy", "\(formattedMemory(monitor.freedThisMonth)) released this month", .mint)
                }
                if let startup, let reviewStartup {
                    Button(action: reviewStartup) { chip("power", startup + " · Review", (loginItems ?? 0) > 5 ? .yellow : .secondary) }.buttonStyle(.plain)
                        .help("Fewer login items means more free memory every time your Mac starts.")
                }
            }
        }
    }
    private func chip(_ icon: String, _ text: String, _ tint: Color) -> some View {
        Label(text, systemImage: icon).stewardFont(.caption, weight: .medium).foregroundStyle(tint)
            .padding(.horizontal, 11).padding(.vertical, 7).background(.white.opacity(0.06), in: Capsule())
    }
    @ViewBuilder private func appList(_ reading: MemoryReading) -> some View {
        let rows = Array(reading.apps.prefix(showAllApps ? 15 : 5))
        let largest = max(1, reading.apps.first?.bytes ?? 1)
        HStack {
            Text("Apps using the most memory").stewardFont(.headline)
        }
        let quittable = rows.filter(monitor.canQuit).map(\.id)
        BulkBar(title: "Select all", isOn: Binding(get: { !quittable.isEmpty && monitor.selected.isSuperset(of: quittable) }, set: { if $0 { monitor.selected.formUnion(quittable) } else { monitor.selected.subtract(quittable) } }), enabled: !quittable.isEmpty,
                help: "Every app listed that can quit. Each one still asks to save your work.", summary: "\(monitor.selected.count) selected · \(formattedMemory(monitor.selectedBytes))") {
            Button("Quit \(monitor.selected.count)…") { confirmingQuit = true }.buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(monitor.selected.isEmpty)
        }
        VStack(spacing: 6) {
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    Toggle("Select \(row.app.name)", isOn: Binding(get: { monitor.selected.contains(row.id) }, set: { if $0 { monitor.selected.insert(row.id) } else { monitor.selected.remove(row.id) } }))
                        .toggleStyle(.stewardCheckboxOnly).disabled(!monitor.canQuit(row))
                    Image(nsImage: NSWorkspace.shared.icon(forFile: row.app.bundlePath)).resizable().frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.app.name).stewardFont(.body, weight: .medium)
                        Text(lastUsed(row.id)).stewardFont(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formattedMemory(row.bytes)).stewardFont(.body).monospacedDigit()
                }.padding(.horizontal, 11).padding(.vertical, 8)
                .background(alignment: .leading) {
                    GeometryReader { geo in Rectangle().fill(accent.opacity(0.10)).frame(width: geo.size.width * CGFloat(row.bytes) / CGFloat(largest)) }
                }
                .background(.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 11))
            }
        }
        // It can't offer to quit itself, but a tool judging other apps' memory shouldn't hide its own.
        if let own = MemoryReading.ownFootprint() { Text("Artifloam itself is using \(formattedMemory(own)).").stewardFont(.caption).foregroundStyle(.secondary) }
        if reading.apps.count > 5 {
            Button(showAllApps ? "Show fewer" : "Show all \(min(15, reading.apps.count)) apps") { withAnimation(.smooth) { showAllApps.toggle() } }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        if let message = monitor.message { Text(message).stewardFont(.caption).foregroundStyle(.secondary) }
    }
    private func lastUsed(_ pid: Int32) -> String {
        if pid == NSWorkspace.shared.frontmostApplication?.processIdentifier { return "In use now" }
        guard let date = monitor.lastActive[pid] else { return "Not used since Artifloam opened" }
        return date > Date().addingTimeInterval(-60) ? "Used just now" : "Used " + date.formatted(.relative(presentation: .named))
    }
    private func ring(_ reading: MemoryReading) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.06), lineWidth: 17)
            Circle().trim(from: 0, to: CGFloat(reading.used) / CGFloat(max(1, reading.total)))
                .stroke(AngularGradient(colors: [.purple, .blue, .mint], center: .center), style: StrokeStyle(lineWidth: 17, lineCap: .round)).rotationEffect(.degrees(-90))
            VStack(spacing: 6) {
                Text(formattedMemory(reading.available)).stewardFont(.title2, weight: .semibold)
                Text("available estimate").stewardFont(.caption).foregroundStyle(.secondary)
            }
        }.frame(width: compact ? 156 : 190, height: compact ? 156 : 190).padding(10)
    }
    private func metrics(_ reading: MemoryReading) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
            memoryMetric("Physical RAM", formattedMemory(reading.total))
            memoryMetric("Used estimate", formattedMemory(reading.used))
            memoryMetric("Wired", formattedMemory(reading.wired))
            memoryMetric("Compressed", formattedMemory(reading.compressed))
            memoryMetric("Cached / reclaimable", formattedMemory(reading.cached))
            memoryMetric("Swap on disk", reading.swap.map(formattedMemory) ?? "Unavailable")
            memoryMetric("Memory pressure", reading.pressure.rawValue)
        }.frame(minWidth: 230)
    }
    private func memoryMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label).stewardFont(.caption).foregroundStyle(.secondary); Text(value).stewardFont(.body, weight: .semibold).monospacedDigit() }
    }
}

/// Memory uses binary units, like Activity Monitor; every memory figure in the app goes through this.
func formattedMemory(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory) }

/// Fixed-size menu dashboard: overview, four apps and the action are always visible.
struct CompactMemoryView: View {
    @ObservedObject var monitor: MemoryMonitor
    let openWindow: () -> Void
    @State private var confirmingQuit = false
    private var accent: Color { monitor.reading?.pressure == .critical ? .red : monitor.reading?.pressure == .warning ? .orange : .mint }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Memory", systemImage: "memorychip.fill").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button { Task { await monitor.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh readings")
            }
            FlyoutWarningBanner()
            if let reading = monitor.reading {
                HStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.08), lineWidth: 12)
                        Circle().trim(from: 0, to: CGFloat(reading.used) / CGFloat(max(1, reading.total)))
                            .stroke(AngularGradient(colors: [.purple, .blue, .mint], center: .center), style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: 4) {
                            Text(formattedMemory(reading.available)).font(.system(size: 21, weight: .semibold)).monospacedDigit()
                            Text("available estimate").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                        }
                    }.frame(width: 100, height: 100).padding(8)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        stat("Physical RAM", formattedMemory(reading.total))
                        stat("Used estimate", formattedMemory(reading.used))
                        stat("Wired", formattedMemory(reading.wired))
                        stat("Compressed", formattedMemory(reading.compressed))
                        stat("Cached", formattedMemory(reading.cached))
                        stat("Swap", reading.swap.map(formattedMemory) ?? "Unavailable")
                    }
                }
                HStack(spacing: 7) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text("Pressure: " + reading.pressure.rawValue).font(.system(size: 14, weight: .medium)).foregroundStyle(accent)
                    Spacer()
                    Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.65))
                        .help("macOS reuses cached RAM automatically. App footprints include measurable helpers and may share pages; they are not guaranteed recoverable bytes. Quitting apps uses normal save prompts.")
                }.padding(.horizontal, 10).padding(.vertical, 6).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                HStack {
                    Text("Top apps").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("Select to quit").font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                }
                VStack(spacing: 4) {
                    ForEach(Array(reading.apps.prefix(4))) { row in
                        HStack(spacing: 9) {
                            Toggle("Select \(row.app.name)", isOn: Binding(get: { monitor.selected.contains(row.id) }, set: { if $0 { monitor.selected.insert(row.id) } else { monitor.selected.remove(row.id) } })).toggleStyle(.stewardCheckboxOnly).disabled(!monitor.canQuit(row))
                            Image(nsImage: NSWorkspace.shared.icon(forFile: row.app.bundlePath)).resizable().frame(width: 22, height: 22)
                            Text(row.app.name).font(.system(size: 15, weight: .medium)).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(formattedMemory(row.bytes)).font(.system(size: 14, weight: .medium)).monospacedDigit()
                        }.padding(.horizontal, 10).frame(height: 30).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                Button { confirmingQuit = true } label: {
                    Label(monitor.selected.isEmpty ? "Free RAM · Select apps above" : "Free RAM · Review \(monitor.selected.count) \(monitor.selected.count == 1 ? "app" : "apps")", systemImage: "memorychip.fill")
                        .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity)
                }.buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(monitor.selected.isEmpty)
            } else { Spacer(); StewardProgressBar(title: "Reading memory…").frame(maxWidth: 240); Spacer() }
            Spacer(minLength: 0)
            Divider().overlay(.white.opacity(0.06))
            HStack {
                if let error = monitor.error {
                    Text("Reading unavailable").foregroundStyle(.orange).help(error)
                } else if let message = monitor.message {
                    Text("Quit requested").foregroundStyle(.mint).help(message)
                } else { Button("Activity Monitor") { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") { NSWorkspace.shared.open(url) } } }
                Spacer()
                Button("All apps & details", action: openWindow)
            }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(18).frame(width: 460, height: 700)
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.075, blue: 0.29), Color(red: 0.055, green: 0.04, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .confirmationDialog("Quit selected apps to release memory?", isPresented: $confirmingQuit, titleVisibility: .visible) {
            Button("Quit selected apps") { monitor.quitSelected() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Apps receive a normal Quit request and may ask you to save. Nothing is force-quit. Recovered memory varies.") }
        .task {
            while !Task.isCancelled { await monitor.refresh(); do { try await Task.sleep(for: .seconds(3)) } catch { break } }
        }
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
    }
}
