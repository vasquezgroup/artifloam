import Foundation

/// Section, tab and tool names stay English in code, where they are identifiers. This is what people see.
func sectionTitle(_ section: String) -> String {
    switch section {
    case "Overview": return String(localized: "Overview")
    case "Cleanup": return String(localized: "Cleanup")
    case "Trash bins": return String(localized: "Trash bins")
    case "System": return String(localized: "System", comment: "Section: this Mac's protection, updates and remote access")
    case "Duplicates": return String(localized: "Duplicates")
    case "My Clutter": return String(localized: "My Clutter")
    case "Applications": return String(localized: "Applications")
    case "Uninstaller": return String(localized: "Uninstaller")
    case "Browsers": return String(localized: "Browsers")
    case "Browser data": return String(localized: "Browser data")
    case "Worktrees": return String(localized: "Worktrees", comment: "Section: Git worktrees, the developer term")
    case "Space Map": return String(localized: "Space Map")
    case "Login & background items": return String(localized: "Login & background items")
    case "Leftovers": return String(localized: "Leftovers", comment: "Section: files left behind by apps you removed")
    case "Performance": return String(localized: "Performance")
    case "Status": return String(localized: "Status", comment: "Section: live status of this Mac")
    case "Tools": return String(localized: "Tools", comment: "Section: the single-purpose tools")
    case "Settings": return String(localized: "Settings")
    case "General": return String(localized: "General", comment: "Settings tab")
    case "Automation": return String(localized: "Automation", comment: "Settings tab: scheduled cleanup")
    case "Activity": return String(localized: "Activity", comment: "Settings tab: receipts of past cleanups")
    case "Memory": return String(localized: "Memory", comment: "Section: RAM")
    case "Large & old files": return String(localized: "Large & old files")
    case "App removal": return String(localized: "App removal")
    case "Junk cleanup": return String(localized: "Junk cleanup")
    default: return section
    }
}
