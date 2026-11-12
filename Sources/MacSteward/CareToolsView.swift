import SwiftUI
import AppKit
import MacStewardCore

/// True when a tool is shown as a tab inside a module page, which already carries the heading.
private struct InModuleKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var stewardInModule: Bool { get { self[InModuleKey.self] } set { self[InModuleKey.self] = newValue } }
}
struct ToolHeading: View {
    let title: LocalizedStringKey, detail: LocalizedStringKey
    @Environment(\.stewardInModule) private var inModule
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !inModule { Text(title).stewardFont(.title, weight: .semibold) }
            Text(detail).stewardFont(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
final class TrashBinsState: ObservableObject {
    @Published var report: TrashBinsReport?
    @Published var busy = false
    @Published var error: String?
    @Published var note: String?
    /// The Check button: the stage's artwork stays up for a moment, however fast Finder answers.
    @Published private(set) var scanning = false
    private var scanRun: UUID?
    func scan() {
        guard !busy else { return }
        let id = UUID(); scanRun = id; scanning = true; busy = true; error = nil; note = nil
        Task {
            async let pause: Void? = try? Task.sleep(for: .seconds(1.6))
            let found = await Task.detached(priority: .utility) { TrashBins.inspect(askFinder: true) }.value
            _ = await pause
            busy = false
            guard scanRun == id else { return }
            report = found; scanning = false; scanRun = nil
        }
    }
    /// Finder may still answer, but the answer is dropped and the start screen comes back.
    func stop() { scanRun = nil; scanning = false }
    func inspect(askFinder: Bool = false) {
        guard !busy else { return }; busy = true; error = nil
        Task { report = await Task.detached(priority: .utility) { TrashBins.inspect(askFinder: askFinder) }.value; busy = false }
    }
    /// Empties the Trash on the stage. One operation: no per-item progress and no Stop once it starts.
    func empty(on model: StewardModel, then refresh: @escaping () -> Void) {
        guard !busy else { return }; error = nil
        let bytes = report?.bytes ?? report?.measuredBytes ?? 0, items = report?.items ?? 0
        Task {
            // The confirmation sheet closes first, so the stage doesn't start in the middle of its animation.
            try? await Task.sleep(for: .milliseconds(150))
            model.runStage(.emptyTrash, total: items, indeterminate: true, stoppable: false, work: { _, _ in
                do { try TrashBins.empty(); return StageOutcome(completed: items, bytes: bytes, failures: []) }
                catch { return StageOutcome(completed: 0, bytes: 0, failures: [error.localizedDescription]) }
            }, completed: { [weak self] outcome in
                if let failure = outcome.failures.first { self?.error = failure }
                else { self?.report = .emptied }
                self?.inspect(askFinder: true); refresh()
            })
        }
    }
}

struct TrashBinsView: View {
    @ObservedObject var state: TrashBinsState
    @EnvironmentObject private var model: StewardModel
    @State private var confirming = false
    private let accent = StewardTheme.trash.accent
    private var report: TrashBinsReport? { state.report }
    private var heading: String {
        guard let report, report.measuredBytes > 0 || report.bytes != nil else { return String(localized: "Your Trash holds files.") }
        let amount = formattedBytes(report.bytes ?? report.measuredBytes)
        return report.bytes == nil ? String(localized: "At least \(amount) in the Trash.") : String(localized: "\(amount) in the Trash.")
    }
    private var detail: String {
        let free = formattedBytes(model.disk.free + (report?.bytes ?? report?.measuredBytes ?? 0))
        let atLeast = report?.bytes == nil
        guard let items = report?.items else {
            return atLeast ? String(localized: "Some items. Empty it and you'd have at least \(free) free.") : String(localized: "Some items. Empty it and you'd have \(free) free.")
        }
        return atLeast ? String(localized: "\(items) items. Empty it and you'd have at least \(free) free.") : String(localized: "\(items) items. Empty it and you'd have \(free) free.")
    }
    private func age(_ date: Date) -> String { date.formatted(.relative(presentation: .named, unitsStyle: .wide)) }
    private func largestPanel(_ report: TrashBinsReport) -> some View {
        ResultPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Biggest items").stewardFont(.headline)
                    Spacer()
                    Button("Open Trash in Finder") { model.open("file://" + NSHomeDirectory() + "/.Trash") }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true))
                }
                ForEach(report.largest()) { item in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFileType: item.isFolder ? "public.folder" : (item.name as NSString).pathExtension)).resizable().frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).stewardFont(.body, weight: .medium).lineLimit(1).truncationMode(.middle)
                            Text(item.modified.map { String(localized: "\(kindTitle(item.kind)) · changed \($0.formatted(.relative(presentation: .named, unitsStyle: .wide)))") } ?? kindTitle(item.kind)).stewardFont(.caption).foregroundStyle(.white.opacity(0.68))
                        }
                        Spacer(minLength: 8)
                        Text(item.bytes.map(formattedBytes) ?? String(localized: "Size unknown")).stewardFont(.callout, weight: .medium).foregroundStyle(item.bytes == nil ? .white.opacity(0.6) : accent).monospacedDigit()
                    }.padding(.vertical, 3)
                }
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ResultHero(theme: .trash, title: heading, subtitle: detail) {
                Button("Empty Trash…", role: .destructive) { confirming = true }.buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(state.busy)
                Button("Check again") { state.scan() }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)).disabled(state.busy)
            }
            if let error = state.error { Text(error).stewardFont(.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let report, !report.contents.isEmpty {
                let unchanged = report.unchanged(sinceDays: 365), unchangedBytes = unchanged.reduce(UInt64(0)) { $0 + ($1.bytes ?? 0) }
                let share = model.disk.total > 0 ? Double(report.measuredBytes) / Double(model.disk.total) * 100 : 0
                let autoEmpty = UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "FXRemoveOldTrashItems") == true
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12, alignment: .top)], spacing: 12) {
                    ResultMetric(accent: accent, value: share < 0.1 ? String(localized: "<0.1%") : (share / 100).formatted(.percent.precision(.fractionLength(1))), title: String(localized: "of your disk"), note: String(localized: "Space these items are holding."))
                    ResultMetric(accent: accent, value: "\(unchanged.count)", title: String(localized: "untouched for a year"), note: unchanged.isEmpty ? String(localized: "Everything was changed in the last year.") : unchangedBytes > 0 ? String(localized: "\(formattedBytes(unchangedBytes)). Probably safe to let go.") : String(localized: "Probably safe to let go."))
                    ResultMetric(accent: accent, value: report.oldest.map(age) ?? "–", title: String(localized: "oldest item"), note: String(localized: "Last changed then, not when it was thrown away."))
                    ResultMetric(accent: accent, value: autoEmpty ? String(localized: "On", comment: "Setting state: automatic emptying of the Trash is on") : String(localized: "Off", comment: "Setting state: automatic emptying of the Trash is off"), title: String(localized: "automatic emptying"), note: autoEmpty ? String(localized: "Finder deletes items 30 days after they reach the Trash.") : String(localized: "Items stay until you empty it. Change this in Finder › Settings › Advanced."))
                }
                ShareBreakdown(title: String(localized: "What's taking the space"), parts: report.kinds.map { (kindTitle($0.name), $0.bytes, $0.count, kindColors[$0.name] ?? .gray) })
                largestPanel(report)
            }
            if let volumes = report?.volumes, !volumes.isEmpty { Label(String(localized: "Also on \(volumes.joined(separator: ", ").displaySafe). Emptying covers these drives too."), systemImage: "externaldrive").stewardFont(.callout).foregroundStyle(.white.opacity(0.75)) }
            if let unmeasured = report?.unmeasured, unmeasured > 0 {
                Text("\(unmeasured) folders are not included in this total, because macOS keeps folder sizes private. With Full Disk Access, Artifloam can measure them.").stewardFont(.caption).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
            }
            Text("Emptying is permanent. To keep something, open the Trash in Finder and use Put Back first. File names stay on this Mac.").stewardFont(.caption).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("Empty the Trash?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Empty Trash permanently", role: .destructive) { state.empty(on: model) { model.disk = .read() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Everything in the Trash is deleted permanently and cannot be put back.") }
    }
}

