import SwiftUI
import AppKit
import MacStewardCore

@MainActor
final class ProcessesState: ObservableObject {
    @Published var processes: [RunningProcess] = []
    func refresh() async { processes = await Task.detached(priority: .userInitiated) { ProcessList.read() }.value }
}

/// Every running process with the app it belongs to, so a bare "PID 36718" gets a name before anyone quits it.
struct ProcessesView: View {
    @StateObject private var state = ProcessesState()
    @State private var search = ""
    @State private var onlyMine = true
    @State private var grouped = false
    @State private var expanded = Set<String>()
    @State private var order = "Memory"
    @State private var ending: (process: RunningProcess, force: Bool)?
    @State private var error: String?
    private var shown: [RunningProcess] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let found = state.processes.filter { process in
            (!onlyMine || process.mine) && (query.isEmpty || String(process.pid).hasPrefix(query) || process.path.localizedCaseInsensitiveContains(query)
                || title(process).localizedCaseInsensitiveContains(query) || group(of: process).localizedCaseInsensitiveContains(query))
        }
        switch order {
        case "CPU": return found.sorted { $0.cpu > $1.cpu }
        case "Name": return found.sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
        default: return found.sorted { $0.memory > $1.memory }
        }
    }
    /// The app a process belongs to; processes outside any app go under macOS or their own name.
    private func group(of process: RunningProcess) -> String { process.appName ?? (process.isSystem ? "macOS" : process.name) }
    struct ProcessGroup: Identifiable { let id: String; let members: [RunningProcess]; var cpu: Double { members.reduce(0) { $0 + $1.cpu } }; var memory: UInt64 { members.reduce(0) { $0 + $1.memory } } }
    /// Groups in the chosen order, by their totals; members keep the same order inside.
    private var groups: [ProcessGroup] {
        let list = shown
        let found = Dictionary(grouping: list, by: group(of:)).map { ProcessGroup(id: $0.key, members: $0.value) }
        switch order {
        case "CPU": return found.sorted { $0.cpu > $1.cpu }
        case "Name": return found.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        default: return found.sorted { $0.memory > $1.memory }
        }
    }
    private func app(_ process: RunningProcess) -> NSRunningApplication? { NSRunningApplication(processIdentifier: process.pid) }
    private func title(_ process: RunningProcess) -> String { app(process)?.localizedName ?? process.name }
    private func subtitle(_ process: RunningProcess) -> String {
        if app(process)?.activationPolicy == .regular { return process.path }
        if let owner = process.appName { return String(localized: "Part of \(owner)") }
        return process.isSystem ? "macOS" : process.path
    }
    private func icon(_ process: RunningProcess) -> NSImage {
        app(process)?.icon ?? process.appPath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .unixExecutable)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ToolHeading(title: "Processes", detail: "Everything running on your Mac, with the app it belongs to. Quit only what you recognise.")
            HStack(spacing: 12) {
                TextField("Find by name or PID", text: $search).stewardInput()
                Toggle("Only mine", isOn: $onlyMine).toggleStyle(.checkbox)
                Toggle("Group by app", isOn: $grouped).toggleStyle(.checkbox)
                Picker("Sort", selection: $order) { Text("Memory").tag("Memory"); Text("CPU").tag("CPU"); Text("Name").tag("Name") }.frame(width: 170)
                Button("Refresh") { Task { await state.refresh() } }.buttonStyle(RowActionButtonStyle())
            }
            if let error { Text(error).stewardFont(.callout).foregroundStyle(.orange) }
            LazyVStack(spacing: 6) {
                if grouped {
                    ForEach(groups) { group in
                        groupRow(group)
                        if expanded.contains(group.id) { ForEach(group.members) { process in row(process).padding(.leading, 34) } }
                    }
                } else {
                    ForEach(shown) { process in row(process) }
                }
            }
        }
        // Live while the page is open; it stops with the page.
        .task { while !Task.isCancelled { await state.refresh(); try? await Task.sleep(for: .seconds(5)) } }
        .confirmationDialog(ending.map { String(localized: "Quit \(title($0.process))?") } ?? "", isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }), titleVisibility: .visible) {
            if let ending {
                Button(ending.force ? "Force Quit" : "Quit", role: .destructive) { end(ending.process, force: ending.force) }
                Button("Cancel", role: .cancel) { self.ending = nil }
            }
        } message: {
            if let ending { Text(ending.force ? "Unsaved work in it is lost." : "It's asked to quit and can save its work first.") }
        }
    }
    /// One line per app: its icon, how many processes, and their totals. A click opens it; Quit quits the app itself.
    private func groupRow(_ group: ProcessGroup) -> some View {
        let open = expanded.contains(group.id)
        let main = group.members.first { app($0)?.activationPolicy == .regular }
        return HStack(spacing: 12) {
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
            Image(nsImage: icon(main ?? group.members[0])).resizable().frame(width: 28, height: 28)
            Text(group.id).stewardFont(.body, weight: .semibold).lineLimit(1)
            Text(verbatim: "\(group.members.count)").stewardFont(.caption, weight: .semibold).monospacedDigit()
                .padding(.horizontal, 7).padding(.vertical, 2).background(.white.opacity(0.12), in: Capsule())
            Spacer(minLength: 12)
            Text(verbatim: String(format: "%.1f %%", group.cpu)).stewardFont(.caption).monospacedDigit().frame(width: 60, alignment: .trailing)
            Text(formattedBytes(group.memory)).stewardFont(.callout, weight: .medium).monospacedDigit().frame(width: 80, alignment: .trailing)
            if let main { Button("Quit") { ending = (main, false) }.buttonStyle(RowActionButtonStyle()).stewardFont(.caption).disabled(!ProcessList.endable(main)) }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.white.opacity(open ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { if open { expanded.remove(group.id) } else { expanded.insert(group.id) } } }
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isButton)
    }
    private func row(_ process: RunningProcess) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: icon(process)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(process)).stewardFont(.body, weight: .semibold).lineLimit(1)
                Text(subtitle(process)).stewardFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(process.path)
            }
            Spacer(minLength: 12)
            Text(verbatim: "PID \(process.pid)").stewardFont(.caption, design: .monospaced).foregroundStyle(.secondary).textSelection(.enabled)
            Text(verbatim: String(format: "%.1f %%", process.cpu)).stewardFont(.caption).monospacedDigit().frame(width: 60, alignment: .trailing)
            Text(formattedBytes(process.memory)).stewardFont(.callout, weight: .medium).monospacedDigit().frame(width: 80, alignment: .trailing)
            HStack(spacing: 6) {
                if process.path.hasPrefix("/") { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: process.appPath ?? process.path)]) } }
                Button("Quit") { ending = (process, false) }
                Button("Force Quit") { ending = (process, true) }
            }.buttonStyle(RowActionButtonStyle()).stewardFont(.caption).disabled(!ProcessList.endable(process))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
    private func end(_ process: RunningProcess, force: Bool) {
        ending = nil; error = nil
        // A regular app gets the normal quit request, so it can ask to save.
        if !force, let app = app(process), app.activationPolicy == .regular { app.terminate() }
        else { do { try ProcessList.end(process, force: force) } catch { self.error = error.localizedDescription } }
        Task { try? await Task.sleep(for: .seconds(1)); await state.refresh() }
    }
}
