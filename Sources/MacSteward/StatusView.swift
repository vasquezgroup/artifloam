import SwiftUI
import AppKit
import MacStewardCore

@MainActor
final class StatusState: ObservableObject {
    @Published var reading: SystemStatusReading?
    @Published var cpuHistory = [Double]()
    @Published var networkHistory = [Double]()
    private let sampler = SystemStatusSampler()
    private var timer: Timer?
    /// Samples only while the page is visible.
    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.sample() } }
    }
    func stop() { timer?.invalidate(); timer = nil }
    private func sample() {
        let sampler = sampler
        Task {
            let value = await Task.detached(priority: .utility) { sampler.read() }.value
            reading = value
            cpuHistory = Array((cpuHistory + [value.cpuPercent]).suffix(30))
            networkHistory = Array((networkHistory + [Double(value.networkInPerSecond)]).suffix(30))
        }
    }
}

struct StatusView: View {
    @ObservedObject var state: StatusState
    @ObservedObject var memory: MemoryMonitor
    @State private var sortByCPU = false
    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 14)]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Status").stewardFont(.title, weight: .semibold)
                Text("Live readings from macOS, refreshed every 2 seconds while this page is open.").stewardFont(.body).foregroundStyle(.secondary)
            }
            if let r = state.reading {
                // Top row like the reference: condition hero, space freed so far, live CPU.
                HStack(alignment: .top, spacing: 14) {
                    conditionCard(r).frame(maxWidth: .infinity)
                    freedCard.frame(maxWidth: .infinity)
                    card("CPU", icon: "cpu", value: "\(Int(r.cpuPercent.rounded()))", unit: "%", footer: String(localized: "\(r.cores) cores · load \(r.load.formatted(.number.precision(.fractionLength(1))))")) { bars(state.cpuHistory, max: 100) }
                        .frame(maxWidth: .infinity)
                }.frame(minHeight: 250)
                LazyVGrid(columns: columns, spacing: 14) {
                    card("Memory", icon: "memorychip", value: memory.reading.map { "\($0.used * 100 / max(1, $0.total))" } ?? "–", unit: "%", footer: memory.reading.map { m in m.swap.map { String(localized: "\(formattedBytes(m.used)) used · \(formattedBytes($0)) swap") } ?? String(localized: "\(formattedBytes(m.used)) used") } ?? String(localized: "Reading…")) {
                        Text(memory.reading?.pressure.displayTitle ?? "").stewardFont(.caption).foregroundStyle(memory.reading?.pressure == .normal ? .mint : .orange)
                    }
                    card("Network", icon: "network", value: formattedBytes(r.networkInPerSecond), unit: String(localized: "/s in", comment: "Unit shown after a data amount: per second, incoming"), footer: String(localized: "Out \(formattedBytes(r.networkOutPerSecond))/s")) { bars(state.networkHistory, max: state.networkHistory.max() ?? 1) }
                    if let battery = r.battery {
                        card("Battery", icon: battery.charging ? "battery.100.bolt" : "battery.75", value: "\(battery.percent)", unit: "%", footer: batteryFooter(battery)) {
                            if let health = battery.health { Text("\(health)% health").stewardFont(.caption).foregroundStyle(health >= 80 ? .mint : .orange) }
                        }
                    }
                    card("Thermal", icon: "thermometer.medium", value: thermalTitle(r.thermal), unit: "", footer: String(localized: "Uptime \(uptime(r.uptime))")) {
                        Text("Read / write \(formattedBytes(r.diskReadPerSecond))/s · \(formattedBytes(r.diskWritePerSecond))/s").stewardFont(.caption).foregroundStyle(.secondary)
                    }
                }
                processes(r)
            } else { StewardProgressBar(title: String(localized: "Reading system status…")).frame(maxWidth: 320) }
        }
        .onAppear { state.start(); history = CleanupHistory.load() }
        .onDisappear { state.stop() }
        .task { while !Task.isCancelled { await memory.refresh(); do { try await Task.sleep(for: .seconds(3)) } catch { break } } }
    }
    /// Read once when the page opens, not on every 2-second refresh.
    @State private var history = CleanupHistory.empty
    private static let chip: String = {
        var size = 0; sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(1, size)); sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()
    private func condition(_ score: Int) -> String { score >= 90 ? String(localized: "Excellent") : score >= 75 ? String(localized: "Good") : score >= 55 ? String(localized: "Fair") : String(localized: "Needs care") }
    private func batteryFooter(_ battery: SystemStatusReading.Battery) -> String {
        switch (battery.onPower, battery.charging, battery.cycles) {
        case (true, true, let cycles?): return String(localized: "Charging · \(cycles) cycles")
        case (true, true, nil): return String(localized: "Charging")
        case (true, false, let cycles?): return String(localized: "On power, not charging · \(cycles) cycles")
        case (true, false, nil): return String(localized: "On power, not charging")
        case (false, _, let cycles?): return String(localized: "On battery · \(cycles) cycles")
        case (false, _, nil): return String(localized: "On battery")
        }
    }
    /// The hero: condition word, chip, a glowing ring like the reference, and the startup disk bar.
    private func conditionCard(_ r: SystemStatusReading) -> some View {
        let score = health(r), used = r.diskTotal - r.diskFree
        return VStack(alignment: .leading, spacing: 6) {
            Text("Mac condition").stewardFont(.body).foregroundStyle(.white.opacity(0.75))
            Text(condition(score)).font(.system(size: 34, weight: .light)).foregroundStyle(score >= 75 ? .mint : .orange)
            Text(Self.chip).stewardFont(.caption).foregroundStyle(.secondary)
            Text(healthNote(r)).stewardFont(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 20)
            HStack { Text("Macintosh HD").stewardFont(.body, weight: .semibold); Spacer(); Text("\(formattedBytes(used)) of \(formattedBytes(r.diskTotal)) used").stewardFont(.caption).foregroundStyle(.secondary) }
            ProgressView(value: Double(used), total: Double(max(1, r.diskTotal))).tint(.white.opacity(0.85))
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .topTrailing) {
            // Decorative glowing ring that peeks in from the corner.
            Circle().trim(from: 0.05, to: 0.55).stroke(AngularGradient(colors: [.mint.opacity(0), .mint, .cyan, .mint.opacity(0)], center: .center), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .frame(width: 230, height: 230).blur(radius: 1.5).shadow(color: .mint.opacity(0.8), radius: 18).offset(x: 70, y: -70)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)).modifier(StatusGlass())
    }
    private static let kindColors: [String: Color] = ["Simulators": .mint, "App caches": .cyan, "Developer caches": .blue, "Dependencies": .purple, "Project caches": .teal, "Logs": .orange, "Other": .gray]
    /// Space freed with Artifloam so far, split by kind, from the saved cleanup receipts.
    private var freedCard: some View {
        let h = history, kinds = h.byKind.filter { $0.bytes > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Space freed with Artifloam").stewardFont(.body).foregroundStyle(.white.opacity(0.75))
            Text(formattedBytes(h.totalFreed)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
            Label("\(formattedBytes(h.lastThirtyDays)) in the last 30 days", systemImage: "arrowtriangle.up.fill").stewardFont(.caption).foregroundStyle(.mint)
            Spacer(minLength: 10)
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(kinds, id: \.name) { kind in
                        Capsule().fill(Self.kindColors[kind.name] ?? .gray).frame(width: max(4, geometry.size.width * CGFloat(Double(kind.bytes) / Double(max(1, h.totalFreed)))))
                    }
                    if kinds.isEmpty { Capsule().fill(.white.opacity(0.12)) }
                }
            }.frame(height: 14).padding(3).background(.white.opacity(0.08), in: Capsule())
            ForEach(kinds.prefix(3), id: \.name) { kind in
                HStack {
                    Circle().fill(Self.kindColors[kind.name] ?? .gray).frame(width: 7, height: 7)
                    Text(Self.kindTitle(kind.name)).stewardFont(.caption)
                    Spacer()
                    Text(formattedBytes(kind.bytes)).stewardFont(.caption, weight: .semibold).monospacedDigit()
                }
            }
            if kinds.isEmpty { Text("Run a cleanup to start counting.").stewardFont(.caption).foregroundStyle(.secondary) }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).modifier(StatusGlass())
    }
    /// The kind names are identifiers from `CleanupHistory` (they key the colours); this is what a person reads.
    private static func kindTitle(_ name: String) -> String {
        switch name {
        case "Simulators": return String(localized: "Simulators", comment: "Kind of space freed")
        case "App caches": return String(localized: "App caches", comment: "Kind of space freed")
        case "Developer caches": return String(localized: "Developer caches", comment: "Kind of space freed")
        case "Dependencies": return String(localized: "Dependencies", comment: "Kind of space freed")
        case "Project caches": return String(localized: "Project caches", comment: "Kind of space freed")
        case "Logs": return String(localized: "Logs", comment: "Kind of space freed")
        case "Other": return String(localized: "Other", comment: "Kind of space freed")
        default: return name
        }
    }
    private func card<Accessory: View>(_ title: LocalizedStringKey, icon: String, value: String, unit: String, footer: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).textCase(.uppercase).stewardFont(.caption, weight: .semibold).foregroundStyle(.mint)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).stewardFont(.title, weight: .semibold).monospacedDigit()
                Text(unit).stewardFont(.callout).foregroundStyle(.secondary)
            }
            accessory().frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            Text(footer).stewardFont(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).modifier(StatusGlass())
    }
    private func bars(_ values: [Double], max: Double) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 1.5).fill(Color.mint.opacity(0.75)).frame(height: Swift.max(2, 26 * value / Swift.max(1, max)))
            }
        }.frame(height: 26, alignment: .bottom)
    }
    /// A plain score: points off for memory pressure, a full disk, heat and a worn battery.
    private func health(_ r: SystemStatusReading) -> Int {
        var score = 100
        if let pressure = memory.reading?.pressure { score -= pressure == .critical ? 30 : pressure == .warning ? 15 : 0 }
        let free = Double(r.diskFree) / Double(max(1, r.diskTotal))
        score -= free < 0.05 ? 30 : free < 0.15 ? 15 : 0
        score -= ["Hot": 15, "Critical": 30][r.thermal] ?? 0
        if let health = r.battery?.health, health < 80 { score -= 10 }
        return max(0, score)
    }
    private func healthNote(_ r: SystemStatusReading) -> String {
        let free = Double(r.diskFree) / Double(max(1, r.diskTotal))
        if free < 0.15 { return String(localized: "Low disk space · \(formattedBytes(r.diskFree)) free") }
        if let pressure = memory.reading?.pressure, pressure != .normal {
            switch pressure {
            case .warning: return String(localized: "Memory pressure elevated")
            case .critical: return String(localized: "Memory pressure high")
            default: return String(localized: "Memory pressure unavailable")
            }
        }
        return String(localized: "Everything looks fine")
    }
    private func uptime(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86400, hours = Int(seconds) % 86400 / 3600
        return days > 0 ? String(localized: "\(days) d \(hours) h") : String(localized: "\(hours) h \(Int(seconds) % 3600 / 60) min")
    }
    private func processes(_ r: SystemStatusReading) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Processes · \(r.processes.count) largest").stewardFont(.headline)
                Spacer()
                Picker("Sort", selection: $sortByCPU) { Text("Memory").tag(false); Text("CPU").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            HStack { Text("NAME"); Spacer(); Text("MEMORY").frame(width: 90, alignment: .trailing); Text("% CPU").frame(width: 70, alignment: .trailing); Text("PID").frame(width: 70, alignment: .trailing) }
                .stewardFont(.caption, weight: .semibold).foregroundStyle(.secondary).padding(.horizontal, 14)
            ForEach(r.processes.sorted { sortByCPU ? $0.cpu > $1.cpu : $0.memory > $1.memory }) { process in
                HStack {
                    Text(process.name).stewardFont(.body).lineLimit(1)
                    Spacer()
                    Text(formattedBytes(process.memory)).frame(width: 90, alignment: .trailing)
                    Text(process.cpu.formatted(.number.precision(.fractionLength(1)))).frame(width: 70, alignment: .trailing).foregroundStyle(process.cpu > 50 ? .orange : .primary)
                    Text("\(process.pid)").frame(width: 70, alignment: .trailing).foregroundStyle(.secondary)
                }.stewardFont(.callout).monospacedDigit().padding(.horizontal, 14).padding(.vertical, 6)
                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// Bottom banner shown while Full Disk Access is off; dismissing it is remembered.
struct FullDiskAccessBanner: View {
    @AppStorage("fullDiskAccessBannerDismissed") private var dismissed = false
    @State private var status = FullDiskAccess.status()
    var body: some View {
        if status == .denied && !dismissed {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield").foregroundStyle(.orange)
                Text("Allow Full Disk Access so Artifloam can measure the Trash, Safari, Chrome and other protected folders.").stewardFont(.body).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Close") { dismissed = true }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Open System Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }.buttonStyle(.bordered)
            }.padding(.horizontal, 20).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 20).padding(.bottom, 10)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in status = FullDiskAccess.status() }
        }
    }
}

/// Frosted card like the reference: light from the top-left, hairline rim, soft shadow.
struct StatusGlass: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(LinearGradient(colors: [.white.opacity(0.11), .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8) }
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }
}
