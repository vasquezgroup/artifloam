import SwiftUI
import MacStewardCore

struct ToolsView: View {
    @EnvironmentObject private var model: StewardModel
    @State private var search = ""
    struct Tool: Identifiable {
        let id: String; let icon: String; let detail: String; let action: String
    }
    /// Also read by the scan info popover, so both name the tools the same way.
    static let catalog = [
        Tool(id: "Junk cleanup", icon: "sparkles", detail: "Find old, regenerable caches and recognised diagnostic logs.", action: "Scan"),
        Tool(id: "Worktrees", icon: "arrow.triangle.branch", detail: "See which Claude Code and Codex checkouts are in use. Move finished, merged ones to Trash.", action: "Scan"),
        Tool(id: "Duplicates", icon: "square.on.square", detail: "Find exact copies across your home folder by content. Keep one, move the rest to Trash.", action: "Scan"),
        Tool(id: "Memory", icon: "memorychip", detail: "Live pressure, swap and app footprints. Release RAM by quitting apps you choose.", action: "Open memory"),
        Tool(id: "Space Map", icon: "magnifyingglass", detail: "Explore the folders and large files taking up space on your Mac.", action: "Explore storage"),
        Tool(id: "Large & old files", icon: "doc.text.magnifyingglass", detail: "Find large files and older downloads. Review sizes and dates before moving your selection to Trash.", action: "Find large files"),
        Tool(id: "App removal", icon: "app.badge", detail: "Review installed apps and move selected app bundles to Trash. Running and system apps stay protected.", action: "Review apps"),
        Tool(id: "Leftovers", icon: "shippingbox", detail: "Find support files, caches and settings left by apps you already deleted.", action: "Scan"),
        Tool(id: "Browser data", icon: "globe", detail: "Caches and website data per browser and profile. Group by browser or by website.", action: "Scan"),
        Tool(id: "Trash bins", icon: "trash", detail: "See how much the Trash holds on your Mac and drives, then empty it.", action: "Check"),
        Tool(id: "Login & background items", icon: "power", detail: "Inspect launch agents and services. Manage enabled login items using macOS System Settings.", action: "Review background items"),
        Tool(id: "System", icon: "checkmark.shield", detail: "See what protects your Mac and what runs on it.", action: "Check")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your tools").stewardFont(.title, weight: .semibold)
                    Text("Focused checks. Clear choices. One place to care for your Mac.").stewardFont(.body).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan cleanup & system") { model.section = "Overview"; model.scan(allTools: true) }
                    .buttonStyle(CleanupGlassButtonStyle()).disabled(model.busy)
            }
            Text("Each tool below scans only its own area. The button above runs the cleanup, worktree, duplicate and system checks together. Scanning never deletes files or quits apps.").stewardFont(.body).foregroundStyle(.secondary)
            TextField("Find a tool", text: $search).stewardInput()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 16)], spacing: 16) {
                ForEach(Self.catalog.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search) }) { tool in
                    VStack(alignment: .leading, spacing: 14) {
                        StewardNavigationArtwork(name: tool.id, fallback: tool.icon, size: 42)
                        Text(tool.id).stewardFont(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(tool.detail).stewardFont(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(tool.action) { activate(tool.id) }.buttonStyle(.bordered).disabled(model.busy)
                    }.fixedSize(horizontal: false, vertical: true).padding(22).frame(maxWidth: .infinity, minHeight: 235, alignment: .topLeading)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
                        .overlay { RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.10), lineWidth: 0.7) }
                }
            }
        }
    }
    private func activate(_ id: String) {
        switch id {
        // Each card starts only its own tool.
        case "Junk cleanup": model.review(); model.withFullDisk { model.scan(only: StewardModel.junkGroups) }
        case "Worktrees": model.section = "Worktrees"; model.scan(only: [.worktrees])
        case "Duplicates": model.section = "Duplicates"; model.scanDuplicates()
        case "System": model.section = "System"; model.checkSystem()
        case "Leftovers": model.section = "Leftovers"; model.leftovers.scan()
        case "Login & background items": model.section = id; model.startup.scan()
        case "Trash bins": model.section = "Trash bins"; model.withFullDisk { model.trashBins.scan() }
        case "Browser data": model.section = "Browsers"; model.withFullDisk { model.browsers.scan() }
        default: model.section = id
        }
    }
}
