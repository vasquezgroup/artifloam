import SwiftUI
import AppKit
import MacStewardCore

@MainActor
final class ToolFolderSelection: ObservableObject {
    @Published var url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    private var panel: NSOpenPanel?
    private var scopedURL: URL?
    deinit { scopedURL?.stopAccessingSecurityScopedResource() }
    func choose() {
        guard panel == nil else { return }
        let picker = NSOpenPanel(); panel = picker
        picker.title = String(localized: "Choose a folder to inspect"); picker.prompt = String(localized: "Choose Folder", comment: "Button in the folder picker: use the selected folder")
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.directoryURL = url
        DispatchQueue.main.async { [self] in
            NSApp.activate(ignoringOtherApps: true)
            let response = picker.runModal()
            if response == .OK, let selected = picker.urls.first {
                self.scopedURL?.stopAccessingSecurityScopedResource()
                self.scopedURL = selected.startAccessingSecurityScopedResource() ? selected : nil
                self.url = selected
            }
            self.panel = nil
        }
    }
}

@MainActor
final class LargeFilesState: ObservableObject {
    @Published var report: LargeFileReport?
    @Published var minimum = 100_000_000 { didSet { reset() } }
    @Published var months = 0 { didSet { reset() } }
    @Published var selection = Set<String>()
    @Published private(set) var task: Task<LargeFileReport, Error>?
    @Published var error: String?
    var files: [LargeFileItem] { report?.files ?? [] }
    func reset() { report = nil; selection.removeAll() }
    func scan(_ folder: URL) {
        guard task == nil else { return }
        selection.removeAll(); error = nil
        let size = UInt64(minimum), before = months == 0 ? nil : Calendar.current.date(byAdding: .month, value: -months, to: Date())
        let work = Task.detached(priority: .utility) { try LargeFileAudit.scan(root: folder, minimumBytes: size, modifiedBefore: before) }
        task = work
        Task { defer { task = nil }; do { report = try await work.value } catch is CancellationError { error = String(localized: "Search stopped. Run Find files to search again.") } catch { self.error = error.localizedDescription } }
    }
    func cancel() { task?.cancel() }
}

