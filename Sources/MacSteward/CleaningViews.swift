import SwiftUI
import MacStewardCore

/// Under every permanent-delete confirmation: what is left on the disk afterwards. Overwriting files is not offered:
/// on an SSD with APFS it doesn't reach the old blocks; FileVault is what keeps deleted data unreadable.
struct DeletionNote: View {
    @State private var facts: (fileVault: Bool?, localSnapshots: Bool)?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let facts {
                if facts.fileVault == true { Label("FileVault is on: deleted data stays encrypted on the disk, so others can't read it.", systemImage: "lock.shield").foregroundStyle(.secondary) }
                if facts.fileVault == false { Label("FileVault is off: deleted data can stay readable on the disk until macOS reuses the space. Turn on FileVault in System Settings to protect it.", systemImage: "lock.open").foregroundStyle(.orange) }
                if facts.localSnapshots { Label("Time Machine keeps local snapshots of this disk, so some space comes back only when they expire, usually within a day.", systemImage: "clock.arrow.circlepath").foregroundStyle(.secondary) }
            }
        }.stewardFont(.callout).fixedSize(horizontal: false, vertical: true)
        .task { facts = await Task.detached(priority: .userInitiated) { SystemAudit.deletionFacts() }.value }
    }
}

/// Replaces the system dialog: readable on the dark glass window, with a summary of what goes.
/// A ticked Cleanup tile that isn't a scan finding: the Trash, browser caches or worktrees.
struct CleanExtra: Identifiable {
    let icon: String
    let title: String
    let bytes: UInt64?
    var warning: String? = nil
    var id: String { title }
}

struct PendingRemoval: Identifiable {
    let id = UUID()
    /// nil: whatever is ticked when the sheet opens.
    var findings: [Finding]? = nil
    var extras = [CleanExtra]()
    var steps = [() -> Void]()
}

