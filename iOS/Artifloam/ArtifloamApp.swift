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
            Sections()
            .tint(.white)
            // Dates, numbers and sizes follow the chosen language too.
            .environment(\.locale, language.map(Locale.init(identifier:)) ?? .autoupdatingCurrent)
            .environment(library)
            .preferredColorScheme(.dark)
        }
    }
}

/// A tab bar on iPhone; from iOS 18 a sidebar on iPad, like the Mac's, which can fold away. iOS 17 keeps the tab bar everywhere.
private struct Sections: View {
    var body: some View {
        if #available(iOS 18.0, *) {
            TabView {
                Tab("Overview", systemImage: "leaf.fill") { overview }
                Tab("Photos", systemImage: "sparkles") { photos }
                Tab("Videos", systemImage: "video.fill") { videos }
                Tab("Apps", systemImage: "square.grid.2x2.fill") { apps }
                Tab("Tools", systemImage: "wrench.and.screwdriver.fill") { tools }
            }
            .tabViewStyle(.sidebarAdaptable)
        } else {
            TabView {
                overview.tabItem { Label("Overview", systemImage: "leaf.fill") }
                photos.tabItem { Label("Photos", systemImage: "sparkles") }
                videos.tabItem { Label("Videos", systemImage: "video.fill") }
                apps.tabItem { Label("Apps", systemImage: "square.grid.2x2.fill") }
                tools.tabItem { Label("Tools", systemImage: "wrench.and.screwdriver.fill") }
            }
        }
    }
    private var overview: some View { NavigationStack { OverviewView().settingsButton() } }
    private var photos: some View { NavigationStack { MediaSectionView(section: .photos).settingsButton() } }
    private var videos: some View { NavigationStack { MediaSectionView(section: .videos).settingsButton() } }
    private var apps: some View { NavigationStack { AppsStorageView().settingsButton() } }
    private var tools: some View { NavigationStack { ToolsView().settingsButton() } }
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
