import AppKit
import SwiftUI
import MacStewardCore

struct FolderGrant: Codable, Identifiable {
    enum Role: String, Codable, CaseIterable {
        // `downloads` is unused (duplicates search the home folder) but kept so saved grants still decode.
        case project, downloads, claude, codex, additional
        var title: String {
            switch self {
            case .project: return String(localized: "Project folder")
            case .downloads: return String(localized: "Duplicate search folder")
            case .claude: return String(localized: "Claude configuration")
            case .codex: return String(localized: "Codex configuration")
            case .additional: return String(localized: "Additional access")
            }
        }
        /// Title of the folder chooser; whole sentences so each language can phrase them.
        var chooserTitle: String {
            switch self {
            case .project: return String(localized: "Choose project folders")
            case .downloads: return String(localized: "Choose duplicate search folder")
            case .claude: return String(localized: "Choose Claude configuration folder")
            case .codex: return String(localized: "Choose Codex configuration folder")
            case .additional: return String(localized: "Choose additional access folder")
            }
        }
    }
    let id: UUID
    let role: Role
    var path: String
    var bookmark: Data
}

@MainActor
final class FolderAccess: ObservableObject {
    @Published private(set) var grants: [FolderGrant] = []
    @Published private(set) var status: [UUID: String] = [:]
    @Published private(set) var detectedProjects: [KnownProject] = []
    @Published private(set) var discoveringProjects = false
    @Published private(set) var excludedProjects: [String] = []
    @Published var error: String?
    @Published private(set) var agentFolders: [FolderGrant.Role: AgentFolderDiscovery] = [:]
    private var urls: [UUID: URL] = [:]
    private var scoped = Set<UUID>()
    private let defaults = StewardPreferences.defaults
    init() {
        excludedProjects = defaults.stringArray(forKey: "excludedDetectedProjects") ?? []
        if let data = defaults.data(forKey: "folderGrants"), let saved = try? JSONDecoder().decode([FolderGrant].self, from: data) { grants = saved }
        for index in grants.indices {
            var stale = false
            do {
                let url = try URL(resolvingBookmarkData: grants[index].bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                urls[grants[index].id] = url
                if url.startAccessingSecurityScopedResource() { scoped.insert(grants[index].id) }
                if stale { grants[index].bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil); grants[index].path = url.path }
                status[grants[index].id] = String(localized: "Selected · not checked")
            } catch { status[grants[index].id] = String(localized: "Choose this folder again") }
        }
        save()
        // Protected-folder discovery waits for Scan or the Settings feature.
    }
    var projectURLs: [URL] {
        let selected = grants.filter { $0.role == .project }.compactMap { urls[$0.id] }
            .sorted { $0.pathComponents.count < $1.pathComponents.count }
        return selected.reduce(into: [URL]()) { result, url in
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if !result.contains(where: {
                let parent = $0.standardizedFileURL.resolvingSymlinksInPath().path
                return path == parent || path.hasPrefix(parent + "/")
            }) { result.append(url) }
        }
    }
    var scanProjectURLs: [URL] {
        Configuration.canonicalProjectRoots(projectURLs + detectedProjects.filter { !excludedProjects.contains($0.id) }.map(\.url))
    }
    func acceptKnownProjects(_ projects: [KnownProject]) { detectedProjects = projects }
    func url(for role: FolderGrant.Role) -> URL? {
        if let grant = grants.first(where: { $0.role == role }) {
            return urls[grant.id] ?? URL(fileURLWithPath: grant.path)
        }
        if role == .claude { return Configuration().claudeHome }
        if role == .codex { return Configuration().codexHome }
        return nil
    }
    func detectAgentFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        for (role, name, key) in [(FolderGrant.Role.claude, ".claude", "CLAUDE_CONFIG_DIR"), (.codex, ".codex", "CODEX_HOME")] {
            let selected = grants.first(where: { $0.role == role }).map { urls[$0.id] ?? URL(fileURLWithPath: $0.path) }
            Task {
                let result = await Task.detached(priority: .utility) {
                    AgentFolderDiscovery.inspect(home: home, directoryName: name, environmentKey: key, environment: environment, selected: selected)
                }.value
                // Do not let an earlier check overwrite a newly selected location.
                if url(for: role)?.standardizedFileURL.path == result.url.standardizedFileURL.path { agentFolders[role] = result }
            }
        }
    }
    var suggestedProjects: [KnownProject] {
        let selected = Set(projectURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        return detectedProjects.filter { !excludedProjects.contains($0.id) && !selected.contains($0.id) }
    }
    func discoverProjects() {
        guard !discoveringProjects, let claude = url(for: .claude), let codex = url(for: .codex) else { return }
        discoveringProjects = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        Task {
            let projects = await Task.detached(priority: .utility) {
                KnownProjectDiscovery.discover(home: home, claudeHome: claude, codexHome: codex)
            }.value
            if url(for: .claude) == claude && url(for: .codex) == codex { detectedProjects = projects }
            discoveringProjects = false
        }
    }
    func includeProject(_ project: KnownProject) { add([project.url], role: .project) }
    func excludeProject(_ project: KnownProject) {
        excludedProjects.append(project.id)
        defaults.set(excludedProjects, forKey: "excludedDetectedProjects")
    }
    func restoreSuggestions() {
        excludedProjects = []; defaults.removeObject(forKey: "excludedDetectedProjects")
    }
    func choose(_ role: FolderGrant.Role, afterSelection: (() -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = role.chooserTitle
        panel.message = afterSelection == nil ? String(localized: "macOS controls access. Selecting a folder does not start a scan or remove anything.") : String(localized: "Choose a folder to compare file sizes and hashes locally. No files will be removed.")
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = role == .project || role == .additional
        panel.prompt = String(localized: "Allow Folder")
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch role {
        case .project: panel.directoryURL = home
        case .downloads: panel.directoryURL = home.appendingPathComponent("Downloads")
        case .claude: panel.directoryURL = url(for: .claude)
        case .codex: panel.directoryURL = url(for: .codex)
        case .additional: panel.directoryURL = home.appendingPathComponent("Library")
        }
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                self?.add(panel.urls, role: role)
                if self?.url(for: role) != nil { afterSelection?() }
            }
        }
        let host = NSApp.mainWindow ?? NSApp.keyWindow
        DispatchQueue.main.async {
            if let host { panel.beginSheetModal(for: host, completionHandler: completion) }
            else { panel.begin(completionHandler: completion) }
        }
    }
    private func add(_ selected: [URL], role: FolderGrant.Role) {
        do {
            for selectedURL in selected {
                let url = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
                if role == .project && url.path == "/" { throw StewardError.blocked(String(localized: "Choose a project directory, not the entire disk.")) }
                if grants.contains(where: { $0.role == role && $0.path == url.path }) { continue }
                excludedProjects.removeAll { $0 == url.path }
                defaults.set(excludedProjects, forKey: "excludedDetectedProjects")
                let bookmark = try selectedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                if ![.project, .additional].contains(role) {
                    for grant in grants.filter({ $0.role == role }) { remove(grant) }
                }
                let grant = FolderGrant(id: UUID(), role: role, path: url.path, bookmark: bookmark)
                grants.append(grant); urls[grant.id] = selectedURL
                if selectedURL.startAccessingSecurityScopedResource() { scoped.insert(grant.id) }
                status[grant.id] = String(localized: "Selected · not checked")
            }
            save()
            checkAccess()
        } catch { self.error = error.localizedDescription }
    }
    func remove(_ grant: FolderGrant) {
        if scoped.remove(grant.id) != nil { urls[grant.id]?.stopAccessingSecurityScopedResource() }
        urls.removeValue(forKey: grant.id); status.removeValue(forKey: grant.id)
        grants.removeAll { $0.id == grant.id }; save(); detectAgentFolders()
    }
    func checkAccess() {
        detectAgentFolders()
        let checks = grants.compactMap { grant in urls[grant.id].map { (grant.id, $0) } }
        for (id, _) in checks { status[id] = String(localized: "Checking read access…") }
        for (id, url) in checks {
            Task {
                let result = await Task.detached(priority: .utility) {
                    do { _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil); return String(localized: "Readable · cleanup still needs its safety checks") }
                    catch { return String(localized: "Access unavailable · select again or review macOS settings") }
                }.value
                if urls[id] == url { status[id] = result }
            }
        }
    }
    private func save() {
        defaults.set(try? JSONEncoder().encode(grants), forKey: "folderGrants")
        defaults.set(grants.filter { $0.role == .project }.map(\.path), forKey: "projectRoots")
        for (role, key) in [(FolderGrant.Role.claude, "claudeHome"), (.codex, "codexHome"), (.downloads, "downloadsFolder")] {
            defaults.set(grants.first(where: { $0.role == role })?.path, forKey: key)
        }
    }
    func openPrivacySettings(fullDisk: Bool = false) {
        let pane = fullDisk ? "Privacy_AllFiles" : "Privacy_FilesAndFolders"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct AccessSettingsView: View {
    @ObservedObject var access: FolderAccess
    @EnvironmentObject private var model: StewardModel
    @State private var showingProjects = false
    @State private var projectSearch = ""
    /// Looked up off the main thread: the first Git lookup runs xcode-select.
    @State private var gitAvailable: Bool?
    @AppStorage(UsagePing.enabledKey, store: StewardPreferences.defaults) private var sendUsagePing = false
    /// macOS picks the language at launch, so this remembers what the running app is showing.
    private static let launchLanguage = AppLanguage.chosen(in: UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")) ?? ""
    @State private var language = Self.launchLanguage
    /// One System Settings-style group: a heading, rows separated by hairlines, one short footer.
    private func section<Content: View>(_ title: LocalizedStringKey, footer: LocalizedStringKey? = nil, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).stewardFont(.headline)
            VStack(spacing: 0) { rows() }
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.07), lineWidth: 0.7) }
            if let footer { Text(footer).stewardFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 4) }
        }
    }
    private func row<Trailing: View>(_ label: String, detail: String? = nil, icon: String, divider: Bool = true, @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).stewardFont(.body)
                    if let detail { Text(detail).stewardFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 12)
                trailing()
            }.padding(.horizontal, 14).padding(.vertical, 10)
            if divider { Divider().opacity(0.25).padding(.leading, 48) }
        }
    }
    private func toggleRow(_ label: String, icon: String, isOn: Binding<Bool>, key: String, divider: Bool = true) -> some View {
        row(label, icon: icon, divider: divider) {
            Toggle(label, isOn: isOn).labelsHidden().toggleStyle(.switch).tint(.mint)
                .onChange(of: isOn.wrappedValue) { _, value in StewardPreferences.defaults.set(value, forKey: key) }
        }
    }
    private func agentDetail(_ role: FolderGrant.Role) -> String {
        guard let result = access.agentFolders[role] else { return String(localized: "Checking…") }
        guard result.state == .found else { return String(localized: "Not found") }
        return ((result.url ?? access.url(for: role))?.path ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
    var body: some View {
        let fullDisk = FullDiskAccess.status()
        let extra = access.grants.filter { $0.role == .additional }
        let projects = access.grants.filter { $0.role == .project }
        VStack(alignment: .leading, spacing: 26) {
            Text("Settings").stewardFont(.title, weight: .semibold)
            section("Appearance") {
                row(String(localized: "Text size"), icon: "textformat.size", divider: false) {
                    Button { model.changeTextScale(-0.15) } label: { Image(systemName: "minus") }.accessibilityLabel("Smaller text").disabled(model.textScale <= 1)
                    Text("\(Int((model.textScale * 100).rounded()))%").monospacedDigit().frame(minWidth: 44)
                    Button { model.changeTextScale(0.15) } label: { Image(systemName: "plus") }.accessibilityLabel("Bigger text").disabled(model.textScale >= 2)
                    Button("Reset") { model.setTextScale(1) }.disabled(model.textScale == 1)
                }
            }
            section("Language", footer: language == Self.launchLanguage ? nil : "Artifloam needs to restart to change language.") {
                row(String(localized: "Language"), icon: "globe", divider: false) {
                    if language != Self.launchLanguage, Bundle.main.bundleURL.pathExtension == "app" { Button("Restart Now") { try? UpdateChecker.reopen(Bundle.main.bundleURL) } }
                    Picker("Language", selection: $language) {
                        Text("Same as system").tag("")
                        Divider()
                        ForEach(AppLanguage.all, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                    }.labelsHidden().fixedSize()
                    .onChange(of: language) { _, code in
                        if code.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
                        else { UserDefaults.standard.set(AppLanguage.preference(for: code), forKey: "AppleLanguages") }
                    }
                }
            }
            section("Scans include", footer: "Only recognised caches qualify. Source files, credentials and unfinished work always stay.") {
                toggleRow(String(localized: "Application web caches"), icon: "globe", isOn: $model.includeAppCaches, key: "includeAppCaches")
                toggleRow(String(localized: "Unused developer caches"), icon: "hammer", isOn: $model.includeDeveloperCaches, key: "includeDeveloperCaches")
                toggleRow(String(localized: "Old diagnostic logs"), icon: "doc.text", isOn: $model.includeAdditionalLogs, key: "includeAdditionalLogs", divider: false)
            }
            section("Permissions", footer: "Full Disk Access is optional. It lets Artifloam measure the Trash, Safari, Chrome and other protected folders.") {
                row(String(localized: "Full Disk Access"), detail: fullDisk == .granted ? String(localized: "Allowed") : fullDisk == .denied ? String(localized: "Off", comment: "Status: Full Disk Access is turned off") : String(localized: "Unknown"), icon: "lock.shield") {
                    Button("Open Settings") { access.openPrivacySettings(fullDisk: true) }
                }
                ForEach(extra) { grant in
                    row(URL(fileURLWithPath: grant.path).lastPathComponent, detail: grant.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), icon: "folder") {
                        Button("Remove") { access.remove(grant) }
                    }
                }
                row(String(localized: "Other folders"), detail: extra.isEmpty ? String(localized: "Add one only if a tool cannot reach it") : String(localized: "\(extra.count) added"), icon: "folder.badge.plus", divider: false) {
                    Button("Add…") { access.choose(.additional) }
                    Button("Files & Folders") { access.openPrivacySettings() }
                }
            }
            section("Developer tools", footer: gitAvailable == false ? "Apple's Command Line Tools include Git. Until then, anything that needs a Git check is kept." : nil) {
                row("Claude Code", detail: agentDetail(.claude), icon: access.agentFolders[.claude]?.state == .found ? "checkmark.circle" : "exclamationmark.circle") {
                    Button("Change…") { access.choose(.claude) }
                    if access.grants.contains(where: { $0.role == .claude }), let grant = access.grants.first(where: { $0.role == .claude }) { Button("Automatic") { access.remove(grant) } }
                }
                row("Codex", detail: agentDetail(.codex), icon: access.agentFolders[.codex]?.state == .found ? "checkmark.circle" : "exclamationmark.circle") {
                    Button("Change…") { access.choose(.codex) }
                    if let grant = access.grants.first(where: { $0.role == .codex }) { Button("Automatic") { access.remove(grant) } }
                }
                row(String(localized: "Projects"), detail: access.discoveringProjects ? String(localized: "Finding projects…") : projects.isEmpty ? String(localized: "\(access.suggestedProjects.count) found automatically") : String(localized: "\(access.suggestedProjects.count) found automatically · \(projects.count) added"), icon: "folder.badge.gearshape") {
                    Button("Manage…") { showingProjects = true }.disabled(access.discoveringProjects)
                    Button("Add…") { access.choose(.project) }
                }
                row("Git", detail: gitAvailable.map { $0 ? String(localized: "Available") : String(localized: "Not installed") } ?? String(localized: "Checking…"), icon: "arrow.triangle.branch", divider: false) {
                    if gitAvailable == false { Button("Install Command Line Tools") { Task.detached { DeveloperTools.installCommandLineTools() } } }
                    Button("Check Again") { access.checkAccess(); access.discoverProjects() }
                }
            }
            if UpdateChecker.current == nil {
                section("Privacy", footer: "Your files, file names and scan results stay on this Mac and are never sent anywhere. This build doesn't connect to anything.") { EmptyView() }
            } else { section("Privacy", footer: "Your files, file names and scan results stay on this Mac and are never sent anywhere. Artifloam connects to vasquezgroup.ch for one thing on its own: once a day it asks if a new version exists. If you turn on the count below, then once a month it also sends only this: \(UsagePing.Payload(version: UpdateChecker.current ?? "0.0.0").summary), plus a random number that proves about a second of work, to discourage fake counts. The count stores no IP address, but like any website the host may keep standard server logs of these visits.") {
                toggleRow(String(localized: "Help count active users"), icon: "chart.bar", isOn: $sendUsagePing, key: UsagePing.enabledKey, divider: false)
            } }
            section("Uninstall", footer: "Your own files stay where they are. Only what Artifloam created is removed, and you see the list first.") {
                row(String(localized: "Uninstall Artifloam"), detail: String(localized: "The app, its data, its daily cleanup and its settings"), icon: "trash", divider: false) {
                    Button("Uninstall…") { model.requestUninstall() }
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .disabled(model.busy || model.waitingForCancelledScan)
        .onAppear { access.checkAccess(); access.discoverProjects() }
        .task { gitAvailable = await Task.detached { DeveloperTools.gitExecutable != nil }.value }
        .sheet(isPresented: $showingProjects) { projectSuggestions }
        .alert("Folder access", isPresented: Binding(get: { access.error != nil }, set: { if !$0 { access.error = nil } })) { Button { access.error = nil } label: { Text("OK").stewardFont(.body) } } message: { Text(access.error ?? "") }
    }
    private var projectSuggestions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Known projects").stewardFont(.title2, weight: .semibold)
                Spacer()
                Button { showingProjects = false } label: { Text("Done").stewardFont(.body) }.keyboardShortcut(.defaultAction)
            }
            Text("Known Git projects are inspected automatically. Exclude locations you want to leave out. Keep Location saves a bookmark; you can also add a missing folder manually.")
                .stewardFont(.callout).foregroundStyle(.secondary)
            TextField("Find a project or path", text: $projectSearch).stewardInput()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(access.suggestedProjects.filter { projectSearch.isEmpty || $0.id.localizedCaseInsensitiveContains(projectSearch) }) { project in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.url.lastPathComponent).stewardFont(.headline)
                                Text(project.id).stewardFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Text(project.sources.joined(separator: " · ")).stewardFont(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { access.excludeProject(project) } label: { Text("Exclude").stewardFont(.body) }
                            Button { access.includeProject(project) } label: { Text("Keep Location").stewardFont(.body) }
                        }
                    }
                    if access.suggestedProjects.isEmpty { Text("No additional known projects. Standard caches and logs are still inspected automatically; add a folder only if it is missing.").foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
            }
            HStack {
                Button { access.discoverProjects() } label: { Text("Refresh").stewardFont(.body) }.disabled(access.discoveringProjects)
                if !access.excludedProjects.isEmpty { Button { access.restoreSuggestions() } label: { Text("Restore Excluded (\(access.excludedProjects.count))").stewardFont(.body) } }
                Spacer()
                Text("Paths only · on this Mac").stewardFont(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 660, height: 440).preferredColorScheme(.dark)
    }
}
