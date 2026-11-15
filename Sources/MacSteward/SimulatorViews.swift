import SwiftUI
import MacStewardCore

/// Xcode's simulators, read with `simctl` off the main thread: which run, how much memory each takes, and shutting them down.
@MainActor final class SimulatorState: ObservableObject {
    /// nil until read, or when Xcode's tools aren't there.
    @Published private(set) var all: [SimulatorDevice]?
    @Published private(set) var memory = [String: UInt64]()
    @Published private(set) var stopping = Set<String>()
    /// Longest unused first, so the ones to shut down sit together at the top.
    var running: [SimulatorDevice] { (all ?? []).filter(\.running).sorted { ($0.lastUsed ?? .distantFuture) < ($1.lastUsed ?? .distantFuture) } }
    func refresh() async {
        let (list, used) = await Task.detached(priority: .utility) { () -> ([SimulatorDevice]?, [String: UInt64]) in
            let list = Simulators.list()
            return (list, Simulators.memory(of: list?.filter(\.running).map(\.id) ?? []))
        }.value
        all = list; memory = used
    }
    /// Like turning a phone off: apps and data stay. A test running on it stops.
    func shutDown(_ ids: [String]) async {
        stopping.formUnion(ids)
        await Task.detached(priority: .userInitiated) { for id in ids { _ = Simulators.shutdown(id) } }.value
        stopping.subtract(ids)
        await refresh()
    }
    static func icon(_ name: String) -> String { name.contains("Watch") ? "applewatch" : name.contains("iPad") ? "ipad" : name.contains("TV") ? "appletv" : "iphone" }
}

/// Above the Xcode list: what simulators are, how much each kind takes, and one button for the ones that are sure to go.
struct SimulatorOverview: View {
    let findings: [Finding]
    let selectSafe: () -> Void
    let openPerformance: () -> Void
    @StateObject private var state = SimulatorState()

    var body: some View {
        let all = state.all ?? []
        let shut = XcodeStorageInventory.deletableSimulators(all), now = Date()
        let broken = shut.filter { !$0.available }, idle = shut.filter { $0.available && $0.safeToDelete(now: now) }
        let recent = shut.filter { !$0.safeToDelete(now: now) }, running = all.filter(\.running)
        let safe = findings.filter(\.certain)
        VStack(alignment: .leading, spacing: 12) {
            Label("Simulators: \(all.count) · \(formattedBytes(size(all)))", systemImage: "iphone.gen3").stewardFont(.headline)
            Text("A simulator is a virtual iPhone, iPad or Watch that Xcode uses to test apps. Deleting one removes only the test apps and data inside it, never your projects, and Xcode makes a new one in a minute.")
                .stewardFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                tile("xmark.octagon", String(localized: "Can't start anymore"), broken, String(localized: "Made for an older iOS. Safe to delete."), .mint)
                tile("moon.zzz", String(localized: "Not used for 30 days"), idle, String(localized: "Safe to delete."), .mint)
                tile("clock", String(localized: "Used recently"), recent, String(localized: "Keep them unless you're done testing."), .secondary)
                tile("play.circle", String(localized: "Running now"), running, String(localized: "Can't be deleted. Shut down to free memory."), .orange, action: running.isEmpty ? nil : (String(localized: "Open Performance"), openPerformance))
            }
            HStack {
                Button { selectSafe() } label: { Label(safe.isEmpty ? String(localized: "Nothing is sure to delete") : String(localized: "Select the safe ones · \(formattedBytes(size(safe)))"), systemImage: "wand.and.stars") }
                    .buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(safe.isEmpty)
                    .help("Ticks only simulators that can't start anymore or that nothing used for 30 days. Recent ones stay unticked.")
                if state.all == nil { ProgressView().controlSize(.small) }
            }
        }
        .padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .task { await state.refresh() }
    }
    private func tile(_ icon: String, _ title: String, _ items: [SimulatorDevice], _ hint: String, _ tint: Color, action: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).stewardFont(.callout, weight: .semibold).foregroundStyle(tint)
            Text("\(items.count) · \(formattedBytes(size(items)))").stewardFont(.body, weight: .medium).monospacedDigit()
            Text(hint).stewardFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let action { Button(action.0, action: action.1).buttonStyle(.link).stewardFont(.caption) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
    private func size(_ items: [SimulatorDevice]) -> UInt64 { items.reduce(0) { $0 + $1.bytes } }
    private func size(_ items: [Finding]) -> UInt64 { items.reduce(0) { $0 + $1.bytes } }
}

/// On the Memory page: running simulators and the memory each holds, with Shut down.
struct RunningSimulatorsCard: View {
    @StateObject private var state = SimulatorState()
    @State private var confirming = [SimulatorDevice]()
    @AppStorage("simulatorUnusedHours") private var unusedHours = 24

    var body: some View {
        let running = state.running
        Group {
            if !running.isEmpty {
                let size = { (devices: [SimulatorDevice]) in formattedMemory(devices.reduce(UInt64(0)) { $0 + (state.memory[$1.id] ?? 0) }) }
                let unused = running.filter { $0.unused(for: Double(unusedHours) * 3600) }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Running simulators").stewardFont(.headline)
                        Spacer()
                        Button("Shut down all · \(size(running))") { confirming = running }
                            .buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)).disabled(!state.stopping.isEmpty)
                    }
                    Text("Virtual iPhones and iPads from Xcode. Shutting one down frees its memory and keeps its apps and data; Xcode starts it again when needed. A test running on it stops.")
                        .stewardFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Picker("Unused for", selection: $unusedHours) {
                            ForEach([1, 24, 72, 168], id: \.self) { Text(Duration.seconds($0 * 3600).formatted(.units(allowed: [.weeks, .days, .hours], width: .wide))).tag($0) }
                        }.fixedSize()
                        Button("Shut down unused · \(size(unused))") { confirming = unused }
                            .buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(unused.isEmpty || !state.stopping.isEmpty)
                    }
                    VStack(spacing: 6) {
                        ForEach(running) { device in
                            HStack(spacing: 12) {
                                Image(systemName: SimulatorState.icon(device.name)).frame(width: 26).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).stewardFont(.body, weight: .medium).lineLimit(1)
                                    // simctl's lastUsedAt: when Xcode last booted it or ran an app on it.
                                    if let used = device.lastUsed {
                                        Text("Last used \(used.formatted(.relative(presentation: .named)))").stewardFont(.caption)
                                            .foregroundStyle(unused.contains(device) ? .orange : .secondary)
                                    }
                                }
                                Spacer()
                                Text(state.memory[device.id].map(formattedMemory) ?? "–").stewardFont(.body).monospacedDigit()
                                if state.stopping.contains(device.id) { ProgressView().controlSize(.small).frame(width: 90) }
                                else { Button("Shut down") { Task { await state.shutDown([device.id]) } }.frame(width: 90) }
                            }.padding(.horizontal, 11).padding(.vertical, 8).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
                        }
                    }
                }
                .confirmationDialog("Shut down \(confirming.count) simulators?", isPresented: Binding(get: { !confirming.isEmpty }, set: { if !$0 { confirming = [] } }), titleVisibility: .visible) {
                    Button("Shut down") { let ids = confirming.map(\.id); Task { await state.shutDown(ids) } }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Their apps and data stay. Tests running on them stop.") }
            }
        }
        .task { while !Task.isCancelled { await state.refresh(); do { try await Task.sleep(for: .seconds(15)) } catch { break } } }
    }
}
