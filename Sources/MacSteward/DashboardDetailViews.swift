import SwiftUI
import AppKit
import MacStewardCore

/// The flyout that opens beside the menu-bar dashboard when a card is clicked.
enum DashboardDetail: String { case memory, cpu, battery, storage, network, devices }

struct DashboardDetailView: View {
    let kind: DashboardDetail
    @ObservedObject var dashboard: MacDashboardMonitor
    @ObservedObject var memory: MemoryMonitor
    @ObservedObject var health: MacHealthMonitor
    let openWindow: (String) -> Void
    var body: some View {
        // The card can only fit a few words of its warning; the flyout shows it in full, with its fix.
        content.environment(\.flyoutWarning, health.issue(for: kind).map { issue in FlyoutWarning(issue: issue) { health.perform(issue.fix, openSection: openWindow) } })
    }
    @ViewBuilder private var content: some View {
        switch kind {
        case .memory: CompactMemoryView(monitor: memory, openWindow: { openWindow("Performance") })
        case .cpu: CPUDetailView(dashboard: dashboard, memory: memory)
        case .battery: BatteryDetailView(dashboard: dashboard, memory: memory)
        case .storage: StorageDetailView(dashboard: dashboard, openWindow: openWindow)
        case .network: NetworkDetailView(dashboard: dashboard)
        case .devices: DevicesDetailView(dashboard: dashboard)
        }
    }
}

struct FlyoutWarning { let issue: MacIssue; let fix: () -> Void }
private struct FlyoutWarningKey: EnvironmentKey { static let defaultValue: FlyoutWarning? = nil }
extension EnvironmentValues {
    var flyoutWarning: FlyoutWarning? { get { self[FlyoutWarningKey.self] } set { self[FlyoutWarningKey.self] = newValue } }
}
/// The flagged card's warning, in full, under a flyout's title. Hidden when nothing is flagged.
struct FlyoutWarningBanner: View {
    @Environment(\.flyoutWarning) private var warning
    var body: some View {
        if let warning {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 16)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(warning.issue.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text("\(warning.issue.flag) · health +\(warning.issue.points) when fixed").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength: 8)
                if let label = warning.issue.fixLabel {
                    Button(label, action: warning.fix).buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.02, green: 0.2, blue: 0.17)).padding(.horizontal, 11).padding(.vertical, 5).background(Color.mint, in: Capsule())
                }
            }.padding(12).background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.5), lineWidth: 1) }
        }
    }
}

private struct DetailShell<Content: View, Footer: View>: View {
    let title: String, icon: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.system(size: 22, weight: .semibold)).frame(height: 48, alignment: .leading)
            FlyoutWarningBanner()
            content
            Spacer(minLength: 0)
            Divider().overlay(.white.opacity(0.06))
            HStack { footer }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(18).frame(width: 460, height: 700)
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.075, blue: 0.29), Color(red: 0.055, green: 0.04, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .foregroundStyle(.white).preferredColorScheme(.dark)
    }
}

private func openActivityMonitor() {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") { NSWorkspace.shared.open(url) }
}

