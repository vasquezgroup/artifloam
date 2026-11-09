import SwiftUI
import AppKit
import MacStewardCore

/// The word for the connected device: iPhone or iPad once one has been read, both until then.
enum DeviceWord {
    nonisolated(unsafe) static var kind: String?
    /// For sentences: "Unlock your iPad", or "Unlock your iPhone or iPad" before one has been read.
    static var text: String { kind ?? String(localized: "iPhone or iPad") }
    /// For the sidebar and the page title.
    static var title: String { kind ?? String(localized: "Device", comment: "Sidebar: an iPhone or iPad connected to this Mac") }
}

/// What the iPhone page knows. It connects to an iPhone on a cable by itself, and to any other only after it's picked.
@MainActor
final class IPhoneState: ObservableObject {
    @Published private(set) var devices = [IPhoneDevice]()
    @Published private(set) var frameworkMissing = false
    @Published private(set) var picked: IPhoneDevice?
    @Published private(set) var reading = false
    @Published private(set) var problem: IPhoneReadError?
    @Published private(set) var report: IPhoneAppsReport? { didSet { DeviceWord.kind = report?.deviceKind } }
    /// The person went straight to a backup, without reading an iPhone.
    @Published private(set) var backupsOnly = false
    @Published private(set) var backups: [IPhoneBackup]?
    @Published private(set) var backupProblem: WhatsAppBackupError?
    @Published private(set) var readingBackup = false
    @Published private(set) var whatsApp: (backup: IPhoneBackup, report: WhatsAppReport)?
    /// Bundle ID to the newest data change, from a backup. Empty until one is read.
    @Published private(set) var lastChanged = [String: Date]()
    @Published var group: IPhoneAppGroup?
    @Published var selection = Set<String>()
    @Published var removalPlan: IPhoneRemovalPlan?
    /// Deleting apps runs on the centred stage, like removals on the Mac.
    @Published private(set) var stage: RemovalProgress?
    var removing: Bool { stage != nil }
    private var stageStop = false
    @Published private(set) var removalResult: IPhoneRemovalResult?
    @Published private(set) var removalProblem = false
    /// Waiting for the person to unlock before something that needs it. Shown as a large overlay.
    @Published private(set) var waitingForUnlock = false
    private var unlockOverride = false
    private var unlockCancelled = false
    /// Waits until the iPhone is unlocked. False if the person cancelled. If it can't be asked, carries on: the result is checked afterwards anyway.
    private func waitForUnlock(_ id: String) async -> Bool {
        let watcher = watcher
        unlockOverride = false; unlockCancelled = false
        while !unlockOverride && !unlockCancelled {
            let locked = await Task.detached(priority: .userInitiated) { watcher.isLocked(deviceID: id) }.value
            guard locked == true else { break }
            waitingForUnlock = true
            try? await Task.sleep(for: .seconds(1.5))
        }
        waitingForUnlock = false
        return !unlockCancelled
    }
    func continueAnyway() { unlockOverride = true }
    func cancelUnlock() { unlockCancelled = true }
    @Published private(set) var makingBackup = false
    @Published private(set) var backupFailed = false
    /// Made by this app for a phone that had no backup here, so it's the person's choice to remove it right after reading.
    @Published private(set) var removableBackup: IPhoneBackup?
    var insights: IPhoneInsights? { report.map { IPhoneInsights(apps: $0.apps, lastChanged: lastChanged) } }
    private let watcher = IPhoneDeviceWatcher()
    /// A read can't be cancelled once it is talking to the iPhone, so a stopped one must finish before the next starts.
    @Published private var readInFlight = false
    private final class ProcessHolder: @unchecked Sendable { var process: Process? }
    private let backupHolder = ProcessHolder()
    private var generation = 0

    var onStage: Bool { reading || (report == nil && !backupsOnly) }
    /// Read stays available while an earlier read is still waiting on the iPhone. It then starts again as soon as that one ends.
    var canRead: Bool { picked != nil }
    private var readAgain = false
    /// Backups of the iPhone just read. Others show only if it has none here, so the person can pick one.
    var shownBackups: [IPhoneBackup] {
        let all = backups ?? []
        guard let report else { return all }
        let own = all.filter { $0.belongs(toDevice: report.deviceID) }
        return own.isEmpty ? all : own
    }
    /// False until backups have been listed and this iPhone's isn't among them, or nothing is known yet.
    var hasOwnBackupKnown: Bool { report.map { report in (backups ?? []).contains { $0.belongs(toDevice: report.deviceID) } } ?? false }
    var hasOwnBackup: Bool { report.map { report in (backups ?? []).contains { $0.belongs(toDevice: report.deviceID) } } ?? true }
    var stageLine: String {
        if frameworkMissing { return String(localized: "This Mac is missing the Apple software that talks to iPhones. Connecting an iPhone in Finder once usually installs it.") }
        switch problem {
        case .needsTrust: return String(localized: "Unlock your \(DeviceWord.text) and tap Trust. If nothing appears, select it in Finder once, then press Read again.")
        case .unreachable: return String(localized: "Your \(DeviceWord.text) didn't answer. Unlock it, check the cable and press Read again.")
        case .deviceGone: return String(localized: "That \(DeviceWord.text) is no longer connected.")
        case .frameworkMissing: return String(localized: "This Mac is missing the Apple software that talks to iPhones. Connecting an iPhone in Finder once usually installs it.")
        case .failed(let code): return String(localized: "Your \(DeviceWord.text) couldn't list its apps (error \(code)). Unlock it and try again.")
        case nil: break
        }
        if devices.isEmpty { return String(localized: "Connect your \(DeviceWord.text) with a cable and unlock it.") }
        return picked == nil ? String(localized: "Choose your \(DeviceWord.text). Only the one you choose is read.") : String(localized: "Press Read to list its apps by size.")
    }