@MainActor
final class LeftoversState: ObservableObject {
    @Published var items: [LeftoverItem]?
    @Published var selection = Set<String>()
    @Published var busy = false
    private var run: UUID?
    func scan() {
        guard !busy else { return }; busy = true
        let id = UUID(); run = id
        Task {
            let found = await Task.detached(priority: .utility) { () -> [LeftoverItem] in
                let known = AppLeftovers.knownIdentifiers()
                return AppLeftovers.scan(installed: known.installed, referenced: known.referenced, activity: .capture())
            }.value
            guard run == id else { return }
            items = found; selection = Set(found.filter { !$0.vendorInstalled }.map(\.id)); busy = false
        }
    }
    /// the read can't be interrupted, so Stop returns at once and ignores its late result.
    func stop() { run = nil; busy = false }
}

struct LeftoversView: View {
    @ObservedObject var state: LeftoversState
    @EnvironmentObject private var model: StewardModel
    @Environment(\.stewardTheme) private var theme
    @Environment(\.stewardInModule) private var inModule
    @State private var trashRequest: TrashRequest?
    @State private var expanded = Set<String>()
    @State private var sharedOpen = false
    private static let palette: [Color] = [.pink, .mint, .orange, .blue, .yellow, .purple, .teal, .indigo]
    private var items: [LeftoverItem] { state.items ?? [] }
    private func bytes(_ list: [LeftoverItem]) -> UInt64 { list.reduce(0) { $0 + $1.bytes } }
    private func size(_ list: [LeftoverItem]) -> String { formattedBytes(bytes(list)) }
    private func age(_ date: Date) -> String { date.formatted(.relative(presentation: .named, unitsStyle: .wide)) }
    private func toggle(_ ids: [String], label: String) -> some View {
        Toggle(label, isOn: Binding(get: { !ids.isEmpty && state.selection.isSuperset(of: ids) }, set: { if $0 { state.selection.formUnion(ids) } else { state.selection.subtract(ids) } })).toggleStyle(.stewardCheckboxOnly)
    }
    private func appSummary(_ app: LeftoverApp) -> String {
        let count = String(localized: "\(app.items.count) items"), kinds = app.kinds.joined(separator: ", ")
        guard let newest = app.newest else { return String(localized: "\(count) · \(kinds)") }
        return String(localized: "\(count) · \(kinds) · changed \(age(newest))")
    }
    private func appRow(_ app: LeftoverApp) -> some View {
        let open = expanded.contains(app.id)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                toggle(app.items.map(\.id), label: String(localized: "Select \(app.name)"))
                Button { if open { expanded.remove(app.id) } else { expanded.insert(app.id) } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.right").flipsForRightToLeftLayoutDirection(true).font(.system(size: 11, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.white.opacity(0.6))
                        Image(systemName: "shippingbox.fill").font(.system(size: 19)).foregroundStyle(theme.accent).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).stewardFont(.body, weight: .semibold).lineLimit(1)
                            Text(appSummary(app)).stewardFont(.caption).foregroundStyle(.white.opacity(0.68)).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(size(app.items)).stewardFont(.callout, weight: .medium).foregroundStyle(theme.accent).monospacedDigit()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.padding(.horizontal, 14).padding(.vertical, 10)
            if open {
                ForEach(app.items) { item in
                    HStack(spacing: 12) {
                        toggle([item.id], label: String(localized: "Select \(item.bundleID)"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.bundleID.displaySafe).stewardFont(.callout, weight: .medium).lineLimit(1).truncationMode(.middle)
                            Text("\(item.kind) · changed \(age(item.modified))").stewardFont(.caption).foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer(minLength: 8)
                        Text(formattedBytes(item.bytes)).stewardFont(.caption).foregroundStyle(.white.opacity(0.75)).monospacedDigit()
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }.buttonStyle(.plain).stewardFont(.caption).foregroundStyle(theme.accent)
                    }.padding(.leading, 30).padding(.trailing, 14).padding(.vertical, 6).help(item.url.path)
                }.padding(.bottom, 4)
            }
        }.background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
    private func heroSubtitle(leftovers: Int, apps: Int) -> String {
        let leftoversText = String(localized: "\(leftovers) leftovers"), appsText = String(localized: "\(apps) apps")
        return String(localized: "\(leftoversText) from \(appsText). They're deleted permanently after you confirm.")
    }
    var body: some View {
        let apps = AppLeftovers.grouped(items), safe = apps.filter { !$0.shared }, shared = apps.filter(\.shared)
        let safeItems = safe.flatMap(\.items), sharedItems = shared.flatMap(\.items), chosen = items.filter { state.selection.contains($0.id) }
        let kinds = Dictionary(grouping: items, by: \.kind).sorted { bytes($0.value) > bytes($1.value) }
        return VStack(alignment: .leading, spacing: 18) {
            if !inModule {
                ResultHero(theme: theme, title: items.isEmpty ? String(localized: "No leftovers found.") : String(localized: "\(size(items)) left behind."), subtitle: items.isEmpty ? String(localized: "Apps you removed didn't leave anything Artifloam can identify.") : heroSubtitle(leftovers: items.count, apps: apps.count)) {
                    Button("Scan again") { state.scan() }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)).disabled(state.busy)
                }
            }
            if !items.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12, alignment: .top)], spacing: 12) {
                    ResultMetric(accent: theme.accent, value: size(safeItems), title: String(localized: "ready to remove"), note: String(localized: "\(safeItems.count) items whose maker has no other app here."))
                    ResultMetric(accent: theme.accent, value: size(sharedItems), title: String(localized: "may be in use"), note: String(localized: "\(sharedItems.count) items from makers you still have an app from."))
                    ResultMetric(accent: theme.accent, value: "\(apps.count)", title: String(localized: "Apps", comment: "Label under a count of removed apps that left files behind"), note: String(localized: "Removed, but something of them stayed."))
                    ResultMetric(accent: theme.accent, value: items.map(\.modified).min().map(age) ?? "–", title: String(localized: "oldest leftover"), note: String(localized: "Nothing listed changed in the last 30 days."))
                }
                ShareBreakdown(title: String(localized: "What they left"), parts: kinds.enumerated().map { index, kind in (kind.key, bytes(kind.value), kind.value.count, Self.palette[index % Self.palette.count]) })
                BulkBar(title: String(localized: "Select all ready"), isOn: Binding(get: { !safeItems.isEmpty && state.selection.isSuperset(of: safeItems.map(\.id)) }, set: { if $0 { state.selection.formUnion(safeItems.map(\.id)) } else { state.selection.subtract(items.map(\.id)) } }), enabled: !safeItems.isEmpty && !state.busy,
                        help: String(localized: "Everything except items that may be shared with an app you still have"), summary: String(localized: "\(chosen.count) selected · \(size(chosen))")) {
                    SmartSelectButton(enabled: !safeItems.isEmpty && !state.busy, help: String(localized: "Ticks only leftovers of apps you no longer have, and unticks anything that may be shared with an app you still have.")) {
                        state.selection = Set(safeItems.map(\.id))
                    }
                    Button("Delete \(chosen.count)…", role: .destructive) { trashRequest = TrashRequest(urls: chosen.map(\.url)) }
                        .buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(chosen.isEmpty || state.busy)
                }
                if !safe.isEmpty {
                    Text("Ready to remove").stewardFont(.headline)
                    LazyVStack(spacing: 6) { ForEach(safe) { appRow($0) } }
                }
                if !shared.isEmpty {
                    Button { sharedOpen.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("May be in use · \(shared.count) makers").stewardFont(.headline)
                            Spacer()
                            Image(systemName: sharedOpen ? "chevron.up" : "chevron.down").foregroundStyle(.white.opacity(0.6))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if sharedOpen {
                        Text("You still have another app from these makers, and it might use these files. Choose them only if you're sure.").stewardFont(.caption).foregroundStyle(.white.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
                        LazyVStack(spacing: 6) { ForEach(shared) { appRow($0) } }
                    }
                }
            }
        }
        .sheet(item: $trashRequest) { request in
            TrashReviewSheet(urls: request.urls, allowLeftovers: true) { _ in state.scan(); model.disk = .read() }
        }
    }
}

