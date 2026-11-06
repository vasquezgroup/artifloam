import SwiftUI
import AppKit
import MacStewardCore

/// What the iPhone page knows. It connects to an iPhone only after the person picks it and presses Read.
@MainActor
final class IPhoneState: ObservableObject {
    @Published private(set) var devices = [IPhoneDevice]()
    @Published private(set) var frameworkMissing = false
    @Published private(set) var picked: IPhoneDevice?
    @Published private(set) var reading = false
    @Published private(set) var problem: IPhoneReadError?
    @Published private(set) var report: IPhoneAppsReport?
    /// The person went straight to a backup, without reading an iPhone.
    @Published private(set) var backupsOnly = false
    @Published private(set) var backups: [IPhoneBackup]?
    @Published private(set) var backupProblem: WhatsAppBackupError?
    @Published private(set) var readingBackup = false
    @Published private(set) var whatsApp: (backup: IPhoneBackup, report: WhatsAppReport)?
    /// Bundle ID to the newest data change, from a backup. Empty until one is read.
    @Published private(set) var lastChanged = [String: Date]()
    @Published var group: IPhoneAppGroup?
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
    var canRead: Bool { picked != nil && !readInFlight }
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
        case .needsTrust: return String(localized: "Unlock your iPhone and tap Trust. If nothing appears, select it in Finder once, then press Read again.")
        case .unreachable: return String(localized: "Your iPhone didn't answer. Unlock it, check the cable and press Read again.")
        case .deviceGone: return String(localized: "That iPhone is no longer connected.")
        case .frameworkMissing: return String(localized: "This Mac is missing the Apple software that talks to iPhones. Connecting an iPhone in Finder once usually installs it.")
        case .failed(let code): return String(localized: "Your iPhone couldn't list its apps (error \(code)). Unlock it and try again.")
        case nil: break
        }
        if devices.isEmpty { return String(localized: "Connect your iPhone with a cable and unlock it.") }
        return picked == nil ? String(localized: "Choose your iPhone. Only the one you choose is read.") : String(localized: "Press Read to list its apps by size.")
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
    }
    func pick(_ device: IPhoneDevice) { picked = device; problem = nil }
    func read() {
        guard let picked, canRead else { return }
        generation += 1
        let current = generation, watcher = watcher, id = picked.id
        reading = true; readInFlight = true; problem = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try watcher.read(deviceID: id) } }.value
            readInFlight = false
            guard current == generation else { return }
            reading = false
            switch result {
            case .success(let report): self.report = report
            case .failure(let error): problem = error as? IPhoneReadError ?? .failed(-1)
            }
        }
    }
    func stop() { generation += 1; reading = false }
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
    }
}