    /// Listening for iPhones connects to none of them.
    func watch() {
        frameworkMissing = !watcher.start { [weak self] devices in
            Task { @MainActor in self?.update(devices) }
        }
    }
    private func update(_ devices: [IPhoneDevice]) {
        self.devices = devices
        if let picked, !devices.contains(picked) { self.picked = nil; if problem != nil { problem = nil } }
        // Chosen in advance when there's only one, but nothing is read until Read is pressed.
        if picked == nil, let only = IPhoneDevice.preselected(from: devices) { pick(only) }
    }
    func pick(_ device: IPhoneDevice) { picked = device; problem = nil }
    func read() {
        guard let picked, canRead else { return }
        if readInFlight {
            generation += 1
            reading = true; problem = nil; readAgain = true
            return
        }
        generation += 1
        let current = generation, watcher = watcher, id = picked.id
        reading = true; readInFlight = true; problem = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try watcher.read(deviceID: id) } }.value
            readInFlight = false
            if readAgain { readAgain = false; read(); return }
            guard current == generation else { return }
            reading = false
            switch result {
            case .success(let report):
                self.report = report
                IPhoneAppListSender.shared.offer(report)
            case .failure(let error): problem = error as? IPhoneReadError ?? .failed(-1)
            }
        }
    }
    func stop() { generation += 1; reading = false; readAgain = false }
    func openBackups() { backupsOnly = true; findBackups() }
    func findBackups() {
        generation += 1
        let current = generation
        backupProblem = nil; whatsApp = nil; readingBackup = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try WhatsAppBackup.backups() } }.value
            guard current == generation else { return }
            readingBackup = false
            switch result {
            case .success(let found): backups = found
            case .failure(let error): backupProblem = error as? WhatsAppBackupError ?? .unreadable
            }
        }
    }
    func readWhatsApp(_ backup: IPhoneBackup) {
        generation += 1
        let current = generation
        backupProblem = nil; readingBackup = true
        Task {
            async let changes = Task.detached(priority: .userInitiated) { WhatsAppBackup.lastChanged(backup) }.value
            let result = await Task.detached(priority: .userInitiated) { Result { try WhatsAppBackup.read(backup) } }.value
            let changed = await changes
            guard current == generation else { return }
            readingBackup = false
            lastChanged = changed
            switch result {
            case .success(let report): whatsApp = (backup, report)
            case .failure(let error): backupProblem = error as? WhatsAppBackupError ?? .unreadable
            }
        }
    }
    /// Backing up is optional, and only starts once the person has agreed. The tool needs the protected backups folder, so that's checked first.
    func makeBackup() {
        guard let report, !makingBackup else { return }
        backupProblem = nil; backupFailed = false
        let id = report.deviceID
        Task {
            let existing: [IPhoneBackup]
            do { existing = try await Task.detached { try WhatsAppBackup.backups() }.value }
            catch { backupProblem = error as? WhatsAppBackupError ?? .noAccess; return }
            let hadOne = existing.contains { $0.belongs(toDevice: id) }
            guard await waitForUnlock(id) else { return }
            makingBackup = true
            let holder = backupHolder
            let finished = await Task.detached(priority: .utility) { IPhoneBackupMaker.run(deviceID: id) { holder.process = $0 } }.value
            holder.process = nil
            makingBackup = false
            guard finished else { backupFailed = true; return }
            let found = (try? await Task.detached { try WhatsAppBackup.backups() }.value) ?? []
            backups = found
            guard let own = found.first(where: { $0.belongs(toDevice: id) }) else { backupFailed = true; return }
            removableBackup = hadOne ? nil : own
            readWhatsApp(own)
        }
    }
    func planRemoval() {
        guard let report else { return }
        removalPlan = IPhoneRemovalPlan(apps: report.apps.filter { selection.contains($0.id) }, backupIsOld: report.backupIsOld())
    }
    /// Removes exactly the reviewed apps, one at a time, then reads the iPhone again to see what really changed.
    func remove(_ plan: IPhoneRemovalPlan) {
        guard let report, !removing else { return }
        let id = report.deviceID, usedBefore = report.usedBytes, watcher = watcher
        removalPlan = nil; removalResult = nil; removalProblem = false; stageStop = false
        let copy = StageCopy(working: String(localized: "Deleting from your \(DeviceWord.text)…"), done: String(localized: "Deleted from your \(DeviceWord.text)"),
                             amount: String(localized: "freed", comment: "Under a byte counter: how much space was freed"), note: nil)
        stage = RemovalProgress(copy: copy, total: plan.apps.count, current: plan.apps.first.map { String(localized: "Removing \($0.name) from your \(DeviceWord.text). Keep it unlocked and connected.") } ?? "")
        StewardSound.start.play()
        Task {
            for (index, app) in plan.apps.enumerated() {
                guard !stageStop, await waitForUnlock(id) else { break }
                stage?.current = String(localized: "Removing \(app.name) from your \(DeviceWord.text). Keep it unlocked and connected.")
                let bundle = app.bundleID
                _ = await Task.detached(priority: .userInitiated) { Result { try watcher.uninstall(bundleID: bundle, deviceID: id) } }.value
                stage?.completed = index + 1
            }
            stage?.current = String(localized: "Reading your \(DeviceWord.text)…")
            let after = await Task.detached(priority: .userInitiated) { Result { try watcher.read(deviceID: id) } }.value
            selection = []
            switch after {
            case .success(let fresh):
                self.report = fresh
                let result = IPhoneRemovalResult(plan: plan, usedBefore: usedBefore, after: fresh)
                removalResult = result
                // Apps still there are listed on the page after Done, with what to do.
                stage?.completed = result.removed.count; stage?.bytes = result.freedBytes ?? 0
            case .failure: removalProblem = true
            }
            stage?.current = ""; stage?.stopped = stageStop; stage?.finished = true
            StewardSound.done.play()
        }
    }
    /// Stop finishes the app being removed, then skips the rest.
    func stopStage() { stageStop = true }
    func finishStage() { stage = nil }
    func stopBackup() { backupHolder.process?.terminate() }
    func removeBackup() {
        guard let backup = removableBackup else { return }
        do {
            try WhatsAppBackup.remove(backup)
            removableBackup = nil
            backups = backups?.filter { $0.id != backup.id }
        } catch { backupProblem = .unreadable }
    }
    func closeWhatsApp() { whatsApp = nil; backupProblem = nil }
    /// Forgets everything read and the pick, so nothing connects again until the person chooses.
    func reset() {
        generation += 1
        picked = nil; reading = false; problem = nil; report = nil; backupsOnly = false
        backups = nil; backupProblem = nil; readingBackup = false; whatsApp = nil; lastChanged = [:]; group = nil
        selection = []; removalPlan = nil; removalResult = nil; removalProblem = false
    }
}