struct LargeFilesView: View {
    @ObservedObject var location: ToolFolderSelection
    @ObservedObject var state: LargeFilesState
    @State private var trashRequest: TrashRequest?
    @State private var note: String?
    private var files: [LargeFileItem] { state.files }
    private var task: Task<LargeFileReport, Error>? { state.task }
    private var selection: Set<String> { state.selection }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ToolHeading(title: "Large & old files", detail: "Filter by full file size and modification date, with results sorted by space stored on this Mac. Nothing is preselected or removed automatically.")
            Text(location.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).stewardFont(.caption, design: .monospaced).textSelection(.enabled)
            HStack {
                Button("Choose folder…") { choose() }.disabled(task != nil)
                Picker("At least", selection: $state.minimum) { Text("10 MB").tag(10_000_000); Text("100 MB").tag(100_000_000); Text("1 GB").tag(1_000_000_000) }.frame(width: 175).disabled(task != nil)
                Picker("Modified", selection: $state.months) { Text("Any time").tag(0); Text("Over 6 months ago").tag(6); Text("Over a year ago").tag(12) }.frame(width: 230).disabled(task != nil)
                Spacer()
                if task != nil { Button("Stop") { state.cancel() } }
                else { Button("Find files") { scan() }.buttonStyle(CleanupGlassButtonStyle()) }
            }
            Text("‘Old’ means last modified before the chosen date; it does not prove a file is unused. File contents are never opened or downloaded. Hidden folders, Library and app bundles are excluded.").stewardFont(.caption).foregroundStyle(.secondary)
            if task != nil { StewardProgressBar(title: "Reading file sizes…").frame(maxWidth: 400) }
            if let report = state.report {
                HStack {
                    Text("\(files.count) matches · \(formattedBytes(files.reduce(0) { $0 + $1.localBytes })) stored on this Mac").stewardFont(.headline)
                    Spacer()
                }
                if !files.isEmpty {
                    let chosen = files.filter { selection.contains($0.id) }
                    BulkBar(title: String(localized: "Select all", comment: "Checkbox: select every item in the list"), isOn: Binding(get: { chosen.count == files.count }, set: { if $0 { state.selection.formUnion(files.map(\.id)) } else { state.selection.subtract(files.map(\.id)) } }), enabled: task == nil,
                            summary: String(localized: "\(chosen.count) selected · \(formattedBytes(chosen.reduce(0) { $0 + $1.localBytes }))")) {
                        Button("Review \(chosen.count) for Trash…", role: .destructive) { trashRequest = TrashRequest(urls: chosen.map(\.url)) }
                            .buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(chosen.isEmpty || task != nil)
                    }
                }
                if report.limited || report.unreadable > 0 { Text(partialNote(report)).stewardFont(.caption).foregroundStyle(.orange) }
                if files.isEmpty { Text("No files matched these filters in the scanned area.").foregroundStyle(.secondary) }
                LazyVStack(spacing: 8) {
                    ForEach(files) { file in
                        HStack(spacing: 12) {
                            Toggle(String(localized: "Select \(file.url.lastPathComponent)"), isOn: Binding(get: { selection.contains(file.id) }, set: { if $0 { state.selection.insert(file.id) } else { state.selection.remove(file.id) } })).toggleStyle(.stewardCheckboxOnly)
                            Image(systemName: "doc.fill").foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.url.lastPathComponent).stewardFont(.body, weight: .medium)
                                Text(file.url.deletingLastPathComponent().path).stewardFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Text("Modified \(file.modified.formatted(date: .abbreviated, time: .omitted))").stewardFont(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) { Text(formattedBytes(file.localBytes)).monospacedDigit(); Text("\(formattedBytes(file.logicalBytes)) file size").stewardFont(.caption).foregroundStyle(.secondary) }
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        }.padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if let note { Text(note).stewardFont(.body).foregroundStyle(.mint) }
            if let error = state.error { Text(error).stewardFont(.body).foregroundStyle(.orange) }
        }.sheet(item: $trashRequest) { request in
            TrashReviewSheet(urls: request.urls) { results in
                note = String(localized: "\(results.filter { $0.error == nil }.count) moved to Trash. Restore in Finder with Put Back.")
                state.selection.removeAll(); scan()
            }
        }.onChange(of: location.url) { _, _ in state.reset() }
    }
    private func partialNote(_ report: LargeFileReport) -> String {
        let entries = String(localized: "\(report.examined) entries checked"), folders = String(localized: "\(report.unreadable) unreadable folders")
        return String(localized: "Partial results · \(entries) · \(folders). Choose a smaller folder for more detail.")
    }
    private func scan() { state.scan(location.url) }
    private func choose() { location.choose() }
}

