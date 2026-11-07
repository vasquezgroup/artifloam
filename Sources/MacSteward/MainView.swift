import SwiftUI
import MacStewardCore

private let pageBackground = Color.clear
private let panel = Color.white.opacity(0.045)
private let muted = Color.white.opacity(0.55)

struct MainView: View {
    @EnvironmentObject var m: StewardModel
    @Environment(\.stewardTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navigation
    @State private var hoveredNavigation: String?
    @StateObject private var storageMap = StorageMapModel()
    /// Everything the confirmation shows and runs. One value, so the sheet can't open with older contents.
    @State private var pendingRemoval: PendingRemoval?
    /// What the open confirmation covers when it isn't simply the current selection.
    /// Browser caches are recommended, so they start ticked. Emptying the Trash is permanent, so it never does.
    @State private var browsersTicked = true
    @State private var trashTicked = false
    @State private var duplicateTrash: TrashRequest?
    @State private var worktreeSection = "Finished"
    @State private var clutterTab = "Duplicates"
    /// After a Cleanup scan the summary tiles show first; Review opens the detailed list.
    @State private var cleanupReviewing = false
    /// What Run on the Overview summary includes. Only the safe parts start ticked.
    @State private var runCleanup = true
    @State private var runDuplicates = true
    @State private var runBrowsers = false
    @State private var runLeftovers = false
    @State private var runQuitApps = false
    /// A module opened from an Overview tile; Back returns to the tiles without leaving Overview.
    @State private var overviewDetail: String?
    @State private var performanceTab = "Memory"
    @State private var applicationsTab = "Uninstaller"
    @State private var windowPointer: CGPoint?
    @State private var availableWidth: CGFloat = 1160
    @State private var stageControlsHeight: CGFloat = 0
    /// +1 when the chosen page sits below the current one in the navigation, −1 above, 0 otherwise.
    @State private var navDirection: CGFloat = 0
    /// Counts page changes, so a finished slide only clears state when no newer change has started.
    @State private var navRequest: (id: Int, name: String) = (0, "")
    private var theme: StewardTheme { themeFor(m.section) }
    private func themeFor(_ section: String) -> StewardTheme {
        switch section {
        case "Cleanup": return .cleanup
        case "Trash bins": return .trash
        case "System": return .system
        case "Duplicates", "My Clutter": return .files
        case "Applications": return .system
        case "iPhone": return .iphone
        case "Photos": return .files
        case "Browsers", "Browser data": return .browsers
        case "Worktrees": return .worktrees
        case "Space Map": return .space
        default: return .care
        }
    }
    private var mint: Color { theme.accent }
    private var isIntro: Bool { isIntroPage(m.section) }
    private func isIntroPage(_ section: String) -> Bool {
        if m.scanning { return true }
        switch section {
        case "Overview", "Cleanup", "Worktrees": return m.report == nil
        // Each page stays on its stage while its own tool runs, so every scan looks like the Overview scan.
        case "System": return m.checks.isEmpty || m.checking
        case "Duplicates": return !m.duplicateChecked || m.checking
        case "My Clutter": return (!m.duplicateChecked && m.largeFiles.report == nil) || m.checking || m.largeFiles.task != nil
        case "Applications": return m.leftovers.items == nil || m.leftovers.busy
        case "Login & background items": return !m.startup.checked || m.startup.scanning
        case "Leftovers": return m.leftovers.items == nil || m.leftovers.items?.isEmpty == true || m.leftovers.busy
        case "Browsers": return m.browsers.reports == nil || m.browsers.busy
        // Nothing to show means the start screen's big artwork, saying so, rather than an empty results page.
        case "Trash bins": return m.trashBins.report == nil || m.trashBins.report?.items == 0 || m.trashBins.scanning
        case "iPhone": return m.iphone.onStage
        case "Photos": return PhotosModule.onStage
        default: return false
        }
    }
    /// A single page's tool is running from its start screen (Overview's own scan sets `m.scanning`).
    private var toolRunning: Bool {
        guard isIntro, !m.scanning else { return false }
        if m.health.fixing != nil { return true }
        switch m.section {
        case "Applications", "Leftovers": return m.leftovers.busy
        case "Login & background items": return m.startup.scanning
        case "Browsers": return m.browsers.busy
        case "Trash bins": return m.trashBins.scanning
        case "My Clutter": return m.checking || m.largeFiles.task != nil
        case "iPhone": return m.iphone.reading
        case "Photos": return PhotosModule.working
        default: return m.checking
        }
    }
    /// Any scan the stage should present: centred artwork, the scan loop, no sidebar.
    private var stageWorking: Bool { m.scanning || toolRunning }
    private func stopTool() {
        if m.health.fixing != nil { m.health.stopFixing(); return }
        switch m.section {
        case "Applications", "Leftovers": m.leftovers.stop()
        case "Login & background items": m.startup.stop()
        case "Browsers": m.browsers.stop()
        case "Trash bins": m.trashBins.stop()
        case "My Clutter": m.stopChecks(); m.largeFiles.cancel()
        case "iPhone": m.iphone.stop()
        case "Photos": PhotosModule.stop()
        default: m.stopChecks()
        }
    }
    private var toolProgressText: String {
        if let fixing = m.health.fixing { return fixing.detail }
        switch m.section {
        case "Applications": return String(localized: "Finding unused apps and what removed apps left behind…")
        case "Leftovers": return String(localized: "Comparing Library folders with the apps you have…")
        case "Login & background items": return String(localized: "Reading what starts with your Mac…")
        case "Browsers": return String(localized: "Measuring caches and website data for each browser…")
        case "Trash bins": return String(localized: "Asking Finder what the Trash holds…")
        case "iPhone": return String(localized: "Asking your iPhone for its apps. Keep it unlocked.")
        case "Photos": return PhotosModule.progress
        case "My Clutter" where m.largeFiles.task != nil && !m.checking: return String(localized: "Reading file sizes…")
        default: return m.progress
        }
    }
    private var isSummary: Bool { isSummaryPage(m.section) }
    private func isSummaryPage(_ section: String) -> Bool { !m.scanning && section == "Overview" && m.report != nil && overviewDetail == nil }
    private var isMapStage: Bool { isMapStagePage(m.section) }
    private func isMapStagePage(_ section: String) -> Bool { !m.scanning && section == "Space Map" && (storageMap.snapshot == nil || storageMap.mappingFully) }
    /// A removal has the whole window, so Run can't be pressed again under it.
    private var isStage: Bool { m.removal == nil && m.cleaning == nil && (isIntro || isSummary || isMapStage) }
    /// Scans, Trash moves and cleanups take the whole window: the sidebar hides.
    private var focusedScan: Bool { stageWorking || storageMap.mappingFully || m.removal != nil || m.cleaning != nil }
    private var navigationWidth: CGFloat { focusedScan ? 0 : hideSidebar ? 72 : sidebarWidth }
    private var sidebarWidth: CGFloat { 250 + (textScale - 1) * 80 }
    // Names respond to available width; active scans temporarily hide navigation.
    private var hideSidebar: Bool { availableWidth < 960 + (textScale - 1) * 200 }
    var body: some View {
        HStack(spacing: 0) {
            if !focusedScan {
                Group {
                    if hideSidebar { Color.clear.frame(width: 72).overlay(alignment: .trailing) { sidebarDivider } }
                    else { sidebar }
                }.transition(reduceMotion ? .opacity : .modifier(active: ScanSidebarTransition(progress: 0), identity: ScanSidebarTransition(progress: 1)))
            }
            mainColumn
            // The stage controls float over the bottom 72 pt; reserve their measured height (+12 pt gap) so they never cover the stage.
        }
        .padding(.top, 52)
        // Pages slide within the visible window shape, never past its edges or into the transparent margin below.
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .modifier(WelcomeHidden())
        .padding(.bottom, isStage ? 72 : 0)
        .ignoresSafeArea(edges: .top)
        .background {
            AtmosphereView(theme: theme, scanning: m.scanning || storageMap.busy)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .clipShape(WelcomeReveal(progress: m.welcomeReveal))
                .padding(.bottom, isStage ? 72 : 0)
                .ignoresSafeArea(edges: .top)
        }
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { availableWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in availableWidth = width }
            }
        }
        .environment(\.stewardWindowPointer, windowPointer)
        .background { WindowPointerReader(enabled: isStage && !m.scanning && !reduceMotion) { windowPointer = $0 } }
        .modifier(StewardClearWindowBackground())
        .background(StewardWindowAppearance())
        .overlay { StewardWindowResizeSurface(bottomInset: isStage ? 72 : 0, actionHorizontalOffset: navigationWidth / 2, topTrailingClearance: !focusedScan && m.cleaning == nil ? 250 * textScale : 0) }
        .overlay(alignment: .bottom) {
            if isStage {
                stageControls.modifier(WelcomeHidden()).padding(.leading, navigationWidth).background {
                    GeometryReader { geometry in
                        Color.clear.onAppear { stageControlsHeight = geometry.size.height }
                            .onChange(of: geometry.size.height) { _, height in stageControlsHeight = height }
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if hideSidebar && !focusedScan { compactRail.modifier(WelcomeHidden()).padding(.leading, 13).padding(.top, 66).padding(.bottom, 170) }
        }
        .overlay(alignment: .topTrailing) {
            if !focusedScan && m.cleaning == nil { cornerButtons.modifier(WelcomeHidden()).padding(.trailing, 18).padding(.top, 12).transition(.opacity) }
        }
        .overlay(alignment: .topLeading) {
            StewardWindowControls().frame(width: 56, height: 20).padding(.leading, 22).padding(.top, 18)
                .modifier(WelcomeControlsFade())
        }
        .onChange(of: focusedScan) { _, _ in windowPointer = nil }
        .onChange(of: isStage) { _, _ in windowPointer = nil }
        .onChange(of: m.scanning) { _, scanning in if scanning { storageMap.cancel(); cleanupReviewing = false; runCleanup = true; runDuplicates = true; runBrowsers = false; runLeftovers = false; runQuitApps = false } }
        .onChange(of: m.section) { _, section in
            if section != "Overview" { overviewDetail = nil }
            if section == "iPhone" { m.iphone.watch() }
        }
        .onChange(of: m.report == nil) { _, empty in if empty { overviewDetail = nil } }
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.58, dampingFraction: 0.88), value: focusedScan)
        .animation(reduceMotion ? nil : .pagePush, value: theme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: isIntro)
        .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.88), value: m.scanning)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.9), value: hideSidebar)
        .sheet(item: $pendingRemoval) { pending in CleanConfirmSheet(findings: pending.findings ?? m.selectedFindings, appsToQuit: (pending.findings?.isEmpty ?? false) ? [] : m.appsToQuit, extras: pending.extras) {
            if pending.steps.isEmpty { m.clean() } else { m.removalQueue = pending.steps; m.runNextRemoval() }
        } }
        .sheet(item: $m.worktreeBatch) { worktreeSheet($0) }
        .environment(\.stewardTheme, theme)
        .modifier(FullDiskGateHost(theme: theme))
        .modifier(OnceStages(theme: theme))
        .alert("Artifloam", isPresented: errorShown) { Button("OK") { m.error = nil } } message: { Text(m.error ?? "") }
    }
    private var errorShown: Binding<Bool> { Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } }) }
    private func worktreeSheet(_ batch: StewardModel.WorktreeBatch) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Delete merged worktrees", systemImage: "trash").stewardFont(.title2, weight: .semibold)
            Text("Git confirms every commit is merged, no tracked file is edited and no running process uses these checkouts. They are deleted permanently, including ignored files such as node_modules, build output and local .env files. Each merged branch is deleted too; its commit is shown afterwards so you can recreate it.").stewardFont(.body).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(batch.candidates) { candidate in
                        Toggle(isOn: Binding(get: { m.worktreeChoice.contains(candidate.id) }, set: { if $0 { m.worktreeChoice.insert(candidate.id) } else { m.worktreeChoice.remove(candidate.id) } })) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(candidate.finding.title).stewardFont(.body, weight: .semibold); Spacer(); Text(formattedBytes(candidate.finding.bytes)).stewardFont(.callout).foregroundStyle(.secondary) }
                                Text(candidate.finding.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).stewardFont(.caption, design: .monospaced).foregroundStyle(.secondary)
                                ForEach(candidate.assessment.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").stewardFont(.caption).foregroundStyle(.orange) }
                            }
                        }.toggleStyle(.stewardCheckbox)
                    }
                    if !batch.blocked.isEmpty { Text("Kept after recheck:\n\(batch.blocked.joined(separator: "\n"))").stewardFont(.caption).foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 380)
            HStack {
                Button("Cancel") { m.worktreeBatch = nil; m.runNextRemoval() }; Spacer()
                let chosen = batch.candidates.filter { m.worktreeChoice.contains($0.id) }
                Button("Delete \(chosen.count) · \(formattedBytes(chosen.reduce(0) { $0 + $1.finding.bytes }))", role: .destructive) { m.trashChosenWorktrees() }
                    .buttonStyle(.borderedProminent).tint(.red).disabled(chosen.isEmpty)
            }
        }.padding(28).frame(width: 560)
    }
    private var stageProgress: Double? {
        if m.scanning { return m.scanProgress?.fraction }
        if isMapStage, storageMap.busy, let snapshot = storageMap.snapshot, !snapshot.entries.isEmpty {
            return Double(snapshot.entries.filter(\.complete).count) / Double(snapshot.entries.count)
        }
        return nil
    }
    private var stageProgressText: String {
        if m.scanning, let status = m.scanProgress, let total = status.total {
            return String(localized: "\(Int((status.fraction ?? 0) * 100))% · \(status.completed) of \(total) checks · \(status.remaining ?? 0) remaining")
        }
        if isMapStage, storageMap.busy, let snapshot = storageMap.snapshot, !snapshot.entries.isEmpty {
            let complete = snapshot.entries.filter(\.complete).count
            return String(localized: "\(complete) of \(snapshot.entries.count) top-level items measured · \(snapshot.entries.count - complete) remaining")
        }
        return m.scanning ? String(localized: "Preparing the scan checklist…") : String(localized: "Measuring work…")
    }
    private var orbTitle: String {
        if isMapStage { return storageMap.busy ? String(localized: "Stop", comment: "Button: stop the running scan") : String(localized: "Map", comment: "Button: start mapping the disk") }
        if stageWorking { return String(localized: "Stop", comment: "Button: stop the running scan") }
        if isSummary { return String(localized: "Run", comment: "Button: clean what is ticked on the scan summary") }
        switch m.section {
        case "Worktrees": return String(localized: "Inspect", comment: "Button: inspect Git worktrees")
        case "Duplicates": return String(localized: "Compare", comment: "Button: compare files to find duplicates")
        case "System": return String(localized: "Check", comment: "Button: check this Mac's settings")
        case "iPhone": return String(localized: "Read", comment: "Button: read the list of apps from the chosen iPhone")
        default: return String(localized: "Scan", comment: "Button: start a scan")
        }
    }
    var stageControls: some View {
        VStack(spacing: 7) {
            // Same line as On-device, so the health readout never adds height under the artwork.
            HStack(spacing: 10) {
                if m.section == "Overview", !m.scanning, !isSummary, let health = m.health.health {
                    let line = health.issues.isEmpty && m.memory.freedThisMonth > 0 ? String(localized: "Mac health \(health.score) · Level \(health.level) · \(formattedBytes(m.memory.freedThisMonth)) freed this month") : String(localized: "Mac health \(health.score) · Level \(health.level)")
                    Label(line, systemImage: "heart.fill")
                        .stewardFont(.caption).foregroundStyle(health.issues.isEmpty ? Color.mint.opacity(0.85) : Color.orange.opacity(0.9))
                        .contentTransition(.numericText()).animation(.easeOut, value: health.score)
                    Text("·").stewardFont(.caption).foregroundStyle(.white.opacity(0.4))
                }
                if !isSummary && (m.section != "iPhone" || stageWorking) { Label("On-device", systemImage: "lock.fill").stewardFont(.caption).foregroundStyle(.white.opacity(0.5)) }
            }
            // The summary already says "Scan complete" at the top; these lines only cost it room.
            if stageWorking || storageMap.busy {
                Text(m.health.fixing != nil ? "Nothing is being removed." : stageWorking ? "Reading only. Nothing is being removed." : "Sizes only. Nothing is being removed.")
                    .stewardFont(.caption).foregroundStyle(.white.opacity(0.5))
            } else if m.section == "iPhone" {
                IPhoneDevicePicker(state: m.iphone).padding(.top, 6)
            } else if !isSummary { ScanInfoButton(section: m.section, accent: theme.accent) }
            if !toolRunning && (stageWorking || storageMap.busy || m.busy) { Text(stageProgressText).stewardFont(.caption).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center).help("Progress counts completed checks, not an estimate of time remaining.") }
            // On stage screens the banner sits under the progress line, never over the artwork.
            // Hidden while a scan runs, so it never pushes the progress labels into the artwork.
            if !(stageWorking || storageMap.busy || m.busy || isSummary) { FullDiskAccessBanner().frame(maxWidth: 760) }
            OrbAction(title: orbTitle,
                      icon: isMapStage ? (storageMap.busy ? "stop.fill" : "magnifyingglass") : stageWorking ? "stop.fill" : isSummary ? "sparkles" : m.section == "System" ? "checkmark.shield" : m.section == "Duplicates" ? "square.on.square" : m.section == "iPhone" ? "iphone" : "magnifyingglass", accent: theme.vivid,
                      // A running scan can always be stopped; only other busy work disables the orb.
                      disabled: isMapStage ? (!storageMap.busy && !storageMap.canStart) : !stageWorking && (m.busy || m.waitingForCancelledScan || (m.section == "iPhone" && !m.iphone.canRead)), showingProgress: stageWorking || storageMap.busy || m.busy, progress: stageProgress) {
                if isMapStage { if storageMap.busy { storageMap.cancel() } else { m.withFullDisk { storageMap.map() } } }
                else if m.scanning { m.cancelScan() }
                else if toolRunning { stopTool() }
                // Like Smart Care: the big button runs the safe, ticked part; everything else stays in Review.
                else if isSummary { runSummary() }
                else if m.section == "Duplicates" { m.scanDuplicates() }
                else if m.section == "iPhone" { m.iphone.read() }
                else if m.section == "Photos" { PhotosModule.start() }
                else if m.section == "My Clutter" { scanClutter() }
                else if ["Applications", "Leftovers"].contains(m.section) { m.leftovers.scan() }
                else if m.section == "Login & background items" { m.startup.scan() }
                else if m.section == "Browsers" { m.withFullDisk { m.browsers.scan() } }
                else if m.section == "System" { m.checkSystem() }
                else if m.section == "Trash bins" { m.withFullDisk { m.trashBins.scan() } }
                else if m.section == "Cleanup" { m.withFullDisk { m.scan(only: StewardModel.cleanupGroups) } }
                else if m.section == "Worktrees" { m.scan(only: [.worktrees]) }
                else { m.withFullDisk { m.scan(allTools: true) } }
            }.padding(.top, stageWorking || storageMap.busy || m.busy ? 20 : isSummary ? 0 : 29)
        }.frame(maxWidth: .infinity).padding(.bottom, 31)
        .overlay(alignment: .bottomTrailing) {
            // Bottom right, out of the tiles' way: everything not ticked for Run is reviewed here.
            if isSummary {
                Button { m.review(); m.section = "Overview"; overviewDetail = "Cleanup" } label: { Label("Review all", systemImage: "list.bullet") }
                    .buttonStyle(CleanupGlassButtonStyle(secondary: true)).stewardFont(.body, weight: .semibold)
                    .padding(.trailing, 30).padding(.bottom, 96)
            }
        }
    }
    /// After an Overview scan, like Smart Care: one tile per module, one Run for the safe part.
    var summaryStage: some View {
        let findings = m.report?.findings ?? []
        let cleanupFound = Self.found(findings)
        let duplicateBytes = m.duplicates.reduce(0) { $0 + $1.potentialBytes }
        return VStack(spacing: 10) { ScrollView { VStack(spacing: 20) {
            VStack(spacing: 6) {
                Label("Scan complete", systemImage: "checkmark.seal.fill").stewardFont(.caption, weight: .medium).foregroundStyle(mint)
                Text(cleanupFound > 0 ? "You can free up to \(formattedBytes(cleanupFound + duplicateBytes))." : "Your Mac looks tidy.").font(.system(size: 30 * textScale, weight: .light))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14)], spacing: 14) {
                cleanupCard
                clutterCard
                browsersCard
                applicationsCard
                performanceCard
                toolCard("Status", value: m.checks.isEmpty ? String(localized: "Not checked") : String(localized: "\(m.protections.on) of \(m.protections.total) on"), detail: String(localized: "Protection, updates and remote access"), review: { overviewDetail = "System" })
            }.frame(maxWidth: 1000)
            if let note = m.report?.notices.first {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.orange)
                    Text(firstSentence(note)).lineLimit(1).help(m.report?.notices.joined(separator: "\n\n") ?? "")
                }.stewardFont(.caption).foregroundStyle(muted)
            }
        }.frame(maxWidth: .infinity).padding(.horizontal, 30).padding(.top, 8).padding(.bottom, 12).overlayScrollers() }
        }
    }
    // What each card would remove. Each follows the ticks in its tool, so what Review unticks stays out of Run.
    private var chosenFindings: [Finding] { (m.report?.findings ?? []).filter { m.selected.contains($0.id) && $0.userCleanable && $0.group != .worktrees } }
    private var chosenWorktrees: [Finding] { m.reviewableWorktrees.filter { m.worktreeSelection.contains($0.id) } }
    private var chosenDuplicates: [String] { DuplicateGroup.trashable(m.duplicateChoice, in: m.duplicates) }
    private var chosenDuplicateBytes: UInt64 {
        m.duplicates.reduce(0) { $0 + $1.size * UInt64(DuplicateGroup.trashable(m.duplicateChoice, in: [$1]).count) }
    }
    private var chosenBrowserCaches: [BrowserItem] { closedBrowserCaches.filter { m.browsers.selection.contains($0.id) } }
    private var chosenLeftovers: [LeftoverItem] { (m.leftovers.items ?? []).filter { m.leftovers.selection.contains($0.id) } }
    /// The same largest idle apps Performance suggests. Nothing is ticked until the person asks.
    private var idleApps: [MemoryAppUsage] {
        m.memory.reading.map { MemoryVerdict.suggestions($0.apps, recentlyUsed: m.memory.recentlyUsed, canQuit: m.memory.canQuit) } ?? []
    }
    /// Run: one confirmation for every ticked card. Large files are never part of it.
    private func runSummary() {
        let findings = runCleanup ? chosenFindings : [], worktrees = runCleanup ? chosenWorktrees : []
        let duplicates = runDuplicates ? chosenDuplicates : [], browsers = runBrowsers ? chosenBrowserCaches : []
        let leftovers = runLeftovers ? chosenLeftovers : [], apps = runQuitApps ? idleApps : []
        if findings.isEmpty, worktrees.isEmpty, duplicates.isEmpty, browsers.isEmpty, leftovers.isEmpty, apps.isEmpty { m.review(); m.section = "Overview"; overviewDetail = "Cleanup"; return }
        confirmRemoval(findings, worktrees: worktrees, browsers: browsers, duplicates: duplicates, leftovers: leftovers, quitting: apps)
    }
    /// On a card that can't be ticked, this line is the reason, so it never just looks broken.
    private func runStatus(ticked: Bool, bytes: UInt64, found: UInt64) -> String {
        if bytes == 0 { return found > 0 ? String(localized: "Choose in Review") : String(localized: "Nothing to clean") }
        return ticked ? String(localized: "\(formattedBytes(bytes)) selected") : String(localized: "Not selected")
    }
    private var cleanupCard: some View {
        let findings = m.report?.findings ?? []
        let bytes = (chosenFindings + chosenWorktrees).reduce(UInt64(0)) { $0 + $1.bytes }
        return toolCard("Cleanup", value: formattedBytes(Self.found(findings)), detail: Self.readyLine(findings), status: runStatus(ticked: runCleanup, bytes: bytes, found: Self.found(findings)), chosen: $runCleanup, canChoose: bytes > 0,
                        review: { m.review(); m.section = "Overview"; overviewDetail = "Cleanup" })
    }
    private var clutterCard: some View {
        let bytes = chosenDuplicateBytes
        return toolCard("My Clutter", value: m.duplicateChecked ? String(localized: "\(m.duplicates.count) duplicates") : String(localized: "Not checked"),
                        detail: m.duplicateChecked ? String(localized: "\(formattedBytes(m.duplicates.reduce(0) { $0 + $1.potentialBytes })) in extra copies") : String(localized: "Choose a folder to compare"),
                        status: m.duplicateChecked ? runStatus(ticked: runDuplicates, bytes: bytes, found: m.duplicates.reduce(0) { $0 + $1.size }) : String(localized: "Not checked"), chosen: $runDuplicates, canChoose: bytes > 0, review: { overviewDetail = "My Clutter" })
    }
    private var browsersCard: some View {
        let reports = m.browsers.reports
        let found = (reports ?? []).flatMap(\.items).filter(\.recommended).reduce(UInt64(0)) { $0 + $1.bytes }
        let bytes = chosenBrowserCaches.reduce(UInt64(0)) { $0 + $1.bytes }
        let open = (reports ?? []).filter { report in BrowserData.isRunning(report.bundleID) && report.items.contains(where: \.recommended) }.map(\.name).joined(separator: ", ")
        let status = reports == nil ? String(localized: "Checking…") : bytes == 0 && !open.isEmpty ? String(localized: "Quit \(open) to clean") : runStatus(ticked: runBrowsers, bytes: bytes, found: found)
        return toolCard("Browsers", value: reports == nil ? String(localized: "Checking…") : formattedBytes(found), detail: String(localized: "Rebuilt as you browse. You stay signed in."), status: status, chosen: $runBrowsers, canChoose: bytes > 0, review: { overviewDetail = "Browsers" })
    }
    private var applicationsCard: some View {
        let bytes = chosenLeftovers.reduce(UInt64(0)) { $0 + $1.bytes }
        let leftovers = m.leftovers.items?.reduce(UInt64(0)) { $0 + $1.bytes }
        return toolCard("Applications", value: m.unusedApps.map { String(localized: "\($0) unused apps") } ?? String(localized: "Checking…"),
                        detail: leftovers.map { String(localized: "Unused 6+ months · \(formattedBytes($0)) leftovers") } ?? String(localized: "Finding leftovers…"),
                        status: leftovers == nil ? String(localized: "Checking…") : runStatus(ticked: runLeftovers, bytes: bytes, found: leftovers ?? 0), chosen: $runLeftovers, canChoose: bytes > 0, review: { overviewDetail = "Applications" })
    }
    private var performanceCard: some View {
        let apps = idleApps
        return toolCard("Performance", value: m.memory.reading?.pressure.title ?? "–", detail: m.agentCount.map { String(localized: "Memory pressure · \($0) background agents") } ?? String(localized: "Memory pressure"),
                        status: apps.isEmpty ? String(localized: "No idle apps") : runQuitApps ? String(localized: "\(apps.count) apps") : String(localized: "Not selected"), chosen: $runQuitApps, canChoose: !apps.isEmpty, review: { overviewDetail = "Performance" })
    }
    private func toolCard(_ module: String, value: String, detail: String, status: String? = nil, chosen: Binding<Bool>? = nil, canChoose: Bool = true, review: @escaping () -> Void) -> some View {
        // A dimmed card can't go, so it never looks ticked, whatever Run remembers for it.
        let shown = chosen.map { chosen in Binding(get: { chosen.wrappedValue && canChoose }, set: { chosen.wrappedValue = $0 }) }
        return CategoryTile(amount: value, found: false, name: sectionTitle(module), tagline: detail, art: "", module: module, chooseLabel: "Include in Run", status: status, chosen: shown, canChoose: canChoose, review: review)
    }
    /// A module opened from Overview: the shared back button, a breadcrumb, then the module itself.
    @ViewBuilder private func overviewDetailView(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BackSquareButton { overviewDetail = nil }
                Text("Overview").stewardFont(.body).foregroundStyle(muted)
                Image(systemName: "chevron.compact.right").flipsForRightToLeftLayoutDirection(true).foregroundStyle(muted)
                Text(sectionTitle(detail == "System" ? "Status" : detail)).stewardFont(.body, weight: .semibold)
            }
            if detail == "Cleanup" { cleanupDetails.frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ScrollView { content(detail).padding(.bottom, 28).frame(maxWidth: .infinity, alignment: .leading) } }
        }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 16).frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
    /// Whether Settings can fix a scan note. Notes are translated, so their wording can't decide this: the Git note is recognised
    /// by its whole key, an unreadable folder by the path only that note names, and a failed duplicate search (it only fails on access) by its key.
    private func settingsFixes(_ note: String) -> Bool {
        if note.contains("/") || note == String(localized: "Git is unavailable. Git-dependent caches remain protected and worktree checks are skipped; install Git or Command Line Tools to enable verification.") { return true }
        let duplicateSearch = String(localized: "Duplicate search: \("\u{1}")").components(separatedBy: "\u{1}")
        return duplicateSearch.count == 2 && note.hasPrefix(duplicateSearch[0]) && note.hasSuffix(duplicateSearch[1])
    }
    /// Each note as a row with the action that resolves it, instead of a hidden popover.
    @ViewBuilder private var scanNotes: some View {
        ForEach(m.report?.notices ?? [], id: \.self) { note in
            HStack(spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.orange)
                Text(firstSentence(note)).stewardFont(.caption).foregroundStyle(muted).lineLimit(2).help(note)
                Spacer(minLength: 8)
                if settingsFixes(note) { Button("Settings") { m.section = "Settings" }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)) }
            }.padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: 620)
            .background(panel, in: RoundedRectangle(cornerRadius: 12))
        }
    }
    @ViewBuilder private var extraScanResults: some View {
        if m.duplicateChecked {
            summaryPill(sectionTitle("Duplicates"), icon: "square.on.square", value: String(localized: "\(m.duplicates.count) duplicate groups")) { m.section = "Duplicates" }
        }
        if !m.checks.isEmpty {
            summaryPill(sectionTitle("System"), icon: "checkmark.shield", value: String(localized: "\(m.protections.on) of \(m.protections.total) protections on")) { m.section = "System" }
        }
    }
    static let modules = [("Overview", "sparkles"), ("Cleanup", "externaldrive.fill"), ("My Clutter", "doc.on.doc"), ("Applications", "checkmark.shield"), ("Browsers", "globe"), ("Space Map", "circle.dotted"), ("Photos", "photo.on.rectangle"), ("iPhone", "iphone")]
    /// Live readings, not cleanup: small buttons in the window's top-right corner.
    static let corner = [("Performance", "gauge.with.dots.needle.67percent"), ("Status", "waveform.path.ecg")]
    // Automation and Activity live inside Settings as tabs.
    static let utilities = [("Tools", "square.grid.2x2"), ("Settings", "gearshape")]
    @State private var pageHeight: CGFloat = 700
    @State private var switching = false
    /// The page sliding out during a change, and the slide's progress (0 = the new page still off-screen, 1 = done).
    @State private var leaving: String?
    @State private var slide: Double = 1
    /// One page height plus a gap like the free space above a start screen's artwork, so the pages never touch.
    private var slideDistance: CGFloat { pageHeight + max(60, (pageHeight - 360) / 2) }
    /// Changes page with a slide that follows the navigation order (corner buttons count as the top).
    private func go(_ name: String) {
        let order = (Self.corner + Self.modules + Self.utilities).map(\.0)
        guard name != m.section else { return }
        if let from = order.firstIndex(of: m.section), let to = order.firstIndex(of: name) { navDirection = to > from ? 1 : to < from ? -1 : 0 } else { navDirection = 0 }
        guard !reduceMotion, navDirection != 0 else { withAnimation(reduceMotion ? nil : .pagePush) { m.section = name }; return }
        // This update draws the new page off-screen beside the current one; the slide starts on the next run-loop
        // pass, once that start has been rendered (set in the same update, 1 → 0 → 1 would not animate at all).
        leaving = m.section; slide = 0; switching = true
        m.section = name
        navRequest = (navRequest.id + 1, name)
        DispatchQueue.main.async { showRequestedPage() }
    }
    private func showRequestedPage() {
        let request = navRequest.id
        withAnimation(.pagePush) { slide = 1 } completion: { if navRequest.id == request { leaving = nil; switching = false } }
    }
    private var cornerButtons: some View {
        HStack(spacing: 8) {
            if let update = m.updates.available {
                UpdateBadge(version: update.version, accent: mint, scale: textScale, downloading: m.updates.downloading) { m.updates.offer() }
            }
            ForEach(Self.corner, id: \.0) { name, icon in
                let active = m.section == name
                Button { go(name) } label: {
                    HStack(spacing: 6) {
                        StewardNavigationArtwork(name: name, fallback: icon, size: 16)
                        Text(sectionTitle(name)).font(.system(size: 12 * textScale, weight: active ? .semibold : .medium))
                    }.foregroundStyle(.white).padding(.horizontal, 11).frame(height: 28)
                    .background(.white.opacity(active ? 0.18 : 0.07), in: Capsule())
                    .overlay { Capsule().stroke(.white.opacity(active ? 0.22 : 0.10), lineWidth: 0.7) }
                    .contentShape(Capsule())
                }.buttonStyle(.plain).help(sectionTitle(name)).accessibilityLabel(sectionTitle(name))
            }
        }
    }
    private var compactRail: some View {
        ScrollView {
            VStack(spacing: 13) {
                ForEach((Self.modules + Self.utilities).map(\.0), id: \.self) { name in
                    Button { go(name) } label: {
                        StewardNavigationArtwork(name: name, fallback: "square.grid.2x2")
                            .frame(width: 39, height: 39)
                            .background((m.scanning ? name == "Cleanup" : m.section == name) ? .white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).help(sectionTitle(name)).accessibilityLabel(sectionTitle(name)).disabled(m.scanning)
                }
            }.overlayScrollers()
            // A gutter for the scroller, so it shows beside the icons rather than over them.
            .padding(.trailing, 10)
        }.frame(width: 52).padding(.trailing, -10)
    }
    private var sidebarDivider: some View {
        Rectangle().fill(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.17), location: 0.33), .init(color: .white.opacity(0.17), location: 0.67), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)).frame(width: 1).padding(.vertical, 12)
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
            // Modules run several tools in one scan; Tools runs one at a time.
            ForEach(Self.modules, id: \.0) { nav($0.0, $0.1) }
                }.overlayScrollers()
                .padding(.trailing, 10)
            }.padding(.trailing, -10)
            // Settings-like screens sit at the bottom, next to free space.
            VStack(alignment: .leading, spacing: 0) { ForEach(Self.utilities, id: \.0) { nav($0.0, $0.1) } }.padding(.top, 12)
            if !m.scanning {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(formattedBytes(m.disk.free)) free").stewardFont(.callout, weight: .medium)
                    Text("On your Mac").stewardFont(.caption).foregroundStyle(muted)
                }.padding(.horizontal, 9).padding(.top, 23).transition(.opacity)
            }
        }.padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 23)
            .frame(width: sidebarWidth)
            .overlay(alignment: .trailing) {
                sidebarDivider
            }
    }
    func nav(_ name: String, _ icon: String) -> some View {
        let hovered = hoveredNavigation == name
        return Button { go(name) } label: {
            HStack(spacing: 14) {
                StewardNavigationArtwork(name: name, fallback: icon, size: 28)
                    .opacity(m.section == name || hovered ? 1 : 0.85)
                Text(sectionTitle(name)).font(.system(size: 15 * textScale, weight: m.section == name ? .semibold : .medium)).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 0)
            }.frame(minHeight: 40).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 3)
                .background {
                    ZStack {
                        // Active: a soft frosted pill with a faint top light, like the reference.
                        if m.section == name {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LinearGradient(colors: [.white.opacity(0.17), .white.opacity(0.09)], startPoint: .top, endPoint: .bottom))
                                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 0.7) }
                                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                                .matchedGeometryEffect(id: "navigation", in: navigation)
                        }
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)).opacity(hovered && m.section != name ? 1 : 0)
                    }
                }
        }.buttonStyle(.plain).padding(.vertical, 2).help(sectionTitle(name)).accessibilityLabel(sectionTitle(name)).disabled(m.scanning)
            .onHover { inside in
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                    if inside { hoveredNavigation = name }
                    else if hoveredNavigation == name { hoveredNavigation = nil }
                }
            }
    }
    var header: some View {
        HStack {
            if !isIntro && ["Overview", "Cleanup", "Worktrees", "Duplicates", "System"].contains(m.section) { Button {
                if m.section == "System" { m.checks = [] }
                else if m.section == "Duplicates" { m.duplicateChecked = false; m.duplicates = [] }
                else { m.report = nil; m.selected.removeAll() }
            } label: { Label("Start over", systemImage: "arrow.counterclockwise").stewardFont(.caption) }.buttonStyle(.plain).foregroundStyle(muted).disabled(m.busy) }
            Spacer()
        }.frame(height: 38).padding(.leading, 27).padding(.trailing, 27).padding(.top, 14)
    }
    func intro(_ section: String) -> some View {
        let trashEmpty = section == "Trash bins" && m.trashBins.report?.items == 0 && !m.trashBins.scanning
        let title: String
        let subtitle: String
        let points: [(String, String)]
        switch section {
        case "Cleanup":
            title = String(localized: "A little less clutter.")
            subtitle = String(localized: "Find old caches and build leftovers, without touching the work you want to keep.")
            points = [("app", String(localized: "Recognised application caches")), ("doc.text", String(localized: "Old diagnostic logs")), ("lock", String(localized: "Personal files protected"))]
        case "Worktrees":
            title = String(localized: "Room for your next idea.")
            subtitle = String(localized: "See which checkouts are finished and which still hold your work.")
            points = [("arrow.triangle.branch", String(localized: "Git status & unmerged commits")), ("person.crop.circle", String(localized: "Active sessions protected")), ("eye", String(localized: "Review before archiving"))]
        case "Duplicates":
            title = String(localized: "Same file. Extra space.")
            subtitle = String(localized: "Find exact copies across your home folder. Decide which one to keep.")
            points = [("square.on.square", String(localized: "Content compared, not names")), ("lock", String(localized: "Everything stays on your Mac")), ("folder", String(localized: "Review copies in Finder"))]
        case "My Clutter":
            title = String(localized: "Find what you forgot.")
            subtitle = String(localized: "Exact duplicates across your Mac and large, old files. Nothing is removed without your review.")
            points = [("square.on.square", String(localized: "Duplicates compared by content")), ("doc.text.magnifyingglass", String(localized: "Large and old files")), ("house", String(localized: "Across your whole home folder"))]
        case "Browsers":
            title = String(localized: "Lighter browsers, still signed in.")
            subtitle = String(localized: "Caches and website data for every browser and profile on your Mac.")
            points = [("globe", String(localized: "Every browser and profile")), ("checkmark.shield", String(localized: "Caches clean, sign-ins stay")), ("person.crop.circle", String(localized: "Website data only when you choose"))]
        case "Applications":
            title = String(localized: "Apps you no longer need.")
            subtitle = String(localized: "See when each app was last used, and what deleted apps left behind.")
            points = [("clock", String(localized: "Last used, least used first")), ("shippingbox", String(localized: "Leftovers of removed apps")), ("lock", String(localized: "Running and Apple apps protected"))]
        case "Login & background items":
            title = String(localized: "What starts with your Mac.")
            subtitle = String(localized: "Apps that open at login and programs that run in the background.")
            points = [("power", String(localized: "Apps that open at login")), ("gearshape.2", String(localized: "Background agents, in plain language")), ("arrow.uturn.backward", String(localized: "Anything you switch off can come back"))]
        case "Leftovers":
            if m.leftovers.items?.isEmpty == true && !m.leftovers.busy {
                title = String(localized: "Apps you removed left nothing behind that Artifloam can identify.")
                subtitle = title
                points = [("checkmark.circle", String(localized: "Nothing left to clean here")), ("shippingbox", String(localized: "Library folders compared with your apps")), ("internaldrive", String(localized: "\(formattedBytes(m.disk.free)) free on this Mac"))]
            } else {
                title = String(localized: "What removed apps left behind.")
                subtitle = String(localized: "Support files, caches and settings from apps you no longer have.")
                points = [("shippingbox", String(localized: "Grouped by app")), ("exclamationmark.triangle", String(localized: "Possibly shared files stay unticked")), ("arrow.uturn.backward", String(localized: "Everything goes to the Trash first"))]
            }
        case "System":
            title = String(localized: "Know where your Mac stands.")
            subtitle = String(localized: "What protects it, who can reach it and what runs on it.")
            points = [("checkmark.shield", String(localized: "Protection and updates")), ("network", String(localized: "Remote access and backup")), ("app", String(localized: "Background items and app signatures"))]
        case "Trash bins":
            if trashEmpty {
                title = String(localized: "Your Trash is empty, so nothing here is using space.")
                subtitle = title
                let autoEmpty = UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "FXRemoveOldTrashItems") == true
                points = [("checkmark.circle", String(localized: "Nothing left to clean here")), ("internaldrive", String(localized: "\(formattedBytes(m.disk.free)) free on this Mac")), autoEmpty ? ("clock.arrow.circlepath", String(localized: "Finder clears old items after 30 days")) : ("hand.raised", String(localized: "Items stay until you empty it"))]
            } else {
                title = String(localized: "What the Trash still holds.")
                subtitle = String(localized: "Files in the Trash use space until it's emptied.")
                points = [("trash", String(localized: "On your Mac and connected drives")), ("internaldrive", String(localized: "Space you can get back")), ("lock", String(localized: "Nothing goes until you confirm"))]
            }
        case "Photos":
            title = String(localized: "Find what's taking room in Photos.")
            subtitle = title
            points = [("photo.on.rectangle", String(localized: "Duplicates, similar and blurred photos")), ("video", String(localized: "Compress large videos")), ("livephoto", String(localized: "Turn off Live Photos"))]
        case "iPhone":
            title = m.iphone.stageLine
            subtitle = title
            points = [("iphone", String(localized: "Every app by size")), ("bubble.left.and.bubble.right", String(localized: "WhatsApp per chat, from a local backup")), ("lock", String(localized: "Nothing changes on your iPhone"))]
        default:
            title = String(localized: "More room. Less clutter.")
            subtitle = String(localized: "A simple check for the leftovers your Mac can leave behind.")
            points = [("sparkles", String(localized: "Find disposable caches")), ("arrow.triangle.branch", String(localized: "Protect your unfinished work")), ("checkmark.shield", String(localized: "Review every cleanup"))]
        }
        // After a cleanup the start screen says what was freed instead of the generic line.
        let lead = m.lastFreed.map { String(localized: "Last cleanup freed \(formattedBytes($0)). Scan again any time.") }
        return IntroStage(theme: themeFor(section), heading: trashEmpty || (section == "Leftovers" && m.leftovers.items?.isEmpty == true && !m.leftovers.busy) ? String(localized: "All clean.") : sectionTitle(section), title: title, subtitle: ["Overview", "Cleanup"].contains(section) ? (lead ?? subtitle) : subtitle, points: points, scanning: stageWorking, progress: m.scanning ? m.progress : toolProgressText,
                          health: section == "Overview" ? m.health.health : nil, fix: { issue in m.health.performOnStage(issue.fix, prepare: { await m.startup.load() }) { m.section = $0 } }, workingTitle: section == "iPhone" ? String(localized: "Reading your iPhone…") : m.health.fixing?.title, reportsFrames: section == "Overview" && m.welcoming, subtitleIsLastCleanup: ["Overview", "Cleanup"].contains(section) && lead != nil)
    }
    /// Header, pages, banner and footer to the right of the sidebar.
    private var mainColumn: some View {
        VStack(spacing: 0) {
            if !m.scanning && m.removal == nil && !isMapStage && (isStage || ["Overview", "Cleanup", "Worktrees", "Duplicates", "System"].contains(m.section)) { header }
            pages.frame(maxWidth: .infinity, maxHeight: .infinity).environment(\.stewardPageSwitching, switching)
                .background { GeometryReader { geometry in Color.clear.onAppear { pageHeight = geometry.size.height }.onChange(of: geometry.size.height) { _, height in pageHeight = height } } }
            if !isStage && m.cleaning == nil && m.removal == nil { FullDiskAccessBanner() }
            if showsFooter { footer }
        }.frame(maxWidth: .infinity).padding(.bottom, isStage ? max(130 + (textScale - 1) * 50, stageControlsHeight - 60) : 0)
    }
    private var showsFooter: Bool {
        !isStage && m.cleaning == nil && m.removal == nil && !["Space Map", "Memory", "Tools", "Settings", "Large & old files", "App removal", "Login & background items", "Performance", "Applications", "Trash bins", "Leftovers", "Browser data", "Status", "Browsers", "iPhone"].contains(m.section) && !(m.section == "My Clutter" && clutterTab != "Duplicates")
    }
    /// A carousel driven by hand: during a change the leaving page and the current page are both ordinary,
    /// live pages moved by one `slide` value. SwiftUI's removal transitions only move a leaving page; they never blur or fade it.
    private var pages: some View {
        ZStack {
            ForEach([leaving, m.section].compactMap { $0 }, id: \.self) { section in
                let current = section == m.section
                page(section)
                    .modifier(PageSlide(progress: current ? slide : 1 - slide, offset: (current ? 1 : -1) * navDirection * slideDistance, leaving: !current))
                    .transition(.identity)
            }
        }
    }
    /// One page of the main area, for any section, so the carousel can show the leaving page next to the new one.
    @ViewBuilder private func page(_ section: String) -> some View {
        if let removal = m.removal {
            RemovalStage(progress: removal, stop: { m.stopRemoval() }, done: { withAnimation(.easeOut(duration: 0.25)) { m.finishRemoval() } })
                .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.97)))
        } else if isSummaryPage(section) {
            summaryStage
        } else if let cleaning = m.cleaning {
            CleaningStage(progress: cleaning, stopping: m.stoppingClean, freeSpace: m.disk.free, stop: { m.stopCleaning() },
                          done: { m.finishCleaning(); cleanupReviewing = false },
                          receipt: { m.settingsTab = "Activity"; m.finishCleaning(thenShow: "Settings"); cleanupReviewing = false })
                .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.97)))
        } else if m.scanning {
            ScanStage(progress: m.progress, step: m.scanProgress?.step ?? .access, theme: theme).transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.97)))
        } else if isIntroPage(section) {
            intro(section)
        } else if section == "Space Map" {
            StorageMapView(map: storageMap, stage: isMapStagePage(section)).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if section == "Overview", let detail = overviewDetail {
            overviewDetailView(detail)
        } else if section == "Cleanup" && !cleanupReviewing {
            ScrollView { cleanupSummary.padding(.horizontal, 30).padding(.top, 22).padding(.bottom, 28) }
        } else if section == "Cleanup" {
            cleanupDetails.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if section == "Worktrees" {
            worktrees.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView { content(section).padding(.horizontal, 30).padding(.top, 22).padding(.bottom, 28).frame(maxWidth: .infinity, alignment: .leading) }
                .safeAreaInset(edge: .bottom, spacing: 0) { if section == "iPhone" { IPhoneSelectionBar(state: m.iphone) } }
                .overlay { if section == "iPhone" && m.iphone.waitingForUnlock { IPhoneUnlockOverlay(state: m.iphone) } }
        }
    }
    @ViewBuilder var content: some View { content(m.section) }
    @ViewBuilder func content(_ section: String) -> some View {
        switch section {
        case "Cleanup": cleanupDetails
        case "Worktrees": worktrees
        case "Duplicates": duplicatesDetails
        case "System": SystemCheckView()
        case "Automation": automation
        case "Activity": activity
        case "Tools": ToolsView()
        case "Large & old files": LargeFilesView(location: m.largeFileLocation, state: m.largeFiles)
        case "App removal": AppRemovalView()
        case "Login & background items": BackgroundItemsView(state: m.startup)
        case "Trash bins": TrashBinsView(state: m.trashBins)
        case "Leftovers": LeftoversView(state: m.leftovers)
        case "Browser data": BrowserDataView(state: m.browsers)
        case "Browsers": BrowsersModuleView(state: m.browsers)
        case "iPhone": IPhoneView(state: m.iphone)
        case "Photos": PhotosModuleView()
        case "Status": StatusView(state: m.status, memory: m.memory)
        case "Memory": MemoryView(monitor: m.memory)
        case "My Clutter": module("My Clutter", String(localized: "Duplicates across your home folder and large, old files."), tabs: ["Duplicates", "Large & old files"], selection: $clutterTab, summary: clutterSummary, scanAll: scanClutter) {
            if clutterTab == "Duplicates" { duplicatesDetails } else { LargeFilesView(location: m.largeFileLocation, state: m.largeFiles) }
        }
        case "Performance": module("Performance", String(localized: "Memory and the apps that start with your Mac."), tabs: ["Memory", "Login & background items"], selection: $performanceTab, summary: performanceSummary, scanAll: { m.startup.refresh() }) {
            if performanceTab == "Memory" { MemoryView(monitor: m.memory, loginItems: m.startup.loginItems?.count, reviewStartup: { performanceTab = "Login & background items" }) } else { BackgroundItemsView(state: m.startup) }
        }.onAppear { if m.startup.loginItems == nil && m.startup.error == nil { m.startup.refresh() } }
        case "Applications": module("Applications", String(localized: "Remove apps you no longer use and what they left behind."), tabs: ["Uninstaller", "Leftovers"], selection: $applicationsTab, summary: applicationsSummary, scanAll: { m.leftovers.scan() }) {
            if applicationsTab == "Uninstaller" { AppRemovalView() } else { LeftoversView(state: m.leftovers) }
        }
        case "Settings":
            VStack(alignment: .leading, spacing: 20) {
                Picker("Settings", selection: $m.settingsTab) { ForEach(["General", "Automation", "Activity"], id: \.self) { Text(sectionTitle($0)).tag($0) } }
                    // Natural width: in a wider frame macOS centres a segmented control, which pushed it off the page's left edge.
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                switch m.settingsTab {
                case "Automation": automation
                case "Activity": activity
                default: AccessSettingsView(access: m.access)
                }
            }
        default: summaryStage
        }
    }
    func summaryPill(_ title: String, icon: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 5) { Text(title).stewardFont(.caption).foregroundStyle(muted); Text(value).stewardFont(.body, weight: .medium) }
                Image(systemName: "chevron.forward").stewardFont(.caption).foregroundStyle(muted)
            }.padding(.horizontal, 18).padding(.vertical, 13).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain)
    }
    var cleanupDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            // From Overview, the breadcrumb above already goes back.
            if overviewDetail == nil { Button { cleanupReviewing = false } label: { Label("Summary", systemImage: "chevron.backward").stewardFont(.callout) }.buttonStyle(.plain).foregroundStyle(muted) }
            HStack(alignment: .top) {
                title(String(localized: "Review your cleanup"), String(localized: "Choose what goes. Keep what matters."))
                Spacer()
                // Trash bins are part of Cleanup, as a compact row.
                Button { m.section = "Trash bins" } label: {
                    Label(trashPillTitle, systemImage: "trash")
                        .stewardFont(.callout).padding(.horizontal, 14).padding(.vertical, 9).background(panel, in: Capsule())
                }.buttonStyle(.plain).help("Open Trash bins to empty the Trash")
                Button { m.section = "Browsers" } label: {
                    Label(browsersPillTitle, systemImage: "globe")
                        .stewardFont(.callout).padding(.horizontal, 14).padding(.vertical, 9).background(panel, in: Capsule())
                }.buttonStyle(.plain).help("Open Browser data")
            }.onAppear { if m.trashBins.report == nil { m.trashBins.inspect() } }
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 16) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                allCategoriesRow.id("all")
                                ForEach(m.reviewGroups) { group in
                                    categoryRow(group).id(group.id)
                                }
                            }.padding(8)
                        }
                        .onChange(of: m.reviewSelectionID) { _, id in proxy.scrollTo(id, anchor: .center) }
                        .onChange(of: geometry.size) { _, _ in proxy.scrollTo(m.reviewSelectionID, anchor: .center) }
                        .onChange(of: textScale) { _, _ in proxy.scrollTo(m.reviewSelectionID, anchor: .center) }
                        .onAppear { proxy.scrollTo(m.reviewSelectionID, anchor: .center) }
                        .focusable().focusEffectDisabled()
                        .onKeyPress(.upArrow) { moveCategory(-1); return .handled }
                        .onKeyPress(.downArrow) { moveCategory(1); return .handled }
                        .accessibilityLabel("Cleanup categories")
                    }
                    .frame(width: min(280, geometry.size.width * 0.40), height: geometry.size.height)
                    .background(panel, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(m.showAllFindings ? String(localized: "All findings") : m.group.title).stewardFont(.title3, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                        TextField("Filter paths", text: $m.search).stewardInput()
                            .accessibilityLabel("Filter finding paths")
                        reviewBulkBar
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                if m.showAllFindings {
                                    allCategoriesOverview
                                } else {
                                    Text(m.group.explanation).stewardFont(.body).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                                }
                                if m.groupFindings.isEmpty {
                                    if m.search.isEmpty { empty(String(localized: "No removable findings in this group."), String(localized: "Protected categories are intentionally excluded from automatic cleanup.")) }
                                    else {
                                        empty(String(localized: "No paths match “\(m.search)”."), String(localized: "The filter is hiding items in this list. Nothing was removed."))
                                        Button("Clear filter") { m.search = "" }.buttonStyle(CleanupGlassButtonStyle(compact: true))
                                    }
                                }
                                ForEach(m.groupFindings) { finding in findingRow(finding) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                        }.id(m.reviewSelectionID).accessibilityLabel("Cleanup findings")
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }
    private var trashPillTitle: String {
        guard let report = m.trashBins.report else { return String(localized: "Trash") }
        let items = report.items.map { String(localized: "\($0) items") } ?? String(localized: "private", comment: "The Trash's item count, when macOS won't say what it holds")
        if let bytes = report.bytes { return String(localized: "Trash · \(items) · \(formattedBytes(bytes))") }
        return String(localized: "Trash · \(items)")
    }
    private var browsersPillTitle: String {
        guard let reports = m.browsers.reports else { return String(localized: "Browsers") }
        let bytes = reports.flatMap(\.items).reduce(UInt64(0)) { $0 + $1.bytes }
        return String(localized: "Browsers · \(formattedBytes(bytes))")
    }
    private var reviewBulkBar: some View {
        let scope = m.bulkScope, isWorktrees = !m.showAllFindings && m.group == .worktrees
        let chosen = m.reviewableWorktrees.filter { m.worktreeSelection.contains($0.id) }
        let count = isWorktrees ? chosen.count : m.selectedFindings.count
        let bytes = isWorktrees ? chosen.reduce(0) { $0 + $1.bytes } : m.selectedBytes
        return BulkBar(title: m.showAllFindings ? String(localized: "Select ready") : m.search.isEmpty ? String(localized: "Select all") : String(localized: "Select shown"), isOn: Binding(get: { m.allSelected(scope) }, set: { m.setSelected(scope, $0) }), enabled: !scope.isEmpty && !m.busy,
                       help: m.showAllFindings ? String(localized: "Every category's ready items. Recent caches and running apps are chosen per category.") : String(localized: "Everything listed here that can be removed, including recently used caches. You confirm before anything goes."),
                       summary: String(localized: "\(count) selected · \(formattedBytes(bytes))")) {
            if isWorktrees {
                Button("Delete \(count)…") { m.requestWorktreeRemoval(chosen) }.buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(count == 0 || m.busy)
            } else {
                Button("Clean \(count)…") { pendingRemoval = PendingRemoval() }.buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(count == 0 || m.busy)
            }
        }
    }
    private var allCategoriesRow: some View {
        HStack(alignment: .top, spacing: 2) {
        categoryToggle(nil).padding(.leading, 9).padding(.top, 12)
        Button { m.showAllFindings = true } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "square.grid.2x2.fill").frame(width: 18).foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 5) {
                    Text("All", comment: "List row: every cleanup category").stewardFont(.body, weight: .semibold)
                    Text("\(formattedBytes(m.overview.eligibleBytes)) eligible").stewardFont(.caption).foregroundStyle(mint)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(m.showAllFindings ? mint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityAddTraits(m.showAllFindings ? [.isSelected] : [])
        }
    }
    private var allCategoriesOverview: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScanTotal(overview: m.overview, compact: true)
            Text("Ready caches are ticked. Recently used caches and caches of running apps are yours to tick. Unfinished worktrees and anything only Xcode manages are kept.")
                .stewardFont(.body).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 12)], spacing: 12) {
                ForEach(m.overview.categories.filter { m.reviewGroups.contains($0.group) }) { summary in
                    ScanCategoryCard(summary: summary, compact: true) { m.review(summary.group) }
                }
            }
            Text("All inspected findings").stewardFont(.headline).padding(.top, 6)
        }
    }
    private func moveCategory(_ offset: Int) {
        let groups = m.reviewGroups
        let index = m.showAllFindings ? -1 : (groups.firstIndex(of: m.group) ?? -1)
        let next = min(groups.count - 1, max(-1, index + offset))
        m.showAllFindings = next == -1
        if next >= 0 { m.group = groups[next] }
    }
    private func categoryRow(_ group: CleanupGroup) -> some View {
        let items = m.report?.findings.filter { $0.group == group } ?? []
        return HStack(alignment: .top, spacing: 2) {
        categoryToggle(group).padding(.leading, 9).padding(.top, 12)
        Button { m.group = group; m.showAllFindings = false } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: group.icon).frame(width: 18).foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.title).stewardFont(.body, weight: .medium)
                    Text(items.isEmpty ? "No automatic removal" : "\(items.count) findings").stewardFont(.caption).foregroundStyle(muted)
                    if !items.isEmpty {
                        Text(items.contains(where: { $0.safety == .automatic }) ? formattedBytes(items.filter { $0.safety == .automatic }.reduce(0) { $0 + $1.bytes }) : String(localized: "Review", comment: "Button: open the details and choose what goes"))
                            .stewardFont(.caption, weight: .medium).foregroundStyle(mint)
                    }
                }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(!m.showAllFindings && m.group == group ? mint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityAddTraits(!m.showAllFindings && m.group == group ? [.isSelected] : [])
        }
    }
    private func categoryToggle(_ group: CleanupGroup?) -> some View {
        let eligible = !m.choosable(group).isEmpty
        return Toggle(group.map { String(localized: "Select everything removable in \($0.title)") } ?? String(localized: "Select everything removable in All"), isOn: Binding(get: { m.categorySelected(group) }, set: { m.setCategory(group, selected: $0) }))
            .toggleStyle(.stewardCheckboxOnly).disabled(!eligible || m.busy)
            .help(!eligible ? "Nothing here can be removed right now" : group == nil ? "Select every category's ready items" : "Select everything removable here, including recently used caches")
    }
    func findingRow(_ finding: Finding) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if finding.group == .worktrees && finding.safety == .review {
                Toggle("Select", isOn: Binding(get: { m.worktreeSelection.contains(finding.id) }, set: { if $0 { m.worktreeSelection.insert(finding.id) } else { m.worktreeSelection.remove(finding.id) } })).toggleStyle(.stewardCheckboxOnly)
            } else if finding.userCleanable {
                Toggle("Select", isOn: Binding(get: { m.selected.contains(finding.id) }, set: { if $0 { m.selected.insert(finding.id) } else { m.selected.remove(finding.id) } })).toggleStyle(.stewardCheckboxOnly)
            } else { Image(systemName: finding.safety == .protected ? "lock.fill" : "eye").stewardFont(.body).foregroundStyle(muted).frame(width: 15) }
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(finding.title).stewardFont(.body, weight: .semibold); Spacer(); Text(formattedBytes(finding.bytes)).stewardFont(.callout, weight: .medium).foregroundStyle(mint) }
                Text(finding.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).stewardFont(.caption, design: .monospaced).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text(finding.reason).stewardFont(.callout).foregroundStyle(finding.safety == .automatic ? .white.opacity(0.8) : muted).fixedSize(horizontal: false, vertical: true)
                if finding.hold == .recent { Label("Used recently. You can still clean it; its app will likely rebuild it.", systemImage: "clock.arrow.circlepath").stewardFont(.caption).foregroundStyle(.orange) }
                if finding.hold == .inUse, let owner = finding.owner { Label("\(owner) is running. Artifloam quits it first if you clean this.", systemImage: "xmark.app").stewardFont(.caption).foregroundStyle(.orange) }
                if finding.group == .worktrees { Label(usage(finding), systemImage: "clock").stewardFont(.caption).foregroundStyle(muted) }
                else { ForEach(finding.warnings ?? [], id: \.self) { Label($0, systemImage: "exclamationmark.triangle").stewardFont(.caption).foregroundStyle(.orange) } }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Modified \(finding.modifiedAt.formatted(date: .abbreviated, time: .shortened))").stewardFont(.caption).foregroundStyle(muted)
                    HStack { Button("Finder") { m.reveal(finding.path) }; if finding.rule == "xcode-managed-review" { Button("Open Xcode") { m.openXcode() } }; if finding.rule == BroadCaches.brewOldVersionsRule { Button("Run brew cleanup in Terminal") { m.runBrewCleanup(cellar: finding.path) }.help("Opens Terminal and runs Homebrew's own cleanup there") }; if finding.group == .worktrees { Button("Delete…") { m.requestWorktreeRemoval([finding]) }.disabled(m.busy || finding.safety != .review).help(finding.safety == .review ? String(localized: "Review and delete this merged worktree") : finding.reason) }; if finding.safety == .automatic { Button("Select to clean") { m.selected.insert(finding.id) }.disabled(m.selected.contains(finding.id) || m.busy) }; Button { m.ignore(finding) } label: { Text("Keep", comment: "Button: keep this item and never suggest it again") } }
                        .buttonStyle(.bordered).stewardFont(.body).foregroundStyle(mint)
                }
            }
        }.padding(14).background(panel, in: RoundedRectangle(cornerRadius: 12))
    }
    private func usage(_ finding: Finding) -> String {
        guard let used = finding.lastUsedAt else { return String(localized: "No agent session in 90 days") }
        if Date().timeIntervalSince(used) < 60 { return String(localized: "In use now") }
        return String(localized: "Used: \(used.formatted(.relative(presentation: .named)))")
    }
    private var worktreeSections: [(id: String, name: String, icon: String, detail: String, items: [Finding])] {
        let trees = m.report?.findings.filter { $0.group == .worktrees } ?? []
        return [
            ("Finished", String(localized: "Finished", comment: "Worktrees: merged and not in use"), "checkmark.circle", String(localized: "Merged and not in use. Safe to delete."), trees.filter { !StewardModel.inUse($0) && $0.safety == .review }),
            ("In use", String(localized: "In use"), "bolt.circle", String(localized: "A running process or a Claude Code or Codex session used these in the last 24 hours."), trees.filter(StewardModel.inUse)),
            ("Unfinished", String(localized: "Unfinished", comment: "Worktrees: uncommitted or unmerged work"), "lock.circle", String(localized: "Uncommitted edits or commits that are not merged. Always kept."), trees.filter { !StewardModel.inUse($0) && $0.safety != .review })
        ]
    }
    var worktrees: some View {
        let sections = worktreeSections
        let current = sections.first { $0.id == worktreeSection } ?? sections[0]
        return VStack(alignment: .leading, spacing: 16) {
            title(String(localized: "Your worktrees"), String(localized: "See what is in use. Delete what is finished."))
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sections, id: \.id) { section in
                            Button { worktreeSection = section.id } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: section.icon).frame(width: 20).foregroundStyle(mint)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(section.name).stewardFont(.body, weight: .semibold)
                                        Text("\(section.items.count) · \(formattedBytes(section.items.reduce(0) { $0 + $1.bytes }))").stewardFont(.caption).foregroundStyle(muted)
                                    }
                                    Spacer()
                                }.padding(12).contentShape(Rectangle())
                                .background(worktreeSection == section.id ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                    }.padding(8).frame(width: min(250, geometry.size.width * 0.34), height: geometry.size.height)
                    .background(panel, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(current.detail).stewardFont(.body).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                        let finished = current.items.filter { $0.safety == .review && !StewardModel.inUse($0) }
                        let chosen = m.reviewableWorktrees.filter { m.worktreeSelection.contains($0.id) }
                        if !finished.isEmpty {
                            BulkBar(title: String(localized: "Select all"), isOn: Binding(get: { m.allSelected(finished) }, set: { m.setSelected(finished, $0) }), enabled: !m.busy, summary: String(localized: "\(chosen.count) selected · \(formattedBytes(chosen.reduce(0) { $0 + $1.bytes }))")) {
                                Button("Delete \(chosen.count)…") { m.requestWorktreeRemoval(chosen) }.buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(chosen.isEmpty || m.busy)
                            }
                        }
                        if current.items.isEmpty { empty(m.report == nil ? String(localized: "Scan to inspect your worktrees.") : String(localized: "Nothing here."), String(localized: "Claude Code and Codex checkouts appear here with Git evidence.")) }
                        ScrollView {
                            LazyVStack(spacing: 2) { ForEach(current.items) { worktreeRow($0) } }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }
    private func worktreeRow(_ finding: Finding) -> some View {
        HStack(spacing: 12) {
            if finding.safety == .review {
                Toggle("Select", isOn: Binding(get: { m.worktreeSelection.contains(finding.id) }, set: { if $0 { m.worktreeSelection.insert(finding.id) } else { m.worktreeSelection.remove(finding.id) } })).toggleStyle(.stewardCheckboxOnly)
            } else { Image(systemName: "lock.fill").foregroundStyle(muted).frame(width: 15) }
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).stewardFont(.body, weight: .semibold).lineLimit(1)
                Text((finding.warnings ?? []).reduce(finding.reason) { $0.replacingOccurrences(of: " " + $1, with: "") }).stewardFont(.caption).foregroundStyle(muted).lineLimit(1)
                ForEach(finding.warnings ?? [], id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").stewardFont(.caption).foregroundStyle(.orange).lineLimit(1) }
            }
            Spacer(minLength: 12)
            Text(usage(finding)).stewardFont(.caption).foregroundStyle(muted).frame(width: 150, alignment: .trailing)
            Text(formattedBytes(finding.bytes)).stewardFont(.callout, weight: .medium).foregroundStyle(mint).frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .help(finding.path)
        .contextMenu {
            Button("Reveal in Finder") { m.reveal(finding.path) }
            Button("Always keep") { m.ignore(finding) }
        }
    }
    var duplicatesDetails: some View {
        VStack(alignment: .leading, spacing: 20) {
            if m.section != "My Clutter" { title(String(localized: "Same content. Clear evidence."), String(localized: "Exact duplicate files anywhere in your home folder, compared locally by SHA-256.")) }
            DuplicatesView { paths in m.recheckDuplicates(paths) { safe in duplicateTrash = TrashRequest(urls: safe.map { URL(fileURLWithPath: $0) }) } }
        }.sheet(item: $duplicateTrash) { request in
            TrashReviewSheet(urls: request.urls, duplicateGroups: m.duplicates) { results in m.removeDuplicates(results.filter { $0.error == nil }.map(\.path)) }
        }
    }
    /// One switch for everyone: Settings › Automation › on. Weekly, and right away when space gets low.
    private var keepSpaceFreeCard: some View {
        let keeper = m.keeper
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                if let art = CategoryArt.images["drive"] { Image(nsImage: art).resizable().frame(width: 58, height: 58) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep space free").stewardFont(.title3, weight: .semibold)
                    Text("Cleans known caches that rebuild themselves, for apps you're not using. Weekly, and right away when space gets low. If that isn't enough, it asks before removing anything else.")
                        .stewardFont(.body).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("Keep space free", isOn: Binding(get: { keeper.enabled }, set: { keeper.enabled = $0 })).labelsHidden().toggleStyle(.switch).tint(mint).controlSize(.large)
            }
            if keeper.enabled {
                HStack(spacing: 10) {
                    if keeper.running {
                        ProgressView().controlSize(.small)
                        Text("Cleaning now…").stewardFont(.callout)
                    } else if let last = keeper.lastRun {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(mint)
                        Text("Last run: \(last.formatted(.relative(presentation: .named))) · freed \(formattedBytes(keeper.lastFreed))").stewardFont(.callout)
                    } else {
                        Image(systemName: "clock").foregroundStyle(muted)
                        Text("First run starts in a moment.").stewardFont(.callout).foregroundStyle(muted)
                    }
                    Spacer()
                    Button { keeper.run(m.configuration) } label: { Text("Run now", comment: "Button: run the space-keeping cleanup now") }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)).disabled(keeper.running || m.busy)
                }
                if keeper.needsReview && !keeper.running {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text("Still low on space. Larger items need your choice.").stewardFont(.callout)
                        Spacer()
                        Button { m.reviewLowSpace() } label: { Text("Review", comment: "Button: open the details and choose what goes") }.buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(m.busy)
                    }
                }
                if keeper.hasXcode {
                    Toggle("Also delete simulators Xcode can no longer run, with the apps and data inside", isOn: Binding(get: { keeper.includeSimulators }, set: { keeper.includeSimulators = $0 }))
                        .toggleStyle(.stewardCheckbox).stewardFont(.callout)
                }
            }
            Label("Never touches your documents, downloads, sign-ins, or apps that are open.", systemImage: "lock")
                .stewardFont(.caption).foregroundStyle(muted)
        }.padding(25).background(panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(mint.opacity(keeper.enabled ? 0.45 : 0), lineWidth: 1) }
        .animation(.easeOut(duration: 0.2), value: keeper.enabled)
    }
    var automation: some View {
        VStack(alignment: .leading, spacing: 24) {
            title(String(localized: "A routine you can trust."), String(localized: "Off by default. Conservative by design."))
            keepSpaceFreeCard
            VStack(alignment: .leading, spacing: 20) {
                Toggle(isOn: Binding(get: { m.scheduleEnabled }, set: { m.setSchedule($0) })) { VStack(alignment: .leading, spacing: 6) { Text("Daily safe cleanup").stewardFont(.headline); Text("12:15 local time, as your signed-in user. Install in Applications first.").stewardFont(.body).foregroundStyle(muted) } }.toggleStyle(.switch).tint(mint)
                Divider()
                Label("Only allowlisted caches older than seven days", systemImage: "checkmark")
                Label("Fresh process, Git and filesystem checks each run", systemImage: "checkmark")
                Label("Never removes worktrees, source, databases or original assets", systemImage: "lock")
                Label("Every removal and skip gets a local receipt", systemImage: "doc.text")
            }.stewardFont(.body).padding(25).background(panel, in: RoundedRectangle(cornerRadius: 16))
            Toggle("Include recognised application web caches in manual scans", isOn: $m.includeAppCaches).onChange(of: m.includeAppCaches) { _, value in StewardPreferences.defaults.set(value, forKey: "includeAppCaches") }.stewardFont(.body)
            Text("App caches are not included in scheduled cleanup. The schedule is a user LaunchAgent; it requests no administrator access and runs without a network service.").stewardFont(.body).foregroundStyle(muted)
            if !m.ignores.isEmpty {
                Text("Always keep").stewardFont(.headline)
                ForEach(m.ignores, id: \.self) { path in HStack { Text(path).stewardFont(.callout, design: .monospaced).lineLimit(2); Spacer(); Button("Remove exception") { m.ignores.removeAll { $0 == path }; StewardPreferences.defaults.set(m.ignores, forKey: "ignoredPaths") } }.foregroundStyle(muted) }
            }
        }
    }
    var activity: some View {
        VStack(alignment: .leading, spacing: 20) {
            title(String(localized: "A receipt, not a promise."), String(localized: "Content removed and actual free-space change are different measurements."))
            Button("Open local receipts") { m.showReceipts() }.buttonStyle(.bordered)
            if let receipt = m.receipt {
                HStack(spacing: 40) {
                    metric(String(localized: "CACHES REMOVED"), receipt.removedCount.formatted())
                    metric(String(localized: "FREE BEFORE"), formattedBytes(receipt.before.free))
                    metric(String(localized: "FREE AFTER"), formattedBytes(receipt.after.free))
                }.padding(25).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 16))
                Text("Measured change: \(receipt.measuredChange >= 0 ? "+" : "−")\(formattedBytes(UInt64(abs(receipt.measuredChange)))). Other applications and shared filesystem blocks can affect this number.").stewardFont(.body).foregroundStyle(muted)
                ForEach(Array(receipt.items.enumerated()), id: \.offset) { _, item in VStack(alignment: .leading, spacing: 6) { HStack { Text(item.outcome == "removed" ? "REMOVED" : "SKIPPED", comment: "Receipt: what happened to this item").foregroundStyle(item.outcome == "removed" ? mint : .orange).stewardFont(.caption, weight: .bold); Text(URL(fileURLWithPath: item.path).lastPathComponent).stewardFont(.body) }; Text(item.detail).stewardFont(.callout).foregroundStyle(muted).textSelection(.enabled) }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 12)) }
            } else { empty(String(localized: "No cleanup in this session."), String(localized: "Older JSON receipts stay in your local application support folder.")) }
        }
    }
    /// Groups that are always reviewed one by one, never cleaned from a tile.
    private static let reviewOnlyGroups: Set<CleanupGroup> = [.worktrees, .inactiveDependencies]
    /// Everything found that you can choose to delete here: ready items, held caches you can tick,
    /// and finished worktrees. Not counted: what only Xcode manages, unfinished work, or anything kept on purpose.
    private static func found(_ findings: [Finding]) -> UInt64 {
        findings.filter { $0.userCleanable || ($0.group == .worktrees && $0.safety == .review) }.reduce(0) { $0 + $1.bytes }
    }
    /// What a Clean or Run takes without asking.
    private static func ready(_ findings: [Finding]) -> UInt64 { findings.filter { $0.safety == .automatic && !reviewOnlyGroups.contains($0.group) }.reduce(0) { $0 + $1.bytes } }
    private static func readyLine(_ findings: [Finding]) -> String {
        let ready = ready(findings), rest = found(findings) - min(found(findings), ready)
        if ready > 0 && rest > 0 { return String(localized: "\(formattedBytes(ready)) ready · \(formattedBytes(rest)) for you to choose") }
        return ready > 0 ? String(localized: "\(formattedBytes(ready)) ready to clean") : rest > 0 ? String(localized: "Review to choose what goes") : String(localized: "Nothing to clean")
    }
    private var cleanupSummary: some View {
        let findings = m.report?.findings ?? []
        let groups = CleanupGroup.allCases.filter { group in findings.contains { $0.group == group } }
        return VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("You can free up to \(formattedBytes(Self.found(findings))).").stewardFont(.title, weight: .semibold).multilineTextAlignment(.center)
                Text(Self.readyLine(findings)).stewardFont(.body).foregroundStyle(muted)
            }
            // Exactly what the tile checkboxes (and the Review list) have ticked; recommended items start ticked.
            let chosenItems = findings.filter { m.selected.contains($0.id) && $0.userCleanable && $0.group != .worktrees }
            let chosenWorktrees = m.reviewableWorktrees.filter { m.worktreeSelection.contains($0.id) }
            let chosenBrowsers = browsersTicked ? closedBrowserCaches : []
            let chosenTrash = trashTicked && m.trashBins.report?.items != 0
            let chosenBytes = (chosenItems + chosenWorktrees).reduce(UInt64(0)) { $0 + $1.bytes } + chosenBrowsers.reduce(UInt64(0)) { $0 + $1.bytes } + (chosenTrash ? m.trashBins.report?.bytes ?? 0 : 0)
            HStack(spacing: 12) {
                Button { m.review(); cleanupReviewing = true } label: { Label("Review all", systemImage: "list.bullet") }.buttonStyle(CleanupGlassButtonStyle(secondary: true))
                Button { confirmRemoval(chosenItems, worktrees: chosenWorktrees, browsers: chosenBrowsers, trash: chosenTrash) } label: { Label(chosenBytes > 0 ? "Remove selected · \(formattedBytes(chosenBytes))" : "Remove selected", systemImage: "sparkles") }
                    .buttonStyle(CleanupGlassButtonStyle()).disabled((chosenItems.isEmpty && chosenWorktrees.isEmpty && chosenBrowsers.isEmpty && !chosenTrash) || m.busy)
            }.stewardFont(.body, weight: .semibold)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                ForEach(groups) { group in
                    let items = findings.filter { $0.group == group }
                    let eligible = items.filter { $0.safety == .automatic }
                    groupTile(group, items: items, eligible: eligible)
                }
                trashTile
                browsersTile
            }
        }.frame(maxWidth: .infinity)
        .onAppear { if m.browsers.reports == nil { m.browsers.scan() }; if m.trashBins.report == nil { m.trashBins.inspect() } }
    }
    /// One confirmation for everything ticked, then each remover in turn. The Trash goes last, so it also takes whatever the others moved there.
    private func confirmRemoval(_ items: [Finding], worktrees: [Finding] = [], browsers: [BrowserItem] = [], trash: Bool = false, duplicates: [String] = [], leftovers: [LeftoverItem] = [], quitting: [MemoryAppUsage] = []) {
        var extras = [CleanExtra](), steps = [() -> Void]()
        // Inside the step, so Cancel leaves the page and the ticks as they were.
        if !items.isEmpty { steps.append { m.review(); m.selected = Set(items.map(\.id)); m.clean() } }
        if !worktrees.isEmpty {
            extras.append(CleanExtra(icon: CleanupGroup.worktrees.icon, title: CleanupGroup.worktrees.title, bytes: worktrees.reduce(0) { $0 + $1.bytes }, warning: String(localized: "Git rechecks each worktree next, and you confirm them one more time.")))
            steps.append { m.requestWorktreeRemoval(worktrees) }
        }
        if !duplicates.isEmpty {
            extras.append(CleanExtra(icon: "square.on.square", title: sectionTitle("Duplicates"), bytes: chosenDuplicateBytes))
            steps.append {
                m.recheckDuplicates(duplicates) { safe in
                    m.trashConfirmed(safe.map { URL(fileURLWithPath: $0) }, duplicateGroups: m.duplicates) { results in m.removeDuplicates(results.filter { $0.error == nil }.map(\.path)) }
                }
            }
        }
        if !leftovers.isEmpty {
            extras.append(CleanExtra(icon: "shippingbox", title: sectionTitle("Leftovers"), bytes: leftovers.reduce(0) { $0 + $1.bytes }))
            steps.append { m.trashConfirmed(leftovers.map(\.url), allowLeftovers: true) { _ in m.leftovers.scan(); m.disk = .read() } }
        }
        if !browsers.isEmpty {
            extras.append(CleanExtra(icon: "globe", title: String(localized: "Browser caches"), bytes: browsers.reduce(0) { $0 + $1.bytes }))
            steps.append { m.browsers.selection = Set(browsers.map(\.id)); m.browsers.clean(on: m) { m.disk = .read() } }
        }
        if trash {
            extras.append(CleanExtra(icon: "trash", title: String(localized: "Trash"), bytes: m.trashBins.report?.bytes, warning: String(localized: "Everything in the Trash is deleted permanently and cannot be put back.")))
            steps.append { trashTicked = false; m.trashBins.empty(on: m) { m.disk = .read() } }
        }
        if !quitting.isEmpty {
            let names = quitting.map(\.app.name.displaySafe).joined(separator: ", ")
            extras.append(CleanExtra(icon: "memorychip", title: sectionTitle("Performance"), bytes: nil, warning: String(localized: "\(names) will be asked to quit. Save your work if they ask.")))
            steps.append { quitting.forEach { m.memory.quit($0) }; runQuitApps = false; m.runNextRemoval() }
        }
        pendingRemoval = PendingRemoval(findings: items, extras: extras, steps: steps)
    }
    /// Recommended caches of closed browsers: the only ones that can go right now.
    private var closedBrowserCaches: [BrowserItem] {
        (m.browsers.reports ?? []).filter { $0.readable && !BrowserData.isRunning($0.bundleID) }.flatMap(\.items).filter(\.recommended)
    }
    private var trashTile: some View {
        let report = m.trashBins.report
        let empty = report == nil || report?.items == 0
        let ticked = trashTicked && !empty
        let status = empty ? (report == nil ? String(localized: "Checking…") : String(localized: "Empty", comment: "The Trash holds nothing")) : !ticked ? String(localized: "Not selected") : report?.bytes.map { String(localized: "\(formattedBytes($0)) selected") } ?? String(localized: "Selected")
        return CategoryTile(amount: report?.bytes.map(formattedBytes), name: String(localized: "Trash"), tagline: String(localized: "Deleted files still using space"), art: "trash", status: status,
                            chosen: Binding(get: { ticked }, set: { trashTicked = $0 }), canChoose: !empty, review: { m.section = "Trash bins" },
                            clean: ticked ? { confirmRemoval([], trash: true) } : nil)
    }
    private var browsersTile: some View {
        let reports = m.browsers.reports
        let found: UInt64 = (reports ?? []).flatMap(\.items).filter(\.recommended).reduce(0) { $0 + $1.bytes }
        let closed = closedBrowserCaches
        let bytes: UInt64 = closed.reduce(0) { $0 + $1.bytes }
        let ticked = browsersTicked && !closed.isEmpty
        let status = reports == nil ? String(localized: "Checking…") : closed.isEmpty ? (found > 0 ? String(localized: "Browser open") : String(localized: "Nothing to clean")) : ticked ? String(localized: "\(formattedBytes(bytes)) selected") : String(localized: "Not selected")
        return CategoryTile(amount: reports.map { _ in formattedBytes(found) }, name: String(localized: "Browser caches"), tagline: String(localized: "Rebuilt as you browse. You stay signed in."), art: "globe",
                            appIcons: CategoryArt.appIcons(bundleIDs: reports?.map(\.bundleID) ?? []), status: status,
                            chosen: Binding(get: { ticked }, set: { browsersTicked = $0 }), canChoose: !closed.isEmpty, review: { m.section = "Browsers" },
                            clean: ticked ? { confirmRemoval([], browsers: closed) } : nil)
    }
    /// A Cleanup category: a big amount, what it is, art or the apps behind it, one short line.
    /// Kept as its own function: inlined in the grid, this expression took the compiler minutes to type-check.
    private func groupTile(_ group: CleanupGroup, items: [Finding], eligible: [Finding]) -> some View {
        let foundBytes: UInt64 = Self.found(items)
        let icons: [NSImage]
        switch group {
        case .agentBuilds: icons = CategoryArt.appIcons(bundleIDs: CategoryArt.aiApps)
        case .userCaches: icons = CategoryArt.appIcons(bundleIDs: items.sorted { $0.bytes > $1.bytes }.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        default: icons = []
        }
        // Same checkbox on every tile. Worktrees keep their own selection: finished ones only, rechecked with Git before they go.
        let isWorktrees = group == .worktrees
        let choosable = isWorktrees ? m.reviewableWorktrees : items.filter(\.userCleanable)
        let ticked = choosable.filter { (isWorktrees ? m.worktreeSelection : m.selected).contains($0.id) }
        let tickedBytes = ticked.reduce(UInt64(0)) { $0 + $1.bytes }
        let inUse = items.contains { $0.hold == .inUse }
        let status: String = tickedBytes > 0 ? String(localized: "\(formattedBytes(tickedBytes)) selected") : !choosable.isEmpty ? String(localized: "Not selected") : inUse ? String(localized: "In use") : String(localized: "Kept")
        let chosen = Binding<Bool>(get: { !ticked.isEmpty }, set: { on in
            // Ticking takes everything you can delete in the tile; unticking clears it. Review picks single items.
            let ids = choosable.map(\.id)
            if isWorktrees { if on { m.worktreeSelection.formUnion(ids) } else { m.worktreeSelection.subtract(ids) } }
            else if on { m.selected.formUnion(ids) } else { m.selected.subtract(items.map(\.id)) }
        })
        let clean: (() -> Void)? = ticked.isEmpty ? nil : isWorktrees ? { m.requestWorktreeRemoval(ticked) } : { m.review(group); m.selected = Set(ticked.map(\.id)); pendingRemoval = PendingRemoval() }
        return CategoryTile(amount: foundBytes > 0 ? formattedBytes(foundBytes) : nil, name: group.title, tagline: CategoryArt.tagline(for: group),
                            art: CategoryArt.name(for: group), appIcons: icons, status: status, chosen: chosen, canChoose: !choosable.isEmpty,
                            review: { m.review(group); cleanupReviewing = true }, clean: clean)
    }
    /// A module page: one heading and a tab per tool it groups.
    func module<Content: View>(_ heading: String, _ detail: String, tabs: [String], selection: Binding<String>, summary: [String], scanAll: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                title(sectionTitle(heading), detail)
                Spacer()
                Button("Scan all") { scanAll() }.buttonStyle(CleanupGlassButtonStyle()).disabled(m.busy)
            }
            // Same segment control as Settings; what the module's scan found for this tab sits beside it.
            HStack(spacing: 12) {
                Picker(sectionTitle(heading), selection: selection) { ForEach(tabs, id: \.self) { Text(sectionTitle($0)).tag($0) } }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(minLength: 8)
                if let index = tabs.firstIndex(of: selection.wrappedValue), index < summary.count {
                    Text(summary[index]).stewardFont(.callout, weight: .medium).foregroundStyle(muted).lineLimit(1)
                }
            }
            content().environment(\.stewardInModule, true)
        }
    }
    private var clutterSummary: [String] {
        [m.duplicateChecked ? String(localized: "\(m.duplicates.count) groups · \(formattedBytes(m.duplicates.reduce(0) { $0 + $1.potentialBytes }))") : String(localized: "Not scanned"),
         m.largeFiles.report.map { String(localized: "\($0.files.count) files · \(formattedBytes($0.files.reduce(0) { $0 + $1.localBytes }))") } ?? (m.largeFiles.task != nil ? String(localized: "Scanning…") : String(localized: "Not scanned"))]
    }
    private func scanClutter() { m.scanDuplicates(); m.largeFiles.scan(m.largeFileLocation.url) }
    private var performanceSummary: [String] {
        // Health and pressure, not a GB figure: this card refreshes throttled, so a live number would disagree with the ring below.
        [m.memory.reading.map { reading in
            let score = MemoryVerdict.evaluate(pressure: reading.pressure, swap: reading.swap, total: reading.total, loginItems: m.startup.loginItems?.count).score
            switch reading.pressure {
            case .normal: return String(localized: "Health \(score) · Normal pressure")
            case .warning: return String(localized: "Health \(score) · Elevated pressure")
            case .critical: return String(localized: "Health \(score) · High pressure")
            case .unknown: return String(localized: "Health \(score) · Pressure unavailable")
            }
        } ?? String(localized: "Reading…"),
         m.startup.loginItems.map { items in
            let agents = String(localized: "\(m.startup.agents.count) agents")
            return String(localized: "\(items.count) at login · \(agents)")
        } ?? String(localized: "Not scanned")]
    }
    private var applicationsSummary: [String] {
        [String(localized: "Installed apps"), m.leftovers.items.map { String(localized: "\($0.count) · \(formattedBytes($0.reduce(0) { $0 + $1.bytes }))") } ?? (m.leftovers.busy ? String(localized: "Scanning…") : String(localized: "Not scanned"))]
    }
    func title(_ heading: String, _ detail: String) -> some View { VStack(alignment: .leading, spacing: 10) { Text(heading).stewardFont(.title, weight: .semibold).tracking(-0.5); Text(detail).stewardFont(.body).foregroundStyle(muted) }.padding(.bottom, 7) }
    func empty(_ heading: String, _ detail: String) -> some View { VStack(alignment: .leading, spacing: 10) { Text(heading).stewardFont(.headline, weight: .medium); Text(detail).stewardFont(.body).foregroundStyle(muted) }.padding(23).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 14)) }
    func metric(_ label: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 12) { Text(label).stewardFont(.caption, weight: .semibold).tracking(1).foregroundStyle(muted); Text(value).stewardFont(.title2, weight: .semibold) } }
    @ViewBuilder private var footerAction: some View {
        if m.busy && !m.scanning { Text("Please wait…").stewardFont(.body) }
        else if m.section == "Cleanup" || overviewDetail == "Cleanup" {
            Button { pendingRemoval = PendingRemoval() } label: {
                Label(m.selectedFindings.isEmpty ? (m.scopeEligible.isEmpty ? "Tick what you want to clean" : "Select caches to clean") : "Clean \(m.selectedFindings.count) caches · \(formattedBytes(m.selectedBytes))", systemImage: "sparkles")
                    .fixedSize(horizontal: false, vertical: true)
            }.buttonStyle(CleanupGlassButtonStyle())
                .stewardFont(.body, weight: .semibold).disabled(m.busy || m.selectedFindings.isEmpty)
        } else if m.section == "Worktrees" {
            let chosen = m.reviewableWorktrees.filter { m.worktreeSelection.contains($0.id) }
            Button { m.requestWorktreeRemoval(chosen) } label: {
                Label(chosen.isEmpty ? "Select finished worktrees" : "Delete \(chosen.count) worktrees · \(formattedBytes(chosen.reduce(0) { $0 + $1.bytes }))", systemImage: "trash")
            }.buttonStyle(CleanupGlassButtonStyle()).stewardFont(.body, weight: .semibold).disabled(m.busy || chosen.isEmpty)
        } else { Text("Review comes before removal").stewardFont(.caption).foregroundStyle(muted) }
    }
    private var footerStatus: some View {
        HStack(spacing: 10) {
            if m.busy { StewardProgressBar().frame(width: 90) } else { Image(systemName: "checkmark.shield").foregroundStyle(mint) }
            Text(m.progress).stewardFont(.body).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { footerStatus; Spacer(); footerAction }
            VStack(alignment: .leading, spacing: 10) { footerStatus; footerAction }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 14).background(panel.opacity(0.7))
    }
}