/// Connected iPhones on the start screen, when it isn't clear which one is meant. See IPhoneDevice.automatic.
struct IPhoneDevicePicker: View {
    @ObservedObject var state: IPhoneState
    @EnvironmentObject private var m: StewardModel
    var body: some View {
        HStack(spacing: 8) {
            ForEach(state.devices) { device in
                let active = state.picked == device
                Button { state.pick(device) } label: {
                    Label(device.label, systemImage: active ? "checkmark.circle.fill" : "iphone").stewardFont(.callout, weight: active ? .semibold : .medium)
                        .foregroundStyle(.white).padding(.horizontal, 13).frame(height: 30)
                        .background(.white.opacity(active ? 0.2 : 0.08), in: Capsule())
                        .overlay { Capsule().stroke(.white.opacity(active ? 0.3 : 0.12), lineWidth: 0.7) }
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
            }
            Button { state.openBackups() } label: { Text("Use a backup on this Mac").stewardFont(.callout) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).padding(.leading, state.devices.isEmpty ? 0 : 6)
        }
    }
}

/// Results: every app by size, then WhatsApp per chat from a backup. Nothing here can change the iPhone.
struct IPhoneView: View {
    @ObservedObject var state: IPhoneState
    @EnvironmentObject private var m: StewardModel
    private let columnWidth: CGFloat = 104
    @State private var confirmingBackup = false
    @State private var confirmingRemoval = false
    private enum ListMode { case size, category, use }
    @State private var mode = ListMode.category
    @State private var showingAll = false
    @State private var expanded = Set<String>()
    private static let topCount = 15
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.report?.deviceName ?? sectionTitle("iPhone")).font(.system(size: 34, weight: .light))
                    if let report = state.report {
                        Text("\(report.apps.count) apps · \(formattedBytes(report.totalBytes))").stewardFont(.body).foregroundStyle(.secondary)
                    }
                    Label(state.report == nil ? "Read from a backup on this Mac. Nothing is changed." : "Sizes come from the \(DeviceWord.text). Nothing is changed on it.", systemImage: "lock.fill").stewardFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start over") { state.reset() }.buttonStyle(CleanupGlassButtonStyle(secondary: true))
            }
            if let report = state.report, let insights = state.insights {
                IPhoneBackupStatus(report: report)
                if let result = state.removalResult { IPhoneRemovalResultCard(result: result) }
                if state.removalProblem { Text("Your \(DeviceWord.text) stopped answering, so Artifloam can't confirm what was removed. Check it, then start over.").stewardFont(.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                IPhoneSpaceBar(apps: report.apps, total: report.totalBytes)
                IPhoneGroupTiles(insights: insights, hasBackup: !state.lastChanged.isEmpty, selected: $state.group)
                apps(report, insights)
            }
            whatsApp
        }
    }
    @ViewBuilder private func apps(_ report: IPhoneAppsReport, _ insights: IPhoneInsights) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if report.sizesMissing {
                Text("This \(DeviceWord.text) listed its apps but didn't report their sizes.").stewardFont(.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if report.apps.isEmpty { Text("This \(DeviceWord.text) reported no apps.").stewardFont(.body).foregroundStyle(.secondary) }
            else if let group = state.group {
                HStack(spacing: 8) {
                    Text(IPhoneGroupTiles.title(group)).stewardFont(.title3, weight: .semibold)
                    Button("Show all") { state.group = nil }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true))
                    Spacer()
                }
                bulkBar(insights.apps(in: group))
                columnTitles
                rows(insights.apps(in: group))
            } else {
                HStack {
                    Text("\(report.apps.count) apps").stewardFont(.title3, weight: .semibold)
                    Spacer()
                    Picker("Show apps by", selection: $mode) {
                        Text("Size").tag(ListMode.size)
                        Text("Category").tag(ListMode.category)
                        Text(state.lastChanged.isEmpty ? "Data" : "Use").tag(ListMode.use)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 270)
                }
                bulkBar(report.apps)
                switch mode {
                case .size:
                    columnTitles
                    rows(showingAll ? report.apps : Array(report.apps.prefix(Self.topCount)))
                    if !showingAll && report.apps.count > Self.topCount {
                        Button("Show all \(report.apps.count) apps") { showingAll = true }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true))
                    }
                case .category:
                    ForEach(insights.categories) { section($0.id, title: $0.id.isEmpty ? String(localized: "No category") : $0.id, $0.apps) }
                case .use:
                    Text(state.lastChanged.isEmpty ? "iOS doesn't tell a computer when an app was last opened, so this groups apps by how much data they hold. It's only a clue: apps like email keep their data online. A backup shows when each app last changed anything." : "From when each app's data last changed, according to the backup. Background activity counts too.")
                        .stewardFont(.caption).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                    ForEach(IPhoneAppUse.allCases.reversed()) { use in
                        section("use-\(use.rawValue)", title: useTitle(use), insights.apps(use: use))
                    }
                }
            }
        }
    }
    private func selectAll(_ apps: [IPhoneAppRow]) -> Binding<Bool> {
        let ids = apps.bulkSelectable.map(\.id)
        return Binding(get: { !ids.isEmpty && state.selection.isSuperset(of: ids) }, set: { if $0 { state.selection.formUnion(ids) } else { state.selection.subtract(ids) } })
    }
    private func bulkBar(_ apps: [IPhoneAppRow]) -> some View {
        let chosen = apps.filter { state.selection.contains($0.id) }
        let skipped = apps.count - apps.bulkSelectable.count
        return BulkBar(title: String(localized: "Select all", comment: "Checkbox: select every item in the list"), isOn: selectAll(apps), enabled: !state.removing,
                       help: skipped > 0 ? String(localized: "Chat and login-code apps can only be chosen one at a time") : String(localized: "Select or deselect everything listed"),
                       summary: String(localized: "\(chosen.count) selected · \(formattedBytes(chosen.reduce(0) { $0 + $1.totalBytes }))")) { EmptyView() }
    }
    private var columnTitles: some View {
        HStack(spacing: 8) {
            Spacer()
            Text("App").frame(width: columnWidth, alignment: .trailing)
            Text("Documents & Data").frame(width: columnWidth + 20, alignment: .trailing)
            Text("Total").frame(width: columnWidth, alignment: .trailing)
        }.stewardFont(.caption, weight: .semibold).foregroundStyle(.secondary).padding(.horizontal, 14)
    }
    private func rows(_ apps: [IPhoneAppRow]) -> some View { LazyVStack(spacing: 6) { ForEach(apps) { appRow($0) } } }
    private func useTitle(_ use: IPhoneAppUse) -> String {
        let dated = !state.lastChanged.isEmpty
        switch use {
        case .more: return dated ? String(localized: "Active this month") : String(localized: "Holds a lot of data")
        case .some: return dated ? String(localized: "Active in the last 6 months") : String(localized: "Holds some data")
        case .less: return dated ? String(localized: "Quiet for over 6 months") : String(localized: "Holds little data")
        }
    }
    /// A collapsed group: its name and total, with its apps only when opened, so 300 apps stay readable.
    @ViewBuilder private func section(_ id: String, title: String, _ apps: [IPhoneAppRow]) -> some View {
        if !apps.isEmpty {
            let open = expanded.contains(id), total = apps.reduce(UInt64(0)) { $0 + $1.totalBytes }
            let chosen = apps.filter { state.selection.contains($0.id) }
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Toggle(String(localized: "Select all \(title)"), isOn: selectAll(apps)).toggleStyle(.stewardCheckboxOnly).disabled(state.removing).padding(.leading, 14)
                    Button {
                        if open { expanded.remove(id) } else { expanded.insert(id) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0)).accessibilityHidden(true)
                            Text(title).stewardFont(.body, weight: .semibold).lineLimit(1)
                            Text("\(apps.count) apps").stewardFont(.caption).foregroundStyle(.white.opacity(0.65))
                            Spacer()
                            // Shows what's ticked even while closed, so nothing chosen is out of sight.
                            if chosen.isEmpty {
                                Text(apps.prefix(3).map(\.name).joined(separator: ", ")).stewardFont(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1).frame(maxWidth: 300, alignment: .trailing)
                            } else {
                                Text("\(chosen.count) selected · \(formattedBytes(chosen.reduce(0) { $0 + $1.totalBytes }))").stewardFont(.caption, weight: .semibold).monospacedDigit().padding(.horizontal, 8).padding(.vertical, 3).background(.white.opacity(0.16), in: Capsule())
                            }
                            Text(formattedBytes(total)).stewardFont(.callout, weight: .semibold).monospacedDigit().frame(minWidth: 76, alignment: .trailing)
                        }
                        .padding(.trailing, 14).padding(.vertical, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityValue(open ? String(localized: "Open") : String(localized: "Closed"))
                }
                .background(.white.opacity(open ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if open { columnTitles; rows(apps) }
            }
        }
    }
    private func appRow(_ app: IPhoneAppRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(String(localized: "Select \(app.name)"), isOn: Binding(get: { state.selection.contains(app.id) }, set: { if $0 { state.selection.insert(app.id) } else { state.selection.remove(app.id) } }))
                .toggleStyle(.stewardCheckboxOnly).disabled(state.removing)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).stewardFont(.body, weight: .semibold).lineLimit(1).help(app.bundleID)
                if app.measured && app.totalBytes > 0 { Text(advice(app.advice)).stewardFont(.caption).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true) }
                if let got = app.firstDownloaded, state.lastChanged[app.bundleID] == nil { Text("First downloaded \(got.formatted(.dateTime.month(.abbreviated).year()))").stewardFont(.caption).foregroundStyle(.secondary) }
                if let changed = state.lastChanged[app.bundleID] { Text("Last data change: \(changed.formatted(date: .abbreviated, time: .omitted))").stewardFont(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Group {
                Text(app.measured ? formattedBytes(app.appBytes) : "–").frame(width: columnWidth, alignment: .trailing)
                Text(app.measured ? formattedBytes(app.dataBytes) : "–").frame(width: columnWidth + 20, alignment: .trailing)
                Text(app.measured ? formattedBytes(app.totalBytes) : "–").fontWeight(.semibold).frame(width: columnWidth, alignment: .trailing)
            }.stewardFont(.callout).monospacedDigit()
        }.padding(.horizontal, 14).padding(.vertical, 10).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
    private func advice(_ advice: IPhoneAppRow.Advice) -> String {
        switch advice {
        case .offloadHelps: return String(localized: "Mostly the app. Offloading frees this and keeps your data.")
        case .offloadFreesAppOnly: return String(localized: "Offloading frees only the app part.")
        case .offloadKeepsData: return String(localized: "Mostly data, so offloading won't help. Deleting clears it, and anything not synced.")
        case .cleanInWhatsApp: return String(localized: "Mostly chat media. Remove it in WhatsApp: Settings, Storage and data, Manage storage. Don't delete the app unless your chats are backed up.")
        }
    }
    private var whatsApp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WhatsApp").stewardFont(.title2, weight: .semibold)
            Text("Storage per chat, from a local backup. Message text is never read.").stewardFont(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if state.readingBackup { StewardProgressBar(title: String(localized: "Reading the backup…")).frame(maxWidth: 380) }
            else if let result = state.whatsApp { chats(result.backup, result.report) }
            else {
                if let problem = state.backupProblem { backupMessage(problem) }
                if state.makingBackup {
                    StewardProgressBar(title: String(localized: "Backing up your \(DeviceWord.text). Keep it unlocked and connected.")).frame(maxWidth: 420)
                    Button("Stop") { state.stopBackup() }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true))
                } else {
                    if let backups = state.backups { backupList(backups) }
                    else if state.backupProblem == nil { Button("Find a backup") { state.findBackups() }.buttonStyle(CleanupGlassButtonStyle()) }
                    if let report = state.report, !state.hasOwnBackupKnown, state.backupProblem != .noAccess { backupOffer(report) }
                }
            }
        }
    }
    /// Optional: everything above works without it. It's only offered when the Mac has room.
    @ViewBuilder private func backupOffer(_ report: IPhoneAppsReport) -> some View {
        let free = DiskSpace.read().free, used = report.usedBytes ?? report.totalBytes
        VStack(alignment: .leading, spacing: 8) {
            if state.backupFailed { Text("The backup didn't finish. Unlock your \(DeviceWord.text), keep it connected and try again.").stewardFont(.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if report.encryptsBackups {
                encryptedNote
            } else if IPhoneBackupMaker.hasRoom(free: free, phoneUses: used) {
                Text("You don't need a backup for anything above. It adds WhatsApp by person or group, and which apps have been quiet.").stewardFont(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Back up to this Mac") { confirmingBackup = true }.buttonStyle(CleanupGlassButtonStyle())
            } else {
                Text("This Mac doesn't have room for a backup. It needs up to \(formattedBytes(used + 5_000_000_000)) and has \(formattedBytes(free)) free. You can see chats by size in WhatsApp: Settings, Storage and data, Manage storage.").stewardFont(.body).fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Back up this \(DeviceWord.text) to this Mac?", isPresented: $confirmingBackup, titleVisibility: .visible) {
            Button("Back Up") { state.makeBackup() }
        } message: {
            Text("This can take a long time and use up to \(formattedBytes(used)). It's an unencrypted copy of your \(DeviceWord.text), so you can remove it once it's been read.")
        }
    }
    @ViewBuilder private func backupMessage(_ problem: WhatsAppBackupError) -> some View {
        switch problem {
        case .noAccess:
            Text("To make or read a backup, Artifloam needs your permission to use the Mac's protected backup folder. Turn on Artifloam under Full Disk Access, then reopen it if macOS asks.").stewardFont(.body).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Give permission") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }.buttonStyle(CleanupGlassButtonStyle(compact: true))
                Button("Try again") { state.findBackups() }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true))
            }
        case .encrypted: encryptedNote
        case .noWhatsApp: Text("This backup has no WhatsApp data.").stewardFont(.body)
        case .unsupportedVersion: Text("This WhatsApp version isn't supported yet.").stewardFont(.body)
        case .unreadable: Text("This backup couldn't be read.").stewardFont(.body)
        }
    }
    private var encryptedNote: some View {
        Text("Encrypted backups aren't supported yet. To check yours, select your \(DeviceWord.text) in Finder and look at Encrypt local backup.").stewardFont(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private func backupList(_ backups: [IPhoneBackup]) -> some View {
        if backups.isEmpty {
            Text("There's no \(DeviceWord.text) backup on this Mac. To make one, select your \(DeviceWord.text) in Finder, choose to back up all its data to this Mac, then click Back Up Now.").stewardFont(.body).fixedSize(horizontal: false, vertical: true)
        } else {
            if !state.hasOwnBackup { Text("No backup of this \(DeviceWord.text) is on this Mac. You can pick another one.").stewardFont(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            ForEach(state.shownBackups) { backup in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(backup.deviceName).stewardFont(.body, weight: .semibold).lineLimit(1)
                        if let date = backup.date { Text(date.formatted(date: .abbreviated, time: .shortened)).stewardFont(.caption).foregroundStyle(backup.isOld() ? .orange : .secondary) }
                        if backup.encrypted { encryptedNote }
                    }
                    Spacer(minLength: 8)
                    if !backup.encrypted { Button("Read") { state.readWhatsApp(backup) }.buttonStyle(CleanupGlassButtonStyle(compact: true)) }
                }.padding(.horizontal, 14).padding(.vertical, 10).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    @ViewBuilder private func chats(_ backup: IPhoneBackup, _ report: WhatsAppReport) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(formattedBytes(report.totalBytes)) of media in \(report.chats.count) chats").stewardFont(.body, weight: .semibold)
            if let date = backup.date { Text("From the backup of \(date.formatted(date: .abbreviated, time: .omitted))").stewardFont(.caption).foregroundStyle(backup.isOld() ? .orange : .secondary) }
            Spacer()
            Button("Other backups") { state.closeWhatsApp() }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true))
        }
        if let removable = state.removableBackup {
            Button("Remove the backup from this Mac") { confirmingRemoval = true }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true))
                .confirmationDialog("Delete this backup for good?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                    Button("Delete backup of \(removable.deviceName)", role: .destructive) { state.removeBackup() }
                } message: { Text("This frees the space. The results stay here until you start over.") }
        }
        if backup.isOld() { Text("This backup is old, so these sizes may no longer be right.").stewardFont(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        Text("Removing media happens in WhatsApp: Settings, Storage and data, Manage storage. Clear chat removes the messages too. Artifloam can't delete from here.").stewardFont(.caption).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
        LazyVStack(spacing: 6) { ForEach(report.chats) { chatRow($0) } }
    }
    private func chatRow(_ chat: WhatsAppChat) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(chat.name.isEmpty ? String(localized: "Unnamed chat") : chat.name).stewardFont(.body, weight: .semibold).lineLimit(1)
                    Text(chat.isGroup ? String(localized: "Group") : String(localized: "Person")).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(0.1), in: Capsule()).foregroundStyle(.white.opacity(0.85))
                }
                Text(WhatsAppMediaKind.allCases.compactMap { kind in chat.kinds[kind].map { "\(title(kind)) \(formattedBytes($0))" } }.joined(separator: " · ")).stewardFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(formattedBytes(chat.bytes)).stewardFont(.callout, weight: .semibold).monospacedDigit()
        }.padding(.horizontal, 14).padding(.vertical, 10).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
    private func title(_ kind: WhatsAppMediaKind) -> String {
        switch kind {
        case .photos: return String(localized: "Photos")
        case .videos: return String(localized: "Videos")
        case .audio: return String(localized: "Audio")
        case .documents: return String(localized: "Documents")
        case .other: return String(localized: "Other", comment: "WhatsApp media that is not a photo, video, audio or document")
        }
    }
}