/// Connected iPhones on the start screen. None is ever picked for the person, even when there's only one.
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
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.report?.deviceName ?? sectionTitle("iPhone")).font(.system(size: 34, weight: .light))
                    if let report = state.report {
                        Text("\(report.apps.count) apps · \(formattedBytes(report.totalBytes))").stewardFont(.body).foregroundStyle(.secondary)
                    }
                    Label(state.report == nil ? "Read from a backup on this Mac. Nothing is changed." : "Sizes come from the iPhone. Nothing is changed on it.", systemImage: "lock.fill").stewardFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start over") { state.reset() }.buttonStyle(CleanupGlassButtonStyle(secondary: true))
            }
            if let report = state.report, let insights = state.insights {
                IPhoneBackupStatus(report: report)
                IPhoneSpaceBar(apps: report.apps, total: report.totalBytes)
                IPhoneGroupTiles(insights: insights, hasBackup: !state.lastChanged.isEmpty, selected: $state.group)
                apps(report, insights)
            }
            whatsApp
        }
    }
    @ViewBuilder private func apps(_ report: IPhoneAppsReport, _ insights: IPhoneInsights) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if report.sizesMissing {
                Text("This iPhone listed its apps but didn't report their sizes.").stewardFont(.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if report.apps.isEmpty { Text("This iPhone reported no apps.").stewardFont(.body).foregroundStyle(.secondary) }
            else {
                HStack(spacing: 8) {
                    Text(state.group.map(IPhoneGroupTiles.title) ?? String(localized: "All apps")).stewardFont(.title3, weight: .semibold)
                    if state.group != nil { Button("Show all") { state.group = nil }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)) }
                    Spacer()
                    Text("App").frame(width: columnWidth, alignment: .trailing)
                    Text("Documents & Data").frame(width: columnWidth + 20, alignment: .trailing)
                    Text("Total").frame(width: columnWidth, alignment: .trailing)
                }.stewardFont(.caption, weight: .semibold).foregroundStyle(.secondary).padding(.horizontal, 14)
            }
            LazyVStack(spacing: 6) { ForEach(state.group.map(insights.apps(in:)) ?? report.apps) { appRow($0) } }
        }
    }
    private func appRow(_ app: IPhoneAppRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).stewardFont(.body, weight: .semibold).lineLimit(1).help(app.bundleID)
                if app.measured && app.totalBytes > 0 { Text(advice(app.advice)).stewardFont(.caption).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true) }
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
                    StewardProgressBar(title: String(localized: "Backing up your iPhone. Keep it unlocked and connected.")).frame(maxWidth: 420)
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
            if state.backupFailed { Text("The backup didn't finish. Unlock your iPhone, keep it connected and try again.").stewardFont(.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if report.encryptsBackups {
                encryptedNote
            } else if IPhoneBackupMaker.hasRoom(free: free, phoneUses: used) {
                Text("You don't need a backup for anything above. It adds WhatsApp by person or group, and which apps have been quiet.").stewardFont(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Back up to this Mac") { confirmingBackup = true }.buttonStyle(CleanupGlassButtonStyle())
            } else {
                Text("This Mac doesn't have room for a backup. It needs up to \(formattedBytes(used + 5_000_000_000)) and has \(formattedBytes(free)) free. You can see chats by size in WhatsApp: Settings, Storage and data, Manage storage.").stewardFont(.body).fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Back up this iPhone to this Mac?", isPresented: $confirmingBackup, titleVisibility: .visible) {
            Button("Back Up") { state.makeBackup() }
        } message: {
            Text("This can take a long time and use up to \(formattedBytes(used)). It's an unencrypted copy of your iPhone, so you can remove it once it's been read.")
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
        Text("Encrypted backups aren't supported yet. To check yours, select your iPhone in Finder and look at Encrypt local backup.").stewardFont(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private func backupList(_ backups: [IPhoneBackup]) -> some View {
        if backups.isEmpty {
            Text("There's no iPhone backup on this Mac. To make one, select your iPhone in Finder, choose to back up all its data to this Mac, then click Back Up Now.").stewardFont(.body).fixedSize(horizontal: false, vertical: true)
        } else {
            if !state.hasOwnBackup { Text("No backup of this iPhone is on this Mac. You can pick another one.").stewardFont(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
        case .barelyUsed: return String(localized: "Big, but barely used?")
        case .heavyData: return String(localized: "Full of data")
        case .offloadable: return String(localized: "Easy to offload")
        }
    }
    private func tagline(_ group: IPhoneAppGroup) -> String {
        switch group {
        case .quiet: return hasBackup ? String(localized: "Nothing in them has changed for over 6 months. Good ones to delete.") : String(localized: "Needs a backup, which shows when each app last changed anything.")
        case .barelyUsed: return String(localized: "Almost no data of their own. Offloading frees nearly all of it.")
        case .heavyData: return String(localized: "Offloading won't help. Check inside the app, or delete it.")
        case .offloadable: return String(localized: "Mostly the app. Offloading keeps your data.")
        }
    }
    private func symbol(_ group: IPhoneAppGroup) -> String {
        switch group {
        case .quiet: return "moon.zzz.fill"
        case .barelyUsed: return "questionmark.app.fill"
        case .heavyData: return "tray.full.fill"
        case .offloadable: return "icloud.and.arrow.down.fill"
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
                Image(systemName: symbol(group)).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white).frame(width: 42, height: 42)
                    .background(LinearGradient(colors: [theme.accent.opacity(0.75), theme.vivid], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.28), lineWidth: 0.7) }.accessibilityHidden(true)
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
                Text(old ? "Back up before you delete anything" : "This iPhone has a recent backup").stewardFont(.body, weight: .semibold)
                Text("iCloud: \(when(report.lastCloudBackup)) · This Mac: \(when(report.lastMacBackup))").stewardFont(.caption).foregroundStyle(.white.opacity(0.75))
                if old { Text("Its newest backup is over a month old, or there isn't one. On the iPhone: Settings, your name, iCloud, iCloud Backup, Back Up Now.").stewardFont(.caption).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(14).background(old ? Color.orange.opacity(0.14) : Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(old ? Color.orange.opacity(0.4) : .white.opacity(0.1), lineWidth: 0.8) }
    }
}
