import SwiftUI

@main
struct ArtifloamApp: App {
    @State private var library = Library()

    @AppStorage(AppLanguage.key) private var language: String?

    init() {
        LanguageBundle.use(AppLanguage.chosen)
        SpaceReminder.register()
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Overview", systemImage: "leaf.fill") { NavigationStack { OverviewView().settingsButton() } }
                Tab("Photos", systemImage: "sparkles") { NavigationStack { MediaSectionView(section: .photos).settingsButton() } }
                Tab("Videos", systemImage: "video.fill") { NavigationStack { MediaSectionView(section: .videos).settingsButton() } }
                Tab("Apps", systemImage: "square.grid.2x2.fill") { NavigationStack { AppsStorageView().settingsButton() } }
                Tab("Tools", systemImage: "wrench.and.screwdriver.fill") { NavigationStack { ToolsView().settingsButton() } }
            }
            // A tab bar on iPhone; on iPad and an unfolded iPhone a sidebar like the Mac's, which can fold away.
            .tabViewStyle(.sidebarAdaptable)
            .tint(.white)
            // Dates, numbers and sizes follow the chosen language too.
            .environment(\.locale, language.map(Locale.init(identifier:)) ?? .autoupdatingCurrent)
            .environment(library)
            .preferredColorScheme(.dark)
        }
    }
}

func formatted(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

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