/// Where the space goes, at a glance: the biggest apps as one bar.
private struct IPhoneSpaceBar: View {
    let apps: [IPhoneAppRow]
    let total: UInt64
    @Environment(\.stewardTheme) private var theme
    private static let colors: [StewardTheme] = [.iphone, .care, .browsers, .files, .space, .cleanup, .worktrees]
    private var top: [IPhoneAppRow] { Array(apps.prefix(Self.colors.count)) }
    private var others: UInt64 { total - top.reduce(0) { $0 + $1.totalBytes } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(Array(top.enumerated()), id: \.element.id) { index, app in
                        LinearGradient(colors: [Self.colors[index].accent, Self.colors[index].vivid], startPoint: .top, endPoint: .bottom)
                            .frame(width: width(app.totalBytes, in: geometry.size.width))
                    }
                    Color.white.opacity(0.14)
                }
            }.frame(height: 26).clipShape(Capsule()).overlay { Capsule().stroke(.white.opacity(0.18), lineWidth: 0.7) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(Array(top.enumerated()), id: \.element.id) { index, app in legend(app.name, app.totalBytes, Self.colors[index].accent) }
                legend(String(localized: "\(max(apps.count - top.count, 0)) other apps"), others, .white.opacity(0.3))
            }
        }
        .padding(18).background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 0.8) }
        .accessibilityElement(children: .contain)
    }
    private func width(_ bytes: UInt64, in full: CGFloat) -> CGFloat { total == 0 ? 0 : max(full * CGFloat(bytes) / CGFloat(total) - 2, 2) }
    private func legend(_ name: String, _ bytes: UInt64, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
            Text(name).stewardFont(.caption, weight: .medium).lineLimit(1)
            Text(formattedBytes(bytes)).stewardFont(.caption).foregroundStyle(.secondary).monospacedDigit().layoutPriority(1)
        }
    }
}

