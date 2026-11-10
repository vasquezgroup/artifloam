import SwiftUI
import AppKit
import MacStewardCore

@MainActor
final class MacDashboardMonitor: ObservableObject {
    @Published private(set) var sample: MacDashboardSample?
    @Published private(set) var cpuPercent: Double?
    @Published private(set) var download: Double?
    @Published private(set) var upload: Double?
    @Published private(set) var devices = [ConnectedMacDevice]()
    @Published private(set) var refreshing = false
    @Published private(set) var cpuSplit: (user: Double, system: Double, idle: Double)?
    @Published private(set) var cpuHistory = [Double]()
    @Published private(set) var downloadHistory = [Double]()
    @Published private(set) var uploadHistory = [Double]()
    /// The card whose flyout is open, so the card can show it is selected.
    @Published var detail: DashboardDetail?
    static let historyLength = 60
    private var previous: MacDashboardSample?
    private var lastDeviceRead: TimeInterval = 0
    func refresh() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        let readDevices = ProcessInfo.processInfo.systemUptime - lastDeviceRead > 15 || sample == nil
        let reading = await Task.detached(priority: .utility) { MacDashboard.sample(includeDevices: readDevices) }.value
        guard !Task.isCancelled else { return }
        let elapsed = previous.map { reading.uptime - $0.uptime } ?? 0
        if elapsed > 0 && elapsed <= 30, let cpu = reading.cpu, let old = previous?.cpu { cpuPercent = cpu.usage(since: old); cpuSplit = cpu.split(since: old) } else { cpuPercent = nil; cpuSplit = nil }
        if let network = reading.network, let old = previous?.network, let rates = network.rates(since: old, interval: elapsed) { download = rates.download; upload = rates.upload } else { download = nil; upload = nil }
        func push(_ value: Double?, _ history: inout [Double]) { if let value { history = Array((history + [value]).suffix(Self.historyLength)) } }
        push(cpuPercent, &cpuHistory); push(download, &downloadHistory); push(upload, &uploadHistory)
        if let devices = reading.devices { self.devices = devices; lastDeviceRead = reading.uptime }
        sample = reading; previous = reading
    }
}

