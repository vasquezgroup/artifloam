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
    private let watcher = IPhoneDeviceWatcher()
    /// A read can't be cancelled once it is talking to the iPhone, so a stopped one must finish before the next starts.
    @Published private var readInFlight = false
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
            let result = await Task.detached(priority: .userInitiated) { Result { try WhatsAppBackup.read(backup) } }.value
            guard current == generation else { return }
            readingBackup = false
            switch result {
            case .success(let report): whatsApp = (backup, report)
            case .failure(let error): backupProblem = error as? WhatsAppBackupError ?? .unreadable
            }
        }
    }
    func closeWhatsApp() { whatsApp = nil; backupProblem = nil }
    /// Forgets everything read and the pick, so nothing connects again until the person chooses.
    func reset() {
        generation += 1
        picked = nil; reading = false; problem = nil; report = nil; backupsOnly = false
        backups = nil; backupProblem = nil; readingBackup = false; whatsApp = nil
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
            Button { m.withFullDisk { state.openBackups() } } label: { Text("Use a backup on this Mac").stewardFont(.callout) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).padding(.leading, state.devices.isEmpty ? 0 : 6)
        }
    }
}

/// Results: every app by size, then WhatsApp per chat from a backup. Nothing here can change the iPhone.
struct IPhoneView: View {
    @ObservedObject var state: IPhoneState
    @EnvironmentObject private var m: StewardModel
    private let columnWidth: CGFloat = 104
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
            if let report = state.report { apps(report) }
            whatsApp
        }
    }
    @ViewBuilder private func apps(_ report: IPhoneAppsReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if report.sizesMissing {
                Text("This iPhone listed its apps but didn't report their sizes.").stewardFont(.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if report.apps.isEmpty { Text("This iPhone reported no apps.").stewardFont(.body).foregroundStyle(.secondary) }
            else {
                HStack(spacing: 8) {
                    Spacer()
                    Text("App").frame(width: columnWidth, alignment: .trailing)
                    Text("Documents & Data").frame(width: columnWidth + 20, alignment: .trailing)
                    Text("Total").frame(width: columnWidth, alignment: .trailing)
                }.stewardFont(.caption, weight: .semibold).foregroundStyle(.secondary).padding(.horizontal, 14)
            }
            LazyVStack(spacing: 6) { ForEach(report.apps) { appRow($0) } }
        }
    }
    private func appRow(_ app: IPhoneAppRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).stewardFont(.body, weight: .semibold).lineLimit(1)
                Text(app.bundleID).stewardFont(.caption, design: .monospaced).foregroundStyle(.secondary).lineLimit(1)
                if app.measured && app.totalBytes > 0 { Text(advice(app.advice)).stewardFont(.caption).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true) }
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
        case .offloadHelps: return String(localized: "Offloading helps: it removes the app and keeps its data.")
        case .offloadFreesAppOnly: return String(localized: "Offloading frees only the app part.")
        case .offloadKeepsData: return String(localized: "Offloading won't help because it keeps the data. Deleting and reinstalling clears it, along with anything not synced.")
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
                if let backups = state.backups { backupList(backups) }
                else if state.backupProblem == nil { Button("Find a backup") { m.withFullDisk { state.findBackups() } }.buttonStyle(CleanupGlassButtonStyle()) }
            }
        }
    }
    @ViewBuilder private func backupMessage(_ problem: WhatsAppBackupError) -> some View {
        switch problem {
        case .noAccess:
            Text("Artifloam needs Full Disk Access to read backups.").stewardFont(.body).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }.buttonStyle(CleanupGlassButtonStyle(compact: true))
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
                        if let date = backup.date { Text(date.formatted(date: .abbreviated, time: .shortened)).stewardFont(.caption).foregroundStyle(.secondary) }
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
            if let date = backup.date { Text("From the backup of \(date.formatted(date: .abbreviated, time: .omitted))").stewardFont(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Other backups") { state.closeWhatsApp() }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true))
        }
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