/// Apps grouped by the decision they need. Tapping one filters the list below.
private struct IPhoneGroupTiles: View {
    let insights: IPhoneInsights
    let hasBackup: Bool
    @Binding var selected: IPhoneAppGroup?
    @Environment(\.stewardTheme) private var theme
    static func title(_ group: IPhoneAppGroup) -> String {
        switch group {
        case .quiet: return String(localized: "No activity in 6 months")
        case .barelyUsed: return String(localized: "Big, with little data")
        case .heavyData: return String(localized: "Full of data")
        case .offloadable: return String(localized: "Easy to offload")
        }
    }
    private func tagline(_ group: IPhoneAppGroup) -> String {
        switch group {
        case .quiet: return hasBackup ? String(localized: "Nothing in them has changed for over 6 months. Good ones to delete.") : String(localized: "Needs a backup, which shows when each app last changed anything.")
        case .barelyUsed: return String(localized: "Offloading frees nearly all of it. Some apps keep their data online, so check you don't use them.")
        case .heavyData: return String(localized: "Offloading won't help. Check inside the app, or delete it.")
        case .offloadable: return String(localized: "Mostly the app. Offloading keeps your data.")
        }
    }
    private func symbol(_ group: IPhoneAppGroup) -> String {
        switch group {
        case .quiet: return "moon"
        case .barelyUsed: return "roomy"
        case .heavyData: return "full"
        case .offloadable: return "offload"
        }
    }
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
            ForEach(IPhoneAppGroup.allCases) { tile($0) }
        }
    }
    private func tile(_ group: IPhoneAppGroup) -> some View {
        let apps = insights.apps(in: group), active = selected == group, unavailable = group == .quiet && !hasBackup
        return Button { selected = active ? nil : group } label: {
            HStack(alignment: .top, spacing: 13) {
                if let art = CategoryArt.images[symbol(group)] { Image(nsImage: art).resizable().interpolation(.high).frame(width: 58, height: 58).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.title(group)).stewardFont(.body, weight: .semibold)
                    if !unavailable { Text("\(formattedBytes(insights.bytes(in: group))) · \(apps.count) apps").font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(.white).monospacedDigit() }
                    Text(tagline(group)).stewardFont(.caption).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(.white.opacity(active ? 0.17 : 0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            // Keeps the text readable where the page's gradient is brightest.
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(active ? 0.4 : 0.1), lineWidth: 0.8) }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain).disabled(unavailable || apps.isEmpty).accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// When this iPhone was last backed up, and a warning before someone deletes apps without a recent backup.
private struct IPhoneBackupStatus: View {
    let report: IPhoneAppsReport
    private func when(_ date: Date?) -> String { date?.formatted(.relative(presentation: .named)) ?? String(localized: "Never") }
    var body: some View {
        let old = report.backupIsOld()
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: old ? "exclamationmark.triangle.fill" : "checkmark.shield.fill").foregroundStyle(old ? .orange : .mint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(old ? "Back up before you delete anything" : "This \(DeviceWord.text) has a recent backup").stewardFont(.body, weight: .semibold)
                Text("iCloud: \(when(report.lastCloudBackup)) · This Mac: \(when(report.lastMacBackup))").stewardFont(.caption).foregroundStyle(.white.opacity(0.75))
                if old { Text("Its newest backup is over a month old, or there isn't one. On the \(DeviceWord.text): Settings, your name, iCloud, iCloud Backup, Back Up Now.").stewardFont(.caption).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(14).background(old ? Color.orange.opacity(0.14) : Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(old ? Color.orange.opacity(0.4) : .white.opacity(0.1), lineWidth: 0.8) }
    }
}

/// Stays visible while scrolling, and only appears once something is chosen.
struct IPhoneSelectionBar: View {
    @ObservedObject var state: IPhoneState
    var body: some View {
        if !state.removing, let report = state.report, !state.selection.isEmpty {
            let chosen = report.apps.filter { state.selection.contains($0.id) }
            HStack(spacing: 10) {
                Text("\(chosen.count) chosen · \(formattedBytes(chosen.reduce(0) { $0 + $1.totalBytes }))").stewardFont(.body, weight: .semibold)
                Button("Clear choice") { state.selection = [] }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).stewardFont(.callout)
                Spacer()
                Button("Delete…") { state.planRemoval() }.buttonStyle(CleanupGlassButtonStyle(compact: true))
            }
            .padding(.horizontal, 30).padding(.vertical, 12).background(.ultraThinMaterial)
            .sheet(item: Binding(get: { state.removalPlan.map(IPhonePlanItem.init) }, set: { if $0 == nil { state.removalPlan = nil } })) { item in
                IPhoneRemovalSheet(plan: item.plan, report: report) { state.remove(item.plan) }
            }
        }
    }
}
private struct IPhonePlanItem: Identifiable {
    let plan: IPhoneRemovalPlan
    var id: String { plan.apps.map(\.id).joined() }
}

/// Everything someone needs to decide, before anything happens. Nothing here is chosen for them.
private struct IPhoneRemovalSheet: View {
    let plan: IPhoneRemovalPlan
    let report: IPhoneAppsReport
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var understood = false
    private var phone: String { report.deviceName ?? String(localized: "this \(DeviceWord.text)") }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete ^[\(plan.apps.count) app](inflect: true) from \(phone)?").stewardFont(.title2, weight: .semibold).fixedSize(horizontal: false, vertical: true)
            Text("Frees up to \(formattedBytes(plan.freedBytes))").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(plan.apps) { app in
                        HStack(spacing: 8) {
                            Text(app.name).stewardFont(.body, weight: .medium).lineLimit(1)
                            Spacer()
                            Text("App \(formattedBytes(app.appBytes)) · Data \(formattedBytes(app.dataBytes))").stewardFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }.padding(.horizontal, 12).padding(.vertical, 7).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }.frame(maxHeight: 170)
            Text("This is what iOS reports for these apps. The real amount can be lower. You'll see what actually changed afterwards.").stewardFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            info("trash", "What goes", String(localized: "The app and everything stored in it on this \(DeviceWord.text): downloads, settings and anything not synced. This can't be undone from Artifloam."))
            info("person.crop.circle", "What usually stays", String(localized: "Your account, and whatever the app keeps online or in iCloud. Purchases can be restored. Not every app works this way, so check if it matters to you."))
            info(report.backupIsOld() ? "exclamationmark.triangle.fill" : "checkmark.shield", "Your backup", report.newestBackup.map { String(localized: "Newest backup: \($0.formatted(date: .abbreviated, time: .omitted)).") + (report.backupIsOld() ? " " + String(localized: "That's over a month ago, so it may not hold what you'd lose.") : "") } ?? String(localized: "This \(DeviceWord.text) has no backup."), warning: report.backupIsOld())
            ForEach(plan.risky) { app in
                info("exclamationmark.triangle.fill", app.name, app.risk == .chats
                     ? String(localized: "Deleting this removes its chats from this \(DeviceWord.text). They only come back if they're in the app's own backup. To free space and keep chats, remove media in the app instead.")
                     : String(localized: "This may hold your login codes. Without them or a recovery option, you can get locked out of your accounts."), warning: true)
            }
            if !plan.notOnStore.isEmpty {
                info("exclamationmark.triangle.fill", "Can't simply be installed again", String(localized: "Not from the App Store, so you may not get these back: \(plan.notOnStore.map(\.name).joined(separator: ", "))."), warning: true)
            }
            if plan.needsAcknowledgement { Toggle("I understand and still want to do this", isOn: $understood).toggleStyle(.stewardCheckbox).stewardFont(.body) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete from \(DeviceWord.text)", role: .destructive) { dismiss(); confirm() }
                    .disabled(plan.needsAcknowledgement && !understood)
            }
        }.padding(24).frame(width: 540)
    }
    private func info(_ symbol: String, _ title: String, _ text: String, warning: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(warning ? .orange : .secondary).frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).stewardFont(.callout, weight: .semibold)
                Text(text).stewardFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Reports what the iPhone itself now says, including anything that wasn't removed.
private struct IPhoneRemovalResultCard: View {
    let result: IPhoneRemovalResult
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !result.removed.isEmpty {
                Label("Removed ^[\(result.removed.count) app](inflect: true).", systemImage: "checkmark.circle.fill").stewardFont(.body, weight: .semibold)
                // iOS can take a while to release the space, and what it reports per app can be more than comes back.
                if let freed = result.freedBytes { Text(freed > 0 ? "So far your \(DeviceWord.text) uses \(formattedBytes(freed)) less. iOS can take a while to release more." : "iOS hasn't released the space yet. It can take a while, so check again later.").stewardFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                // Deleting is also the only way iOS empties an app's data, so say how to get a fresh copy.
                Text("To get them back, install them on your \(DeviceWord.text) from the App Store, then sign in.").stewardFont(.caption).foregroundStyle(.secondary)
            }
            if !result.stillThere.isEmpty {
                Label("Still on your \(DeviceWord.text): \(result.stillThere.map(\.name).joined(separator: ", ")). Unlock it and try again, or delete them on the \(DeviceWord.text).", systemImage: "exclamationmark.triangle.fill").stewardFont(.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Large on purpose: the action can't go on until the iPhone is unlocked, and it carries on by itself once it is.
struct IPhoneUnlockOverlay: View {
    @ObservedObject var state: IPhoneState
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay(StewardTheme.iphone.backdrop.deep.opacity(0.72)).ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack(alignment: .bottomTrailing) {
                    ScanMovieArtwork(animated: true, asset: "sculpture-motion-iphone", interactive: false).frame(width: 220, height: 220)
                    Image(systemName: "lock.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white).frame(width: 62, height: 62)
                        .background(StewardTheme.iphone.vivid, in: Circle()).overlay { Circle().stroke(.white.opacity(0.75), lineWidth: 1.5) }
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4).offset(x: -6, y: -6).accessibilityHidden(true)
                }
                Text("Unlock your \(DeviceWord.text)").font(.system(size: 34, weight: .light)).accessibilityAddTraits(.isHeader)
                Text("Enter your passcode on the \(DeviceWord.text). Artifloam continues by itself as soon as it's unlocked.").stewardFont(.body).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack(spacing: 10) {
                    Button("Cancel") { state.cancelUnlock() }.buttonStyle(CleanupGlassButtonStyle(secondary: true)).keyboardShortcut(.cancelAction)
                    Button("It's unlocked") { state.continueAnyway() }.buttonStyle(CleanupGlassButtonStyle())
                }.padding(.top, 6)
            }.padding(30)
        }
    }
}
