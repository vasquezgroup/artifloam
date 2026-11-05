import SwiftUI
import AppKit
import MacStewardCore

@MainActor
final class StorageMapModel: ObservableObject {
    @Published private(set) var snapshot: StorageMapSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var checkedCount = 0
    @Published private(set) var currentPath = ""
    @Published private(set) var refreshingChanges = false
    @Published private(set) var task: Task<StorageMapSnapshot, Error>?
    @Published private(set) var root = FileManager.default.homeDirectoryForCurrentUser
    /// Browser-style history of mapped folders.
    @Published private(set) var backStack = [URL]()
    @Published private(set) var forwardStack = [URL]()
    /// Maps measured in this session, by folder. Navigation reuses them instead of scanning.
    private var saved = [String: StorageMapSnapshot]()
    func goBack() { guard task == nil, let previous = backStack.popLast() else { return }; forwardStack.append(root); navigate(previous, record: false) }
    func goForward() { guard task == nil, let next = forwardStack.popLast() else { return }; backStack.append(root); navigate(next, record: false) }
    /// Moves to a folder: a saved map, one built from an enclosing map's measurements (reading only what is missing), or a new map.
    func navigate(_ url: URL, record: Bool = true) {
        guard task == nil else { return }
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        guard target.path != root.path else { return }
        if record && snapshot != nil { backStack.append(root); forwardStack.removeAll() }
        if let cached = saved[target.path] {
            root = target; snapshot = cached; hasChanges = false; watch(root); return
        }
        let enclosing = saved.values.filter { $0.canOpenSubfolders && target.path.hasPrefix($0.root.path == "/" ? "/" : $0.root.path + "/") }
            .max { $0.root.path.count < $1.root.path.count }
        map(target, from: enclosing)
    }
    @Published var error: String?
    @Published private(set) var hasChanges = false
    @Published private(set) var watching = false
    private var watcher: FolderChangeMonitor?
    private var watchID = UUID()
    private var dirty = Set<URL>()
    private var requiresFullScan = false
    private var refreshDebounce: Task<Void, Never>?
    private var active = false
    private var autoPaused = false
    func setActive(_ value: Bool) { active = value; if value { scheduleRefresh() } else { refreshDebounce?.cancel() } }
    private func watch(_ location: URL) {
        let token = UUID(); watchID = token
        watcher = FolderChangeMonitor(root: location) { [weak self] paths, reset in
            Task { @MainActor in
                guard let self, self.watchID == token else { return }
                self.dirty.formUnion(paths); self.requiresFullScan = self.requiresFullScan || reset
                if reset { self.watchID = UUID(); self.watcher = nil; self.watching = false }
                self.hasChanges = true; self.scheduleRefresh()
            }
        }
        watching = watcher?.available == true
    }
    private func scheduleRefresh() {
        refreshDebounce?.cancel()
        // Only quick refreshes of changed folders run by themselves; a full re-map waits for Refresh.
        guard active, !autoPaused, hasChanges, !busy, task == nil, snapshot?.canRefreshIncrementally == true, watching, !requiresFullScan else { return }
        refreshDebounce = Task {
            do { try await Task.sleep(for: .milliseconds(850)) } catch { return }
            guard !Task.isCancelled, active, !busy else { return }
            map()
        }
    }
    private var runID: UUID?
    private var scopedURL: URL?
    deinit { scopedURL?.stopAccessingSecurityScopedResource() }
    /// The first map measures as far as it can: one that stops early can't refresh in place, so the bubbles wouldn't settle.
    /// 1M entries matches StorageMapper's node cap; a larger tree stays partial until that cap and its memory use are revisited.
    private let entryBudget = 1_000_000, timeBudget: TimeInterval = 300
    var canStart: Bool { task == nil }
    /// A first map, Map again or Deeper Scan: the artwork stays up until it finishes. Only quick refreshes of changed folders keep the map visible.
    var mappingFully: Bool { busy && !refreshingChanges }
    func map(_ url: URL? = nil, full: Bool = false, from enclosing: StorageMapSnapshot? = nil) {
        guard task == nil else { return }
        active = true; autoPaused = false
        let newRoot = url?.standardizedFileURL.resolvingSymlinksInPath() ?? root
        let rootChanged = newRoot.path != root.path
        // A folder that's already measured opens in a moment: the current map stays up instead of flashing the scan screen.
        if rootChanged { if enclosing?.hasMeasured(newRoot) != true { snapshot = nil }; dirty.removeAll(); requiresFullScan = false }
        root = newRoot
        if watcher == nil || rootChanged || !watching { watch(root) }
        let previous = enclosing ?? snapshot
        let changed = Array(dirty), forceFull = enclosing == nil && (full || requiresFullScan || !watching)
        dirty.removeAll(); requiresFullScan = false; hasChanges = false
        error = nil; checkedCount = 0; refreshingChanges = enclosing != nil || (previous != nil && !forceFull && previous?.canRefreshIncrementally == true); busy = true
        let id = UUID(); runID = id
        let location = root, receiver = self
        let maximumEntries = entryBudget, maximumDuration = timeBudget
        let operation = Task.detached(priority: .utility) {
            let progress: @Sendable (StorageMapSnapshot) -> Void = { partial in
                Task { @MainActor in
                    guard receiver.runID == id else { return }
                    receiver.checkedCount = partial.examinedCount; receiver.currentPath = partial.currentPath
                    if previous == nil { receiver.snapshot = partial }
                }
            }
            if let previous {
                return try StorageMapper.refresh(previous, root: location, changedPaths: changed, forceFull: forceFull,
                    maximumEntries: maximumEntries, maximumDuration: maximumDuration, progress: progress)
            }
            return try StorageMapper.scan(root: location, maximumEntries: maximumEntries, maximumDuration: maximumDuration, progress: progress)
        }
        task = operation
        Task {
            defer { task = nil; scheduleRefresh() }
            do {
                let result = try await operation.value
                guard runID == id else { return }
                snapshot = result; busy = false; runID = nil
                if result.finished { saved[result.root.path] = result }
            } catch {
                guard runID == id else { return }
                dirty.formUnion(changed); requiresFullScan = true; hasChanges = true; active = false; autoPaused = true
                self.error = error.localizedDescription; busy = false; runID = nil
                if snapshot?.root.path != root.path { snapshot = nil }
            }
        }
    }
    func refreshChanged(_ paths: [URL]) { dirty.formUnion(paths); hasChanges = true; if canStart { map() } }
    func cancel() { if snapshot?.root.path != root.path { snapshot = nil }; runID = nil; task?.cancel(); busy = false; requiresFullScan = true; hasChanges = true; refreshDebounce?.cancel(); active = false; autoPaused = true }
    func chooseFolder() {
        guard canStart else { return }
        let panel = NSOpenPanel()
        panel.title = "Map a folder or drive"; panel.prompt = "Map Folder"
        panel.message = "Read file sizes and folder names. This never removes files."
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = root
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.scopedURL?.stopAccessingSecurityScopedResource()
                self.scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
                self.map(url)
            }
        }
        let host = NSApp.windows.first(where: { $0.identifier?.rawValue == "ArtifloamMainWindow" }) ?? NSApp.mainWindow ?? NSApp.keyWindow
        DispatchQueue.main.async {
            if let host { panel.beginSheetModal(for: host, completionHandler: completion) }
            else { panel.begin(completionHandler: completion) }
        }
    }
}

