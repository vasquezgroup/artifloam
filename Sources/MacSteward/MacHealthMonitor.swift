import SwiftUI
import AppKit
import Combine
import UserNotifications
import MacStewardCore

/// Turns live readings into one health score and a short list of issues. Runs while Artifloam runs,
/// so the leaf dot, notifications and the Overview stay current even when the dashboard is closed.
@MainActor
final class MacHealthMonitor: ObservableObject {
    /// Set by the model: quits the idle apps on the stage. The monitor itself has no stage.
    var quitIdleApps: (() -> Void)?
    @Published private(set) var health: MacHealth?
    /// Installers and archives in Downloads untouched for 30 days. Read when the dashboard opens.
    @Published private(set) var installers: (urls: [URL], bytes: UInt64)?
    let dashboard: MacDashboardMonitor
    let memory: MemoryMonitor
    /// What the stage says while an Overview warning's fix runs; nil when none is running.
    @Published private(set) var fixing: (title: String, detail: String)?
    private var fixRun: UUID?
    private var busySince = [Int32: Date](), pressureSince: Date?
    private var notified = Set<String>()
    private var forecastSamples: [DiskForecast.Sample]
    private var watching = [AnyCancellable]()
    private static let forecastKey = "diskForecastSamples"

    init(dashboard: MacDashboardMonitor, memory: MemoryMonitor) {
        self.dashboard = dashboard; self.memory = memory
        forecastSamples = (StewardPreferences.defaults.data(forKey: Self.forecastKey)).flatMap { try? JSONDecoder().decode([DiskForecast.Sample].self, from: $0) } ?? []
        // Re-evaluate on every fresh reading, including the fast ones while the dashboard is open.
        dashboard.$sample.map { _ in () }.merge(with: memory.$reading.map { _ in () })
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }.store(in: &watching)
    }

    /// one reading every 20 s in the background; the dashboard reads every 2 s while open.
    func start() {
        Task { [weak self] in
            while let self {
                await self.dashboard.refresh(); await self.memory.refresh()
                do { try await Task.sleep(for: .seconds(20)) } catch { break }
            }
        }
    }

    private func evaluate() {
        guard let sample = dashboard.sample else { return }
        let now = Date()
        var input = MacHealthInput()
        input.diskFree = sample.disk.free; input.diskTotal = sample.disk.total
        let samples = DiskForecast.record(free: sample.disk.free, into: forecastSamples)
        if samples != forecastSamples { forecastSamples = samples; StewardPreferences.defaults.set(try? JSONEncoder().encode(samples), forKey: Self.forecastKey) }
        input.daysUntilFull = DiskForecast.daysUntilFull(forecastSamples)
        if let reading = memory.reading {
            input.pressure = reading.pressure; input.swap = reading.swap; input.ram = reading.total
            pressureSince = reading.pressure == .warning || reading.pressure == .critical ? (pressureSince ?? now) : nil
            input.pressureHighFor = pressureSince.map { now.timeIntervalSince($0) } ?? 0
            let busy = Set(memory.cpu.filter { $0.value >= 80 }.keys)
            busySince = busySince.filter { busy.contains($0.key) }
            for pid in busy where busySince[pid] == nil { busySince[pid] = now }
            if let (pid, since) = busySince.min(by: { $0.value < $1.value }), let row = reading.apps.first(where: { $0.id == pid }) {
                input.busyApp = .init(pid: pid, name: row.app.name, percent: memory.cpu[pid] ?? 0, seconds: now.timeIntervalSince(since), ignoredQuit: memory.ignoredQuit(pid))
            }
        }
        input.thermal = sample.thermalState
        input.batteryHealth = sample.battery?.healthPercent; input.batteryPercent = sample.battery?.percent
        input.onBattery = sample.battery.map { !$0.externalPower } ?? false
        input.uptime = sample.uptime
        input.online = sample.network != nil
        let next = MacHealth.evaluate(input)
        if next != health { health = next }
        notify(next.issues)
    }

    /// Once per problem, only for problems that already lasted; it re-arms when the problem clears.
    private func notify(_ issues: [MacIssue]) {
        let ids = Set(issues.map(\.id))
        notified.formIntersection(ids)
        // Notifications need a real app bundle; `swift run` builds have none.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        for issue in issues where !notified.contains(issue.id) && issue.kind != .network {
            notified.insert(issue.id)
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = issue.title
            switch issue.fix {
            case .quit: content.body = String(localized: "Open Artifloam from the leaf in the menu bar to quit the app.")
            case .forceQuit: content.body = String(localized: "Open Artifloam from the leaf in the menu bar to force quit the app.")
            case .freeSpace: content.body = String(localized: "Open Artifloam from the leaf in the menu bar to free up space.")
            case .quitIdleApps: content.body = String(localized: "Open Artifloam from the leaf in the menu bar to quit idle apps.")
            case .batterySettings, .networkSettings: content.body = String(localized: "Open Artifloam from the leaf in the menu bar to open settings.")
            case .none: content.body = String(localized: "Open Artifloam from the leaf in the menu bar for details.")
            }
            let request = UNNotificationRequest(identifier: "health-" + issue.id, content: content, trigger: nil)
            center.requestAuthorization(options: [.alert]) { granted, _ in if granted { center.add(request) } }
        }
    }

    /// The issue a dashboard card (and its flyout) shows.
    func issue(for kind: DashboardDetail) -> MacIssue? {
        let kinds: [MacIssue.Kind] = switch kind {
        case .storage: [.storage]
        case .memory: [.memory, .restart]
        case .cpu: [.cpu, .heat]
        case .battery: [.battery]
        case .network: [.network]
        case .devices: []
        }
        return health?.issues.first { kinds.contains($0.kind) }
    }
    func perform(_ fix: MacIssue.Fix, openSection: (String) -> Void) {
        switch fix {
        case .quit(let pid): if let row = memory.reading?.apps.first(where: { $0.id == pid }) { memory.quit(row) }
        case .forceQuit(let pid): if let row = memory.reading?.apps.first(where: { $0.id == pid }) { memory.forceQuit(row) }
        case .freeSpace: openSection("Space Map")
        // Opens the window on Performance and quits right away, on the stage.
        case .quitIdleApps: openSection("Performance"); quitIdleApps?()
        case .batterySettings: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
        case .networkSettings: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
        case .none: break
        }
    }

    /// The Overview's warning rows: the same fixes, on the scan stage, so a click always answers at once.
    /// `prepare` loads what the opened page needs, so it arrives ready rather than filling in afterwards.
    func performOnStage(_ fix: MacIssue.Fix, prepare: @escaping @MainActor () async -> Void, openSection: @escaping (String) -> Void) {
        switch fix {
        case .quitIdleApps: openSection("Performance"); quitIdleApps?()
        case .quit(let pid), .forceQuit(let pid):
            guard let row = memory.reading?.apps.first(where: { $0.id == pid }) else { return }
            var asked = false
            if case .quit = fix { asked = memory.quit(row) } else { asked = memory.forceQuit(row) }
            guard asked else { return }
            stage(String(localized: "Asking \(row.app.name.displaySafe) to quit…"), String(localized: "Save your work if \(row.app.name.displaySafe) asks."), work: { [memory] in await memory.waitForQuit(pid) })
        default: perform(fix, openSection: openSection)
        }
    }
    /// The artwork stays up for a moment, however fast the answer is, like every other scan.
    private func stage(_ title: String, _ detail: String, work: @escaping @MainActor () async -> Void, then: @escaping () -> Void = {}) {
        let id = UUID(); fixRun = id; fixing = (title, detail)
        Task {
            async let pause: Void? = try? Task.sleep(for: .seconds(1.6))
            await work()
            _ = await pause
            guard fixRun == id else { return }
            fixRun = nil; fixing = nil
            then()
        }
    }
    /// Stops waiting. An app already asked to quit may still quit.
    func stopFixing() { fixRun = nil; fixing = nil }

    func readInstallers() {
        Task {
            installers = await Task.detached(priority: .utility) { () -> (urls: [URL], bytes: UInt64)? in
                // Opening the dashboard must not set off macOS's Downloads prompt: only read with Full Disk Access.
                guard FullDiskAccess.status() == .granted else { return nil }
                let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
                guard let items = try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
                let cutoff = Date().addingTimeInterval(-30 * 86_400)
                var urls = [URL](), bytes: UInt64 = 0
                for url in items where ["dmg", "pkg", "zip", "xip", "iso"].contains(url.pathExtension.lowercased()) {
                    guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, (values.contentModificationDate ?? .distantFuture) < cutoff else { continue }
                    urls.append(url); bytes += UInt64(values.totalFileAllocatedSize ?? 0)
                }
                return urls.isEmpty ? nil : (urls, bytes)
            }.value
        }
    }
}
