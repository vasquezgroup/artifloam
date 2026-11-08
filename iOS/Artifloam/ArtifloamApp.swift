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
                NavigationStack { OverviewView().settingsButton() }.tabItem { Label("Overview", systemImage: "leaf.fill") }
                NavigationStack { MediaSectionView(section: .photos).settingsButton() }.tabItem { Label("Photos", systemImage: "sparkles") }
                NavigationStack { MediaSectionView(section: .videos).settingsButton() }.tabItem { Label("Videos", systemImage: "video.fill") }
                NavigationStack { AppsStorageView().settingsButton() }.tabItem { Label("Apps", systemImage: "square.grid.2x2.fill") }
                NavigationStack { ToolsView().settingsButton() }.tabItem { Label("Tools", systemImage: "wrench.and.screwdriver.fill") }
            }
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