struct StorageMapView: View {
    @ObservedObject var map: StorageMapModel
    var stage = false
    @EnvironmentObject private var model: StewardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.stewardTextScale) private var textScale
    @State private var largestFiles = false
    @State private var cloudSizing = false
    @State private var selection = Set<String>()
    @State private var trashRequest: TrashRequest?
    @State private var trashNote: String?
    private var rows: [StorageMapEntry] {
        let values = largestFiles ? (cloudSizing ? map.snapshot?.largestCloudFiles : map.snapshot?.largestFiles) : map.snapshot?.entries
        return (values ?? []).filter { !cloudSizing || $0.cloudFileCount > 0 }.sorted { cloudSizing ? $0.cloudLogicalBytes > $1.cloudLogicalBytes : $0.bytes > $1.bytes }
    }
    private func eligible(_ url: URL) -> UInt64 {
        model.report?.findings.filter { $0.safety == .automatic && ($0.path == url.path || $0.path.hasPrefix(url.path + "/")) }.reduce(0) { $0 + $1.bytes } ?? 0
    }
    private func protectedCount(_ url: URL) -> Int {
        model.report?.findings.filter { $0.safety != .automatic && ($0.path == url.path || $0.path.hasPrefix(url.path + "/") || url.path.hasPrefix($0.path + "/")) }.count ?? 0
    }
    private var locationMenu: some View {
        Menu {
            Button("Home") { map.navigate(FileManager.default.homeDirectoryForCurrentUser) }
            Button("Startup Disk") { map.navigate(URL(fileURLWithPath: "/")) }
            Button("Applications") { map.navigate(URL(fileURLWithPath: "/Applications")) }
            Button("Choose Folder or Drive…") { map.chooseFolder() }
        } label: { Label("Location: " + (map.root == FileManager.default.homeDirectoryForCurrentUser ? "Home" : map.root.path == "/" ? "Startup Disk" : map.root.lastPathComponent), systemImage: "folder") }
            .disabled(!map.canStart)
    }
    private func open(_ entry: StorageMapEntry) { if entry.isDirectory { map.navigate(entry.url) } else { model.reveal(entry.url.path) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !stage {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Space Map").stewardFont(.title, weight: .semibold)
                    pathBar
                }
                Spacer()
                Menu {
                    Button("Home") { map.navigate(FileManager.default.homeDirectoryForCurrentUser) }
                    Button("Startup Disk") { map.navigate(URL(fileURLWithPath: "/")) }
                    Button("Applications") { map.navigate(URL(fileURLWithPath: "/Applications")) }
                    Button("Choose Folder or Drive…") { map.chooseFolder() }
                } label: { Label("Location", systemImage: "folder") }.disabled(!map.canStart)
                Button { map.chooseFolder() } label: { Image(systemName: "folder.badge.plus") }.help("Map a folder or drive").disabled(!map.canStart)
                if map.busy { Button("Stop") { map.cancel() } }
                else { Button(map.snapshot == nil ? "Map Storage" : "Refresh") { map.map() }.disabled(!map.canStart) }
            }
            }
            if !stage, let snapshot = map.snapshot {
                mapContent(snapshot)
            } else { mapIntro }
            if let trashNote { Text(trashNote).stewardFont(.caption).foregroundStyle(.secondary) }
            if let error = map.error { Text(error).stewardFont(.caption).foregroundStyle(.orange) }
        }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
        .sheet(item: $trashRequest) { request in
            TrashReviewSheet(urls: request.urls) { results in
                let moved = results.filter { $0.error == nil }.count
                trashNote = "\(moved) moved to Trash · \(results.count - moved) skipped. Restore items in Finder with Put Back."
                selection.removeAll(); map.refreshChanged(results.filter { $0.error == nil }.map { URL(fileURLWithPath: $0.path) })
            }
        }
        .onChange(of: map.root) { _, _ in selection.removeAll(); trashNote = nil }
        .onChange(of: largestFiles) { _, _ in selection.removeAll() }
        .onChange(of: cloudSizing) { _, _ in selection.removeAll() }
        .onChange(of: map.snapshot?.entries.map(\.id)) { _, _ in selection.formIntersection(Set(rows.map(\.id))) }
        .onAppear { map.setActive(scenePhase == .active) }
        .onDisappear { map.setActive(false) }
        .onChange(of: scenePhase) { _, phase in map.setActive(phase == .active) }
    }
    @ViewBuilder private var mapIntro: some View {
        if map.busy { mappingStage } else { mapStart }
    }
    /// Same layout as every other start screen: artwork, large light title, one line, glossy points.
    private var mapStart: some View {
        GeometryReader { geometry in
            let hero = min(345, geometry.size.width * 0.42, geometry.size.height * 0.85)
            HStack(alignment: .center, spacing: 30) {
                ScanMovieArtwork(animated: false, asset: "space-map-sculpture").hueRotation(.degrees(155)).frame(width: hero, height: hero)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Space Map").font(.system(size: 44 * textScale, weight: .light)).tracking(-0.8)
                    Text("See where your space goes.").font(.system(size: 17 * textScale)).foregroundStyle(.white.opacity(0.72))
                    VStack(alignment: .leading, spacing: 18) {
                        GlossyPoint(icon: "circle.dotted", text: "Folders and files as bubbles", accent: StewardTheme.space.accent)
                        GlossyPoint(icon: "doc.text.magnifyingglass", text: "Largest files first", accent: StewardTheme.space.accent)
                        GlossyPoint(icon: "lock", text: "Sizes only, nothing removed", accent: StewardTheme.space.accent)
                    }.padding(.top, 18)
                    HStack(spacing: 10) {
                        locationMenu
                        Button("Choose Folder…") { map.chooseFolder() }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)).disabled(!map.canStart)
                    }.padding(.top, 14)
                }.frame(width: min(380, geometry.size.width - hero - 62), alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var mappingStage: some View {
        GeometryReader { geometry in
            let hero = min(320, max(160, geometry.size.height * (textScale > 1.3 ? 0.48 : 0.64)))
            ScrollView {
                VStack(spacing: 14) {
                    ScanMovieArtwork(animated: map.busy, asset: "space-map-sculpture").hueRotation(.degrees(155)).frame(width: hero, height: hero)
                    Text(map.busy ? "Mapping your space…" : "See where your space goes.").stewardFont(.title)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Text(map.busy ? "Reading sizes and folder names. Your files stay unchanged." : "Explore large folders, find the biggest files and see which caches qualify for cleanup.")
                        .stewardFont(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 480)
                    if map.busy {
                        Text(formattedBytes(map.snapshot?.bytes ?? 0) + " measured so far").stewardFont(.caption).foregroundStyle(.white.opacity(0.65))
                        if map.snapshot != nil {
                            Text(map.currentPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .stewardFont(.caption, design: .monospaced).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.white.opacity(0.45)).frame(maxWidth: 560)
                        }
                    }
                    HStack {
                        locationMenu
                        Button("Choose Folder…") { map.chooseFolder() }.disabled(!map.canStart)
                    }
                }.padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }.scrollIndicators(.hidden)
        }
    }
    private func mapRow(_ entry: StorageMapEntry) -> some View {
        HStack(spacing: 5) {
            Toggle("Select " + entry.url.lastPathComponent, isOn: Binding(get: { selection.contains(entry.id) }, set: { if $0 { selection.insert(entry.id) } else { selection.remove(entry.id) } }))
                .toggleStyle(.stewardCheckboxOnly).help("Select for review")
            Button { open(entry) } label: { mapRowLabel(entry) }.buttonStyle(.plain).disabled(!map.canStart).help(rowHelp(entry))
        }.contextMenu {
            Button("Reveal in Finder") { model.reveal(entry.url.path) }
            Button("Review Move to Trash…", role: .destructive) { trashRequest = TrashRequest(urls: [entry.url]) }.disabled(map.busy)
        }
    }
    private func rowHelp(_ entry: StorageMapEntry) -> String {
        let local = "Stored on this Mac: " + formattedBytes(entry.bytes)
        let logical = "File size: " + formattedBytes(entry.logicalBytes)
        let cloud = "Cloud-backed files: " + formattedBytes(entry.cloudLogicalBytes)
        return entry.url.path + "\n" + local + " · " + logical + " · " + cloud
    }
    private func mapRowLabel(_ entry: StorageMapEntry) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(StewardTheme.space.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.url.lastPathComponent).stewardFont(.body, weight: .medium).lineLimit(2)
                if entry.cloudFileCount > 0 { Text("Cloud-backed: " + formattedBytes(entry.cloudLogicalBytes)).stewardFont(.caption).foregroundStyle(StewardTheme.space.accent) }
                if entry.onlineOnlyCount > 0 { Text("\(entry.onlineOnlyCount) online-only").stewardFont(.caption).foregroundStyle(.secondary) }
                if entry.unknownCloudCount > 0 { Text("Cloud availability partly unknown").stewardFont(.caption).foregroundStyle(.orange) }
                if eligible(entry.url) > 0 { Text(formattedBytes(eligible(entry.url)) + " eligible caches").stewardFont(.caption).foregroundStyle(.mint) }
                if protectedCount(entry.url) > 0 { Text("\(protectedCount(entry.url)) protected / review-only findings").stewardFont(.caption).foregroundStyle(.orange) }
                if !entry.complete { Text(map.busy ? "Measuring…" : "Partial or not measured").stewardFont(.caption).foregroundStyle(.orange) }
            }
            Spacer(minLength: 4)
            Text(formattedBytes(cloudSizing ? entry.cloudLogicalBytes : entry.bytes)).stewardFont(.body).monospacedDigit()
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
    }
    /// Back / forward, clickable path segments, and Up to the parent folder.
    private var pathBar: some View {
        let parts = map.root.pathComponents
        let home = FileManager.default.homeDirectoryForCurrentUser.pathComponents
        let start = parts.starts(with: home) ? home.count - 1 : 0
        return HStack(spacing: 6) {
            BackSquareButton { map.goBack() }.disabled(map.backStack.isEmpty || !map.canStart)
            Button { map.goForward() } label: { Image(systemName: "chevron.right") }.disabled(map.forwardStack.isEmpty || !map.canStart).help("Forward")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(start..<parts.count, id: \.self) { index in
                        if index > start { Image(systemName: "chevron.compact.right").foregroundStyle(.secondary) }
                        let url = URL(fileURLWithPath: NSString.path(withComponents: Array(parts[0...index])))
                        Button(index == start && start > 0 ? "Home" : parts[index] == "/" ? "Startup Disk" : parts[index]) { map.navigate(url) }
                            .buttonStyle(.plain).stewardFont(.callout, weight: index == parts.count - 1 ? .semibold : .regular)
                            .foregroundStyle(index == parts.count - 1 ? .primary : .secondary)
                            .padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(index == parts.count - 1 ? 0.08 : 0), in: Capsule())
                            .disabled(!map.canStart || index == parts.count - 1)
                    }
                }
            }
            Button { map.navigate(map.root.deletingLastPathComponent()) } label: { Image(systemName: "arrow.turn.left.up") }
                .disabled(!map.canStart || map.root.path == "/").help("Up to the enclosing folder")
        }.buttonStyle(.bordered).padding(6).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
    private func storageMetric(_ label: String, _ value: String, explanation: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).stewardFont(.caption).foregroundStyle(.secondary)
            Text(value).stewardFont(.title3, weight: .semibold).foregroundStyle(color).monospacedDigit()
            Text(explanation).stewardFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
    private func mapContent(_ snapshot: StorageMapSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                if map.busy { StewardProgressBar().frame(width: 90) }
                Text(map.busy ? (map.refreshingChanges ? (snapshot.root.path == map.root.path ? "Refreshing changed folders…" : "Opening folder…") : "Mapping local storage…") : "Storage in this map")
                    .stewardFont(.headline)
                Spacer()
                Menu {
                    Button("Current folder") { model.reveal(map.root.path) }
                    Button("Full rescan") { map.map(full: true) }.disabled(!map.canStart)
                    Button("Find eligible caches") { model.section = "Overview"; model.scan() }
                } label: { Image(systemName: "ellipsis.circle") }.help("Map actions")
            }
            HStack(spacing: 10) {
                storageMetric("Stored on this Mac", formattedBytes(snapshot.bytes), explanation: "Space these files occupy on your disk.", color: StewardTheme.space.accent)
                storageMetric("File size", formattedBytes(snapshot.logicalBytes), explanation: "Full file lengths, including online-only files.", color: .white)
                storageMetric("Cloud-backed files", formattedBytes(snapshot.cloudLogicalBytes), explanation: "Full size of cloud-backed files found here. Not your whole cloud account.", color: StewardTheme.space.accent)
            }
            if snapshot.root.path == "/" || snapshot.root.deletingLastPathComponent().path == "/Volumes" { capacityBar(snapshot) }
            if !snapshot.kinds.isEmpty { kindsRow(snapshot) }
            HStack {
                Text("In this map: \(snapshot.cloudFileCount) cloud-backed files · \(snapshot.onlineOnlyCount) online-only").stewardFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Bubble size", selection: $cloudSizing) { Text("Stored on this Mac").tag(false); Text("Cloud-backed files").tag(true) }.pickerStyle(.segmented).frame(maxWidth: 350)
            }
            if eligible(snapshot.root) > 0 {
                Button { model.review() } label: {
                    Label("\(formattedBytes(eligible(snapshot.root))) in previously verified cleanup candidates · Review", systemImage: "sparkles")
                        .stewardFont(.body).foregroundStyle(.mint).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
            GeometryReader { geometry in
                let layout = geometry.size.width < 650 || textScale > 1.4 ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(spacing: 18))
                layout {
                    VStack(alignment: .leading, spacing: 10) {
                        BulkBar(title: "Select all", isOn: Binding(get: { !rows.isEmpty && selection.isSuperset(of: rows.map(\.id)) }, set: { if $0 { selection.formUnion(rows.map(\.id)) } else { selection.subtract(rows.map(\.id)) } }), enabled: !rows.isEmpty,
                                help: "Everything listed here. You review each item before it moves to the Trash.", summary: "\(selection.count) selected") {
                            Button("Move \(selection.count) to Trash…", role: .destructive) { trashRequest = TrashRequest(urls: rows.filter { selection.contains($0.id) }.map(\.url)) }
                                .buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(selection.isEmpty)
                        }
                        Picker("Show", selection: $largestFiles) { Text("Contents").tag(false); Text("Largest files").tag(true) }.pickerStyle(.segmented)
                        ScrollView {
                            LazyVStack(spacing: 5) {
                                ForEach(rows) { entry in
                                    mapRow(entry)
                                }
                            }
                        }
                    }.frame(width: geometry.size.width >= 650 && textScale <= 1.4 ? min(310, geometry.size.width * 0.39) : nil)
                    StorageBubbleMap(cloudSizing: cloudSizing, entries: Array(snapshot.entries.filter { cloudSizing ? $0.cloudLogicalBytes > 0 : $0.bytes > 0 }.sorted { cloudSizing ? $0.cloudLogicalBytes > $1.cloudLogicalBytes : $0.bytes > $1.bytes }.prefix(12)), eligible: eligible, open: open, trash: { trashRequest = TrashRequest(urls: [$0.url]) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity).disabled(!map.canStart)
                }
            }
            HStack {
                Text(map.watching ? (map.hasChanges ? "Changes detected" : snapshot.incremental ? "Refreshed \(snapshot.refreshedFolderCount) \(snapshot.refreshedFolderCount == 1 ? "folder" : "folders") · reused \(snapshot.reusedCount) \(snapshot.reusedCount == 1 ? "item" : "items")" : "Watching for folder changes") : "Change monitoring unavailable · Refresh performs a full scan")
                    .stewardFont(.caption).foregroundStyle(.secondary)
                Spacer()
                if map.busy { Text("\(map.checkedCount) entries checked").stewardFont(.caption).foregroundStyle(.secondary) }
            }
            HStack(alignment: .top) {
                Text(!snapshot.finished && !map.busy ? "Map stopped. Measurements are partial." : snapshot.limited || snapshot.entries.contains(where: { !$0.complete }) && !map.busy ? "Partial map. Open a folder to measure it in more detail." : snapshot.unreadableCount > 0 ? "\(snapshot.unreadableCount) locations could not be read. macOS permissions remain in control." : "Folder names and sizes only. Click a bubble to explore.")
                    .stewardFont(.caption).foregroundStyle(snapshot.limited || snapshot.unreadableCount > 0 ? Color.orange : .secondary)
                Spacer()
                Image(systemName: "info.circle").help("Stored on this Mac uses allocated file blocks; file size is logical length. The cloud total counts files represented in this map, not your full cloud account, and is not reclaimable local space. No cloud file contents are read or downloads requested. Hard links are counted once; APFS clones, shared storage and system-managed space can make free-space changes differ. Small bubbles keep a minimum clickable size. Mapping only reads metadata; moving an item to Trash requires a separate review.")
            }
        }
    }
}

