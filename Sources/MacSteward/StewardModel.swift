import SwiftUI
import Combine
import AppKit
import MacStewardCore

@MainActor
final class StewardModel: ObservableObject {
    @Published private(set) var textScale = min(2, max(1, StewardPreferences.defaults.double(forKey: "textScale")))
    func setTextScale(_ value: Double) {
        textScale = min(2, max(1, value))
        StewardPreferences.defaults.set(textScale, forKey: "textScale")
    }
    func changeTextScale(_ delta: Double) { setTextScale((textScale * 100 + delta * 100).rounded() / 100) }
    @Published var section = "Overview" { didSet { if section != cameFrom?.to { cameFrom = nil } } }
    /// A page opened from inside another one, so it can show the way back. Going anywhere else forgets it.
    @Published private(set) var cameFrom: (from: String, to: String)?
    func openPage(_ target: String) { let from = section; section = target; cameFrom = (from, target) }
    func goBack() { if let from = cameFrom?.from { section = from } }
    /// Settings hosts General, Automation and Activity as tabs.
    @Published var settingsTab = "General"
    let access = FolderAccess()
    let memory = MemoryMonitor()
    let dashboard = MacDashboardMonitor()
    let health: MacHealthMonitor
    let keeper = SpaceKeeperRunner()
    let largeFileLocation = ToolFolderSelection()
    let largeFiles = LargeFilesState()
    let trashBins = TrashBinsState()
    let leftovers = LeftoversState()
    let startup = StartupState()
    let browsers = BrowserDataState()
    let iphone = IPhoneState()
    let status = StatusState()
    let updates = UpdateChecker()
    private var forwarding = [AnyCancellable]()
    /// Module summaries read these tool states, so their changes must refresh views observing the model.
    init() {
        health = MacHealthMonitor(dashboard: dashboard, memory: memory)
        let tools: [AnyPublisher<Void, Never>] = [largeFiles.objectWillChange.map { _ in }.eraseToAnyPublisher(), trashBins.objectWillChange.map { _ in }.eraseToAnyPublisher(), leftovers.objectWillChange.map { _ in }.eraseToAnyPublisher(), startup.objectWillChange.map { _ in }.eraseToAnyPublisher(), updates.objectWillChange.map { _ in }.eraseToAnyPublisher(), browsers.objectWillChange.map { _ in }.eraseToAnyPublisher(), iphone.objectWillChange.map { _ in }.eraseToAnyPublisher()]
        forwarding = tools.map { $0.receive(on: RunLoop.main).sink { [weak self] in self?.objectWillChange.send() } }
        // Memory refreshes every second or two; the summary only needs an occasional update.
        forwarding.append(health.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() })
        forwarding.append(keeper.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() })
        // Keep space free checks every disk reading the dashboard and health monitor take (every 20 s in the background).
        forwarding.append(dashboard.$sample.compactMap { $0?.disk }.receive(on: RunLoop.main).sink { [weak self] disk in
            guard let self else { return }
            self.keeper.consider(disk: disk, configuration: self.configuration, busy: self.busy || self.scanning || self.cleaning != nil || self.removal != nil)
        })
        health.quitIdleApps = { [weak self] in self?.quitIdleAppsOnStage() }
        forwarding.append(memory.objectWillChange.throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true).sink { [weak self] _ in self?.objectWillChange.send() })
    }
    @Published var uninstall: UninstallFlow?
    @Published var welcoming = WelcomeStage.shouldShow
    /// How far the window has filled during the first-launch welcome.
    @Published var welcomeReveal: CGFloat = WelcomeStage.shouldShow ? 0 : 1
    struct WorktreeCandidate: Identifiable { let finding: Finding; let assessment: WorktreeAssessment; var id: String { finding.id } }
    struct WorktreeBatch: Identifiable { let id = UUID(); let candidates: [WorktreeCandidate]; let blocked: [String] }
    @Published var worktreeBatch: WorktreeBatch?
    @Published var worktreeChoice = Set<String>()
    /// Finished worktrees ticked in the list; the review sheet rechecks them.
    @Published var worktreeSelection = Set<String>()
    var removalQueue: [() -> Void] = []
    static func inUse(_ finding: Finding) -> Bool { finding.lastUsedAt.map { Date().timeIntervalSince($0) < 86_400 } ?? false }
    @Published var trashLocations: [String] = []
    @Published var report: ScanReport?
    @Published var selected = Set<String>()
    @Published var busy = false
    /// A read-only duplicates or system check is running (not a removal), so pages show the scan stage.
    @Published private(set) var checking = false
    private var checkTask: Task<Void, Never>?
    /// Cancels the detached search itself; cancelling `checkTask` alone wouldn't reach it.
    private var checkStop: (() -> Void)?
    private var checkRun: UUID?
    /// Stops a duplicates or system check. The duplicates search stops between files; a system read is just ignored.
    func stopChecks() {
        checkStop?(); checkStop = nil; checkTask?.cancel(); checkTask = nil; checkRun = nil
        busy = false; checking = false; progress = String(localized: "Stopped. Nothing was changed.")
    }
    @Published var scanProgress: ScanProgress?
    @Published var progress = String(localized: "Your files stay yours.")
    @Published var error: String?
    @Published var receipt: CleanupReceipt?
    /// Non-nil while the cleaning screen is shown, including its finished state.
    @Published var cleaning: CleanProgress?
    /// A move to the Trash in progress or just finished; see RemovalStage.swift.
    @Published var removal: RemovalProgress?
    var removalStop: StopFlag?
    @Published var stoppingClean = false
    /// Shown on the start screens after a cleanup, until the next scan.
    @Published var lastFreed: UInt64?
    /// Overview's light checks of the other modules: apps unused 6+ months and background agents.
    @Published var unusedApps: Int?
    @Published var agentCount: Int?
    /// Leaving the success screen keeps the scan: cleaned items are already gone from it, so the person carries on with the rest.
    func finishCleaning(thenShow next: String? = nil) {
        if let done = cleaning { lastFreed = done.freedBytes }
        if stoppingClean { removalQueue = [] } // Stop means stop, including what was queued after this.
        cleaning = nil; stoppingClean = false
        if let next { section = next }
        runNextRemoval()
    }
    private var cleanTask: Task<CleanupReceipt, Error>?
    func stopCleaning() { stoppingClean = true; cleanTask?.cancel() }
    @Published var disk = DiskSpace.read()
    @Published var checks = [SecurityCheck]()
    @Published var duplicates = [DuplicateGroup]()
    @Published var duplicateChecked = false
    @Published var duplicateChoice = Set<String>()
    /// The copy each duplicate group keeps, worked out once in the background after a scan.
    private(set) var duplicateKeep = [String: String]()
    /// Every copy except the kept one. Instant: no disk reads, safe in button actions.
    func extraCopies(_ groups: [DuplicateGroup]) -> Set<String> { DuplicateGroup.extras(groups, keeping: duplicateKeep) }
    func keptCopy(_ group: DuplicateGroup) -> String { duplicateKeep[group.id].flatMap { group.files.contains($0) ? $0 : nil } ?? group.files[0] }
    @Published var agents = [BackgroundItem]()
    @Published var appFindings = [AppTrustFinding]()
    @Published var appsChecked = 0
    @Published var checkingApps = false
    private var appAuditRun: UUID?
    var protections: (on: Int, total: Int) { let counted = checks.filter(\.counts); return (counted.filter { $0.status == .good }.count, counted.count) }
    /// A scan waiting behind the Full Disk Access panel.
    @Published var accessGate: (() -> Void)?
    private var accessGateAnswered = false
    /// Scans that would miss protected folders ask first, once per launch. Without access they still run.
    func withFullDisk(_ start: @escaping () -> Void) {
        guard !accessGateAnswered, !UserDefaults.standard.bool(forKey: "fullDiskAccessBannerDismissed"), FullDiskAccess.status() == .denied else { start(); return }
        accessGate = start
    }
    func finishAccessGate(forever: Bool = false) {
        accessGateAnswered = true
        if forever { UserDefaults.standard.set(true, forKey: "fullDiskAccessBannerDismissed") }
        let start = accessGate; accessGate = nil; start?()
    }
    @Published var fixing = false
    /// A button press, then macOS's password dialog. The page then shows what the Mac reports, not what was asked for.
    func apply(_ fix: SystemFix) {
        guard !fixing else { return }; fixing = true; error = nil
        Task {
            let (result, fresh) = await Task.detached(priority: .userInitiated) { (SystemAudit.apply(fix), SystemAudit.checks()) }.value
            checks = fresh; fixing = false
            if result == .failed { error = String(localized: "macOS didn't make that change. Nothing else was touched.") }
        }
    }
    /// Coming back from System Settings: a change made there shows straight away. Quiet, no stage.
    func refreshChecks() {
        guard !checks.isEmpty, !checking, !fixing, !scanning else { return }
        Task {
            let fresh = await Task.detached(priority: .utility) { SystemAudit.checks() }.value
            if !checking && !fixing { checks = fresh }
        }
    }
    /// About a second per app, so it runs after the page is up; its tile fills in when it's done.
    func auditApps() {
        let id = UUID(); appAuditRun = id; checkingApps = true
        Task {
            let result = await Task.detached(priority: .utility) { AppTrust.audit() }.value
            guard appAuditRun == id else { return }
            appsChecked = result.checked; appFindings = result.findings; checkingApps = false
        }
    }
    // A filter typed for one list would otherwise hide everything in the next one.
    @Published var group: CleanupGroup = .agentBuilds { didSet { search = "" } }
    @Published var showAllFindings = true { didSet { search = "" } }
    var reviewGroups: [CleanupGroup] {
        let general: [CleanupGroup] = [.userCaches, .userLogs]
        return general + CleanupGroup.allCases.filter { candidate in
            !general.contains(candidate) && ((report?.findings.contains { $0.group == candidate } ?? false) || (!showAllFindings && group == candidate))
        }
    }
    var reviewSelectionID: String { showAllFindings ? "all" : group.id }
    var overview: ScanOverview { ScanOverview(findings: report?.findings ?? []) }
    /// Asks the apps owning these cache folders to quit normally (they may ask to save) and waits up to 10 s.
    /// An app still running then simply keeps its cache: the cleaner skips it as in use.
    static func appsOwning(caches: [String]) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && app.processIdentifier != getpid() && app.bundleIdentifier != "com.apple.finder"
                && caches.contains { BroadCaches.quitsFor(cache: $0, bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "") }
        }
    }
    static func quitOwners(ofCaches caches: [String]) async {
        let apps = appsOwning(caches: caches)
        apps.forEach { _ = $0.terminate() }
        for _ in 0..<20 where apps.contains(where: { !$0.isTerminated }) { try? await Task.sleep(for: .milliseconds(500)) }
    }
    func review(_ group: CleanupGroup? = nil) {
        if let group { self.group = group; showAllFindings = false }
        else { showAllFindings = true }
        section = "Cleanup"
    }
    @Published var search = ""
    @Published var scheduleEnabled = Scheduler.isInstalled
    @Published var ignores: [String] = StewardPreferences.defaults.stringArray(forKey: "ignoredPaths") ?? []
    @Published var includeDeveloperCaches = StewardPreferences.defaults.object(forKey: "includeDeveloperCaches") as? Bool ?? true
    @Published var includeAdditionalLogs = StewardPreferences.defaults.object(forKey: "includeAdditionalLogs") as? Bool ?? true
    @Published var includeAppCaches = StewardPreferences.defaults.object(forKey: "includeAppCaches") as? Bool ?? true
    @Published private var scanTask: Task<ScanReport, Error>?
    @Published private var scanRunID: UUID?
    var scanning: Bool { scanRunID != nil }
    var waitingForCancelledScan: Bool { scanTask != nil && scanRunID == nil }
    var configuration: Configuration { Configuration(ignoredPaths: ignores + access.excludedProjects, includeApplicationCaches: includeAppCaches, includeDeveloperCaches: includeDeveloperCaches, includeAdditionalLogs: includeAdditionalLogs, projectRoots: access.scanProjectURLs, claudeHome: access.url(for: .claude), codexHome: access.url(for: .codex)) }
    /// Ticked items the cleaner may take: automatic ones, plus held ones the user chose (recent, or with an app to quit).
    var selectedFindings: [Finding] { report?.findings.filter { selected.contains($0.id) && $0.userCleanable && (showAllFindings || $0.group == group) } ?? [] }
    /// Apps that must quit before their ticked caches can be cleaned.
    /// The same list `quitOwners` acts on, so the confirmation names every app that will be asked to quit.
    func appsToQuit(_ items: [Finding]) -> [String] {
        let caches = items.filter { $0.hold == .inUse && $0.owner != nil }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        return caches.isEmpty ? [] : Array(Set(Self.appsOwning(caches: caches).compactMap(\.localizedName))).sorted()
    }
    /// Everything ticked on every page: the one Remove selected button takes all of it, whichever category is open.
    var chosenCaches: [Finding] { report?.findings.filter { selected.contains($0.id) && $0.userCleanable && $0.group != .worktrees } ?? [] }
    var chosenWorktrees: [Finding] { reviewableWorktrees.filter { worktreeSelection.contains($0.id) } }
    enum FindingOrder: String, CaseIterable { case largest, newest, oldest, name }
    @Published var findingOrder = FindingOrder.largest
    @Published var onlySelected = false
    var groupFindings: [Finding] {
        let shown = report?.findings.filter { (showAllFindings || $0.group == group) && (search.isEmpty || $0.path.localizedCaseInsensitiveContains(search))
            && (!onlySelected || ($0.group == .worktrees ? worktreeSelection : selected).contains($0.id)) } ?? []
        switch findingOrder {
        case .largest: return shown // The scan already sorts by size.
        case .newest: return shown.sorted { $0.modifiedAt > $1.modifiedAt }
        case .oldest: return shown.sorted { $0.modifiedAt < $1.modifiedAt }
        case .name: return shown.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
    /// Folder totals reused between scans in this session while FSEvents shows them unchanged.
    nonisolated static let treeSummaries = TreeSummaryCache()
    static let junkGroups: Set<CleanupGroup> = Set(CleanupGroup.allCases).subtracting([.worktrees])
    /// The Cleanup module: caches, logs and AI leftovers plus worktrees, in one scan.
    static let cleanupGroups: Set<CleanupGroup> = Set(CleanupGroup.allCases)
    /// Keep space free couldn't free enough alone: show everything a person can choose to remove, largest first.
    func reviewLowSpace() {
        section = "Cleanup"; review()
        scan(only: Self.cleanupGroups)
    }
    /// Runs only one tool's groups; nil scans everything (Overview).
    func scan(allTools: Bool = false, only groups: Set<CleanupGroup>? = nil) {
        guard !welcoming else { return }
        guard !busy else { return }
        guard scanTask == nil else { error = String(localized: "macOS has not finished the previous folder inspection yet. You can browse other sections while it returns."); return }
        busy = true; error = nil; lastFreed = nil; scanCompleteShown = false; progress = String(localized: "Preparing scan…"); scanProgress = ScanProgress(message: progress)
        let config = configuration
        let runID = UUID(); scanRunID = runID
        let receiver = self
        let relay = ScanProgressRelay(pending: allTools ? 2 : 0)
        // Read alongside the scan: read after it, they kept the app busy another 0.1–0.5 s.
        let inventory = allTools ? Task.detached(priority: .utility) { (ApplicationInventory.scan(), BackgroundInventory.scan().filter { $0.scope == "Your account" }.count) } : nil
        let task = Task.detached(priority: .userInitiated) {
            // The system checks and the duplicate search run alongside project discovery and the main scan.
            // Duplicates are searched across the whole home folder; macOS and app bundles hold intentional copies.
            let downloads: URL? = allTools ? config.home : nil
            async let system = allTools ? (SystemAudit.checks(), BackgroundInventory.scan()) : nil
            async let duplicateSearch = downloads.map { folder in Result { try DuplicateFinder.scan(folder: folder) } }
            let known = KnownProjectDiscovery.discover(home: config.home, claudeHome: config.claudeHome, codexHome: config.codexHome)
            try Task.checkCancellation()
            await MainActor.run { if receiver.scanRunID == runID { receiver.access.acceptKnownProjects(known) } }
            var scanConfig = config
            scanConfig.projectRoots = Configuration.canonicalProjectRoots(config.projectRoots + known.map(\.url))
            let report = try Scanner(configuration: scanConfig, groups: groups, summaries: StewardModel.treeSummaries, priority: .userInitiated).scanWithProgress { update in
                relay.receive(update) { event in
                    Task { @MainActor in receiver.receiveScanProgress(event, runID: runID) }
                }
            }
            if allTools, let (checks, background) = await system {
                await MainActor.run { if receiver.scanRunID == runID { receiver.receiveScanProgress(relay.extra(completed: 0, message: String(localized: "Checking system settings…")), runID: runID) } }
                try Task.checkCancellation()
                await MainActor.run { if receiver.scanRunID == runID { receiver.checks = checks; receiver.agents = background; receiver.auditApps(); receiver.receiveScanProgress(relay.extra(completed: 1, message: String(localized: "Searching for duplicates…")), runID: runID) } }
                do {
                    guard let search = await duplicateSearch else {
                        await MainActor.run { receiver.receiveScanProgress(relay.extra(completed: 2, message: String(localized: "Duplicate search skipped — no folder selected.")), runID: runID) }
                        return ScanReport(home: report.home, findings: report.findings, notices: report.notices + [String(localized: "The duplicate search was skipped because no folder has been chosen. Open Tools > Duplicates to choose one. Other checks are complete.")])
                    }
                    let duplicates = try search.get()
                    let keep = DuplicateGroup.oldestCopies(duplicates)
                    try Task.checkCancellation()
                    await MainActor.run { if receiver.scanRunID == runID { receiver.duplicates = duplicates; receiver.duplicateKeep = keep; receiver.duplicateChoice = DuplicateGroup.extras(duplicates, keeping: keep); receiver.duplicateChecked = true; receiver.receiveScanProgress(relay.extra(completed: 2, message: String(localized: "All checks complete.")), runID: runID) } }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    await MainActor.run { receiver.receiveScanProgress(relay.extra(completed: 2, message: String(localized: "Duplicate search finished with an access notice.")), runID: runID) }
                    return ScanReport(home: report.home, findings: report.findings, notices: report.notices + [String(localized: "Duplicate search: \(error.localizedDescription)")])
                }
            }
            return report
        }
        scanTask = task
        Task {
            do {
                let result = try await task.value
                guard scanRunID == runID else { scanTask = nil; return }
                let total = relay.fullTotal
                receiveScanProgress(ScanProgress(message: String(localized: "Scan complete."), completed: total, total: total), runID: runID)
                scanCompleteShown = true
                try? await Task.sleep(for: .milliseconds(240))
                guard scanRunID == runID else { scanTask = nil; return }
                // A focused scan replaces only its own groups and keeps the other tools' results.
                let kept = groups.map { only in report?.findings.filter { !only.contains($0.group) } ?? [] } ?? []
                report = ScanReport(home: result.home, findings: (kept + result.findings).sorted { $0.bytes > $1.bytes }, notices: result.notices)
                if allTools {
                    // Smart Care-style overview: a quick look at each module, no permission prompts.
                    leftovers.scan(); browsers.scan(); Task { await memory.refresh() }
                    if let (apps, agents) = await inventory?.value {
                        unusedApps = apps.filter { ($0.lastUsed ?? .distantPast) < Date().addingTimeInterval(-180 * 86400) }.count; agentCount = agents
                    }
                }
                // Dependencies of idle projects are offered, never pre-ticked.
                selected = Set(report?.findings.filter { $0.safety == .automatic && $0.group != .inactiveDependencies }.map(\.id) ?? []); disk = .read()
                worktreeSelection = []; unlockedWorktrees = [] // Worktrees are offered, never pre-ticked: deleting one is permanent.
                progress = String(localized: "Scan complete. Nothing has been removed.")
            } catch is CancellationError {
                guard scanRunID == runID else { scanTask = nil; return }
                progress = String(localized: "Scan cancelled. Nothing was removed.")
            } catch {
                guard scanRunID == runID else { scanTask = nil; return }
                self.error = error.localizedDescription
            }
            busy = false; scanTask = nil; scanRunID = nil
        }
    }
    /// Set once the "Scan complete." line is shown, so late progress events cannot replace it.
    private var scanCompleteShown = false
    private func receiveScanProgress(_ update: ScanProgress, runID: UUID) {
        guard scanRunID == runID, !scanCompleteShown else { return }
        if let current = scanProgress, let oldTotal = current.total {
            guard let total = update.total, total == oldTotal, update.completed >= current.completed else { return }
        }
        scanProgress = update; progress = update.message
    }
    func cancelScan() {
        scanTask?.cancel()
        // File-system calls may remain in macOS until a permission/provider request returns.
        // Stop the visible operation immediately and discard every late callback/result.
        scanRunID = nil; busy = false
        progress = String(localized: "Scan cancelled. Nothing was removed.")
    }
    func setCategory(_ group: CleanupGroup?, selected: Bool) { setSelected(choosable(group), selected) }
    func categorySelected(_ group: CleanupGroup?) -> Bool { allSelected(choosable(group)) }
    /// What a checkbox takes. A worktree in use is never bulk-selected; each chosen one is rechecked with Git before it goes.
    func choosable(_ group: CleanupGroup?) -> [Finding] { (report?.findings ?? []).bulkChoosable(in: group).filter { $0.group != .worktrees || !Self.inUse($0) } }
    /// The review page's bar acts on what the filter shows, never on hidden rows.
    var bulkScope: [Finding] { choosable(showAllFindings ? nil : group).filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) } }
    func allSelected(_ items: [Finding]) -> Bool { !items.isEmpty && items.allSatisfy { ($0.group == .worktrees ? worktreeSelection : selected).contains($0.id) } }
    func setSelected(_ items: [Finding], _ on: Bool) {
        let trees = Set(items.filter { $0.group == .worktrees }.map(\.id)), rest = Set(items.map(\.id)).subtracting(trees)
        if on { worktreeSelection.formUnion(trees); selected.formUnion(rest) } else { worktreeSelection.subtract(trees); selected.subtract(rest) }
    }
    /// Ticks only what's certain in `items` and unticks the rest, so the selection is exactly the safe part.
    func smartSelect(_ items: [Finding]) {
        setSelected(items, false)
        setSelected(items.filter(\.certain), true)
    }
    var reviewableWorktrees: [Finding] { report?.findings.filter { $0.group == .worktrees && ($0.safety == .review || unlockedWorktrees.contains($0.id)) } ?? [] }
    /// Worktrees kept only because a process has them open, which the person unlocked to delete anyway. Git still rechecks them first.
    @Published var unlockedWorktrees = Set<String>()
    func unlock(_ finding: Finding) {
        guard finding.group == .worktrees, finding.hold == .inUse else { return }
        unlockedWorktrees.insert(finding.id); worktreeSelection.insert(finding.id)
    }
    /// Rechecks each worktree, then opens one sheet. Clean ones start ticked; ones with warnings start unticked.
    func requestWorktreeRemoval(_ findings: [Finding]) {
        guard !busy, !findings.isEmpty else { return }; busy = true; progress = String(localized: "Rechecking worktrees with Git…")
        let config = configuration
        Task {
            let results = await Task.detached(priority: .utility) { WorktreeReview.validate(findings, configuration: config) }.value
            let checked: [(WorktreeCandidate?, String?)] = zip(findings, results).map { finding, result in
                switch result {
                case .success(let assessment): return (WorktreeCandidate(finding: finding, assessment: assessment), nil)
                case .failure(let error): return (nil, String(localized: "\(finding.title): \(error.localizedDescription)"))
                }
            }
            let candidates = checked.compactMap(\.0), blocked = checked.compactMap(\.1)
            if candidates.isEmpty { error = blocked.joined(separator: "\n") }
            // The person already chose these, so they stay ticked. Only a worktree that would lose work Git can't restore starts unticked.
            else { worktreeChoice = Set(candidates.filter { !$0.assessment.losesWork }.map(\.id)); worktreeBatch = WorktreeBatch(candidates: candidates, blocked: blocked) }
            progress = String(localized: "Nothing was removed."); busy = false
            if candidates.isEmpty { runNextRemoval() }
        }
    }
    func trashChosenWorktrees() {
        guard !busy, let batch = worktreeBatch else { return }
        let chosen = batch.candidates.filter { worktreeChoice.contains($0.id) }.map(\.finding)
        busy = true; worktreeBatch = nil
        let config = configuration
        let box = WorktreeResults()
        // On the stage, one worktree at a time: each is rechecked with Git right before it goes, and Stop leaves the rest.
        runStage(.worktrees, total: chosen.count, first: chosen.first?.title ?? "", work: { report, stop in
            var freed: UInt64 = 0
            let results = WorktreeReview.delete(chosen, configuration: config, progress: { done, title in
                // counts a worktree's size as it's handled; the final total counts only the ones actually deleted.
                freed = chosen.prefix(done).reduce(0) { $0 + $1.bytes }; report(done, freed, title)
            }, shouldStop: { stop.isSet })
            box.set(results)
            let deleted = zip(chosen, results).filter { if case .success = $0.1 { return true } else { return false } }
            return StageOutcome(completed: results.count, bytes: deleted.reduce(0) { $0 + $1.0.bytes },
                                failures: zip(chosen, results).compactMap { finding, result in if case .failure(let error) = result { return String(localized: "\(finding.title) · \(error.localizedDescription)") } else { return nil } })
        }, completed: { [weak self] _ in self?.finishWorktreeRemoval(chosen, box.value) })
    }
    private func finishWorktreeRemoval(_ chosen: [Finding], _ results: [Result<WorktreeRemoval, Error>]) {
        var moved = [String](), kept = [String](), branches = [String]()
        for (finding, result) in zip(chosen, results) {
            switch result {
            case .success(let removal):
                moved.append(finding.id)
                if let branch = removal.branch { branches.append(removal.branchDeleted ? String(localized: "\(branch) (was \(String(removal.head.prefix(10))))") : String(localized: "\(branch) kept")) }
            case .failure(let error): kept.append(String(localized: "\(finding.title): \(error.localizedDescription)"))
            }
        }
        if let report { self.report = ScanReport(home: report.home, findings: report.findings.filter { !moved.contains($0.id) }, notices: report.notices) }
        worktreeSelection.subtract(moved); unlockedWorktrees.subtract(moved)
        let deleted = String(localized: "\(moved.count) worktrees deleted.")
        progress = branches.isEmpty ? deleted : deleted + " " + String(localized: "Branches: \(branches.joined(separator: ", ")). Restore one with git branch <name> <commit>.")
        if !kept.isEmpty { error = String(localized: "Kept because they changed or could not be verified:\n\(kept.joined(separator: "\n"))") }
        disk = .read(); busy = false
    }

    /// Cleans `items`, or what's ticked in the open category. Other ticks stay, so the person can carry on afterwards.
    func clean(_ items: [Finding]? = nil) {
        let chosen = items ?? selectedFindings
        guard !busy, let report, !chosen.isEmpty else { return }
        busy = true; progress = String(localized: "Rechecking each selected item before removal…"); error = nil
        let config = configuration; let ids = Set(chosen.map(\.id))
        // Held items are cleaned only because the user ticked them; the cleaner still rechecks each one.
        let approved = Set(chosen.filter { $0.safety != .automatic }.map(\.id))
        let quitting = chosen.filter { $0.hold == .inUse && $0.owner != nil }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        cleaning = CleanProgress(completed: 0, total: ids.count, current: quitting.isEmpty ? String(localized: "Preparing…") : String(localized: "Quitting \(appsToQuit(chosen).joined(separator: ", "))…"), group: nil, freedBytes: 0, removed: 0, skipped: 0)
        StewardSound.start.play()
        let receiver = self
        Task {
            do {
                if !quitting.isEmpty { await Self.quitOwners(ofCaches: quitting) }
                let work = Task.detached(priority: .utility) {
                    try Cleaner(configuration: config).clean(report, selectedIDs: ids, approvedIDs: approved) { update in Task { @MainActor in if !receiver.stoppingClean || update.finished { receiver.cleaning = update } } }
                }
                cleanTask = work; stoppingClean = false
                let result = try await work.value
                cleanTask = nil
                receipt = result; disk = result.after
                let removed = Set(result.items.filter { $0.outcome == "removed" }.map(\.path))
                self.report = ScanReport(home: report.home, findings: report.findings.filter { !removed.contains($0.path) }, notices: report.notices)
                selected.subtract(removed); progress = String(localized: "\(result.removedCount) items removed. Skipped items are recorded in the receipt.")
                // Finished state stays on screen until the person chooses Done or View receipt.
                let freed = result.items.filter { $0.outcome == "removed" }.reduce(0) { $0 + $1.bytes }
                try? await Task.sleep(for: .milliseconds(200))
                cleaning = CleanProgress(completed: result.items.count, total: result.items.count, current: "", group: nil, freedBytes: freed, removed: result.removedCount, skipped: result.items.count - result.removedCount)
                StewardSound.done.play()
            } catch { self.error = error.localizedDescription; cleaning = nil; removalQueue = [] }
            busy = false
        }
    }
    func checkSystem() {
        guard !busy else { return }; busy = true; checking = true; progress = String(localized: "Reading macOS security settings…")
        let id = UUID(); checkRun = id
        checkTask = Task {
            // Both run tools and read the disk, so neither runs on the main thread. A moment on stage, however fast they are.
            async let pause: Void? = try? Task.sleep(for: .seconds(1.6))
            let (result, background) = await Task.detached { (SystemAudit.checks(), BackgroundInventory.scan()) }.value
            _ = await pause
            guard checkRun == id else { return }
            checks = result; agents = background; auditApps()
            busy = false; checking = false; progress = String(localized: "System settings checked. No settings were changed.")
        }
    }
    /// Reads the files again before the review opens: the list may be from an earlier scan.
    func recheckDuplicates(_ paths: [String], then review: @escaping ([String]) -> Void) {
        guard !busy else { return }
        busy = true; progress = String(localized: "Checking that each copy is still identical…"); error = nil
        let groups = duplicates
        Task {
            let result = await Task.detached(priority: .userInitiated) { (try? DuplicateFinder.stillSafeToTrash(paths, in: groups)) ?? (paths: [], dropped: paths.count) }.value
            busy = false; progress = String(localized: "Review comes before removal.")
            if result.dropped > 0 { error = String(localized: "\(result.dropped) files were left out because the file or the copy being kept changed. Scan again to refresh the list.") }
            if result.paths.isEmpty { runNextRemoval() } else { review(result.paths) }
        }
    }
    /// For items the person already confirmed in one summary: the same safety review as the Trash sheet, without a second sheet.
    /// That sheet warns about cloud files, so here those stay for the person to review.
    func trashConfirmed(_ urls: [URL], allowLeftovers: Bool = false, duplicateGroups: [DuplicateGroup] = [], completed: @escaping ([TrashOutcome]) -> Void) {
        Task {
            let reviewed = await Task.detached(priority: .userInitiated) { ReviewedTrash.reviewUnattended(urls, allowLeftovers: allowLeftovers) }.value
            if reviewed.kept > 0 { error = String(localized: "\(reviewed.kept) items were kept for you to review.") }
            if reviewed.ready.isEmpty { runNextRemoval() }
            else { startRemoval(reviewed.ready, allowApplications: false, allowLeftovers: allowLeftovers, duplicateGroups: duplicateGroups, completed: completed) }
        }
    }
    func removeDuplicates(_ paths: [String]) {
        let gone = Set(paths)
        duplicates = duplicates.compactMap { group in
            let files = group.files.filter { !gone.contains($0) }
            return files.count > 1 ? DuplicateGroup(id: group.id, files: files, size: group.size, projectFiles: group.projectFiles.filter { !gone.contains($0) }) : nil
        }
        duplicateChoice.subtract(gone); disk = .read()
    }
    func scanDuplicates() {
        guard !busy else { return }
        let folder = FileManager.default.homeDirectoryForCurrentUser
        busy = true; checking = true; progress = String(localized: "Comparing files by size and SHA-256…")
        let id = UUID(); checkRun = id
        let search = Task.detached { () -> ([DuplicateGroup], [String: String]) in let groups = try DuplicateFinder.scan(folder: folder); return (groups, DuplicateGroup.oldestCopies(groups)) }
        checkStop = { search.cancel() }
        checkTask = Task {
            do {
                let (found, keep) = try await search.value
                guard checkRun == id else { return }
                duplicates = found; duplicateKeep = keep; duplicateChoice = DuplicateGroup.extras(found, keeping: keep); duplicateChecked = true; progress = String(localized: "Exact duplicate groups found. Original files are unchanged.") }
            catch is CancellationError { return }
            catch { guard checkRun == id else { return }; self.error = error.localizedDescription }
            busy = false; checking = false
        }
    }
    func ignore(_ item: Finding) {
        ignores.append(item.path); StewardPreferences.defaults.set(ignores, forKey: "ignoredPaths"); selected.remove(item.id)
        if let report { self.report = ScanReport(home: report.home, findings: report.findings.filter { $0.path != item.path }, notices: report.notices) }
    }
    func setSchedule(_ enabled: Bool) {
        do {
            if enabled { try Scheduler.enable(helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/stewardctl")) }
            else { try Scheduler.disable() }
            scheduleEnabled = Scheduler.isInstalled
        } catch { self.error = error.localizedDescription; scheduleEnabled = Scheduler.isInstalled }
    }
    func openXcode() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") { NSWorkspace.shared.open(url) }
    }
    /// Terminal runs it, not this app, so a replaced `brew` never gets this app's disk access.
    func runBrewCleanup(cellar: String) {
        guard let script = BroadCaches.brewCleanupScript(cellar: cellar) else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("artifloam-brew-cleanup-\(UUID().uuidString).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, failure in
                if let failure { Task { @MainActor in self.error = failure.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func open(_ url: String) { if let url = URL(string: url) { NSWorkspace.shared.open(url) } }
    func showReceipts() { reveal(NSHomeDirectory() + "/Library/Application Support/MacSteward/Receipts") }
}

private final class ScanProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private let pending: Int
    private var latest = ScanProgress(message: String(localized: "Preparing scan…"))
    private var scheduled = false
    init(pending: Int) { self.pending = pending }
    var fullTotal: Int { lock.lock(); defer { lock.unlock() }; return total + pending }
    func receive(_ update: ScanProgress, deliver: @escaping @Sendable (ScanProgress) -> Void) {
        lock.lock()
        if let count = update.total { total = count }
        latest = update.addingPendingChecks(pending)
        guard !scheduled else { lock.unlock(); return }
        scheduled = true; lock.unlock()
        // Coalesce bursts of small checks without queuing one main-actor task per
        // file. The last actual status is delivered even if the next check is slow.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.07) { [self] in
            lock.lock(); let event = latest; scheduled = false; lock.unlock()
            deliver(event)
        }
    }
    func extra(completed: Int, message: String) -> ScanProgress {
        lock.lock(); defer { lock.unlock() }
        latest = ScanProgress(message: message, completed: total + min(pending, max(0, completed)), total: total + pending, step: .tools)
        return latest
    }
}

/// Hands worktree results from the background stage run back to the model.
private final class WorktreeResults: @unchecked Sendable {
    private let lock = NSLock(); private var results = [Result<WorktreeRemoval, Error>]()
    var value: [Result<WorktreeRemoval, Error>] { lock.lock(); defer { lock.unlock() }; return results }
    func set(_ new: [Result<WorktreeRemoval, Error>]) { lock.lock(); results = new; lock.unlock() }
}
