import LocalAuthentication
import Network
import SwiftUI

/// What iOS tells an app about this iPhone at this moment. A plain value, so the scoring can be tested.
struct DeviceReading {
    var free: Int64
    var total: Int64
    var purgeable: Int64
    var passcode: Bool
    var biometrics: String?
    var iosVersion: String
    var model: String
    var lowPower: Bool
    var heat: ProcessInfo.ThermalState
    var battery: Float
    var charging: Bool
    var memory: UInt64
    var cores: Int
    var uptime: TimeInterval

    @MainActor static func current() -> DeviceReading {
        let context = LAContext()
        let passcode = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        var biometrics: String?
        switch context.biometryType {
        case .faceID: biometrics = "Face ID"
        case .touchID: biometrics = "Touch ID"
        case .opticID: biometrics = "Optic ID"
        default: biometrics = nil
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let space = DiskSpace.current, info = ProcessInfo.processInfo
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let state = UIDevice.current.batteryState
        return DeviceReading(free: space.free, total: space.total, purgeable: space.purgeable, passcode: passcode, biometrics: biometrics, iosVersion: UIDevice.current.systemVersion, model: model,
                             lowPower: info.isLowPowerModeEnabled, heat: info.thermalState, battery: UIDevice.current.batteryLevel, charging: state == .charging || state == .full,
                             memory: info.physicalMemory, cores: info.activeProcessorCount, uptime: info.systemUptime)
    }
}

struct HealthItem: Identifiable, Equatable {
    enum Level: Int { case good, note, problem }
    let id: String
    let title: LocalizedStringKey
    let value: String
    let level: Level
    var advice: LocalizedStringKey? = nil

    static func == (a: HealthItem, b: HealthItem) -> Bool { a.id == b.id && a.level == b.level }
}

/// Only what iOS really reports. Apple's rules also forbid telling people to restart for no reason, so uptime is only shown.
struct HealthReport {
    let items: [HealthItem]
    let about: [(title: LocalizedStringKey, value: String)]

    /// Out of 100: each thing worth a look costs points, a real problem costs more.
    var score: Int { max(0, 100 - items.reduce(0) { $0 + ($1.level == .problem ? 30 : $1.level == .note ? 10 : 0) }) }

    init(reading r: DeviceReading) {
        var list: [HealthItem] = []
        let share = r.total > 0 ? Double(r.free) / Double(r.total) : 1
        list.append(HealthItem(id: "storage", title: "Storage", value: String(app: "\(formatted(r.free)) free"), level: share < 0.05 ? .problem : share < 0.1 ? .note : .good,
                               advice: share < 0.1 ? "Run a scan to see what can go. Under 10% free, iOS may slow down and updates can fail." : nil))
        list.append(HealthItem(id: "passcode", title: "Passcode", value: r.passcode ? String(app: "On") : String(app: "Off"), level: r.passcode ? .good : .problem,
                               advice: r.passcode ? nil : "Without a passcode, anyone holding this iPhone can open it, and its data isn't protected. Turn it on in Settings, Face ID & Passcode."))
        if let name = r.biometrics { list.append(HealthItem(id: "biometrics", title: "Biometric unlock", value: name, level: .good)) }
        switch r.heat {
        case .serious: list.append(HealthItem(id: "heat", title: "Temperature", value: String(app: "Hot"), level: .note, advice: "iOS may slow down to cool off. Give it a break from charging or heavy apps."))
        case .critical: list.append(HealthItem(id: "heat", title: "Temperature", value: String(app: "Very hot"), level: .problem, advice: "Take it out of the sun, stop heavy apps and let it cool down."))
        default: list.append(HealthItem(id: "heat", title: "Temperature", value: String(app: "Normal"), level: .good))
        }
        if r.battery >= 0 {
            let low = r.battery < 0.2 && !r.charging
            list.append(HealthItem(id: "battery", title: "Battery charge", value: "\(Int(r.battery * 100))%" + (r.charging ? " · " + String(app: "Charging") : ""), level: low ? .note : .good, advice: low ? "Running low. Charge it soon." : nil))
        }
        list.append(HealthItem(id: "power", title: "Low Power Mode", value: r.lowPower ? String(app: "On") : String(app: "Off"), level: .good))
        items = list
        about = [("Model code", r.model), ("iOS", r.iosVersion), ("Memory", ByteCountFormatter.string(fromByteCount: Int64(r.memory), countStyle: .memory)), ("Processor cores", String(r.cores)),
                 ("On for", Duration.seconds(r.uptime).formatted(.units(allowed: [.days, .hours], width: .wide, maximumUnitCount: 2))), ("iOS can clear by itself", formatted(r.purgeable))]
    }
}

struct HealthView: View {
    @Environment(Library.self) private var library
    @State private var report = HealthReport(reading: .current())
    @State private var space = DiskSpace.current
    @State private var network: LocalizedStringKey = "Checking"
    @Environment(\.scenePhase) private var scenePhase

    private var status: (title: LocalizedStringKey, color: Color) {
        report.score >= 90 ? ("Great", StewardTheme.cleanup.accent) : report.score >= 60 ? ("Good", StewardTheme.space.accent) : ("Needs attention", StewardTheme.files.accent)
    }
    private static let colors: [Color] = [StewardTheme.care.vivid, StewardTheme.files.vivid, StewardTheme.system.accent, StewardTheme.cleanup.accent, StewardTheme.space.accent, .pink, .teal, .indigo]
    private var categories: [PhotoCategory] {
        PhotoCategory.allCases.filter { !library.items($0).isEmpty }.sorted { library.saving($0) > library.saving($1) }
    }