let kindColors: [String: Color] = ["Folders": .mint, "Videos": .pink, "Images": .orange, "Audio": .yellow, "Archives": .brown, "Disk images": .purple, "Documents": .blue, "Code & data": .teal, "Apps & libraries": .indigo, "Other": .gray]
extension StorageMapView {
    /// Whole-drive maps show mapped, other (system, purgeable, unreadable) and free space.
    func capacityBar(_ snapshot: StorageMapSnapshot) -> some View {
        let disk = DiskSpace.read(at: snapshot.root.path)
        let mapped = min(snapshot.bytes, disk.total), free = min(disk.free, disk.total - mapped)
        let other = disk.total - mapped - free
        let parts: [(String, UInt64, Color)] = [("Mapped", mapped, StewardTheme.space.accent), ("Other", other, .white.opacity(0.35)), ("Free", free, .white.opacity(0.08))]
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { part in
                        RoundedRectangle(cornerRadius: 4).fill(part.2).frame(width: max(2, geometry.size.width * CGFloat(Double(part.1) / Double(max(1, disk.total)))))
                    }
                }
            }.frame(height: 10)
            HStack(spacing: 16) {
                ForEach(parts, id: \.0) { part in Label(part.0 + " " + formattedBytes(part.1), systemImage: "circle.fill").stewardFont(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon).tint(part.2) }
                Spacer()
                Image(systemName: "info.circle").help("Other is space on this drive the map could not attribute to a file: macOS system data, snapshots, purgeable space and folders macOS did not let Artifloam read.")
            }
        }
    }
    /// Space by kind of file, counted once per file even when hard-linked.
    func kindsRow(_ snapshot: StorageMapSnapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(snapshot.kinds.prefix(9)) { kind in
                    HStack(spacing: 6) {
                        Circle().fill(kindColors[kind.name] ?? .gray).frame(width: 8, height: 8)
                        Text(kind.name).stewardFont(.caption, weight: .semibold)
                        Text(formattedBytes(kind.bytes)).stewardFont(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 10).padding(.vertical, 6).background(.white.opacity(0.06), in: Capsule())
                    .help("\(kind.files) files")
                }
            }
        }
    }
}