struct AppRemovalView: View {
    @State private var apps = [InstalledApplication]()
    @State private var search = ""
    @State private var selection = Set<String>()
    @State private var trashRequest: TrashRequest?
    @State private var note: String?
    @State private var byLastUsed = true
    /// The apps you use stay folded away: the list opens on the ones you could remove.
    @State private var open: Set<AppUsageAge> = [.overYear, .sixMonths]
    private var matches: [InstalledApplication] {
        let found = apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.identifier.localizedCaseInsensitiveContains(search) }
        // Least recently used first; apps never recorded as opened come before everything else.
        return byLastUsed ? found.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) } : found
    }
    private func used(_ app: InstalledApplication) -> String {
        guard let date = app.lastUsed else { return String(localized: "No usage record") }
        if Date().timeIntervalSince(date) < 86400 { return String(localized: "Today") }
        return date.formatted(.relative(presentation: .named))
    }
    private var runningPaths: Set<String> { Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }) }
    private func protected(_ app: InstalledApplication) -> Bool { AppleCode.isProtectedApp(app.url, identifier: app.identifier) }
    var body: some View {
        let running = runningPaths
        let removable: (InstalledApplication) -> Bool = { !running.contains($0.url.path) && !protected($0) }
        let shown = matches.filter { removable($0) && (!search.isEmpty || open.contains(AppUsageAge(lastUsed: $0.lastUsed))) }.map(\.id)
        let groups = Dictionary(grouping: matches) { AppUsageAge(lastUsed: $0.lastUsed) }
        return VStack(alignment: .leading, spacing: 16) {
            ToolHeading(title: "Uninstaller", detail: "Move apps you no longer use to the Trash. Your documents and support data stay in place.")
            HStack(spacing: 12) {
                ForEach(AppUsageAge.allCases) { age in
                    CountCard(count: groups[age]?.count ?? 0, title: age.title, active: open.contains(age), help: String(localized: "Show apps last used: \(age.title)")) { open = [age] }
                }
            }
            HStack(spacing: 10) {
                TextField("Find an app", text: $search).stewardInput()
                Picker("Sort", selection: $byLastUsed) { Text("Least used").tag(true); Text("Name").tag(false) }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if let note { Text(note).foregroundStyle(.mint) }
            BulkBar(title: String(localized: "Select all shown"), isOn: Binding(get: { !shown.isEmpty && selection.isSuperset(of: shown) }, set: { if $0 { selection.formUnion(shown) } else { selection.subtract(shown) } }), enabled: !shown.isEmpty,
                    help: String(localized: "Apps in the open sections. Running apps, Apple apps and Artifloam stay protected."), summary: String(localized: "\(selection.count) selected")) {
                Button("Move \(selection.count) to Trash…", role: .destructive) { trashRequest = TrashRequest(urls: apps.filter { selection.contains($0.id) && removable($0) }.map(\.url)) }
                    .buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(selection.isEmpty)
            }
            if matches.isEmpty && !apps.isEmpty { Text("No apps match this search.").foregroundStyle(.secondary) }
            ForEach(AppUsageAge.allCases) { age in
                if let list = groups[age] { section(age, list, removable: removable, running: running) }
            }
            Text("Running apps, Apple apps and Artifloam are protected. Removing an app does not cancel subscriptions. Some related files may stay behind.").stewardFont(.caption).foregroundStyle(.secondary)
        }.onAppear { refresh() }
        .sheet(item: $trashRequest) { request in
            TrashReviewSheet(urls: request.urls, allowApplications: true) { results in
                note = String(localized: "\(results.filter { $0.error == nil }.count) app bundles moved to Trash. Restore in Finder with Put Back."); refresh()
            }
        }
    }
    /// One age group: a header that folds it and ticks all of it, then one compact row per app.
    private func section(_ age: AppUsageAge, _ list: [InstalledApplication], removable: @escaping (InstalledApplication) -> Bool, running: Set<String>) -> some View {
        let ids = list.filter(removable).map(\.id)
        return FoldSection(title: age.title, count: String(localized: "\(list.count) apps"), open: open.contains(age) || !search.isEmpty, canSelectAll: !ids.isEmpty,
                           selectAll: Binding(get: { !ids.isEmpty && selection.isSuperset(of: ids) }, set: { if $0 { selection.formUnion(ids) } else { selection.subtract(ids) } }),
                           toggle: { if open.contains(age) { open.remove(age) } else { open.insert(age) } }) {
            ForEach(list) { app in
                Divider().opacity(0.25)
                AppRow(app: app, used: used(app), locked: !removable(app), lockReason: running.contains(app.url.path) ? String(localized: "Running", comment: "Label on an app that is open right now") : String(localized: "Protected", comment: "Label on an app Artifloam will not remove"),
                       selected: Binding(get: { selection.contains(app.id) }, set: { if $0 { selection.insert(app.id) } else { selection.remove(app.id) } }))
            }
        }
    }
    private func refresh() {
        selection.removeAll()
        // Spotlight is asked about every app: not on the main thread.
        Task { apps = await Task.detached(priority: .userInitiated) { ApplicationInventory.scan() }.value }
    }
}