@MainActor
final class BrowserDataState: ObservableObject {
    @Published var reports: [BrowserReport]?
    @Published var selection = Set<String>()
    @Published var busy = false
    @Published var note: String?
    var items: [BrowserItem] { reports?.flatMap(\.items) ?? [] }
    private var run: UUID?
    func scan() {
        guard !busy else { return }; busy = true
        let id = UUID(); run = id
        Task {
            let found = await Task.detached(priority: .utility) { BrowserData.scan() }.value
            guard run == id else { return }
            reports = found; selection = Set(found.flatMap(\.items).filter(\.recommended).map(\.id)); busy = false
        }
    }
    /// the read can't be interrupted, so Stop returns at once and ignores its late result.
    func stop() { run = nil; busy = false }
    /// Cleans the chosen browser data on the stage. One operation, so the totals appear when it finishes.
    /// `only`: the items the confirmation actually named. Ticks in other browsers' views stay untouched.
    func clean(only ids: Set<String>? = nil, on model: StewardModel, then refresh: @escaping () -> Void) {
        guard !busy else { return }
        let chosen = ids ?? selection, picked = items.filter { chosen.contains($0.id) }
        model.runStage(.browsers, total: chosen.count, indeterminate: true, stoppable: false, work: { _, _ in
            let result = BrowserData.clean(chosen, ignoredPaths: StewardPreferences.ignoredPaths)
            let removed = Set(result.removed)
            return StageOutcome(completed: result.removed.count, bytes: picked.filter { removed.contains($0.id) }.reduce(0) { $0 + $1.bytes }, failures: result.skipped)
        }, completed: { [weak self] outcome in
            let kept = outcome.failures.prefix(4).joined(separator: "; ") + (outcome.failures.count > 4 ? "…" : "")
            self?.note = outcome.failures.isEmpty ? String(localized: "\(outcome.completed) items removed.") : String(localized: "\(outcome.completed) items removed. Kept: \(kept)")
            // Drop what is gone instead of measuring every browser again.
            self?.reports = self?.reports?.map { r in BrowserReport(name: r.name, bundleID: r.bundleID, items: r.items.filter { FileManager.default.fileExists(atPath: $0.id) }, readable: r.readable) }
            self?.selection.formIntersection(Set((self?.reports ?? []).flatMap(\.items).map(\.id)))
            refresh()
        })
    }
}

