import SwiftUI
import AppKit
import QuickLook
import MacStewardCore

/// Duplicates as an overview plus one compact row per group. Files are matched by content (SHA-256), not by name.
/// Every action keeps at least one copy in each group, and everything goes through the Trash review first.
struct DuplicatesView: View {
    @EnvironmentObject private var m: StewardModel
    let trash: ([String]) -> Void
    @State private var expanded = Set<String>()
    @State private var query = ""
    /// Shown with Quick Look, so copies can be compared without opening Finder.
    @State private var preview: URL?
    /// Groups whose file names or folders match the search; all groups when it's empty.
    private var shown: [DuplicateGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return m.duplicates }
        return m.duplicates.filter { $0.files.contains { $0.localizedCaseInsensitiveContains(needle) } }
    }
    private let muted = Color.white.opacity(0.62)
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if m.duplicates.isEmpty {
                HStack(spacing: 12) {
                    Button(m.duplicateChecked ? "Scan again" : "Find duplicates") { m.scanDuplicates() }
                        .buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(m.busy)
                    Text("Compares file contents across your home folder.").stewardFont(.caption).foregroundStyle(muted)
                }
                if m.duplicateChecked { Text("No exact duplicates found. Only files of 1 MB or more are compared.").stewardFont(.body).foregroundStyle(muted) }
            } else {
                overview
                bulkBar
                LazyVStack(spacing: 8) {
                    ForEach(shown.filter { $0.extraCount > 0 }) { group in row(group) }
                    let inProjects = shown.filter { $0.extraCount == 0 }
                    if !inProjects.isEmpty {
                        Text("Inside your projects. Never ticked for you: a project may still need these. Files Git tracks aren't listed.")
                            .stewardFont(.caption).foregroundStyle(muted).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                        ForEach(inProjects) { group in row(group) }
                    }
                }
                if shown.isEmpty { Text("No duplicates match “\(query)”.").stewardFont(.body).foregroundStyle(muted).padding(.vertical, 8) }
            }
        }
        .quickLookPreview($preview, in: m.duplicates.flatMap(\.files).map { URL(fileURLWithPath: $0) })
    }

    private var overview: some View {
        let copies = m.duplicates.reduce(0) { $0 + $1.extraCount }
        let bytes = m.duplicates.reduce(0) { $0 + $1.potentialBytes }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                stat("Groups", "\(m.duplicates.count)")
                stat("Extra copies", "\(copies)")
                stat("Space to free", formattedBytes(bytes), tint: .mint)
            }
            HStack(spacing: 10) {
                Button { trash(DuplicateGroup.trashable(m.extraCopies(m.duplicates), in: m.duplicates)) } label: {
                    Label("Trash all extra copies · \(formattedBytes(bytes))", systemImage: "trash")
                }.buttonStyle(CleanupGlassButtonStyle()).disabled(m.busy)
                    .help("Keeps the oldest copy in every group and reviews the rest before they move to the Trash.")
                Spacer()
                Button("Scan again") { m.scanDuplicates() }.buttonStyle(.plain).foregroundStyle(muted).disabled(m.busy)
            }.stewardFont(.body, weight: .semibold)
            Label("Matched by content (SHA-256), not by file name. One copy always stays, and the Trash lets you put files back.", systemImage: "checkmark.shield")
                .stewardFont(.caption).foregroundStyle(muted)
        }
    }

    /// Search plus actions on the groups shown: tick, clear, trash what's ticked.
    private var bulkBar: some View {
        let groups = shown
        // While searching, bulk trash acts on the groups shown, never on hidden ones.
        let ticked = DuplicateGroup.trashable(m.duplicateChoice, in: groups)
        let allTicked = !groups.isEmpty && groups.allSatisfy(isTicked)
        return BulkBar(title: query.isEmpty ? String(localized: "All groups") : String(localized: "\(groups.count) of \(m.duplicates.count) groups"), isOn: Binding(get: { allTicked }, set: { on in groups.forEach { setTicked($0, on) } }),
                       help: allTicked ? String(localized: "Untick every shown group") : String(localized: "Tick the extra copies in every shown group"), summary: String(localized: "\(ticked.count) selected")) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(muted)
                TextField("Search file names or folders", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(muted).help("Clear search") }
            }.padding(.horizontal, 10).frame(height: 32).frame(maxWidth: 360).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            SmartSelectButton(enabled: !m.busy && groups.contains { $0.extraCount > 0 }, help: String(localized: "Ticks the extra copies outside your projects and keeps one copy of each. Copies inside a project stay unticked.")) {
                groups.forEach { setTicked($0, $0.extraCount > 0) }
            }
            Button("Trash \(ticked.count)…") { trash(ticked) }
                .buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(ticked.isEmpty || m.busy)
        }
    }
    private func isTicked(_ group: DuplicateGroup) -> Bool { group.files.contains { m.duplicateChoice.contains($0) } }
    /// Ticking a group ticks every copy but the oldest; unticking clears the whole group.
    private func setTicked(_ group: DuplicateGroup, _ on: Bool) {
        m.duplicateChoice.subtract(group.files)
        if on { m.duplicateChoice.formUnion(m.extraCopies([group])) }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String, tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).stewardFont(.caption, weight: .semibold).foregroundStyle(muted)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ group: DuplicateGroup) -> some View {
        let open = expanded.contains(group.id)
        let names = Set(group.files.map { URL(fileURLWithPath: $0).lastPathComponent })
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Toggle("Select \(group.files.count) copies", isOn: Binding(get: { isTicked(group) }, set: { setTicked(group, $0) }))
                    .toggleStyle(.stewardCheckboxOnly).help("Ticks every copy but the oldest")
                Button { withAnimation(.easeOut(duration: 0.18)) { if open { expanded.remove(group.id) } else { expanded.insert(group.id) } } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.right").flipsForRightToLeftLayoutDirection(true).font(.system(size: 11, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(muted)
                        Image(nsImage: NSWorkspace.shared.icon(forFile: group.files[0])).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(names.count == 1 ? names.first! : "\(names.count) different names").stewardFont(.body, weight: .semibold).lineLimit(1).truncationMode(.middle)
                            Text("\(group.files.count) copies · \(formattedBytes(group.size)) each").stewardFont(.caption).foregroundStyle(muted)
                        }
                        Spacer(minLength: 8)
                        Text(group.extraCount > 0 ? String(localized: "\(formattedBytes(group.potentialBytes)) extra") : String(localized: "Your choice")).stewardFont(.callout, weight: .semibold).foregroundStyle(.mint).monospacedDigit()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button("Keep 1, trash \(group.extraCount)") { trash(DuplicateGroup.trashable(m.extraCopies([group]), in: [group])) }
                    .buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)).disabled(m.busy || group.extraCount == 0)
                    .help("Keeps the oldest copy and reviews the others before they move to the Trash.")
            }.padding(.horizontal, 14).frame(height: 56)
            if open {
                Divider().overlay(.white.opacity(0.08))
                VStack(alignment: .leading, spacing: 8) { ForEach(group.files, id: \.self) { path in file(path, in: group) } }.padding(14)
            }
        }.background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func file(_ path: String, in group: DuplicateGroup) -> some View {
        let ticked = m.duplicateChoice.contains(path)
        // The last unticked copy can't be ticked: one file in every group must stay.
        let lastKept = !ticked && group.files.filter { !m.duplicateChoice.contains($0) }.count <= 1
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { ticked }, set: { if $0 { m.duplicateChoice.insert(path) } else { m.duplicateChoice.remove(path) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(URL(fileURLWithPath: path).lastPathComponent.displaySafe).stewardFont(.callout).lineLimit(1)
                        if group.projectFiles.contains(path) { Text("In a project").stewardFont(.caption, weight: .semibold).foregroundStyle(.orange).help("Inside a Git checkout, not tracked. The project may still need it.") }
                    }
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~").displaySafe).stewardFont(.caption, design: .monospaced).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                }
            }.toggleStyle(.stewardCheckbox).disabled(lastKept).help(lastKept ? "One copy always stays" : ticked ? "Moves to the Trash" : "Kept")
            Spacer(minLength: 8)
            if lastKept { Text("Kept").stewardFont(.caption, weight: .semibold).foregroundStyle(.mint) }
            Button("Preview") { preview = URL(fileURLWithPath: path) }.buttonStyle(.plain).stewardFont(.caption, weight: .semibold).foregroundStyle(muted)
            Button("Reveal") { m.reveal(path) }.buttonStyle(.plain).stewardFont(.caption, weight: .semibold).foregroundStyle(muted)
        }
    }
}