/// An overview number that opens its section.
struct CountCard: View {
    let count: Int
    let title: String
    let active: Bool
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(count)").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(active ? .mint : .primary)
                Text(title).stewardFont(.caption, weight: .semibold).foregroundStyle(.secondary).lineLimit(1)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(active ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).help(help)
    }
}

/// A list section that folds, with an optional checkbox for everything in it.
struct FoldSection<Content: View>: View {
    let title: String
    let count: String
    let open: Bool
    var canSelectAll = false
    var selectAll: Binding<Bool>? = nil
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let selectAll { Toggle(String(localized: "Select all \(title)"), isOn: selectAll).toggleStyle(.stewardCheckboxOnly).disabled(!canSelectAll) }
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        Text(title).stewardFont(.headline)
                        Text(count).stewardFont(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: open ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.padding(.horizontal, 14).padding(.vertical, 12)
            if open { LazyVStack(spacing: 0) { content() } }
        }.background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AppRow: View {
    let app: InstalledApplication
    let used: String
    let locked: Bool
    let lockReason: String
    @Binding var selected: Bool
    @State private var hovered = false
    var body: some View {
        HStack(spacing: 12) {
            Toggle(String(localized: "Select \(app.name)"), isOn: $selected).toggleStyle(.stewardCheckboxOnly).disabled(locked).opacity(locked ? 0.4 : 1)
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().scaledToFit().frame(width: 28, height: 28)
            Text(app.name).stewardFont(.body, weight: .medium).lineLimit(1).help(app.identifier + " · " + app.version)
            if locked { Text(lockReason).stewardFont(.caption).foregroundStyle(.secondary) }
            Spacer()
            if hovered { Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }.controlSize(.small) }
            Text(used).stewardFont(.callout).foregroundStyle(.secondary).monospacedDigit()
        }.padding(.horizontal, 14).padding(.vertical, 7)
        .background(.white.opacity(hovered ? 0.06 : 0))
        .contentShape(Rectangle()).onHover { hovered = $0 }
    }
}

@MainActor
final class StartupState: ObservableObject {
    @Published var loginItems: [String]?
    @Published var agents = [BackgroundItem]()
    @Published var disabled = Set<String>()
    @Published var error: String?
    /// Something has been read, so there is a result page to show.
    @Published private(set) var checked = false
    @Published private(set) var scanning = false
    private var scanRun: UUID?
    private nonisolated static func read() async -> ([String]?, [BackgroundItem], Set<String>, String?) {
        await Task.detached(priority: .utility) {
            var message: String?
            let logins: [String]?
            do { logins = try LoginItems.list() } catch { logins = nil; message = error.localizedDescription }
            return (logins, BackgroundInventory.scan(), LaunchAgentControl.disabledLabels(), message)
        }.value
    }
    /// The Check button: the stage's artwork stays up for a moment, however fast the answer is.
    func scan() {
        guard !scanning else { return }
        let id = UUID(); scanRun = id; scanning = true; error = nil
        Task {
            async let pause: Void? = try? Task.sleep(for: .seconds(1.6))
            let result = await Self.read()
            _ = await pause
            guard scanRun == id else { return }
            (loginItems, agents, disabled, error) = result
            checked = true; scanning = false; scanRun = nil
        }
    }
    func stop() { scanRun = nil; scanning = false }
    /// For a page about to open: waits for the first reading, so it arrives filled in.
    func load() async {
        guard loginItems == nil, error == nil else { return }
        (loginItems, agents, disabled, error) = await Self.read()
        checked = true
    }
    /// `message` is a failure that must stay on screen through the refresh.
    func refresh(keeping message: String? = nil) {
        error = message
        Task {
            (loginItems, agents, disabled, error) = await Self.read()
            checked = true
            if let message { error = message }
        }
    }
    func add(_ apps: [URL]) {
        Task {
            error = await Task.detached { () -> String? in
                var failed = [String]()
                for app in apps { do { try LoginItems.add(app) } catch { failed.append(error.localizedDescription) } }
                return failed.isEmpty ? nil : failed.joined(separator: "\n")
            }.value
            refresh(keeping: error)
        }
    }
    func remove(_ names: [String]) {
        Task {
            error = await Task.detached { () -> String? in
                var failed = [String]()
                for name in names { do { try LoginItems.remove(name) } catch { failed.append(error.localizedDescription) } }
                return failed.isEmpty ? nil : failed.joined(separator: "\n")
            }.value
            refresh(keeping: error)
        }
    }
    func set(_ item: BackgroundItem, enabled: Bool) {
        Task {
            do { try await Task.detached { try LaunchAgentControl.setEnabled(enabled, item: item) }.value } catch { self.error = error.localizedDescription }
            refresh()
        }
    }
}

