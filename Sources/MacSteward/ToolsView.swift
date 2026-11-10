import SwiftUI
import MacStewardCore

struct ToolsView: View {
    @EnvironmentObject private var model: StewardModel
    @State private var search = ""
    struct Tool: Identifiable {
        let id: String; let icon: String; let detail: String; let action: String
        /// What people read; `id` stays the English identifier (navigation, artwork, scan info).
        var title: String {
            switch id {
            case "Junk cleanup": return String(localized: "Junk cleanup")
            case "Worktrees": return String(localized: "Worktrees")
            case "Duplicates": return String(localized: "Duplicates")
            case "Memory": return String(localized: "Memory")
            case "Processes": return String(localized: "Processes")
            case "Space Map": return String(localized: "Space Map")
            case "Large & old files": return String(localized: "Large & old files")
            case "App removal": return String(localized: "App removal")
            case "Leftovers": return String(localized: "Leftovers")
            case "Browser data": return String(localized: "Browser data")
            case "Trash bins": return String(localized: "Trash bins")
            case "Login & background items": return String(localized: "Login & background items")
            case "System": return String(localized: "System")
            default: return id
            }
        }
    }
    /// Also read by the scan info popover, so both name the tools the same way.
    static let catalog = [
        Tool(id: "Junk cleanup", icon: "sparkles", detail: String(localized: "Find old, regenerable caches and recognised diagnostic logs."), action: String(localized: "Scan", comment: "Button: scan with this tool")),
        Tool(id: "Worktrees", icon: "arrow.triangle.branch", detail: String(localized: "See which Claude Code and Codex checkouts are in use. Delete finished, merged ones."), action: String(localized: "Scan", comment: "Button: scan with this tool")),
        Tool(id: "Duplicates", icon: "square.on.square", detail: String(localized: "Find exact copies across your home folder by content. Keep one, delete the rest."), action: String(localized: "Scan", comment: "Button: scan with this tool")),
        Tool(id: "Memory", icon: "memorychip", detail: String(localized: "Live pressure, swap and app footprints. Release RAM by quitting apps you choose."), action: String(localized: "Open memory")),
        Tool(id: "Processes", icon: "list.bullet.rectangle", detail: String(localized: "See every program running on your Mac and the app it belongs to. Quit the ones you choose."), action: String(localized: "Show processes")),
        Tool(id: "Space Map", icon: "magnifyingglass", detail: String(localized: "Explore the folders and large files taking up space on your Mac."), action: String(localized: "Explore storage")),
        Tool(id: "Large & old files", icon: "doc.text.magnifyingglass", detail: String(localized: "Find large files and older downloads. Review sizes and dates before deleting your selection."), action: String(localized: "Find large files")),
        Tool(id: "App removal", icon: "app.badge", detail: String(localized: "Review installed apps and delete the ones you choose. Running and system apps stay protected."), action: String(localized: "Review apps")),
        Tool(id: "Leftovers", icon: "shippingbox", detail: String(localized: "Find support files, caches and settings left by apps you already deleted."), action: String(localized: "Scan", comment: "Button: scan with this tool")),
        Tool(id: "Browser data", icon: "globe", detail: String(localized: "Caches and website data per browser and profile. Group by browser or by website."), action: String(localized: "Scan", comment: "Button: scan with this tool")),
        Tool(id: "Trash bins", icon: "trash", detail: String(localized: "See how much the Trash holds on your Mac and drives, then empty it."), action: String(localized: "Check", comment: "Button: check with this tool")),
        Tool(id: "Login & background items", icon: "power", detail: String(localized: "Inspect launch agents and services. Manage enabled login items using macOS System Settings."), action: String(localized: "Review background items")),
        Tool(id: "System", icon: "checkmark.shield", detail: String(localized: "See what protects your Mac and what runs on it."), action: String(localized: "Check", comment: "Button: check with this tool"))
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
                ForEach(Self.catalog.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search) }) { tool in
                    VStack(alignment: .leading, spacing: 14) {
                        StewardNavigationArtwork(name: tool.id, fallback: tool.icon, size: 42)
                        Text(tool.title).stewardFont(.headline).fixedSize(horizontal: false, vertical: true)
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
        case "Worktrees": model.openPage("Worktrees"); model.scan(only: [.worktrees])
        case "Duplicates": model.openPage("Duplicates"); model.scanDuplicates()
        case "System": model.openPage("System"); model.checkSystem()
        case "Leftovers": model.openPage("Leftovers"); model.leftovers.scan()
        case "Login & background items": model.openPage(id); model.startup.scan()
        case "Trash bins": model.openPage("Trash bins"); model.withFullDisk { model.trashBins.scan() }
        case "Browser data": model.openPage("Browsers"); model.withFullDisk { model.browsers.scan() }
        default: model.openPage(id)
        }
    }
}
