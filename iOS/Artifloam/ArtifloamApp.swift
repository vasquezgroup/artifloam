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
            .task { await library.start() }
        }
    }
}

func formatted(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

struct OverviewView: View {
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var space = DiskSpace.current
    @State private var confirming = false

    var body: some View {
        StagePage(theme: .care, title: "Artifloam", subtitle: "More room. Less clutter.", moving: library.working) {
            GlassCard {
                Text("\(formatted(space.free)) free").font(.title.weight(.semibold))
                StorageSplit(photos: library.photoBytes, videos: library.videoBytes, used: max(space.total - space.free, 0), total: space.total)
                Text("of \(formatted(space.total)) on this iPhone").font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
            content
            Text("iOS doesn't let any app look inside another app or clear its data. Artifloam only shows what it can really see, and removes nothing until you choose.")
                .font(.footnote).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
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
                GlassCard {
                    Text(library.phase == .reading ? "Reading your library" : "Looking for similar and blurred photos").font(.headline)
                    ProgressView(value: Double(library.checked), total: Double(max(library.total, 1)))
                    Text("\(library.checked) of \(library.total) checked").font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
            }
            summary
        }
    }

    @ViewBuilder private var summary: some View {
        let picks = library.recommended
        let bytes = picks.reduce(Int64(0)) { $0 + $1.bytes }
        if library.everything > 0 {
            Text("\(formatted(library.everything)) of photos and videos to review").font(.subheadline).foregroundStyle(.white.opacity(0.85))
        }
        if !picks.isEmpty {
            VStack(spacing: 10) {
                Text("Recommended: ^[\(picks.count) item](inflect: true), up to \(formatted(bytes))").font(.headline).multilineTextAlignment(.center)
                Text("Exact copies, and screenshots over 90 days old. You can review them first.").font(.footnote).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                OrbAction(title: "Clean", icon: "sparkles", accent: StewardTheme.care.vivid, disabled: library.working) {
                    Task { await library.delete(Set(picks.map(\.id))) }
                }
                .padding(.top, 6)
                NavigationLink("Review first") {
                    PhotoReviewView(title: "Recommended", note: "Exact copies, and screenshots over 90 days old.", theme: .care, groups: [CleanupGroup(items: picks)])
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
            }
        } else if library.phase == .done {
            GlassCard { Label(library.everything > 0 ? "Nothing is safe to remove without a look. Check Photos and Videos for the rest." : "Nothing to clean right now.", systemImage: "checkmark.seal.fill") }
        }
        if let notice = library.notice {
            GlassCard { Label(notice, systemImage: "info.circle") }
        }
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { library.failure != nil }, set: { if !$0 { library.failure = nil } })
    }
}

struct DiskSpace {
    var total: Int64
    var free: Int64
    static var current: DiskSpace {
        let values = try? URL.homeDirectory.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return DiskSpace(total: Int64(values?.volumeTotalCapacity ?? 0), free: values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

/// Share of the whole disk: photos, videos, everything else, then free space.
private struct StorageSplit: View {
    let photos: Int64
    let videos: Int64
    let used: Int64
    let total: Int64
    private var other: Int64 { max(used - photos - videos, 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    segment(photos, StewardTheme.cleanup.accent, geometry.size.width)
                    segment(videos, StewardTheme.files.accent, geometry.size.width)
                    segment(other, StewardTheme.system.accent, geometry.size.width)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 10)
            .background(.white.opacity(0.12), in: .capsule)
            .clipShape(.capsule)
            HStack(spacing: 12) {
                legend("Photos", photos, StewardTheme.cleanup.accent)
                legend("Videos", videos, StewardTheme.files.accent)
                legend("Other", other, StewardTheme.system.accent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photos \(formatted(photos)), videos \(formatted(videos)), other \(formatted(other))")
    }

    private func segment(_ bytes: Int64, _ color: Color, _ width: CGFloat) -> some View {
        color.frame(width: total > 0 ? max(width * CGFloat(bytes) / CGFloat(total), bytes > 0 ? 3 : 0) : 0)
    }

    private func legend(_ title: LocalizedStringKey, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption2)
            Text(formatted(bytes)).font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
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
