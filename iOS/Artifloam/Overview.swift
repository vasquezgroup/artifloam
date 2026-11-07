import SwiftUI

/// One job: how much room is there, and one press to get more.
struct OverviewView: View {
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var space = DiskSpace.current
    @State private var reviewing = false

    private var ring: Double {
        library.working ? Double(library.checked) / Double(max(library.total, 1)) : Double(max(space.total - space.free, 0)) / Double(max(space.total, 1))
    }
    private var found: [PhotoCategory] {
        PhotoCategory.allCases.filter { !library.items($0).isEmpty }.sorted { library.saving($0) > library.saving($1) }
    }

    var body: some View {
        let picks = library.recommended
        StagePage(theme: .care, moving: library.working, ring: ring) {
            VStack(spacing: 2) {
                Text("\(formatted(space.free)) free").font(.system(size: 34, weight: .semibold)).monospacedDigit().contentTransition(.numericText()).accessibilityAddTraits(.isHeader)
                if let days = SpaceHistory.daysUntilFull(SpaceHistory.load()) {
                    Text("Full in about ^[\(days) day](inflect: true)").font(.subheadline).foregroundStyle(.white.opacity(0.75))
                }
            }
            switch library.status {
            case .denied, .restricted: NoPhotoAccess()
            default:
                if !found.isEmpty {
                    GlassCard {
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
                    }
                } else if library.phase == .done {
                    Label("Nothing to clean", systemImage: "checkmark.seal.fill").font(.headline)
                } else if let counts = library.counts {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        tile("category-sparkles", "Photos", counts.photos)
                        tile("category-drive", "Videos", counts.videos)
                        tile("category-document", "Screenshots", counts.screenshots)
                        tile("category-branch", "Live Photos", counts.livePhotos)
                    }
                }
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

    private func tile(_ icon: String, _ title: LocalizedStringKey, _ count: Int) -> some View {
        GlassCard {
            CategoryIcon(name: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(count, format: .number).font(.title2.weight(.semibold)).monospacedDigit()
                Text(title).font(.footnote).foregroundStyle(.white.opacity(0.75))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { library.failure != nil }, set: { if !$0 { library.failure = nil } })
    }
}
