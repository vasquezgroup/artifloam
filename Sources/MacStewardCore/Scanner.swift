import Foundation
import Darwin

public final class Scanner: @unchecked Sendable {
    public let configuration: Configuration
    /// nil scans every group; a set limits the scan to one tool's groups.
    public let groups: Set<CleanupGroup>?
    /// The app passes one cache for its whole session; the CLI and scheduled cleanup always read every folder.
    public let summaries: TreeSummaryCache?
    /// `.userInitiated` while someone waits in the app: on a busy Mac it scanned ~3× faster for the same CPU.
    /// The CLI and scheduled cleanup keep `.utility` so they yield to the user's work.
    public let priority: DispatchQoS.QoSClass
    public init(configuration: Configuration = Configuration(), groups: Set<CleanupGroup>? = nil, summaries: TreeSummaryCache? = nil, priority: DispatchQoS.QoSClass = .utility) { self.configuration = configuration; self.groups = groups; self.summaries = summaries; self.priority = priority }
    private func wants(_ group: CleanupGroup) -> Bool { groups?.contains(group) ?? true }
    static let reusableRules: Set<String> = ["simulator-cache", "nx-task-cache", "framework-cache", "xcode-intermediates", "agent-xcode-intermediates",
                                             "python-bytecode", "project-test-cache", "old-agent-version", "inactive-dependencies"]
    public func scan(progress: @Sendable (String) -> Void = { _ in }) throws -> ScanReport {
        let throttle = ScanTextProgressThrottle()
        return try scanWithProgress { if throttle.shouldPublish($0) { progress($0.message) } }
    }
    public func scanWithProgress(_ status: @Sendable (ScanProgress) -> Void) throws -> ScanReport {
        try scanWithProgress(status, activityOverride: nil)
    }
    func scanWithProgress(_ status: @Sendable (ScanProgress) -> Void, activityOverride: ActivitySnapshot?, maximumChecks: Int = 250_000, workers workerOverride: Int? = nil) throws -> ScanReport {
        var findings = [Finding](); var notices = [String]()
        // Checks start on a few workers as soon as discovery plans them, so results are gathered under a lock.
        let resultLock = NSLock()
        func collect(_ body: () -> Void) { resultLock.lock(); body(); resultLock.unlock() }
        var checklistLimited = false, planned = 0, completed = 0, failure: Error?, stopped = false, latest: String?, latestStep = ScanStep.access
        let checkLimit = max(1, maximumChecks)
        let queue = OperationQueue(), running = DispatchGroup()
        // Utility priority: faster, while macOS keeps the Mac responsive for the user.
        queue.maxConcurrentOperationCount = workerOverride ?? ScanPacing.workers(); queue.qualityOfService = priority == .userInitiated ? .userInitiated : .utility
        func progress(_ message: String) { status(ScanProgress(message: String(localized: "Preparing scan… \(message)"))) }
        try Task.checkCancellation()
        progress(String(localized: "Checking running apps and open files…"))
        // lsof takes about a second; discovery doesn't need it, so it runs alongside. Checks wait for it: their own
        // git and simctl processes must not appear in the snapshot as other apps' activity.
        let capture = Pending(priority) { activityOverride ?? ActivitySnapshot.capture() }
        var activity: ActivitySnapshot { capture.value }
        /// `independent` checks start without the activity snapshot: nothing they run looks like a candidate's user.
        func plan(_ label: String, step: ScanStep = .caches, independent: Bool = false, _ check: @escaping () throws -> Void) {
            resultLock.lock(); defer { resultLock.unlock() }
            guard planned < checkLimit else { checklistLimited = true; return }
            planned += 1; running.enter()
            queue.addOperation {
                defer { running.leave() }
                // Workers only note what they start; the scan thread reports it.
                resultLock.lock(); let skip = stopped || failure != nil; if !skip { latest = label; latestStep = step }; resultLock.unlock()
                guard !skip else { return }
                if !independent { _ = capture.value }
                do { try check() } catch { collect { failure = failure ?? error } }
                collect { completed += 1 }
            }
        }
        // However the scan ends, no check is still running once it returns.
        defer { collect { stopped = true }; running.wait() }
        if DeveloperTools.gitExecutable == nil && !configuration.projectRoots.isEmpty { notices.append(String(localized: "Git is unavailable. Git-dependent caches remain protected and worktree checks are skipped; install Git or Command Line Tools to enable verification.")) }
        try Task.checkCancellation()
        progress(String(localized: "Checking access to project folders…"))
        for root in configuration.projectRoots + [configuration.agentTemp] where FileManager.default.fileExists(atPath: root.path) {
            try Task.checkCancellation()
            do { _ = try FileManager.default.contentsOfDirectory(atPath: root.path) }
            catch { notices.append(String(localized: "Cannot read \(root.path): \(error.localizedDescription). Grant folder access in macOS Privacy & Security if needed.")) }
        }
        let policy = SafetyPolicy(configuration: configuration)
        let runningApps = BroadCaches.runningApps()
        summaries?.prepare(watching: [configuration.home, configuration.agentTemp] + configuration.projectRoots)
        /// `busy` runs inside the check rather than during discovery: per-project git calls would serialize the walk.
        func add(_ url: URL, group: CleanupGroup, rule: String, reason: String, busy: (() -> Bool)? = nil) {
            let path = url.path.replacingOccurrences(of: configuration.home.path, with: "~")
            let label: String
            switch group {
            case .agentBuilds: label = String(localized: "Inspecting session build caches: \(path)")
            case .xcode: label = rule == "simulator-cache" ? String(localized: "Inspecting simulator caches: \(path)") : String(localized: "Inspecting Xcode build intermediates: \(path)")
            case .developerCaches: label = String(localized: "Inspecting developer caches: \(path)")
            case .projectCaches: label = String(localized: "Inspecting project caches: \(path)")
            case .inactiveDependencies: label = String(localized: "Inspecting idle project dependencies: \(path)")
            case .userCaches: label = rule == "application-web-cache" ? String(localized: "Inspecting application web caches: \(path)") : String(localized: "Inspecting app caches: \(path)")
            default: label = String(localized: "Inspecting old user logs: \(path)")
            }
            // A check with a `busy` test starts after the open-files snapshot, like before. The others measure their
            // folder while lsof runs (the snapshot leaves out this process's own files) and wait for it only before
            // the first Git call: Git processes must not appear in the snapshot as other apps' activity.
            plan(label, step: group == .userLogs || group == .systemLogs ? .logs : .caches, independent: busy == nil) {
            do {
                if let busy, busy() { return }
                // Totals only; the full per-file inventory runs right before removal.
                // Only build output and simulator downloads are reused: they change when a build or simulator runs and closes
                // its files. Gradle and module caches count reads (access times), which FSEvents does not report, and app,
                // web and log caches are written by running apps that keep files open; those are always read.
                let dependencies = TreeInventory.regenerableRules.contains(rule)
                let tree = try self.summaries?.read(url, dependencies: dependencies, reusable: Scanner.reusableRules.contains(rule))
                    ?? TreeSummary.read(url, dependencies: dependencies)
                guard tree.bytes >= (rule == "old-user-log" ? 65_536 : 1_000_000) else { return }
                _ = capture.value
                try policy.validatePath(url, rule: rule)
                let days = DeveloperJunk.minimumAge(rule: rule, configured: self.configuration.minimumAgeDays)
                let lastUse = ["gradle-generated-cache", "xcode-module-cache"].contains(rule) ? max(tree.newest, tree.lastAccessed) : tree.newest
                let old = lastUse < Date().addingTimeInterval(-Double(days)*86400)
                let active = activity.isActive(url) || DeveloperJunk.producerActive(rule: rule, path: url.path, activity: activity) || (rule == "application-web-cache" && ApplicationWebCaches.producerActive(url, home: self.configuration.home, activity: activity))
                    || (rule == "app-cache" && BroadCaches.ownerRunning(url.lastPathComponent, running: runningApps)) || (rule == "simulator-cache" && BroadCaches.simulatorRunning(activity))
                let safe = old && !active && activity.reliable
                let note = active ? String(localized: "In use: its app or a running process uses it.") : !old ? String(localized: "Used or modified within the last \(days) days.") : !activity.reliable ? String(localized: "Protected: process inspection is incomplete.") : reason
                let hold: Hold? = safe ? nil : active ? .inUse : !old ? .recent : .unverified
                // Only an app-owned cache gets an owner: that's the one case Artifloam can resolve by quitting an app.
                let owner = hold == .inUse && rule == "app-cache" ? BroadCaches.owner(of: url.lastPathComponent, running: runningApps) : nil
                let finding = Finding(path: url.path, group: group, bytes: tree.bytes, modifiedAt: tree.newest, safety: safe ? .automatic : .protected, reason: note, rule: rule, fingerprint: tree.fingerprint, hold: hold, owner: owner)
                collect { findings.append(finding) }
            } catch is CancellationError { throw CancellationError() } catch { /* Unknown structures and protected contents never become deletion candidates. */ }
            }
        }
        // The longest single checks start first, so they overlap everything else instead of finishing last.
        if configuration.includeDeveloperCaches, wants(.developerCaches), configuration.home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
           let cellar = BroadCaches.cellars.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            plan(String(localized: "Measuring old Homebrew versions…"), independent: true) {
                let old = BroadCaches.oldVersions(cellar: URL(fileURLWithPath: cellar))
                let bytes = old.reduce(UInt64(0)) { $0 + directoryBytes($1) }
                guard bytes > 1_000_000 else { return }
                collect { findings.append(Finding(path: cellar, group: .developerCaches, bytes: bytes, modifiedAt: Date(), safety: .review, reason: String(localized: "\(old.count) older versions of installed formulae. Homebrew removes these itself, in Terminal, where you can watch it."), rule: BroadCaches.brewOldVersionsRule, fingerprint: "review-only", label: String(localized: "Old Homebrew versions"))) }
            }
        }
        if wants(.worktrees) { plan(String(localized: "Reviewing Git worktrees…"), step: .worktrees) { let rows = self.worktreeFindings(activity: activity); collect { findings += rows } } }
        if wants(.xcode) {
            plan(String(localized: "Reviewing Xcode storage…")) {
                let xcodeStorage = XcodeStorageInventory.inspect(home: self.configuration.home, ignoredPaths: self.configuration.ignoredPaths)
                collect { findings += xcodeStorage.findings; notices += xcodeStorage.notices }
            }
        }
        if wants(.agentBuilds) {
        progress(String(localized: "Inspecting Claude temporary builds…"))
        walk(configuration.agentTemp, maximumDepth: 8) { url, names in
            if names.contains("Build") && (names.contains("info.plist") || names.contains("ModuleCache.noindex")) {
                for relative in ["Build/Intermediates.noindex", "ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex"] {
                    let p = url.appendingPathComponent(relative, isDirectory: true)
                    if FileManager.default.fileExists(atPath: p.path) { add(p, group: .agentBuilds, rule: "agent-xcode-intermediates", reason: String(localized: "Regenerable temporary build cache; no source, app products or archives.")) }
                }
                return false
            }
            return true
        }
        progress(String(localized: "Inspecting old AI tool versions…"))
        for root in DeveloperJunk.agentVersionRoots(home: configuration.home) {
            for version in DeveloperJunk.oldAgentVersions(in: root) {
                add(version, group: .agentBuilds, rule: "old-agent-version", reason: String(localized: "Older copy of an AI tool; the newest version stays and is the one that runs."))
            }
        }
        }
        let derived = configuration.home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        if wants(.xcode) {
        progress(String(localized: "Inspecting Xcode build intermediates…"))
        for project in children(derived) {
            let intermediates = project.appendingPathComponent("Build/Intermediates.noindex", isDirectory: true)
            if FileManager.default.fileExists(atPath: intermediates.path) { add(intermediates, group: .xcode, rule: "xcode-intermediates", reason: String(localized: "Regenerable compiler output. Final products, archives and source packages are preserved.")) }
        }
        }
        // Simulator asset folders are the slowest single checks; planned before thousands of Gradle folders, they start first.
        if wants(.xcode) {
        progress(String(localized: "Inspecting simulator caches…"))
        for candidate in BroadCaches.simulatorCandidates(home: configuration.home) {
            add(candidate.url, group: .xcode, rule: "simulator-cache", reason: String(localized: "\(candidate.label). iOS downloads these again when the simulator needs them."))
        }
        }
        if configuration.includeDeveloperCaches && wants(.developerCaches) {
            progress(String(localized: "Inspecting developer caches…"))
            for (index, cache) in DeveloperJunk.gradleCandidates(home: configuration.home).enumerated() {
                try Task.checkCancellation()
                if index.isMultiple(of: 100) { let path = cache.path.replacingOccurrences(of: configuration.home.path, with: "~"); progress(String(localized: "Inspecting developer caches: \(path)")) }
                add(cache, group: .developerCaches, rule: "gradle-generated-cache", reason: String(localized: "Generated Gradle output unused for at least 30 days. Dependencies, wrappers and configuration are kept."))
            }
            for cache in children(derived.appendingPathComponent("ModuleCache.noindex")) {
                add(cache, group: .developerCaches, rule: "xcode-module-cache", reason: String(localized: "Regenerable compiler module cache unused for at least 30 days."))
            }
            let npm = configuration.home.appendingPathComponent(".npm/_cacache")
            // Measured and removed here rather than by running `brew`: that binary is writable by any process of this user.
            let homebrew = configuration.home.appendingPathComponent("Library/Caches/Homebrew")
            if FileManager.default.fileExists(atPath: homebrew.path) { add(homebrew, group: .developerCaches, rule: "homebrew-cache", reason: String(localized: "Homebrew's download cache, unused for at least 30 days. Installed formulae stay; Homebrew downloads again when needed.")) }
            if FileManager.default.fileExists(atPath: npm.path) { add(npm, group: .developerCaches, rule: "npm-cache", reason: String(localized: "npm's download cache, unused for at least 30 days. npm downloads packages again when needed; projects keep what they installed.")) }
        }
        let sessions = wants(.inactiveDependencies) ? AgentSessionIndex.load(claudeHome: configuration.claudeHome, codexHome: configuration.codexHome) : AgentSessionIndex()
        progress(String(localized: "Inspecting project caches…"))
        // Each project is walked on its own thread; the scan thread reports where they are and passes on a cancel.
        let walkers = DispatchGroup()
        var walking: String?
        for projectRoot in configuration.projectRoots where wants(.projectCaches) || wants(.inactiveDependencies) {
        walkers.enter()
        DispatchQueue.global(qos: self.priority).async {
        defer { walkers.leave() }
        // One thread per root: splitting a root's folders across more threads saved ~0.2 s but doubled kernel CPU (lock contention).
        walk(projectRoot, maximumDepth: 12, excluding: self.configuration.ignoredPaths) { url, names in
            resultLock.lock(); let stop = stopped; resultLock.unlock()
            if stop { return false }
            if url.deletingLastPathComponent().path == projectRoot.path { collect { walking = url.lastPathComponent } }
            let name = url.lastPathComponent
            // Any Python environment (pyvenv.cfg), whatever its name, is installed packages: never walk it.
            if names.contains("pyvenv.cfg") { return false }
            // Idle projects only; an active project's dependencies are never listed.
            if self.wants(.inactiveDependencies) {
                for folder in ["node_modules", "target", ".build"] where names.contains(folder) {
                    let candidate = url.appendingPathComponent(folder, isDirectory: true)
                    if ProjectActivity.dependencyFolder(candidate) {
                        add(candidate, group: .inactiveDependencies, rule: "inactive-dependencies", reason: String(localized: "Project idle for 30+ days. Reinstall with the project's package manager when you need it again."),
                            busy: { ProjectActivity.busyReason(url, activity: activity, sessions: sessions) != nil })
                    }
                }
            }
            guard self.wants(.projectCaches) else { return true }
            if name == "cache" && url.deletingLastPathComponent().lastPathComponent == ".nx" {
                for task in children(url) where !task.lastPathComponent.isEmpty && task.lastPathComponent.allSatisfy(\.isNumber) {
                    add(task, group: .projectCaches, rule: "nx-task-cache", reason: String(localized: "Old Nx task output; current tasks, locks and workspace metadata are preserved."))
                }
                return false
            }
            if name == "cache" && [".next", ".angular"].contains(url.deletingLastPathComponent().lastPathComponent) {
                add(url, group: .projectCaches, rule: "framework-cache", reason: String(localized: "Regenerable framework cache; Git confirms that it is ignored and untracked.")); return false
            }
            if name == "__pycache__" { add(url, group: .projectCaches, rule: "python-bytecode", reason: String(localized: "Compiled Python bytecode. Original .py files stay.")); return false }
            if [".pytest_cache", ".mypy_cache", ".ruff_cache"].contains(name) { add(url, group: .projectCaches, rule: "project-test-cache", reason: String(localized: "Regenerable test or analysis cache.")); return false }
            return true
        }
        }
        }
        if configuration.includeApplicationCaches && wants(.userCaches) {
            progress(String(localized: "Inspecting app caches…"))
            for url in BroadCaches.appCacheCandidates(home: configuration.home) {
                add(url, group: .userCaches, rule: "app-cache", reason: String(localized: "Cache its app rebuilds when needed. Settings, documents and sign-ins are elsewhere."))
            }
            for url in BroadCaches.xdgCandidates(home: configuration.home) {
                add(url, group: .userCaches, rule: "xdg-cache", reason: String(localized: "Command-line tool cache in ~/.cache; downloaded again when needed."))
            }
            progress(String(localized: "Inspecting application web caches…"))
            for location in ApplicationWebCaches.locations {
                let relative = location.path
                for file in children(configuration.home.appendingPathComponent(relative)) where file.lastPathComponent != "index" {
                    add(file, group: .userCaches, rule: "application-web-cache", reason: String(localized: "Old web cache entry; accounts, cookies and application data are preserved."))
                }
            }
        }
        if wants(.userLogs) {
        progress(String(localized: "Inspecting old user logs…"))
        let logs = configuration.home.appendingPathComponent("Library/Logs")
        walk(logs, maximumDepth: 3, includeFiles: true) { url, _ in
            if url.pathExtension == "log" { add(url, group: .userLogs, rule: "old-user-log", reason: String(localized: "Recognised application log older than 30 days; settings and conversation history are kept.")) }
            return true
        }
        }
        if configuration.includeAdditionalLogs && wants(.userLogs) {
        for (bundle, app) in [("com.microsoft.Word", "WORD"), ("com.microsoft.Excel", "EXCEL"), ("com.microsoft.Powerpoint", "POWERPNT")] {
            let diagnostics = configuration.home.appendingPathComponent("Library/Containers/\(bundle)/Data/Library/Logs/Diagnostics/\(app)")
            walk(diagnostics, maximumDepth: 2, includeFiles: true) { url, _ in
                if url.pathExtension == "log" { add(url, group: .userLogs, rule: "old-user-log", reason: String(localized: "Old Office diagnostic log. Documents, recovery files and settings are kept.")) }
                return true
            }
        }
        }
        // App caches, web caches and logs were discovered while the project walk ran; wait for it only now.
        var shown: String?
        while walkers.wait(timeout: .now() + 0.05) == .timedOut {
            if Task.isCancelled { collect { stopped = true }; continue }
            resultLock.lock(); let now = walking; resultLock.unlock()
            if let now, now != shown { progress(String(localized: "Inspecting project caches: \(now)…")); shown = now }
        }
        try Task.checkCancellation()
        resultLock.lock(); let total = planned, done = completed, limited = checklistLimited; resultLock.unlock()
        if limited { collect { notices.append(String(localized: "The scan checklist reached \(checkLimit) checks. Some candidates were not inspected; narrow the selected locations and scan again.")) } }
        // Checks already finished during discovery count straight away.
        status(ScanProgress(message: String(localized: "Checking discovered items…"), completed: done, total: total))
        var reported = (done, String?.none)
        while running.wait(timeout: .now() + 0.05) == .timedOut {
            if Task.isCancelled { collect { stopped = true }; continue }
            resultLock.lock(); let now = (completed, latest), step = latestStep; resultLock.unlock()
            if now != reported, let label = now.1 { status(ScanProgress(message: label, completed: now.0, total: total, step: step)); reported = now }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        if !activity.reliable { notices.append(String(localized: "Open-file inspection was incomplete. Automatic cleanup will remain blocked until it can be verified.")) }
        status(ScanProgress(message: String(localized: "Checking discovered items…"), completed: total, total: total))
        let unique = Dictionary(findings.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        try Task.checkCancellation()
        return ScanReport(home: configuration.home.path, findings: XcodeStorageInventory.countingNestedCachesOnce(Array(unique.values)).sorted { $0.bytes > $1.bytes }, notices: notices)
    }
    private func worktreeFindings(activity: ActivitySnapshot) -> [Finding] {
        let sessions = AgentSessionIndex.load(claudeHome: configuration.claudeHome, codexHome: configuration.codexHome)
        let roots = configuration.projectRoots + [configuration.codexHome.appendingPathComponent("worktrees"), configuration.claudeHome.appendingPathComponent("worktrees")]
        var candidates = [URL]()
        for root in roots {
        walk(root, maximumDepth: 4, excluding: configuration.ignoredPaths) { url, names in
            if names.contains(".git") { candidates.append(url); return false }
            return true
        }
        }
        // Every git call and folder size below is independent, so they run side by side.
        let repositories = parallelMap(Array(Set(candidates))) { git($0, ["rev-parse", "--git-common-dir"]).code == 0 ? $0 : nil }.compactMap { $0 }
        let lists = parallelMap(repositories) { git($0, ["worktree", "list", "--porcelain"]) }
        var paths = [String](), seen = Set<String>()
        for list in lists where list.code == 0 {
            for block in list.output.components(separatedBy: "\n\n").dropFirst() {
                let pairs = block.split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).map(String.init) }
                let info = Dictionary(pairs.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }, uniquingKeysWith: { first, _ in first })
                guard let path = info["worktree"], FileManager.default.fileExists(atPath: path), !configuration.ignoredPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }), seen.insert(path).inserted else { continue }
                paths.append(path)
            }
        }
        return parallelMap(paths) { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let verdict = WorktreeReview.assess(path, configuration: configuration, activity: activity, sessions: sessions)
            let merged = verdict.unmerged > 0 ? [] : [verdict.base == "HEAD" ? String(localized: "Merged into the primary checkout.") : String(localized: "Merged into \(verdict.base).")]
            let reason = verdict.blocker ?? (merged + verdict.warnings).joined(separator: " ")
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return Finding(path: path, group: .worktrees, bytes: directoryBytes(url), modifiedAt: values?.contentModificationDate ?? Date(), safety: verdict.blocker == nil ? .review : .protected, reason: reason, rule: "worktree-review-only", fingerprint: verdict.fingerprint, lastUsedAt: verdict.lastUsed, warnings: verdict.warnings)
        }
    }
}
/// `map` with every element on its own thread, results in order.
func parallelMap<T, R>(_ items: [T], _ transform: (T) -> R) -> [R] {
    var results = [R?](repeating: nil, count: items.count)
    results.withUnsafeMutableBufferPointer { out in DispatchQueue.concurrentPerform(iterations: items.count) { out[$0] = transform(items[$0]) } }
    return results.map { $0! }
}
func children(_ url: URL) -> [URL] {
    let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])) ?? []
    // Foundation may rewrite /private/var to /var. Keep the caller's parent
    // spelling so fixed-location policies compare the same path consistently.
    return entries.map { $0.deletingLastPathComponent().path == url.path ? $0 : url.appendingPathComponent($0.lastPathComponent) }
}
/// `parallelDepth` walks the first levels' folders side by side; `visit` must then be safe to call from several threads.
func walk(_ root: URL, maximumDepth: Int, includeFiles: Bool = false, excluding: [String] = [], parallelDepth: Int = 0, visit: (URL, Set<String>) -> Bool) {
    let blocked: Set<String> = [".git", "node_modules", "vendor", ".venv", "venv", "Pods", "SourcePackages", ".build", "Archives", "wp-includes", "wp-content", "output", "storage", "build", "dist", "target", ".tools", ".yarn", ".gradle", ".kotlin", "DerivedData", "site-packages"]
    let excludedPaths = excluding.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
    // Symlinks are never followed, so a folder's real path is its parent's plus its name: resolved once, at the root.
    // readdir's d_type says what each entry is, so nothing is stat'ed unless the filesystem does not say (DT_UNKNOWN).
    func descend(_ url: URL, _ resolved: String, _ depth: Int, _ known: UInt8) {
        if Task.isCancelled || depth > maximumDepth { return }
        if excludedPaths.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) { return }
        var type = known
        if type == UInt8(DT_UNKNOWN) {
            var info = stat(); guard lstat(url.path, &info) == 0 else { return }
            let mode = info.st_mode & S_IFMT
            type = mode == S_IFDIR ? UInt8(DT_DIR) : mode == S_IFLNK ? UInt8(DT_LNK) : UInt8(DT_REG)
        }
        if type == UInt8(DT_LNK) { return }
        guard type == UInt8(DT_DIR) else { if includeFiles { _ = visit(url, []) }; return }
        var entries = [(String, UInt8)]()
        if let dir = opendir(url.path) {
            while let entry = readdir(dir) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
                if name == "." || name == ".." { continue }
                var type = entry.pointee.d_type
                if type == UInt8(DT_UNKNOWN) {
                    var info = stat()
                    if lstat(url.path + "/" + name, &info) == 0 { let mode = info.st_mode & S_IFMT; type = mode == S_IFDIR ? UInt8(DT_DIR) : mode == S_IFLNK ? UInt8(DT_LNK) : UInt8(DT_REG) }
                }
                // FileManager hid AppleDouble files ("._name") that are not folders; the walk keeps seeing what it saw.
                if name.hasPrefix("._") && type != UInt8(DT_DIR) { continue }
                entries.append((name, type))
            }
            closedir(dir)
        }
        guard visit(url, Set(entries.map(\.0))) else { return }
        let next = entries.filter { !blocked.contains($0.0) }
        func step(_ child: (String, UInt8)) { descend(url.appendingPathComponent(child.0, isDirectory: child.1 == UInt8(DT_DIR)), resolved + "/" + child.0, depth + 1, child.1) }
        if depth < parallelDepth { DispatchQueue.concurrentPerform(iterations: next.count) { step(next[$0]) } }
        else { for child in next { step(child) } }
    }
    descend(root, root.standardizedFileURL.resolvingSymlinksInPath().path, 0, UInt8(DT_UNKNOWN))
}
/// A value computed on another thread; reading it waits until it is ready.
final class Pending<Value>: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private var result: Value?
    init(_ qos: DispatchQoS.QoSClass = .utility, _ make: @escaping () -> Value) { DispatchQueue.global(qos: qos).async { self.result = make(); self.ready.signal() } }
    /// The semaphore hands the result across threads; each reader passes the signal on.
    var value: Value { ready.wait(); ready.signal(); return result! }
}

private final class ScanTextProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var wasKnown = false
    func shouldPublish(_ value: ScanProgress) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date(), known = value.total != nil
        guard now.timeIntervalSince(last) >= 0.10 || known && !wasKnown || value.fraction == 1 else { return false }
        last = now; wasKnown = known; return true
    }
}

/// How many scan checks may run at once without making the Mac feel slow.
enum ScanPacing {
    static func workers(processInfo: ProcessInfo = .processInfo) -> Int {
        if processInfo.isLowPowerModeEnabled { return 1 }
        switch processInfo.thermalState {
        case .serious, .critical: return 1
        case .fair: return 2
        // Checks are bound by filesystem locks in the kernel, not by cores: past 4 workers a scan got no faster
        // (M3 Max: 3.5 s at 4 vs 3.8 s at 7) while kernel CPU nearly doubled (9 s vs 16–20 s).
        default: return min(4, max(2, processInfo.activeProcessorCount / 2))
        }
    }
}
