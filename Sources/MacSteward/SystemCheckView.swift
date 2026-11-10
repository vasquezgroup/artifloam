import SwiftUI
import AppKit
import MacStewardCore

/// The result page's top: the section's artwork and one sentence that says how things stand.
struct ResultHero<Actions: View>: View {
    let theme: StewardTheme
    let title: String
    let subtitle: String
    @ViewBuilder var actions: () -> Actions
    @Environment(\.stewardTextScale) private var textScale
    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            ScanMovieArtwork(animated: false, asset: "sculpture-motion-" + theme.rawValue).frame(width: 150, height: 150)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 34 * textScale, weight: .light)).tracking(-0.6).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.system(size: 15 * textScale)).foregroundStyle(.white.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) { actions() }.padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }
}

struct ResultPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { content().padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14)) }
}
/// A headline number on a result page.
struct ResultMetric: View {
    let accent: Color
    let value: String
    let title: String
    let note: String
    var body: some View {
        ResultPanel {
            VStack(alignment: .leading, spacing: 5) {
                Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.6)
                Text(title).stewardFont(.body, weight: .semibold)
                Text(note).stewardFont(.caption).foregroundStyle(.white.opacity(0.68)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
/// A bar of what takes the space, with its legend. Parts without a size are only counted in the legend.
struct ShareBreakdown: View {
    let title: String
    let parts: [(name: String, bytes: UInt64, count: Int, color: Color)]
    /// `bytes` holds a count, so the legend shows just that.
    var countsOnly = false
    var body: some View {
        let total = max(1, parts.reduce(UInt64(0)) { $0 + $1.bytes }), sized = parts.filter { $0.bytes > 0 }
        ResultPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).stewardFont(.headline)
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(sized, id: \.name) { part in
                            RoundedRectangle(cornerRadius: 4).fill(part.color).frame(width: max(4, (geometry.size.width - 2 * CGFloat(sized.count)) * CGFloat(Double(part.bytes) / Double(total))))
                        }
                    }
                }.frame(height: 12).clipShape(Capsule())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(parts, id: \.name) { part in
                        HStack(spacing: 7) {
                            Circle().fill(part.color).frame(width: 8, height: 8)
                            Text(part.name).stewardFont(.callout, weight: .medium)
                            Text((part.bytes > 0 && !countsOnly ? formattedBytes(part.bytes) + " · " : "") + "\(part.count)").stewardFont(.callout).foregroundStyle(.white.opacity(0.68)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

struct SystemCheckView: View {
    @EnvironmentObject private var m: StewardModel
    @Environment(\.stewardTheme) private var theme
    /// A tile's Review shows its rows in place of the tiles.
    @State private var detail: String?
    private var attention: [SecurityCheck] { m.checks.filter { $0.status == .review } }
    private var missingAgents: [BackgroundItem] { m.agents.filter(\.programMissing) }
    private var toReview: Int { attention.count + (missingAgents.isEmpty ? 0 : 1) + (m.appFindings.isEmpty ? 0 : 1) }
    private var heading: String {
        // No checks read yet: never claim the Mac is protected.
        if m.checks.isEmpty { return m.busy ? String(localized: "Checking…") : String(localized: "Not checked") }
        if toReview > 0 { return String(localized: "\(toReview) things to review.") }
        return m.checks.contains { $0.status == .unknown } ? String(localized: "Some checks couldn't be read.") : String(localized: "Your Mac is well protected.")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let detail { detailPage(detail) } else { summary }
            Text("Artifloam changes a setting only when you press its button. This isn't an antivirus and can't say that a Mac is free of malware.")
                .stewardFont(.caption).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
        }.onChange(of: m.checks.isEmpty) { _, _ in detail = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in m.refreshChecks() }
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 22) {
            ResultHero(theme: theme, title: heading, subtitle: m.protections.total == 0 ? "" : String(localized: "\(m.protections.on) of \(m.protections.total) protections on.")) {
                Button("Check again") { m.checkSystem() }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true)).disabled(m.busy)
            }
            if toReview > 0 {
                VStack(spacing: 8) {
                    ForEach(attention) { checkRow($0) }
                    if !missingAgents.isEmpty {
                        row(icon: "exclamationmark.circle", tint: .orange, title: String(localized: "\(missingAgents.count) background items point at missing programs"), detail: String(localized: "Usually left behind by an app you removed.")) { Button("Review") { detail = "Background" }.buttonStyle(CleanupGlassButtonStyle(compact: true)) }
                    }
                    if !m.appFindings.isEmpty {
                        row(icon: "exclamationmark.circle", tint: .orange, title: String(localized: "\(m.appFindings.count) apps Gatekeeper wouldn't accept"), detail: String(localized: "That isn't a malware verdict. See the reason for each one.")) { Button("Review") { detail = "Apps" }.buttonStyle(CleanupGlassButtonStyle(compact: true)) }
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 400), spacing: 14)], spacing: 14) {
                ForEach(SystemArea.allCases) { area in areaTile(area) }
                CategoryTile(amount: "\(m.agents.count)", found: false, name: String(localized: "Background items"), tagline: String(localized: "Programs that start with your Mac, in plain language."), art: "symbol-automation", status: missingAgents.isEmpty ? String(localized: "None broken") : String(localized: "\(missingAgents.count) broken"), review: { detail = "Background" })
                CategoryTile(amount: m.checkingApps ? "…" : "\(m.appFindings.count)", found: false, name: String(localized: "App signatures"), tagline: String(localized: "Apps Gatekeeper wouldn't simply accept."), art: "symbol-tools", status: m.checkingApps ? String(localized: "Checking…") : String(localized: "\(m.appsChecked) checked"), review: { detail = "Apps" })
            }
        }
    }
    private func areaTile(_ area: SystemArea) -> some View {
        let items = m.checks.filter { $0.area == area }, flagged = items.filter { $0.status == .review }.count, good = items.filter { $0.status == .good }.count
        let art: String, tagline: String, amount: String?
        switch area {
        case .protection: art = "symbol-system"; tagline = String(localized: "What keeps your files and this Mac safe."); amount = String(localized: "\(good) of \(items.count)")
        case .updates: art = "sparkles"; tagline = String(localized: "Fixes from Apple, and whether they arrive by themselves."); amount = flagged == 0 ? String(localized: "Current") : String(localized: "\(flagged) to do")
        case .remote: art = "globe"; tagline = String(localized: "Who can reach this Mac from another device."); amount = flagged == 0 ? String(localized: "Closed") : String(localized: "\(flagged) open")
        case .backup: art = "drive"; tagline = String(localized: "Whether your files have a second home."); amount = items.first?.status == .good ? String(localized: "Current") : items.first?.status == .review ? String(localized: "Review", comment: "Status: needs a look") : "–"
        }
        return CategoryTile(amount: amount, found: false, name: areaTitle(area), tagline: tagline, art: art, status: flagged == 0 ? String(localized: "Nothing to review") : String(localized: "\(flagged) to review"), review: { detail = area.rawValue })
    }
    /// `SystemArea.rawValue` is the English identifier; this is what a person reads.
    private func areaTitle(_ area: SystemArea) -> String {
        switch area {
        case .protection: return String(localized: "Protection", comment: "Section of the system check")
        case .updates: return String(localized: "Updates", comment: "Section of the system check")
        case .remote: return String(localized: "Remote access")
        case .backup: return String(localized: "Backup", comment: "Section of the system check")
        }
    }
    @ViewBuilder private func detailPage(_ name: String) -> some View {
        HStack(spacing: 10) {
            BackSquareButton { detail = nil }
            Text(name == "Background" ? String(localized: "Background items") : name == "Apps" ? String(localized: "App signatures") : SystemArea(rawValue: name).map(areaTitle) ?? name).stewardFont(.title2, weight: .semibold)
        }
        VStack(spacing: 8) {
            switch name {
            case "Background": backgroundRows
            case "Apps": appRows
            default: ForEach(m.checks.filter { $0.area.rawValue == name }) { checkRow($0) }
            }
        }
    }
    @ViewBuilder private var backgroundRows: some View {
        Button("Manage startup items…") { m.openPage("Login & background items") }.buttonStyle(CleanupGlassButtonStyle(compact: true)).frame(maxWidth: .infinity, alignment: .trailing)
        // Broken ones first, then by maker.
        ForEach(m.agents.sorted { ($0.programMissing ? 0 : 1, $0.maker.name.lowercased()) < ($1.programMissing ? 0 : 1, $1.maker.name.lowercased()) }) { item in
            row(icon: item.programMissing ? "exclamationmark.circle" : "gearshape", tint: item.programMissing ? .orange : .white.opacity(0.6), title: item.maker.name.displaySafe, detail: item.programMissing ? String(localized: "Its program is gone. \(item.summary.displaySafe) · \(item.scopeTitle)") : item.summary.displaySafe + " · " + item.scopeTitle) {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true))
            }
        }
    }
    @ViewBuilder private var appRows: some View {
        if m.checkingApps { StewardProgressBar(title: String(localized: "Asking Gatekeeper about each app…")).frame(maxWidth: 380).frame(maxWidth: .infinity, alignment: .leading) }
        if !m.checkingApps && m.appFindings.isEmpty { row(icon: "checkmark.shield.fill", tint: theme.accent, title: String(localized: "Gatekeeper accepts all \(m.appsChecked) apps"), detail: String(localized: "Apple's own apps aren't included in this count.")) { EmptyView() } }
        ForEach(m.appFindings) { app in
            row(icon: "exclamationmark.circle", tint: .orange, title: app.name + " · " + app.kind.title, detail: app.kind.detail) {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }.buttonStyle(CleanupGlassButtonStyle(compact: true, secondary: true))
            }
        }
        Text("Gatekeeper may ask Apple about an app, just as when you open it. Artifloam sends none of this anywhere.").stewardFont(.caption).foregroundStyle(.white.opacity(0.55)).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func checkRow(_ check: SecurityCheck) -> some View {
        let look: (String, Color) = switch check.status {
        case .good: ("checkmark.shield.fill", theme.accent)
        case .review: ("exclamationmark.circle", .orange)
        case .info: ("info.circle", .white.opacity(0.6))
        case .unknown: ("questionmark.circle", .white.opacity(0.6))
        }
        return row(icon: look.0, tint: look.1, title: check.title, detail: check.detail, nextStep: check.nextStep) {
            if let fix = check.fix, let action = check.action {
                Button(m.fixing ? String(localized: "Waiting…") : action) { m.apply(fix) }.buttonStyle(CleanupGlassButtonStyle(compact: true)).disabled(m.fixing)
            } else if let settings = check.settings, let action = check.action {
                Button(action) { m.open(settings) }.buttonStyle(CleanupGlassButtonStyle(compact: true))
            }
        }
    }
    private func row<Trailing: View>(icon: String, tint: Color, title: String, detail: String, nextStep: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 19)).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).stewardFont(.body, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                Text(detail).stewardFont(.callout).foregroundStyle(.white.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
                if let nextStep { Text(nextStep).stewardFont(.callout, weight: .medium).foregroundStyle(theme.accent).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 10)
            trailing()
        }.padding(.horizontal, 16).padding(.vertical, 12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}