struct BrowserDataView: View {
    @ObservedObject var state: BrowserDataState
    /// Set when opened from a browser card: only that browser is listed.
    var only: String? = nil
    private var reports: [BrowserReport] { (state.reports ?? []).filter { only == nil || $0.name == only } }
    @EnvironmentObject private var model: StewardModel
    @State private var bySite = false
    @State private var confirming = false
    private var chosen: [BrowserItem] { reports.flatMap(\.items).filter { state.selection.contains($0.id) } }
    private func toggle(_ item: BrowserItem) -> some View {
        Toggle(String(localized: "Select \((item.site ?? item.kindTitle))"), isOn: Binding(get: { state.selection.contains(item.id) }, set: { if $0 { state.selection.insert(item.id) } else { state.selection.remove(item.id) } })).toggleStyle(.stewardCheckboxOnly)
    }
    private func row(_ item: BrowserItem, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            toggle(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).stewardFont(.body, weight: .medium)
                Text(detail).stewardFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(formattedBytes(item.bytes)).stewardFont(.callout, weight: .medium).foregroundStyle(.mint)
        }.padding(.horizontal, 14).padding(.vertical, 8).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .help(item.url.path)
        .contextMenu { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ToolHeading(title: "Browser data", detail: "Caches rebuild as you browse and never sign you out. Website data is stored by each site and can hold a sign-in, so it is listed separately and never pre-ticked. Cookies, history, passwords, bookmarks and extensions are never touched.")
            HStack {
                Picker("Group", selection: $bySite) { Text("By browser").tag(false); Text("By website").tag(true) }.pickerStyle(.segmented).frame(width: 240).labelsHidden()
                Spacer()
                Button(state.reports == nil ? "Scan browsers" : "Scan again") { state.scan() }.disabled(state.busy)
            }
            if !reports.isEmpty {
                let caches = reports.flatMap(\.items).filter(\.recommended).map(\.id)
                BulkBar(title: String(localized: "Select all caches"), isOn: Binding(get: { !caches.isEmpty && state.selection.isSuperset(of: caches) }, set: { if $0 { state.selection.formUnion(caches) } else { state.selection.subtract(reports.flatMap(\.items).map(\.id)) } }), enabled: !caches.isEmpty && !state.busy,
                        help: String(localized: "Caches that rebuild as you browse. Website data can hold a sign-in, so it is chosen one by one."), summary: String(localized: "\(chosen.count) selected · \(formattedBytes(chosen.reduce(0) { $0 + $1.bytes }))")) {
                    SmartSelectButton(enabled: !caches.isEmpty && !state.busy, help: String(localized: "Ticks only caches that rebuild as you browse. Website data that can hold a sign-in stays unticked.")) {
                        state.selection = Set(caches)
                    }
                    Button("Clean \(chosen.count)…", role: .destructive) { confirming = true }
                        .buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(chosen.isEmpty || state.busy)
                }
            }
            if state.busy { StewardProgressBar(title: String(localized: "Measuring browser folders…")).frame(maxWidth: 380) }
            if let note = state.note { Text(note).stewardFont(.body).foregroundStyle(.mint).fixedSize(horizontal: false, vertical: true) }
            if bySite { sites } else { browsers }
        }
        .onAppear { if state.reports == nil { state.scan() } }
        .confirmationDialog("Clean browser data?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove \(chosen.count) items permanently", role: .destructive) { state.clean(only: Set(chosen.map(\.id)), on: model) { model.disk = .read() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Open browsers are skipped; quit a browser first to clean it. Caches are rebuilt automatically.") }
    }
    private var browsers: some View {
        ForEach(reports) { report in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: report.bundleID) { Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 26, height: 26) }
                    Text(report.name).stewardFont(.title3, weight: .semibold)
                    Text(formattedBytes(report.items.reduce(0) { $0 + $1.bytes })).stewardFont(.body).foregroundStyle(.secondary)
                    Spacer()
                    if !report.readable { Text("Needs Full Disk Access").stewardFont(.caption).foregroundStyle(.orange) }
                    else if BrowserData.isRunning(report.bundleID) { Text("Quit \(report.name) to clean").stewardFont(.caption).foregroundStyle(.orange) }
                }.padding(.top, 8)
                ForEach(Array(Dictionary(grouping: report.items, by: \.profile).sorted { $0.key < $1.key }), id: \.key) { profile, items in
                    Text(items.first?.profileTitle ?? profile).stewardFont(.caption, weight: .semibold).foregroundStyle(.secondary).padding(.top, 4)
                    let caches = items.filter { !$0.mayHoldSignIn }, siteData = items.filter(\.mayHoldSignIn)
                    if !caches.isEmpty { Label("Caches · you stay signed in", systemImage: "checkmark.shield").stewardFont(.caption).foregroundStyle(.mint) }
                    ForEach(caches) { row($0, title: $0.kindTitle, detail: $0.recommended ? String(localized: "Rebuilds automatically") : String(localized: "Downloaded again when needed")) }
                    if !siteData.isEmpty { Label("Website data · may sign you out of that site", systemImage: "person.crop.circle.badge.exclamationmark").stewardFont(.caption).foregroundStyle(.orange).padding(.top, 2) }
                    ForEach(siteData) { row($0, title: $0.site ?? $0.kindTitle, detail: $0.kindTitle) }
                }
            }
        }
    }
    /// Grouping key for caches that belong to no site; shown through a localized title.
    private static let offlineSites = "Offline caches (all sites)"
    private var sites: some View {
        let siteItems = reports.flatMap(\.items).filter { $0.site != nil || $0.kind == "Offline site cache" }
        // Typed steps: as one expression, older Swift compilers give up type-checking it.
        let groups: [(site: String, items: [BrowserItem], bytes: UInt64)] = Dictionary(grouping: siteItems, by: { $0.site ?? Self.offlineSites })
            .map { (site: $0.key, items: $0.value, bytes: $0.value.reduce(UInt64(0)) { $0 + $1.bytes }) }
            .sorted { $0.bytes > $1.bytes }
        return ForEach(groups, id: \.site) { group in
            let title: String = group.site == Self.offlineSites ? String(localized: "Offline caches (all sites)") : group.site
            VStack(alignment: .leading, spacing: 4) {
                Text("\(title) · \(formattedBytes(group.bytes))").stewardFont(.headline).padding(.top, 6)
                ForEach(group.items) { row($0, title: "\($0.browser) · \($0.profileTitle)", detail: $0.kindTitle) }
            }
        }
    }
}

