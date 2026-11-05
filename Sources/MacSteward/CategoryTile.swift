import SwiftUI
import AppKit
import MacStewardCore

/// The glass-and-pearl category illustrations rendered by design/render-category-art.py.
enum CategoryArt {
    static let images: [String: NSImage] = {
        var images = [String: NSImage]()
        for name in ["cache", "hammer", "document", "trash", "stack", "drive", "sparkles", "branch", "globe", "done"] {
            if let url = StewardResources.bundle.url(forResource: "category-" + name, withExtension: "heic"), let image = NSImage(contentsOf: url) { images[name] = image }
        }
        for name in ["symbol-system", "symbol-automation", "symbol-tools"] {
            if let url = StewardResources.bundle.url(forResource: name, withExtension: "heic"), let image = NSImage(contentsOf: url) { images[name] = image }
        }
        return images
    }()
    static func name(for group: CleanupGroup) -> String {
        switch group {
        case .agentBuilds: return "sparkles"
        case .worktrees: return "branch"
        case .xcode, .developerCaches: return "hammer"
        case .projectCaches: return "cache"
        case .inactiveDependencies: return "stack"
        case .userCaches: return "drive"
        case .userLogs, .systemLogs: return "document"
        default: return "cache"
        }
    }
    /// One short line per category; the full explanation lives on the Review page.
    static func tagline(for group: CleanupGroup) -> String {
        switch group {
        case .agentBuilds: return "Old Claude, Codex and Cursor leftovers"
        case .worktrees: return "Finished checkouts you can delete"
        case .xcode: return "Build data and simulators. Some can't be rebuilt, so you choose."
        case .developerCaches: return "Gradle and Xcode module caches"
        case .projectCaches: return "Generated caches inside your projects"
        case .inactiveDependencies: return "Dependencies of projects you haven't touched"
        case .userCaches: return "Caches apps rebuild on their own"
        case .userLogs: return "Old diagnostic logs"
        case .systemCaches, .systemLogs: return "Managed by macOS"
        case .universalApps, .languages: return "Kept: part of signed apps"
        case .deviceBackups: return "iPhone and iPad backups"
        case .documentVersions: return "Saved document history"
        }
    }
    /// Icons of installed apps, for tiles that are about specific apps.
    static func appIcons(bundleIDs: [String], limit: Int = 3) -> [NSImage] {
        var seen = Set<String>()
        return bundleIDs.compactMap { id -> NSImage? in
            guard seen.insert(id.lowercased()).inserted, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }.prefix(limit).map { $0 }
    }
    static let aiApps = ["com.anthropic.claudefordesktop", "com.openai.chat", "com.todesktop.230313mzl4w4u92", "com.openai.codex"]
}

/// A category tile: a big amount, what it is, art or app icons, one short line, then actions.
struct CategoryTile: View {
    let amount: String?
    /// False when the amount is a state ("6 of 8"), not something found.
    var found = true
    let name: String
    let tagline: String
    let art: String
    var appIcons: [NSImage] = []
    var status: String? = nil
    var chosen: Binding<Bool>? = nil
    /// False when nothing in the tile can go right now: the checkbox stays in its place, dimmed.
    var canChoose = true
    let review: () -> Void
    var clean: (() -> Void)? = nil
    @Environment(\.stewardTheme) private var theme
    @Environment(\.stewardTextScale) private var textScale
    @State private var hovered = false
    private var selection: some View {
        HStack(spacing: 8) {
            if let chosen { Toggle("Include in Remove selected", isOn: chosen).toggleStyle(.stewardCheckboxOnly).disabled(!canChoose).opacity(canChoose ? 1 : 0.4).help(canChoose ? "Include in Remove selected" : "Nothing here can be removed right now") }
            if let status {
                Text(status).font(.system(size: 11 * textScale, weight: .semibold)).lineLimit(1).fixedSize().padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.white.opacity(0.10), in: Capsule()).foregroundStyle(.white.opacity(0.85))
            }
        }
    }
    private var actions: some View {
        HStack(spacing: 8) {
            Button("Review", action: review).buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true))
            if let clean { Button("Clean", action: clean).buttonStyle(CleanupGlassButtonStyle(compact: true)) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let amount {
                        Text(amount).font(.system(size: 26 * textScale, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(theme.accent)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Text(amount == nil || !found ? name : name + " found").font(.system(size: 15 * textScale, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if appIcons.isEmpty {
                    if let image = CategoryArt.images[art] {
                        Image(nsImage: image).resizable().interpolation(.high).frame(width: 64, height: 64)
                            .rotationEffect(.degrees(hovered ? -4 : 0)).scaleEffect(hovered ? 1.06 : 1)
                    }
                } else {
                    HStack(spacing: -10) { ForEach(Array(appIcons.enumerated()), id: \.offset) { Image(nsImage: $0.element).resizable().frame(width: 40, height: 40).shadow(color: .black.opacity(0.25), radius: 4, y: 2) } }
                }
            }
            Text(tagline).font(.system(size: 12.5 * textScale)).foregroundStyle(.white.opacity(0.68)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // One row when it fits; otherwise the checkbox and status sit above the buttons, never truncated.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { selection; Spacer(minLength: 4); actions }
                VStack(alignment: .leading, spacing: 8) { selection; HStack(spacing: 8) { Spacer(minLength: 0); actions } }
            }
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 186, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(hovered ? 0.13 : 0.09), .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(hovered ? 0.18 : 0.08), lineWidth: 0.8) }
        .onHover { inside in withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { hovered = inside } }
    }
}
