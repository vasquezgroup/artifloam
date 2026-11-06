import SwiftUI
import WidgetKit

struct FreeSpaceEntry: TimelineEntry {
    var date = Date()
    var free: Int64
    var total: Int64
}

struct FreeSpaceProvider: TimelineProvider {
    private var now: FreeSpaceEntry {
        let values = try? URL.homeDirectory.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return FreeSpaceEntry(free: values?.volumeAvailableCapacityForImportantUsage ?? 0, total: Int64(values?.volumeTotalCapacity ?? 0))
    }
    func placeholder(in context: Context) -> FreeSpaceEntry { FreeSpaceEntry(free: 64_000_000_000, total: 128_000_000_000) }
    func getSnapshot(in context: Context, completion: @escaping (FreeSpaceEntry) -> Void) { completion(now) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FreeSpaceEntry>) -> Void) {
        completion(Timeline(entries: [now], policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct FreeSpaceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FreeSpace", provider: FreeSpaceProvider()) { entry in
            VStack(alignment: .leading, spacing: 4) {
                Text(ByteCountFormatter.string(fromByteCount: entry.free, countStyle: .file)).font(.title2.weight(.semibold)).minimumScaleFactor(0.7)
                Text("free").font(.subheadline).opacity(0.8)
                Spacer()
                ProgressView(value: Double(max(entry.total - entry.free, 0)), total: Double(max(entry.total, 1))).tint(.white)
            }
            .foregroundStyle(.white)
            .containerBackground(for: .widget) {
                LinearGradient(stops: [.init(color: Color(red: 0.10, green: 0.04, blue: 0.22), location: 0), .init(color: Color(red: 0.36, green: 0.11, blue: 0.62), location: 0.55), .init(color: Color(red: 0.84, green: 0.32, blue: 0.80), location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .configurationDisplayName("Free space")
        .description("How much room your iPhone has.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct ArtifloamWidgets: WidgetBundle {
    var body: some Widget { FreeSpaceWidget() }
}