    var body: some View {
        StagePage(theme: .system, title: "Device health", subtitle: "How your iPhone is doing right now.", artwork: "sculpture-card-performance") {
            HStack(spacing: 10) {
                Text(status.title).font(.headline)
                Text("\(report.score)").font(.headline.monospacedDigit()).padding(.horizontal, 10).padding(.vertical, 3).background(.black.opacity(0.14), in: .capsule)
            }
            .foregroundStyle(.black.opacity(0.85)).padding(.leading, 18).padding(.trailing, 7).padding(.vertical, 8).background(status.color, in: .capsule)
            .accessibilityElement(children: .combine)

            securityCard
            storageCard
            deviceCard
            aboutCard
            Text("Battery wear, cycle counts and available iOS updates aren't shared with apps. You'll find them in Settings, Battery and Settings, General, Software Update.").font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                report = HealthReport(reading: .current())
                space = DiskSpace.current
            }
        }
        .task {
            // Only asks what kind of connection there is. Nothing is sent.
            let monitor = NWPathMonitor()
            let stream = AsyncStream<NWPath> { continuation in
                monitor.pathUpdateHandler = { continuation.yield($0) }
                monitor.start(queue: .global(qos: .utility))
                continuation.onTermination = { _ in monitor.cancel() }
            }
            for await path in stream {
                network = path.status != .satisfied ? "Offline" : path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.cellular) ? "Mobile data" : "Connected"
            }
        }
    }

    private func tag(_ text: LocalizedStringKey, _ color: Color) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 5).background(color.opacity(0.16), in: .rect(cornerRadius: 8))
    }

    private func rows(_ ids: [String]) -> some View {
        ForEach(report.items.filter { ids.contains($0.id) }) { item in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: item.level == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(item.level == .good ? StewardTheme.cleanup.accent : item.level == .note ? StewardTheme.space.accent : StewardTheme.files.accent).accessibilityHidden(true)
                    Text(item.title)
                    Spacer()
                    Text(item.value).foregroundStyle(.white.opacity(0.8)).monospacedDigit()
                }
                if let advice = item.advice { Text(advice).font(.footnote).foregroundStyle(.white.opacity(0.75)) }
            }.accessibilityElement(children: .combine)
        }
    }

    private var securityCard: some View {
        let safe = report.items.first { $0.id == "passcode" }?.level == .good
        return GlassCard {
            tag(safe ? "Security looks good" : "Security at risk", safe ? StewardTheme.cleanup.accent : StewardTheme.files.accent)
            rows(["passcode", "biometrics"])
        }
    }

    private var storageCard: some View {
        let low = SpaceReminder.isLow(free: space.free, total: space.total)
        return GlassCard {
            tag(low ? "Running out of space" : "Enough space left", low ? StewardTheme.files.accent : StewardTheme.cleanup.accent)
            Text("\(formatted(space.free)) free of \(formatted(space.total))").font(.title3.weight(.semibold))
            if categories.isEmpty {
                ProgressView(value: Double(Swift.max(space.total - space.free, 0)), total: Double(Swift.max(space.total, 1))).tint(StewardTheme.system.accent).accessibilityLabel("Storage used")
                Text(library.phase == .idle ? "Press Scan on Overview to see what's taking up room." : "Nothing to review right now.").font(.footnote).foregroundStyle(.white.opacity(0.7))
            } else {
                Text("What could go, largest first").font(.footnote).foregroundStyle(.white.opacity(0.75))
                GeometryReader { geometry in
                    let total = categories.reduce(Int64(0)) { $0 + library.saving($1) }
                    HStack(spacing: 2) {
                        ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                            Self.colors[index % Self.colors.count].frame(width: Swift.max(3, (geometry.size.width - CGFloat(categories.count - 1) * 2) * CGFloat(library.saving(category)) / CGFloat(Swift.max(total, 1))))
                        }
                    }
                }
                .frame(height: 34).clipShape(.rect(cornerRadius: 10)).accessibilityHidden(true)
                ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                    NavigationLink {
                        if category == .livePhotos { LivePhotosView() } else {
                            PhotoReviewView(title: category.title, note: category.note, theme: .system, groups: library.results[category] ?? [], category: category)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 3).fill(Self.colors[index % Self.colors.count]).frame(width: 6, height: 36).accessibilityHidden(true)
                            Text(category.title)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(formatted(library.saving(category))).monospacedDigit()
                                Text("^[\(library.items(category).count) item](inflect: true)").font(.footnote).foregroundStyle(.white.opacity(0.65))
                            }
                            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.4))
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var deviceCard: some View {
        GlassCard {
            tag("Right now", StewardTheme.system.accent)
            rows(["heat", "battery", "power"])
            LabeledContent("Connection") { Text(network) }
        }
    }

    private var aboutCard: some View {
        GlassCard {
            Text("This iPhone").font(.headline)
            ForEach(report.about.indices, id: \.self) { index in LabeledContent(report.about[index].title, value: report.about[index].value) }
        }
    }
}