struct BackgroundItemsView: View {
    private enum Kind: CaseIterable { case login, yours, managed }
    @ObservedObject var state: StartupState
    @Environment(\.stewardTheme) private var theme
    @Environment(\.stewardInModule) private var inModule
    @State private var search = ""
    @State private var chosen = Set<String>()
    private func filterCard(_ kind: Kind, _ value: String, _ title: String, _ note: String) -> some View {
        Button { open = [kind] } label: { ResultMetric(accent: theme.accent, value: value, title: title, note: note).contentShape(RoundedRectangle(cornerRadius: 14)) }.buttonStyle(.plain).help(String(localized: "Show \(title)"))
    }
    /// Agents that deserve a second look: broken, or waking up every few minutes.
    private func attention(_ items: [BackgroundItem]) -> some View {
        ResultPanel {
            VStack(alignment: .leading, spacing: 4) {
                Text("Worth a look").stewardFont(.headline)
                Text("Switching one off stops it from starting. You can switch it on again.").stewardFont(.caption).foregroundStyle(.white.opacity(0.68)).padding(.bottom, 4)
                ForEach(items) { item in
                    AgentRow(item: item) { Toggle("On", isOn: Binding(get: { !state.disabled.contains(item.label) }, set: { state.set(item, enabled: $0) })).toggleStyle(.switch).labelsHidden().tint(.mint).controlSize(.small) }
                    if item.programMissing { Label("Its program is gone, probably from an app you removed.", systemImage: "exclamationmark.triangle.fill").stewardFont(.caption).foregroundStyle(.orange).padding(.leading, 44).padding(.bottom, 4) }
                }
            }
        }
    }
    /// What you can change stays open. What only macOS manages folds away until you ask for it.
    @State private var open: Set<Kind> = [.login, .yours]
    private func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }
    private func matches(_ item: BackgroundItem) -> Bool { matches(item.label) || matches(item.program) || matches(item.maker.name) || matches(item.summary) }
    private func isOpen(_ kind: Kind) -> Bool { open.contains(kind) || !search.isEmpty }
    private func fold(_ kind: Kind) { if open.contains(kind) { open.remove(kind) } else { open.insert(kind) } }
    var body: some View {
        let logins = (state.loginItems ?? []).filter { matches($0) }
        let found = state.agents.filter(matches)
        let yours = found.filter { $0.scope == "Your account" }, managed = found.filter { $0.scope != "Your account" }
        let toRemove = logins.filter(chosen.contains)
        let allLogins = state.loginItems?.count ?? 0, allYours = state.agents.filter { $0.scope == "Your account" }, allManaged = state.agents.count - allYours.count
        let active = allYours.filter { !state.disabled.contains($0.label) }, flagged = allYours.filter { $0.programMissing || ($0.runsOften && !state.disabled.contains($0.label)) }
        let rhythms = Dictionary(grouping: active, by: \.rhythm).map { (name: $0.key, count: $0.value.count) }.sorted { ($0.count, $0.name) > ($1.count, $1.name) }
        let colors: [String: Color] = ["Always running": .pink, "On a schedule": .orange, "At login": .mint, "When needed": .blue]
        return VStack(alignment: .leading, spacing: 18) {
            if inModule { ToolHeading(title: "Login & background items", detail: "What starts with your Mac. Removing a login item keeps the app, and an agent you switch off can be switched on again.") }
            else {
                ResultHero(theme: theme, title: String(localized: "\(allLogins + active.count) things start with your Mac."), subtitle: heroSubtitle(logins: allLogins, agents: active.count)) {
                    Button("Check again") { state.scan() }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)).disabled(state.scanning)
                    Button("Open Login Items") { openSettings() }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true))
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12, alignment: .top)], spacing: 12) {
                filterCard(.login, "\(allLogins)", String(localized: "Open at login"), String(localized: "Apps that open each time you sign in."))
                filterCard(.yours, "\(allYours.count)", String(localized: "Your agents"), String(localized: "\(allYours.count - active.count) off. Switch any off, and back on."))
                filterCard(.yours, "\(active.filter { $0.rhythm == "Always running" }.count)", String(localized: "Always running"), String(localized: "Stay on even while you don't use them."))
                filterCard(.managed, "\(allManaged)", String(localized: "Managed by macOS"), String(localized: "Only System Settings can change these."))
            }
            if !flagged.isEmpty { attention(flagged) }
            if !rhythms.isEmpty { ShareBreakdown(title: String(localized: "When your agents run"), parts: rhythms.map { (rhythmTitle($0.name), UInt64($0.count), $0.count, colors[$0.name] ?? .gray) }, countsOnly: true) }
            HStack(spacing: 10) {
                TextField("Find an item", text: $search).stewardInput()
                Button { addApps() } label: { Label("Add app…", systemImage: "plus") }.buttonStyle(CleanupGlassButtonStyle(compact: true)).help("Choose an app to open each time you sign in")
                Button { state.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)).help("Check again")
                Button { openSettings() } label: { Image(systemName: "gearshape") }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)).help("Open Login Items settings")
            }
            if let error = state.error { Text(error).stewardFont(.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if !logins.isEmpty {
                BulkBar(title: String(localized: "Select all", comment: "Checkbox: select every item in the list"), isOn: Binding(get: { Set(logins).isSubset(of: chosen) }, set: { if $0 { chosen.formUnion(logins) } else { chosen.subtract(logins) } }), help: String(localized: "Every app listed under Open at login. The apps themselves stay installed."), summary: String(localized: "\(toRemove.count) selected")) {
                    Button("Remove \(toRemove.count) from login") { state.remove(toRemove); chosen.removeAll() }.buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(toRemove.isEmpty)
                }
            }
            if !logins.isEmpty {
                FoldSection(title: String(localized: "Open at login"), count: String(localized: "\(logins.count) apps"), open: isOpen(.login), canSelectAll: true,
                            selectAll: Binding(get: { Set(logins).isSubset(of: chosen) }, set: { if $0 { chosen.formUnion(logins) } else { chosen.subtract(logins) } }), toggle: { fold(.login) }) {
                    ForEach(logins, id: \.self) { name in
                        Divider().opacity(0.25)
                        LoginRow(name: name, selected: Binding(get: { chosen.contains(name) }, set: { if $0 { chosen.insert(name) } else { chosen.remove(name) } })) { state.remove([name]); chosen.remove(name) }
                    }
                }
            }
            if !yours.isEmpty {
                FoldSection(title: String(localized: "Your agents"), count: String(localized: "\(yours.count) · \(yours.filter { state.disabled.contains($0.label) }.count) off"), open: isOpen(.yours), toggle: { fold(.yours) }) {
                    ForEach(yours) { item in
                        Divider().opacity(0.25)
                        AgentRow(item: item) { Toggle("On", isOn: Binding(get: { !state.disabled.contains(item.label) }, set: { state.set(item, enabled: $0) })).toggleStyle(.switch).labelsHidden().tint(.mint).controlSize(.small) }
                    }
                }
            }
            if !managed.isEmpty {
                FoldSection(title: String(localized: "Managed by macOS"), count: String(localized: "\(managed.count) · change these in System Settings"), open: isOpen(.managed), toggle: { fold(.managed) }) {
                    ForEach(managed) { item in
                        Divider().opacity(0.25)
                        AgentRow(item: item) { Text(item.scopeTitle).stewardFont(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
    private func heroSubtitle(logins: Int, agents: Int) -> String {
        let apps = String(localized: "\(logins) apps open at login"), running = String(localized: "\(agents) agents run in the background")
        return String(localized: "\(apps) and \(running). Removing a login item keeps the app.")
    }
    private func rhythmTitle(_ name: String) -> String {
        switch name {
        case "Always running": return String(localized: "Always running")
        case "On a schedule": return String(localized: "On a schedule")
        case "At login": return String(localized: "At login")
        case "When needed": return String(localized: "When needed")
        default: return name
        }
    }
    private func addApps() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open at login"); panel.prompt = String(localized: "Add", comment: "Button in the app picker: add the chosen apps to login items"); panel.message = String(localized: "Choose the apps to open each time you sign in.")
        panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { response in
            guard response == .OK else { return }
            let apps = panel.urls
            Task { @MainActor in open.insert(.login); search = ""; state.add(apps) }
        }
    }
    private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"), NSWorkspace.shared.open(url) { return }
        state.error = String(localized: "Open System Settings → General → Login Items & Extensions.")
    }
}

private struct LoginRow: View {
    let name: String
    @Binding var selected: Bool
    let remove: () -> Void
    @State private var hovered = false
    /// Login items only give a name, so the icon comes from the app of that name, if it's where apps usually are.
    private var icon: NSImage? {
        ["/Applications/\(name).app", "/Applications/Setapp/\(name).app", NSHomeDirectory() + "/Applications/\(name).app"]
            .first { FileManager.default.fileExists(atPath: $0) }.map { NSWorkspace.shared.icon(forFile: $0) }
    }
    var body: some View {
        HStack(spacing: 12) {
            Toggle(String(localized: "Select \(name)"), isOn: $selected).toggleStyle(.stewardCheckboxOnly)
            if let icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 28, height: 28) }
            else { Image(systemName: "power").foregroundStyle(.mint).frame(width: 28, height: 28) }
            Text(name.displaySafe).stewardFont(.body, weight: .medium).lineLimit(1)
            Spacer()
            if hovered { Button("Remove", action: remove).controlSize(.small) }
        }.padding(.horizontal, 14).padding(.vertical, 7)
        .background(.white.opacity(hovered ? 0.06 : 0)).contentShape(Rectangle()).onHover { hovered = $0 }
    }
}

/// The maker first, then what the agent is. The full path is in the tooltip.
private struct AgentRow<Trailing: View>: View {
    let item: BackgroundItem
    @ViewBuilder let trailing: () -> Trailing
    @State private var hovered = false
    var body: some View {
        HStack(spacing: 12) {
            if let app = item.appPath { Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable().scaledToFit().frame(width: 28, height: 28) }
            else { Image(systemName: "gearshape.fill").foregroundStyle(.secondary).frame(width: 28, height: 28) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.maker.name.displaySafe).stewardFont(.body, weight: .medium).lineLimit(1).layoutPriority(1)
                    Text(item.maker.rest.displaySafe).stewardFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text(item.summary.displaySafe).stewardFont(.callout).foregroundStyle(.white.opacity(0.78)).lineLimit(1).truncationMode(.tail)
                if item.programMissing { Text("Its program is gone, probably left behind by a removed app").stewardFont(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            if hovered { Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }.controlSize(.small) }
            trailing()
        }.padding(.horizontal, 14).padding(.vertical, 7)
        .background(.white.opacity(hovered ? 0.06 : 0)).contentShape(Rectangle()).onHover { hovered = $0 }
        .help(item.label + "\n" + item.program)
    }
}

