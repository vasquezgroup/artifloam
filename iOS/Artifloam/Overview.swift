import SwiftUI

/// One job: how much room is there, and one press to get more.
struct OverviewView: View {
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var space = DiskSpace.current
    @State private var reviewing = false

    private var used: Double { Double(max(space.total - space.free, 0)) / Double(max(space.total, 1)) }
    private var found: [PhotoCategory] {
        PhotoCategory.allCases.filter { !library.items($0).isEmpty }.sorted { library.saving($0) > library.saving($1) }
    }

    var body: some View {
        let picks = library.recommended
        StagePage(theme: .care, moving: library.working, sculptureSize: 220) {
            GlassCard {
                HStack(alignment: .firstTextBaseline) {
                    amount(formatted(space.free), "Free", .leading, size: 30)
                    Spacer(minLength: 12)
                    amount(formatted(space.total), "Total", .trailing, size: 17)
                }
                GlassMeter(fraction: used, theme: .care)
                if let days = SpaceHistory.daysUntilFull(SpaceHistory.load()) {
                    Text("Full in about ^[\(days) day](inflect: true)").font(.footnote).foregroundStyle(.white.opacity(0.75))
                }
                if library.status != .denied && library.status != .restricted { contents }
            }
            switch library.status {
            case .denied, .restricted: NoPhotoAccess()
            default:
                if let notice = library.notice { GlassCard { Label(notice, systemImage: "info.circle").font(.footnote) } }
            }
        }
        // Pull down to scan again. Not awaited, because the Scan button's ring shows the progress, not the spinner.
        .refreshable { Task { await library.scan() } }
        .navigationDestination(isPresented: $reviewing) {
            // Ticked in advance because they're recommended. Nothing goes until the person has seen them and pressed Delete.
            PhotoReviewView(title: "Recommended", note: "Exact copies, and screenshots over 90 days old. Untick anything to keep. Items in iCloud may free less on this iPhone.", theme: .care, groups: library.recommendedGroups, preselected: true)
        }
        .orbFooter(summary: library.scanSummary) {
            if library.phase == .done && !picks.isEmpty {
                OrbAction(title: "Review", icon: "sparkles", accent: StewardTheme.care.vivid) { reviewing = true }
            } else {
                ScanOrb(theme: .care)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { space = DiskSpace.current }
        }
        .onChange(of: library.phase) { _, _ in space = DiskSpace.current; Task { await library.loadCounts() } }
        .task { await library.loadCounts() }
        .onAppear { SpaceHistory.record(space) }
        .alert("Couldn't delete", isPresented: failureBinding) { Button("OK", role: .cancel) {} } message: { Text(library.failure ?? "") }
    }

    private func amount(_ value: String, _ label: LocalizedStringKey, _ alignment: HorizontalAlignment, size: CGFloat) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(value).font(.system(size: size, weight: .semibold)).monospacedDigit().contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.7))
        }
        .accessibilityElement(children: .combine)
    }

    /// What's on the iPhone, or once a scan has found something, what could go. Part of the storage card, because it explains the bar.
    @ViewBuilder private var contents: some View {
        if !found.isEmpty {
            Divider().overlay(.white.opacity(0.14))
            ForEach(found) { category in
                NavigationLink {
                    if category == .livePhotos { LivePhotosView() } else {
                        PhotoReviewView(title: category.title, note: category.note, theme: .care, groups: library.results[category] ?? [], category: category)
                    }
                } label: {
                    FeatureRow(icon: category.icon, title: category.title, value: formatted(library.saving(category)))
                }
                .buttonStyle(.plain)
            }
        } else if library.phase == .done {
            Divider().overlay(.white.opacity(0.14))
            Label("Nothing to clean", systemImage: "checkmark.seal.fill").font(.headline)
        } else if let counts = library.counts {
            Divider().overlay(.white.opacity(0.14))
            row("category-sparkles", "Photos", counts.photos, counts.photoBytes)
            row("category-drive", "Videos", counts.videos, counts.videoBytes)
            row("category-document", "Screenshots", counts.screenshots, counts.screenshotBytes)
            row("category-branch", "Live Photos", counts.livePhotos, counts.livePhotoBytes)
            if counts.photoBytes != nil || counts.videoBytes != nil {
                Text("Full size, including iCloud.").font(.footnote).foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    @ViewBuilder private func row(_ icon: String, _ title: LocalizedStringKey, _ count: Int, _ bytes: Int64?) -> some View {
        if count > 0 {
            FeatureRow(icon: icon, title: title, detail: Text(count, format: .number), value: bytes.map(formatted), chevron: false)
                .accessibilityElement(children: .combine)
        }
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { library.failure != nil }, set: { if !$0 { library.failure = nil } })
    }
}