private struct StorageBubbleMap: View {
    var cloudSizing = false
    let entries: [StorageMapEntry]
    let eligible: (URL) -> UInt64
    let open: (StorageMapEntry) -> Void
    let trash: (StorageMapEntry) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct Bubble { let entry: StorageMapEntry; var center: CGPoint; let radius: CGFloat }
    private func packed(_ size: CGSize) -> [Bubble] {
        let total = max(1, entries.reduce(0) { $0 + (cloudSizing ? $1.cloudLogicalBytes : $1.bytes) })
        let unit = max(40, min(size.width, size.height))
        var bubbles = entries.enumerated().map { index, entry in
            let angle = Double(index) * 2.39996
            return Bubble(entry: entry, center: CGPoint(x: size.width / 2 + cos(angle) * unit * 0.20, y: size.height / 2 + sin(angle) * unit * 0.20), radius: max(20, sqrt(Double(cloudSizing ? entry.cloudLogicalBytes : entry.bytes) / Double(total)) * unit * 0.41))
        }
        for _ in 0..<90 {
            for i in bubbles.indices {
                for j in bubbles.indices where j > i {
                    let dx = bubbles[j].center.x - bubbles[i].center.x, dy = bubbles[j].center.y - bubbles[i].center.y
                    let distance = max(0.1, hypot(dx, dy)), overlap = bubbles[i].radius + bubbles[j].radius + 8 - distance
                    if overlap > 0 {
                        let shift = overlap * 0.51
                        bubbles[i].center.x -= dx / distance * shift; bubbles[i].center.y -= dy / distance * shift
                        bubbles[j].center.x += dx / distance * shift; bubbles[j].center.y += dy / distance * shift
                    }
                }
                let radius = bubbles[i].radius
                bubbles[i].center.x += (size.width / 2 - bubbles[i].center.x) * 0.008
                bubbles[i].center.y += (size.height / 2 - bubbles[i].center.y) * 0.008
                bubbles[i].center.x = min(max(radius + 3, bubbles[i].center.x), max(radius + 3, size.width - radius - 3))
                bubbles[i].center.y = min(max(radius + 3, bubbles[i].center.y), max(radius + 3, size.height - radius - 3))
            }
        }
        return bubbles
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: cloudSizing ? "icloud" : "folder").font(.system(size: 30)).foregroundStyle(.secondary)
                        Text(cloudSizing ? "No cloud-backed files measured in this map" : "No local file blocks measured").stewardFont(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ForEach(Array(packed(geometry.size).enumerated()), id: \.element.entry.id) { index, bubble in
                    StorageBubble(entry: bubble.entry, displayBytes: cloudSizing ? bubble.entry.cloudLogicalBytes : bubble.entry.bytes, cloudSizing: cloudSizing, diameter: bubble.radius * 2, index: index, eligibleBytes: eligible(bubble.entry.url)) { open(bubble.entry) }
                        .contextMenu { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([bubble.entry.url]) }; Button("Review Move to Trash…", role: .destructive) { trash(bubble.entry) } }
                        .position(bubble.center)
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.55)))
                }
            }.animation(reduceMotion ? nil : .spring(response: 0.65, dampingFraction: 0.83), value: entries.map { $0.id + ":" + String($0.bytes) + ":" + String($0.cloudLogicalBytes) })
        }
    }
}
private struct StorageBubble: View {
    let entry: StorageMapEntry
    let displayBytes: UInt64
    let cloudSizing: Bool
    let diameter: CGFloat
    let index: Int
    let eligibleBytes: UInt64
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var hovered = false
    /// Same gold as the section; white labels stay readable on its deep shade.
    private var accent: Color { StewardTheme.space.vivid }
    private var helpText: String {
        var text = entry.url.lastPathComponent + " · Stored on this Mac: " + formattedBytes(entry.bytes)
        text += " · Cloud-backed files: " + formattedBytes(entry.cloudLogicalBytes)
        if !entry.complete { text += " · partial measurement" }
        return text
    }
    private var accessibilityText: String { entry.url.lastPathComponent + ", " + formattedBytes(displayBytes) + (cloudSizing ? " cloud-backed files" : " stored on this Mac") }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || scenePhase != .active)) { timeline in
            let phase = reduceMotion || scenePhase != .active ? 0 : timeline.date.timeIntervalSinceReferenceDate * 0.7 + Double(index)
            Button(action: action) { bubbleSurface }
                .buttonStyle(.plain)
                .offset(y: reduceMotion ? 0 : sin(phase) * 2)
                .scaleEffect(hovered && !reduceMotion ? 1.04 : 1)
                .rotation3DEffect(.degrees(hovered && !reduceMotion ? -7 : 0), axis: (x: 1, y: 1, z: 0))
                .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78), value: hovered)
                .onHover { hovered = $0 }
                .help(helpText).accessibilityLabel(accessibilityText)
        }
    }
    private var bubbleSurface: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(RadialGradient(colors: [Color.white.opacity(0.18), accent.opacity(0.35), StewardTheme.space.glow.opacity(0.75)], center: .topLeading, startRadius: 0, endRadius: diameter))
            Circle().stroke(LinearGradient(colors: [Color.white.opacity(0.64), accent.opacity(0.15), accent.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: hovered ? 1.8 : 0.8)
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(.white.opacity(0.85))
                    if eligibleBytes > 0 { Image(systemName: "sparkles").foregroundStyle(.mint).help(formattedBytes(eligibleBytes) + " eligible caches") }
                }.font(.system(size: min(34, diameter * 0.22)))
                if diameter > 95 {
                    Text(entry.url.lastPathComponent).stewardFont(.body, weight: .medium).lineLimit(2).multilineTextAlignment(.center)
                    Text(formattedBytes(displayBytes)).stewardFont(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }.padding(12)
            Ellipse().fill(.white.opacity(0.16)).frame(width: diameter * 0.5, height: diameter * 0.15)
                .blur(radius: 5).offset(x: -diameter * 0.12, y: -diameter * 0.30)
        }.frame(width: diameter, height: diameter).contentShape(Circle())
            .shadow(color: accent.opacity(hovered ? 0.32 : 0.10), radius: hovered ? 16 : 7, y: 6)
    }
}
