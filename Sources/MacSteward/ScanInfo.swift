import SwiftUI

/// Which Tools-page tools each page's Scan button runs. Shown as a quiet line above the Scan button;
/// clicking it opens a popover (the macOS pattern for supplementary help, unlike a modal sheet).
enum ScanInfo {
    /// Sidebar pages and the tools their Scan runs, in sidebar order. Keep in step with the Scan button in MainView.
    static let pages: [(page: String, tools: [String])] = [
        ("Overview", ["Junk cleanup", "Worktrees", "Duplicates", "Leftovers", "System", "Memory"]),
        ("Cleanup", ["Junk cleanup", "Worktrees"]),
        ("My Clutter", ["Duplicates", "Large & old files"]),
        ("Applications", ["Leftovers"]),
        ("Browsers", ["Browser data"]),
        ("Space Map", ["Space Map"]),
    ]
    /// Pages reached from inside a module run a single tool.
    static func tools(for section: String) -> [String] {
        pages.first { $0.page == section }?.tools ?? [section == "System" ? "System" : section == "Duplicates" ? "Duplicates" : section == "Worktrees" ? "Worktrees" : "Junk cleanup"]
    }
    static func line(for section: String) -> String {
        let names = tools(for: section)
        if names.count > 3 { return "Runs \(names.count) tools · reading only" }
        let list = names.count > 2 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.joined(separator: " and ")
        return "Runs \(list) · reading only"
    }
    /// Tools this scan leaves out, with the page whose Scan covers them.
    static func elsewhere(for section: String) -> [(page: String, tools: [String])] {
        let here = Set(tools(for: section))
        var seen = here
        return pages.filter { $0.page != "Overview" && $0.page != section }.compactMap { entry in
            let missing = entry.tools.filter { !seen.contains($0) }
            seen.formUnion(missing)
            return missing.isEmpty ? nil : (entry.page, missing)
        }
    }
}

/// The clickable info line: a "?" marks it as help, hover lightens it like a button.
struct ScanInfoButton: View {
    let section: String
    let accent: Color
    @State private var hovered = false
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(ScanInfo.line(for: section))
                Image(systemName: "questionmark.circle").imageScale(.small)
            }
            .stewardFont(.caption).foregroundStyle(.white.opacity(hovered || open ? 0.85 : 0.5))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.white.opacity(hovered || open ? 0.10 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .help("Which tools this scan runs")
        .accessibilityLabel("About this scan: \(ScanInfo.line(for: section))")
        .popover(isPresented: $open, arrowEdge: .top) { details }
    }

    private var details: some View {
        let tools = ScanInfo.tools(for: section).compactMap { name in ToolsView.catalog.first { $0.id == name } }
        let elsewhere = ScanInfo.elsewhere(for: section)
        return VStack(alignment: .leading, spacing: 14) {
            Text(section == "Overview" ? "Overview runs every main check" : "What \(section) scans").stewardFont(.headline, weight: .semibold)
            part("This scan runs") {
                ForEach(tools) { tool in
                    HStack(alignment: .top, spacing: 10) {
                        StewardNavigationArtwork(name: tool.id, fallback: tool.icon, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.id).stewardFont(.callout, weight: .semibold)
                            Text(tool.detail).stewardFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !elsewhere.isEmpty {
                part("Not in this scan") {
                    ForEach(elsewhere, id: \.page) { entry in
                        (Text(entry.tools.joined(separator: ", ")) + Text(entry.tools == [entry.page] ? "  its own page" : "  on \(entry.page)").foregroundColor(accent)).stewardFont(.caption)
                    }
                }
            }
            Divider().opacity(0.4)
            Label("Scanning only reads. Nothing is removed until you review it.", systemImage: "lock.fill").stewardFont(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(width: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func part<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).stewardFont(.caption, weight: .bold).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { content() }
        }
    }
}