/// The Browsers module after a scan: one card per installed browser, one action for every cache.
struct BrowsersModuleView: View {
    @ObservedObject var state: BrowserDataState
    @EnvironmentObject private var model: StewardModel
    @State private var detail: String?
    @State private var confirming = false
    /// Browsers ticked on their cards; nil means every browser that can be cleaned right now.
    @State private var picked: Set<String>?
    /// Readable, closed, and holding caches that keep you signed in.
    private func cleanable(_ report: BrowserReport) -> Bool {
        report.readable && !BrowserData.isRunning(report.bundleID) && report.items.contains { $0.recommended }
    }
    private var chosen: Set<String> { picked ?? Set((state.reports ?? []).filter(cleanable).map(\.bundleID)) }
    /// Caches of the ticked browsers only: the top button cleans exactly what the checkboxes show.
    private var caches: [BrowserItem] {
        (state.reports ?? []).filter { chosen.contains($0.bundleID) && cleanable($0) }.flatMap(\.items).filter(\.recommended)
    }
    var body: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    BackSquareButton { self.detail = nil }
                    Text("Browsers").stewardFont(.body).foregroundStyle(.secondary)
                    Image(systemName: "chevron.compact.right").flipsForRightToLeftLayoutDirection(true).foregroundStyle(.secondary)
                    Text(detail).stewardFont(.body, weight: .semibold)
                }
                BrowserDataView(state: state, only: detail).environment(\.stewardInModule, true)
            }
        } else { summary }
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Browsers").font(.system(size: 34, weight: .light))
                    Text("\(formattedBytes(caches.reduce(0) { $0 + $1.bytes })) of caches you can clean and stay signed in.").stewardFont(.body).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan again") { state.scan(); picked = nil }.buttonStyle(CleanupGlassButtonStyle(secondary: true)).disabled(state.busy)
                let count = Set(caches.map(\.browser)).count
                Button { confirming = true } label: { Label(caches.isEmpty ? String(localized: "Tick a browser to clean") : String(localized: "Clean \(count) browsers · \(formattedBytes(caches.reduce(0) { $0 + $1.bytes }))"), systemImage: "sparkles") }
                    .buttonStyle(CleanupGlassButtonStyle()).disabled(caches.isEmpty || state.busy)
            }
            if state.busy { StewardProgressBar(title: String(localized: "Measuring browser folders…")).frame(maxWidth: 380) }
            if let note = state.note { Text(note).stewardFont(.body).foregroundStyle(.mint).fixedSize(horizontal: false, vertical: true) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 14)], spacing: 14) {
                // A readable browser with nothing stored is only an empty leftover folder; leave it out.
                ForEach((state.reports ?? []).filter { !$0.readable || !$0.items.isEmpty }) { report in card(report) }
            }
        }
        .confirmationDialog("Clean the caches of \(Set(caches.map(\.browser)).sorted().joined(separator: ", "))?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Clean \(caches.count) caches") { state.selection = Set(caches.map(\.id)); state.clean(on: model) { model.disk = .read() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("You stay signed in everywhere. Open browsers are skipped; quit one first to clean it.") }
    }
    private func card(_ report: BrowserReport) -> some View {
        let cacheBytes = report.items.filter { !$0.mayHoldSignIn }.reduce(0) { $0 + $1.bytes }
        let siteBytes = report.items.filter(\.mayHoldSignIn).reduce(0) { $0 + $1.bytes }
        let profiles = Set(report.items.map(\.profile)).subtracting(["All profiles"]).count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                // Tick it right here; Review is only for picking individual items.
                if cleanable(report) {
                    Toggle("Clean \(report.name)", isOn: Binding(get: { chosen.contains(report.bundleID) }, set: { on in
                        var next = chosen; if on { next.insert(report.bundleID) } else { next.remove(report.bundleID) }; picked = next
                    })).toggleStyle(.stewardCheckboxOnly).help("Clean \(report.name)'s caches. You stay signed in.")
                }
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: report.bundleID) { Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 44, height: 44) }
                else { Image(systemName: "globe").font(.system(size: 30)).frame(width: 44, height: 44) }
                Spacer()
                if !report.readable { badge("Needs Full Disk Access", .orange) }
                else if BrowserData.isRunning(report.bundleID) { badge("Open · quit to clean", .orange) }
            }
            Text(report.name).stewardFont(.headline)
            Text(report.readable ? formattedBytes(cacheBytes + siteBytes) : String(localized: "Not readable")).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            if report.readable {
                Label("\(formattedBytes(cacheBytes)) caches · stay signed in", systemImage: "checkmark.shield").stewardFont(.caption).foregroundStyle(.mint)
                Label("\(formattedBytes(siteBytes)) website data · may sign out", systemImage: "person.crop.circle").stewardFont(.caption).foregroundStyle(.secondary)
                if profiles > 0 { Text("\(profiles) profiles").stewardFont(.caption).foregroundStyle(.secondary) }
            } else { Text("Allow Full Disk Access in System Settings to see what this browser stores.").stewardFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if report.readable { Button("Review") { detail = report.name }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)) }
                else { Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)) }
            }
        }.padding(18).frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 0.7) }
    }
    private func badge(_ text: LocalizedStringKey, _ color: Color) -> some View {
        Text(text).stewardFont(.caption2, weight: .semibold).foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.14), in: Capsule())
    }
}