struct CleanConfirmSheet: View {
    @Environment(\.stewardTheme) private var theme
    let findings: [Finding]
    /// Apps that will be asked to quit first, so their caches can go.
    var appsToQuit: [String] = []
    var extras: [CleanExtra] = []
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var groups: [(CleanupGroup, UInt64, Int)] {
        Dictionary(grouping: findings, by: \.group).map { ($0.key, $0.value.reduce(0) { $0 + $1.bytes }, $0.value.count) }.sorted { $0.1 > $1.1 }
    }
    private var total: UInt64 { findings.reduce(0) { $0 + $1.bytes } + extras.reduce(0) { $0 + ($1.bytes ?? 0) } }
    private var categories: Int { groups.count + extras.count }
    private var summaryLine: String {
        if !extras.isEmpty { return String(localized: "\(categories) categories") }
        let itemsText = String(localized: "\(findings.count) items"), categoriesText = String(localized: "\(groups.count) categories")
        return String(localized: "\(itemsText) in \(categoriesText)")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(total > 0 ? "Clean \(formattedBytes(total))?" : "Clean what you selected?").stewardFont(.title2, weight: .semibold)
                    Text(summaryLine).stewardFont(.body).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(groups.prefix(6).enumerated()), id: \.offset) { index, entry in
                    HStack {
                        Image(systemName: entry.0.icon).frame(width: 20).foregroundStyle(theme.accent)
                        Text(entry.0.title).stewardFont(.body)
                        Spacer()
                        Text("\(entry.2) · \(formattedBytes(entry.1))").stewardFont(.body, weight: .medium).monospacedDigit()
                    }.padding(.horizontal, 14).padding(.vertical, 9)
                    if index < min(groups.count, 6) - 1 { Divider().opacity(0.3).padding(.leading, 46) }
                }
                ForEach(extras) { extra in
                    if extra.id != extras.first?.id || !groups.isEmpty { Divider().opacity(0.3).padding(.leading, 46) }
                    HStack {
                        Image(systemName: extra.icon).frame(width: 20).foregroundStyle(theme.accent)
                        Text(extra.title).stewardFont(.body)
                        Spacer()
                        if let bytes = extra.bytes { Text(formattedBytes(bytes)).stewardFont(.body, weight: .medium).monospacedDigit() }
                    }.padding(.horizontal, 14).padding(.vertical, 9)
                }
            }.background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            if !appsToQuit.isEmpty {
                Label(appsToQuit.count == 1 ? String(localized: "\(appsToQuit.joined(separator: ", ")) will quit first. It may ask you to save. If an app doesn't quit, its cache is kept.") : String(localized: "\(appsToQuit.joined(separator: ", ")) will quit first. They may ask you to save. If an app doesn't quit, its cache is kept."), systemImage: "xmark.app")
                    .stewardFont(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(extras.filter { $0.warning != nil }) { extra in
                Label(extra.warning ?? "", systemImage: "exclamationmark.triangle").stewardFont(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            let flagged = findings.filter { !($0.warnings ?? []).isEmpty }
            if !flagged.isEmpty {
                Label("\(flagged.count) selected items have a warning. Go back to Review to check them if you're unsure.", systemImage: "exclamationmark.triangle")
                    .stewardFont(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            let recent = findings.filter { $0.hold == .recent }
            if !recent.isEmpty {
                Label("\(recent.count) recently used caches · \(formattedBytes(recent.reduce(0) { $0 + $1.bytes })). Apps will likely rebuild them soon.", systemImage: "clock.arrow.circlepath")
                    .stewardFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Label("Each item is checked again right before removal. Anything in use is skipped. Removed caches are rebuilt by their apps when needed.", systemImage: "checkmark.shield")
                .stewardFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label("Deleted permanently after you confirm", systemImage: "exclamationmark.triangle")
                .stewardFont(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            DeletionNote()
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(CleanupGlassButtonStyle(secondary: true))
                Spacer()
                Button { dismiss(); confirm() } label: { Label(extras.isEmpty ? String(localized: "Delete \(findings.count) items · \(formattedBytes(total))") : total > 0 ? String(localized: "Delete · \(formattedBytes(total))") : String(localized: "Delete", comment: "Button: confirm deleting the selected items"), systemImage: "trash.fill").stewardFont(.body, weight: .semibold) }
                    .buttonStyle(DestructiveCapsuleStyle())
            }
        }.padding(26).frame(width: 520).preferredColorScheme(.dark)
    }
}
/// High-contrast destructive action: white text on solid red.
struct DestructiveCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label.foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color(red: 0.86, green: 0.22, blue: 0.24).opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.35), lineWidth: 0.8) }
            .shadow(color: .red.opacity(0.35), radius: 10, y: 4)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Full-window cleaning stage: moving artwork, ring, the item in progress and space freed so far.
struct CleaningStage: View {
    @Environment(\.stewardTheme) private var theme
    let progress: CleanProgress
    let stopping: Bool
    let freeSpace: UInt64
    let stop: () -> Void
    let done: () -> Void
    let receipt: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if progress.finished { success } else { working }
    }
    private var fraction: Double { Double(progress.completed) / Double(max(1, progress.total)) }
    private var working: some View {
        VStack(spacing: 14) {
            ZStack {
                ScanMovieArtwork(animated: true, asset: "sculpture-motion-" + theme.rawValue).frame(width: 260, height: 260)
                Circle().stroke(.white.opacity(0.10), lineWidth: 6).frame(width: 300, height: 300)
                Circle().trim(from: 0, to: max(0.02, fraction))
                    .stroke(LinearGradient(colors: [theme.accent, .white], startPoint: .bottomLeading, endPoint: .topTrailing), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 300, height: 300)
                    .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: fraction)
            }.shadow(color: theme.accent.opacity(0.2), radius: 30, y: 10)
            Text(stopping ? "Stopping after this item…" : "Cleaning up…").stewardFont(.title)
            Text(progress.current.isEmpty ? " " : progress.current).stewardFont(.body).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
                .contentTransition(.opacity)
            HStack(spacing: 28) {
                metric(formattedBytes(progress.freedBytes), String(localized: "freed", comment: "Under a byte counter: space freed"))
                metric(String(localized: "\(progress.completed) of \(progress.total)"), String(localized: "checked", comment: "Under a counter: items checked so far"))
                metric(progress.skipped.formatted(), String(localized: "kept, in use", comment: "Under a counter: items skipped because an app is using them"))
            }.padding(.top, 6)
            Button(action: stop) { Label(stopping ? "Stopping…" : "Stop", systemImage: "stop.fill") }
                .buttonStyle(CleanupGlassButtonStyle(secondary: true)).disabled(stopping).padding(.top, 8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).stewardFont(.title3, weight: .semibold).monospacedDigit().contentTransition(.numericText())
            Text(label).stewardFont(.caption).foregroundStyle(.white.opacity(0.55))
        }
    }
    @EnvironmentObject private var model: StewardModel
    /// Removed items from the receipt, grouped by the category they were found in, largest first.
    private var removedByCategory: [(group: CleanupGroup, bytes: UInt64)] {
        let groups = Dictionary((model.report?.findings ?? []).map { ($0.path, $0.group) }, uniquingKeysWith: { first, _ in first })
        var totals = [CleanupGroup: UInt64]()
        for item in model.receipt?.items ?? [] where item.outcome == "removed" { if let group = groups[item.path] { totals[group, default: 0] += item.bytes } }
        return totals.map { (group: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }
    }
    @State private var appeared = false
    @State private var shownBytes: Double = 0
    private var success: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(0..<3) { ring in
                    Circle().stroke(theme.accent.opacity(0.25 - Double(ring) * 0.07), lineWidth: 2)
                        .frame(width: 214 + CGFloat(ring) * 40, height: 214 + CGFloat(ring) * 40)
                        .scaleEffect(appeared || reduceMotion ? 1 : 0.6).opacity(appeared ? 1 : 0)
                        .animation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.7).delay(0.1 + Double(ring) * 0.08), value: appeared)
                }
                Group {
                    if !stopping, let art = CategoryArt.images["done"] { Image(nsImage: art).resizable().scaledToFit().frame(width: 190, height: 190) }
                    else { Image(systemName: "pause.circle.fill").font(.system(size: 66, weight: .semibold)).foregroundStyle(.white) }
                }
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.3)
                    .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.55), value: appeared)
            }.frame(height: 300)
            Text(formattedBytes(UInt64(shownBytes))).font(.system(size: 52, weight: .semibold, design: .rounded)).foregroundStyle(theme.accent).monospacedDigit()
                .contentTransition(.numericText())
            Text(stopping ? "freed before you stopped" : "freed. Your Mac has more room.").stewardFont(.title3).foregroundStyle(.white.opacity(0.8))
            if !removedByCategory.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(removedByCategory.prefix(5), id: \.group) { row in
                        GlossyPoint(icon: row.group.icon, text: String(localized: "\(row.group.title) · \(formattedBytes(row.bytes))"), accent: theme.accent)
                    }
                    if removedByCategory.count > 5 { Text("+\(removedByCategory.count - 5) more").stewardFont(.caption).foregroundStyle(.white.opacity(0.6)).padding(.leading, 46) }
                }.padding(.top, 6)
            }
            HStack(spacing: 24) {
                metric(progress.removed.formatted(), String(localized: "removed", comment: "Under a counter: items removed"))
                metric(progress.skipped.formatted(), String(localized: "kept", comment: "Under a counter: items left in place"))
                metric(formattedBytes(freeSpace), String(localized: "free now", comment: "Under a byte counter: free disk space now"))
            }.padding(.top, 4)
            HStack(spacing: 12) {
                Button("View receipt", action: receipt).buttonStyle(CleanupGlassButtonStyle(secondary: true))
                Button("Done", action: done).buttonStyle(CleanupGlassButtonStyle()).keyboardShortcut(.defaultAction)
            }.stewardFont(.body, weight: .semibold).padding(.top, 10)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            appeared = true
            // Count the freed number up instead of showing it all at once.
            if reduceMotion { shownBytes = Double(progress.freedBytes) } else { withAnimation(.easeOut(duration: 1.1)) { shownBytes = Double(progress.freedBytes) } }
        }
    }
}

/// The square back arrow used in Space Map's path bar and in Overview's module pages.
struct BackSquareButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "chevron.left").flipsForRightToLeftLayoutDirection(true) }.buttonStyle(.bordered).help("Back")
    }
}