struct MacDashboardView: View {
    @ObservedObject var monitor: MacDashboardMonitor
    @ObservedObject var memory: MemoryMonitor
    @ObservedObject var health: MacHealthMonitor
    let openWindow: (String) -> Void
    let openDetail: (DashboardDetail) -> Void
    private func issue(_ kind: DashboardDetail) -> MacIssue? { health.issue(for: kind) }
    private var pressureColor: Color { memory.reading?.pressure == .critical ? .red : memory.reading?.pressure == .warning ? .orange : .mint }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer").font(.system(size: 26)).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your Mac").font(.system(size: 22, weight: .semibold))
                    Text(health.health.map { $0.issues.isEmpty ? String(localized: "Health \($0.score) · Level \($0.level)") : String(localized: "Health \($0.score) · \(String(localized: "\($0.issues.count) things to fix"))") } ?? String(localized: "Live system overview"))
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.62)).monospacedDigit()
                }
                Spacer()
                if let current = health.health {
                    let clear = current.issues.isEmpty
                    Text(clear ? "Running well" : "Needs attention").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .foregroundStyle(clear ? Color.mint : .orange).background((clear ? Color.mint : .orange).opacity(0.16), in: Capsule())
                }
                Button { Task { await monitor.refresh(); await memory.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh system readings").accessibilityLabel("Refresh system readings").disabled(monitor.refreshing)
            }.frame(height: 48).padding(.bottom, 4)
            HStack(spacing: 12) {
                let disk = monitor.sample?.disk
                let lowDisk = disk.map { $0.total > 0 && Double($0.free) / Double($0.total) < 0.1 } ?? false
                card(.storage, metricCard("Storage", icon: "internaldrive.fill", value: disk.map { formattedBytes($0.free) } ?? String(localized: "Reading…"), detail: String(localized: "Free on this Mac"), action: "Details", tint: lowDisk ? .orange : .mint, flag: issue(.storage)))
                    .help("Filesystem free space. macOS may also include purgeable storage in its available-space estimate.")
                card(.memory, metricCard("Memory", icon: "memorychip.fill", value: memory.reading.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0.available), countStyle: .memory) } ?? String(localized: "Reading…"), detail: memory.reading.map { String(localized: "Available · Pressure: \($0.pressure.displayTitle)") } ?? String(localized: "Available · Pressure: Measuring"), action: "Details", tint: pressureColor, flag: issue(.memory)))
            }
            HStack(spacing: 12) {
                card(.battery, batteryCard)
                let busy = (monitor.cpuPercent ?? 0) >= 80 || (monitor.sample.map { $0.thermalState != "Normal" } ?? false)
                card(.cpu, metricCard("CPU", icon: "cpu.fill", value: monitor.cpuPercent.map { String(localized: "\(Int($0.rounded()))%") } ?? String(localized: "Measuring…"), detail: monitor.sample.map { String(localized: "Thermal: \(thermalTitle($0.thermalState))") } ?? String(localized: "Thermal: Reading…"), action: "Details", tint: busy ? .orange : .mint, flag: issue(.cpu)))
                    .help("CPU use is measured between samples. Thermal state comes from macOS; no guessed temperature is displayed.")
            }
            HStack(alignment: .top, spacing: 12) { card(.network, networkCard); card(.devices, devicesCard) }
            if let installers = health.installers {
                Text("Today's tip").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).padding(.top, 2)
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 18)).foregroundStyle(.mint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(installers.urls.count) old installers in Downloads").font(.system(size: 14, weight: .medium))
                        Text("\(formattedBytes(installers.bytes)) · untouched for 30+ days").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Button("Review") { NSWorkspace.shared.activateFileViewerSelecting(installers.urls) }.buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.mint).help("Shows them selected in Finder. You decide what to move to the Trash.")
                }.padding(13).background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
            } else {
                Text("Read-only readings. Click a card for details and the apps behind it.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Divider().overlay(.white.opacity(0.06))
            HStack {
                Button("Open Artifloam") { openWindow("Overview") }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Quit Artifloam", systemImage: "power") }.help("Closes Artifloam completely, including this menu bar icon. Automatic cleanup you turned on still runs on its schedule.")
                Button { openWindow("Settings") } label: { Image(systemName: "gearshape.fill") }.padding(.leading, 10).help("Artifloam settings").accessibilityLabel("Artifloam settings")
            }.font(.system(size: 14, weight: .medium)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
        }.padding(18).frame(width: 460, height: 700)
            .background(LinearGradient(colors: [Color(red: 0.19, green: 0.075, blue: 0.34), Color(red: 0.055, green: 0.04, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .foregroundStyle(.white).preferredColorScheme(.dark)
            .task {
                while !Task.isCancelled {
                    await monitor.refresh(); await memory.refresh()
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }
            .onAppear { health.readInstallers() }
    }
    private func metricCard(_ title: LocalizedStringKey, icon: String, value: String, detail: String, action: LocalizedStringKey? = nil, tint: Color = .mint, flag: MacIssue? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.90))
            Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit().foregroundStyle(flag == nil ? tint : .orange).lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                if let flag {
                    // The fix button sits over the trailing end of this line (see `card`).
                    Label(flag.flag, systemImage: "flag.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange).lineLimit(1).padding(.trailing, flag.fixLabel.map { CGFloat($0.count) * 7 + 24 } ?? 0)
                } else {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if action != nil && flag == nil { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.mint).flipsForRightToLeftLayoutDirection(true) }
            }
        }.padding(15).frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.07), lineWidth: 0.5) }
            .accessibilityElement(children: .combine).accessibilityHint(action ?? "System reading")
    }
    private var batteryCard: some View {
        let battery = monitor.sample?.battery
        let value = battery?.percent.map { String(localized: "\($0)%") } ?? (monitor.sample == nil ? String(localized: "Reading…") : String(localized: "Not reported"))
        let detail = battery.map { $0.charging ? String(localized: "Charging") : $0.externalPower ? String(localized: "On external power") : String(localized: "On battery") } ?? String(localized: "Desktop or unavailable")
        return metricCard("Battery", icon: "battery.100", value: value, detail: detail, action: "Details", tint: (battery?.percent ?? 100) <= 20 && battery?.externalPower == false ? .orange : .mint, flag: issue(.battery))
    }
    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(monitor.sample?.network?.kind ?? String(localized: "Network"), systemImage: "network").font(.system(size: 14, weight: .semibold))
            Label(rate(monitor.download), systemImage: "arrow.down").font(.system(size: 15, weight: .medium)).monospacedDigit()
            Label(rate(monitor.upload), systemImage: "arrow.up").font(.system(size: 15, weight: .medium)).monospacedDigit()
            Text(monitor.sample?.network == nil ? "No active interface reported" : "Current traffic")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(15).frame(maxWidth: .infinity, minHeight: 168, maxHeight: 168, alignment: .topLeading)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
    }
    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Connected devices", systemImage: "keyboard.fill").font(.system(size: 14, weight: .semibold)).help("Showing up to three of \(monitor.devices.count) reported devices. The list may be incomplete.")
            if monitor.devices.isEmpty {
                Text(monitor.sample == nil ? "Reading…" : "No devices reported").font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
            }
            ForEach(Array(monitor.devices.prefix(3))) { device in
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(device.transportTitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }.help(device.name + " · " + device.transportTitle)
            }
            Spacer(minLength: 0)
        }.padding(15).frame(maxWidth: .infinity, minHeight: 168, maxHeight: 168, alignment: .topLeading)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
    }
    /// A card that opens its flyout and shows a highlight while that flyout is open.
    /// A card that opens its flyout, is outlined while its flyout is open, and turns amber with a fix button when flagged.
    private func card(_ kind: DashboardDetail, _ content: some View) -> some View {
        let flagged = issue(kind)
        return Button { openDetail(kind) } label: {
            content
                .background { if flagged != nil { RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.10)) } }
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(monitor.detail == kind ? Color.blue.opacity(0.9) : Color.orange.opacity(flagged == nil ? 0 : 0.6), lineWidth: monitor.detail == kind ? 1.5 : 1) }
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
        .overlay(alignment: .bottomTrailing) {
            if let flagged, let label = flagged.fixLabel {
                Button(label) { health.perform(flagged.fix, openSection: openWindow) }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(red: 0.02, green: 0.2, blue: 0.17))
                    .padding(.horizontal, 9).padding(.vertical, 3).background(Color.mint, in: Capsule()).padding(12)
            }
        }
    }
    private func rate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return monitor.sample?.network == nil ? String(localized: "Unavailable") : String(localized: "Measuring…") }
        if value < 1 { return String(localized: "0 B/s") }
        return String(localized: "\(formattedBytes(UInt64(min(Double(Int64.max / 2), max(0, value)))))/s")
    }
}

/// What a person reads for a thermal state from `MacDashboardSample` / `SystemStatusReading`; the English value stays the identifier.
func thermalTitle(_ state: String) -> String {
    switch state {
    case "Normal": return String(localized: "Normal", comment: "Thermal state")
    case "Warm": return String(localized: "Warm", comment: "Thermal state")
    case "High": return String(localized: "High", comment: "Thermal state")
    case "Hot": return String(localized: "Hot", comment: "Thermal state")
    case "Critical": return String(localized: "Critical", comment: "Thermal state")
    case "Unavailable": return String(localized: "Unavailable", comment: "Thermal state")
    case "Unknown": return String(localized: "Unknown", comment: "Thermal state")
    default: return state
    }
}