private struct ScanSidebarTransition: ViewModifier, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        content.opacity(Double(progress)).blur(radius: (1 - progress) * 10)
            .scaleEffect(0.96 + progress * 0.04, anchor: .leading).offset(x: (1 - progress) * -28)
    }
}

/// Thin macOS overlay scrollers that stay hidden until the pointer is over the list or it scrolls,
/// even when System Settings asks for always-visible scroll bars. Apply to the ScrollView's content.
private final class ScrollViewBox { weak var view: NSScrollView? }
private struct OverlayScrollers: ViewModifier {
    @State private var box = ScrollViewBox()
    func body(content: Content) -> some View {
        content.background(Finder(box: box)).onHover { if $0 { box.view?.flashScrollers() } }
    }
    private struct Finder: NSViewRepresentable {
        let box: ScrollViewBox
        func makeNSView(context: Context) -> NSView { Probe(box: box) }
        func updateNSView(_ view: NSView, context: Context) {}
    }
    private final class Probe: NSView {
        let box: ScrollViewBox
        init(box: ScrollViewBox) { self.box = box; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let scrollView = enclosingScrollView else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            box.view = scrollView
            // AppKit switches back to wide scrollers when the system setting asks for them; keep these overlay.
            NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { [weak scrollView] _ in
                MainActor.assumeIsolated { scrollView?.scrollerStyle = .overlay }
            }
        }
    }
}
extension View { func overlayScrollers() -> some View { modifier(OverlayScrollers()) } }

/// A note's first sentence, by the text's own punctuation: Japanese ends one with "。", and a German "z. B." doesn't.
private func firstSentence(_ text: String) -> String {
    var first = text
    text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, stop in
        first = sentence?.trimmingCharacters(in: .whitespaces) ?? text
        stop = true
    }
    return first
}