private struct StatTile: View {
    let title: String, value: String, note: String
    var tint: Color = .white
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Busiest apps with a normal Quit request per row. Apps may still ask to save.
private struct TopCPUApps: View {
    @ObservedObject var memory: MemoryMonitor
    let title: LocalizedStringKey
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold))
            let rows = Array(memory.topCPU.prefix(5))
            if rows.isEmpty {
                Text(memory.reading == nil ? "Measuring…" : "No app is using noticeable CPU right now.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).padding(.vertical, 6)
            }
            ForEach(rows) { row in
                let percent = memory.cpu[row.id] ?? 0
                HStack(spacing: 9) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: row.app.bundlePath)).resizable().frame(width: 24, height: 24)
                    Text(row.app.name).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text((percent / 100).formatted(.percent.precision(.fractionLength(1)))).font(.system(size: 14, weight: .medium)).monospacedDigit()
                        .foregroundStyle(percent >= 50 ? .orange : .white)
                    let force = memory.ignoredQuit(row.id)
                    Button(force ? "Force quit" : "Quit") { if force { memory.forceQuit(row) } else { memory.quit(row) } }
                        .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(force ? .orange : .mint)
                        .disabled(!memory.canQuit(row))
                        .help(force ? "\(row.app.name) ignored Quit. Force quit ends it; unsaved changes are lost." : "Sends \(row.app.name) a normal Quit. It may ask you to save.")
                }.padding(.horizontal, 12).frame(height: 36).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct Sparkline: View {
    let values: [Double]
    var ceiling: Double? = nil
    var tint: Color = .mint
    var body: some View {
        GeometryReader { geometry in
            let top = max(ceiling ?? 0, values.max() ?? 0, 1e-9)
            let step = geometry.size.width / CGFloat(max(1, MacDashboardMonitor.historyLength - 1))
            let offset = geometry.size.width - step * CGFloat(max(0, values.count - 1))
            let points = values.enumerated().map { CGPoint(x: offset + CGFloat($0.offset) * step, y: geometry.size.height * (1 - CGFloat($0.element / top))) }
            if points.count > 1 {
                Path { path in
                    path.move(to: CGPoint(x: points[0].x, y: geometry.size.height)); points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: points.last!.x, y: geometry.size.height))
                }.fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { path in path.addLines(points) }.stroke(tint, lineWidth: 1.5)
            } else {
                Text("Collecting…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct CPUDetailView: View {
    @ObservedObject var dashboard: MacDashboardMonitor
    @ObservedObject var memory: MemoryMonitor
    var body: some View {
        DetailShell(title: String(localized: "CPU"), icon: "cpu.fill") {
            HStack(alignment: .top, spacing: 12) {
                Sparkline(values: dashboard.cpuHistory, ceiling: 100).frame(height: 104)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    legend("User", dashboard.cpuSplit?.user, .purple)
                    legend("System", dashboard.cpuSplit?.system, .pink)
                    legend("Idle", dashboard.cpuSplit?.idle, .white.opacity(0.5))
                }.frame(width: 116)
            }
            HStack(spacing: 10) {
                StatTile(title: String(localized: "Uptime"), value: uptime, note: (dashboard.sample?.uptime ?? 0) > 7 * 86_400 ? String(localized: "A restart clears stuck background work.") : (dashboard.sample?.uptime ?? 0) < 86_400 ? String(localized: "Restarted recently.") : String(localized: "No restart needed yet."))
                let thermal = dashboard.sample?.thermalState
                StatTile(title: String(localized: "Thermal state"), value: thermal.map(thermalTitle) ?? String(localized: "Reading…"), note: thermal == "Normal" ? String(localized: "Running cool.") : String(localized: "macOS is slowing the CPU to cool down."), tint: thermal == "Normal" ? .mint : .orange)
            }
            TopCPUApps(memory: memory, title: "Top CPU users")
        } footer: {
            Text(load).foregroundStyle(.white.opacity(0.6)).help("Average number of busy threads over 1, 5 and 15 minutes.")
            Spacer()
            Button("Activity Monitor", action: openActivityMonitor)
        }
    }
    private func legend(_ title: LocalizedStringKey, _ value: Double?, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(value.map { ($0 / 100).formatted(.percent.precision(.fractionLength(1))) } ?? "—").font(.system(size: 16, weight: .semibold)).monospacedDigit()
                Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
    private var uptime: String {
        let formatter = DateComponentsFormatter(); formatter.allowedUnits = [.day, .hour, .minute]; formatter.unitsStyle = .abbreviated; formatter.maximumUnitCount = 2
        return dashboard.sample.flatMap { formatter.string(from: $0.uptime) } ?? "—"
    }
    private var load: String {
        var values = [Double](repeating: 0, count: 3)
        return getloadavg(&values, 3) == 3 ? String(localized: "Load \(values.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " · "))") : ""
    }
}

private struct BatteryDetailView: View {
    @ObservedObject var dashboard: MacDashboardMonitor
    @ObservedObject var memory: MemoryMonitor
    var body: some View {
        DetailShell(title: String(localized: "Battery"), icon: "battery.100") {
            if let battery = dashboard.sample?.battery {
                HStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.08), lineWidth: 12)
                        Circle().trim(from: 0, to: CGFloat(battery.percent ?? 0) / 100)
                            .stroke(battery.percent ?? 100 <= 20 ? Color.orange : .mint, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text(battery.percent.map { String(localized: "\($0)%") } ?? "—").font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    }.frame(width: 116, height: 116).padding(6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(battery.charging ? "Charging" : battery.externalPower ? "Not charging" : "On battery").font(.system(size: 17, weight: .semibold))
                        Text(timeNote(battery)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 10) {
                    let health = battery.healthPercent
                    StatTile(title: String(localized: "Health", comment: "Battery health"), value: health.map { String(localized: "\($0)%") } ?? "—",
                             note: health.map { $0 >= 80 ? String(localized: "Holds most of its original charge.") : String(localized: "Holds noticeably less charge. Consider a service check.") } ?? String(localized: "Not reported by this Mac."),
                             tint: (health ?? 100) >= 80 ? .mint : .orange)
                    StatTile(title: String(localized: "Charge cycles"), value: battery.cycleCount.map { $0.formatted() } ?? "—", note: String(localized: "Mac batteries are rated for about 1000 cycles."))
                }
                TopCPUApps(memory: memory, title: "Using the most energy (by CPU)")
            } else {
                Text(dashboard.sample == nil ? "Reading…" : "This Mac doesn't report a battery.").foregroundStyle(.white.opacity(0.65))
            }
        } footer: {
            Spacer()
            Button("Battery settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!) }
        }
    }
    private func timeNote(_ battery: MacBattery) -> String {
        guard let minutes = battery.minutesRemaining else { return battery.externalPower ? String(localized: "Powered by the adapter. macOS may hold charge to protect the battery.") : String(localized: "Estimating time left…") }
        return battery.charging ? String(localized: "\(minutes / 60) h \(minutes % 60) min until full") : String(localized: "\(minutes / 60) h \(minutes % 60) min left")
    }
}

private struct StorageDetailView: View {
    @ObservedObject var dashboard: MacDashboardMonitor
    let openWindow: (String) -> Void
    @State private var important: UInt64?
    var body: some View {
        DetailShell(title: volumeName, icon: "internaldrive.fill") {
            if let disk = dashboard.sample?.disk, disk.total > 0 {
                let used = disk.total - min(disk.total, disk.free), fraction = Double(used) / Double(disk.total)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(formattedBytes(disk.free)).font(.system(size: 28, weight: .semibold)).monospacedDigit().foregroundStyle(fraction > 0.9 ? .orange : .mint)
                        Text("free of \(formattedBytes(disk.total))").font(.system(size: 14)).foregroundStyle(.white.opacity(0.65))
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.08))
                            Capsule().fill(LinearGradient(colors: [.purple, fraction > 0.9 ? .orange : .blue], startPoint: .leading, endPoint: .trailing)).frame(width: geometry.size.width * fraction)
                        }
                    }.frame(height: 10)
                }
                HStack(spacing: 10) {
                    StatTile(title: String(localized: "Used", comment: "Disk space in use"), value: formattedBytes(used), note: String(localized: "\(Int((fraction * 100).rounded()))% of the disk"))
                    StatTile(title: String(localized: "Available for apps"), value: important.map(formattedBytes) ?? "—", note: String(localized: "Includes space macOS can free on its own (purgeable)."))
                }
                Text(fraction > 0.9 ? "Under 10% free: macOS slows down and updates may fail. Start with the biggest items." : "Find what takes the most room, then review it before anything is deleted.")
                    .font(.system(size: 13)).foregroundStyle(fraction > 0.9 ? .orange : .white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 6) {
                    action("See what uses space", icon: "chart.pie.fill", section: "Space Map")
                    action("Clean up caches and leftovers", icon: "sparkles", section: "Cleanup")
                    action("Find large and duplicate files", icon: "doc.on.doc.fill", section: "My Clutter")
                }
            } else { Text("Reading…").foregroundStyle(.white.opacity(0.65)) }
        } footer: {
            Spacer()
            Button("Open Trash") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")) }
        }
        .task {
            important = await Task.detached(priority: .utility) {
                (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage).map { UInt64(max(0, $0)) }
            }.value
        }
    }
    private var volumeName: String { (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? String(localized: "Storage") }
    private func action(_ title: LocalizedStringKey, icon: String, section: String) -> some View {
        Button { openWindow(section) } label: {
            HStack { Label(title, systemImage: icon); Spacer(); Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).flipsForRightToLeftLayoutDirection(true) }
                .font(.system(size: 14, weight: .medium)).padding(.horizontal, 12).frame(height: 38)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct NetworkDetailView: View {
    @ObservedObject var dashboard: MacDashboardMonitor
    var body: some View {
        DetailShell(title: dashboard.sample?.network?.kind ?? String(localized: "Network"), icon: "wifi") {
            if let network = dashboard.sample?.network {
                Text("Interface \(network.interface)").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                traffic("Download", rate: dashboard.download, total: network.received, history: dashboard.downloadHistory, tint: .blue)
                traffic("Upload", rate: dashboard.upload, total: network.sent, history: dashboard.uploadHistory, tint: .pink)
                Text("Totals count since this Mac started. Rates show current traffic, not your connection's top speed.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            } else { Text(dashboard.sample == nil ? "Reading…" : "No active network connection.").foregroundStyle(.white.opacity(0.65)) }
        } footer: {
            Spacer()
            Button("Network settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!) }
        }
    }
    private func traffic(_ title: LocalizedStringKey, rate: Double?, total: UInt64, history: [Double], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(formattedBytes(total)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                Spacer()
                Text(rate.map { String(localized: "\(formattedBytes(UInt64(max(0, min($0, 1e15)))))/s") } ?? String(localized: "Measuring…")).font(.system(size: 15, weight: .semibold)).monospacedDigit()
            }
            Sparkline(values: history, tint: tint).frame(height: 96)
        }.padding(14).background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct DevicesDetailView: View {
    @ObservedObject var dashboard: MacDashboardMonitor
    var body: some View {
        DetailShell(title: String(localized: "Connected devices"), icon: "keyboard.fill") {
            if dashboard.devices.isEmpty {
                Text(dashboard.sample == nil ? "Reading…" : "No devices reported.").foregroundStyle(.white.opacity(0.65))
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(dashboard.devices) { device in
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: icon(device)).font(.system(size: 24)).foregroundStyle(.mint)
                            Text(device.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                            Label(device.transportTitle, systemImage: device.transport.hasPrefix("Bluetooth") ? "dot.radiowaves.left.and.right" : "cable.connector")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                        }.padding(14).frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
                            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        } footer: {
            Text("Battery levels of accessories aren't exposed to apps.").foregroundStyle(.white.opacity(0.55))
            Spacer()
            Button("Bluetooth settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) }
        }
    }
    private func icon(_ device: ConnectedMacDevice) -> String {
        let name = device.name.lowercased()
        if name.contains("airpods") { return "airpodspro" }
        if name.contains("keys") || name.contains("keyboard") { return "keyboard" }
        if name.contains("mouse") || name.contains("mx vertical") || name.contains("mx master") { return "computermouse" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if name.contains("headphone") || name.contains("speaker") || name.contains("audio") { return "headphones" }
        return "cable.connector"
    }
}
