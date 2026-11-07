import SwiftUI

@main
struct ArtifloamApp: App {
    @State private var library = Library()

    init() { SpaceReminder.register() }

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { OverviewView() }.tabItem { Label("Overview", systemImage: "leaf.fill") }
                NavigationStack { MediaSectionView(section: .photos) }.tabItem { Label("Photos", systemImage: "sparkles") }
                NavigationStack { MediaSectionView(section: .videos) }.tabItem { Label("Videos", systemImage: "video.fill") }
                NavigationStack { AppsStorageView() }.tabItem { Label("Apps", systemImage: "square.grid.2x2.fill") }
                NavigationStack { ToolsView() }.tabItem { Label("Tools", systemImage: "wrench.and.screwdriver.fill") }
            }
            .tint(.white)
            .environment(library)
            .preferredColorScheme(.dark)
        }
    }
}

func formatted(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

struct OverviewView: View {
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var space = DiskSpace.current
    @State private var reviewing = false

    var body: some View {
        StagePage(theme: .care, title: "Artifloam", subtitle: "More room. Less clutter.", moving: library.working) {
            GlassCard {
                Text("\(formatted(space.free)) free").font(.title.weight(.semibold))
                ProgressView(value: Double(max(space.total - space.free, 0)), total: Double(max(space.total, 1))).tint(StewardTheme.care.accent)
                    .accessibilityLabel("Storage used")
                Text("of \(formatted(space.total)) on this iPhone").font(.footnote).foregroundStyle(.white.opacity(0.7))
                // Originals can live in iCloud, so these can add up to more than the iPhone holds. They're not part of the bar above.
                if library.photoBytes + library.videoBytes > 0 {
                    Text("Your library at full size, including iCloud: photos \(formatted(library.photoBytes)), videos \(formatted(library.videoBytes))").font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
            }
            content
            Text("iOS doesn't let any app look inside another app or clear its data. Artifloam only shows what it can really see, and removes nothing until you choose.")
                .font(.footnote).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
        }
        .orbFooter(summary: footerSummary) {
            if library.phase == .done && !library.recommended.isEmpty {
                OrbAction(title: "Review", icon: "sparkles", accent: StewardTheme.care.vivid) { reviewing = true }
            } else {
                ScanOrb(theme: .care)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { space = DiskSpace.current }
        }
        .onChange(of: library.phase) { _, _ in space = DiskSpace.current }
        .onAppear { SpaceHistory.record(space) }
        .alert("Couldn't delete", isPresented: failureBinding) { Button("OK", role: .cancel) {} } message: { Text(library.failure ?? "") }
    }

    @ViewBuilder private var content: some View {
        switch library.status {
        case .denied, .restricted:
            NoPhotoAccess()
        default:
            if library.working {
                VStack(spacing: 4) {
                    Text(library.phase == .reading ? "Reading your library" : "Looking for similar and blurred photos").font(.headline)
                    Text("\(library.checked) of \(library.total) checked").font(.footnote).foregroundStyle(.white.opacity(0.7)).monospacedDigit()
                }
            } else if library.phase == .stopped {
                VStack(spacing: 4) {
                    Text("Scan stopped").font(.headline)
                    Text("Results may be incomplete.").font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
            }
            summary
        }
    }

    @ViewBuilder private var summary: some View {
        let picks = library.recommended
        let bytes = picks.reduce(Int64(0)) { $0 + $1.bytes }
        if library.everything > 0 {
            Text("\(formatted(library.everything)) of full-size originals to review. Much of this may be in iCloud, so deleting can free less on this iPhone.").font(.footnote).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
        }
        if !picks.isEmpty {
            VStack(spacing: 10) {
                Text("Recommended: ^[\(picks.count) item](inflect: true), up to \(formatted(bytes))").font(.headline).multilineTextAlignment(.center)
                Text("Exact copies, and screenshots over 90 days old. You'll see each one first, and can untick any you want to keep.").font(.footnote).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                if library.phase == .done {
                    Button("Scan again") { Task { await library.scan() } }.font(.subheadline.weight(.medium)).foregroundStyle(.white)
                } else if library.phase != .reading {
                    Button("Review these") { reviewing = true }.font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                }
            }
            .navigationDestination(isPresented: $reviewing) {
                // Ticked in advance because they're recommended. Nothing goes until the person has seen them and pressed Delete.
                PhotoReviewView(title: "Recommended", note: "Exact copies, and screenshots over 90 days old. Untick anything you want to keep.", theme: .care, groups: library.recommendedGroups, preselected: true)
            }
        } else if library.phase == .done {
            GlassCard { Label(library.everything > 0 ? "Nothing is safe to remove without a look. Check Photos and Videos for the rest." : "Nothing to clean right now.", systemImage: "checkmark.seal.fill") }
        }
        if library.phase == .done || library.phase == .stopped { ScanResults() }
        if let notice = library.notice {
            GlassCard { Label(notice, systemImage: "info.circle") }
        }
    }

    private var footerSummary: Text? {
        if library.working { return library.scanSummary }
        let picks = library.recommended
        guard library.phase == .done, !picks.isEmpty else { return nil }
        return Text("\(formatted(picks.reduce(0) { $0 + $1.bytes }))\n^[\(picks.count) item](inflect: true)")
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { library.failure != nil }, set: { if !$0 { library.failure = nil } })
    }
}

/// Everything the main scan found, in one place, each leading to its own review.
private struct ScanResults: View {
    @Environment(Library.self) private var library
    private var health: HealthReport { HealthReport(reading: .current()) }
    var body: some View {
        GlassCard {
            Text("What the scan found").font(.headline)
            ForEach(PhotoCategory.allCases.filter { !library.items($0).isEmpty }) { category in
                NavigationLink {
                    if category == .livePhotos { LivePhotosView() } else {
                        PhotoReviewView(title: category.title, note: category.note, theme: .care, groups: library.results[category] ?? [], category: category)
                    }
                } label: {
                    FeatureRow(icon: category.icon, title: category.title, detail: Text("^[\(library.items(category).count) item](inflect: true)"), value: formatted(library.saving(category)))
                }.buttonStyle(.plain)
            }
            NavigationLink { ContactsCleanupView() } label: {
                FeatureRow(icon: "category-branch", title: "Duplicate contacts", detail: library.duplicateContactGroups.map { $0 == 0 ? Text("None found") : Text("^[\($0) group](inflect: true) to merge") } ?? Text("Tap to check. Needs Contacts access."))
            }.buttonStyle(.plain)
            NavigationLink { HealthView() } label: {
                FeatureRow(icon: "category-done", title: "Device health", detail: Text("Score \(health.score) of 100"))
            }.buttonStyle(.plain)
            NavigationLink { StorageSummaryView() } label: {
                FeatureRow(icon: "category-drive", title: "Storage summary", detail: Text("What's on this iPhone, and what could go."))
            }.buttonStyle(.plain)
        }
    }
}

struct DiskSpace {
    var total: Int64
    var free: Int64
    /// What iOS could clear by itself, such as caches of apps not in use.
    var purgeable: Int64 = 0
    static var current: DiskSpace {
        let values = try? URL.homeDirectory.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityForOpportunisticUsageKey])
        let important = values?.volumeAvailableCapacityForImportantUsage ?? 0, opportunistic = values?.volumeAvailableCapacityForOpportunisticUsage ?? 0
        return DiskSpace(total: Int64(values?.volumeTotalCapacity ?? 0), free: important, purgeable: max(important - opportunistic, 0))
    }
}

struct NoPhotoAccess: View {
    var body: some View {
        GlassCard {
            Text("No access to Photos").font(.headline)
            Text("Allow access in Settings so Artifloam can find large videos, screenshots and duplicates.").font(.subheadline)
            if let url = URL(string: UIApplication.openSettingsURLString) { Link("Open Settings", destination: url).fontWeight(.medium) }
        }
    }
}
