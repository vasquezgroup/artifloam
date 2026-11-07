import Charts
import SwiftUI

/// Where the space really is: on this iPhone, only in iCloud, and what could go. Only library figures need a scan.
struct StorageSummaryView: View {
    @Environment(Library.self) private var library
    @State private var space = DiskSpace.current
    private let history = SpaceHistory.load()

    private var used: Int64 { max(space.total - space.free, 0) }
    private var localMedia: Int64? {
        guard let photos = library.localPhotoBytes, let videos = library.localVideoBytes else { return nil }
        return photos + videos
    }

    var body: some View {
        DetailPage(theme: .space, title: "Storage summary") {
            GlassCard {
                Text("\(formatted(space.free)) free").font(.title.weight(.semibold))
                segments
                Text("of \(formatted(space.total)) on this iPhone").font(.footnote).foregroundStyle(.white.opacity(0.7))
                if space.purgeable > 0 { Label("iOS can clear about \(formatted(space.purgeable)) by itself when it needs room.", systemImage: "sparkles").font(.footnote) }
            }
            if let days = SpaceHistory.daysUntilFull(history) {
                GlassCard {
                    Label("At the recent rate, this iPhone fills up in about ^[\(days) day](inflect: true).", systemImage: "chart.line.downtrend.xyaxis").font(.subheadline.weight(.medium))
                }
            }
            if library.phase == .idle {
                GlassCard {
                    Text("Scan your library to see more").font(.headline)
                    Text("Press Scan to see what's on this iPhone and in iCloud, what could go, and your biggest items.").font(.footnote).foregroundStyle(.white.opacity(0.75))
                }
            } else {
                libraryCard
                cleanCard
                yearsCard
                biggestCard
            }
        }
        .orbFooter(summary: library.scanSummary) {
            if library.phase == .idle || library.working { ScanOrb(theme: .space) }
        }
    }

    private var segments: some View {
        var parts: [(title: LocalizedStringKey, bytes: Int64, color: Color)] = [(LocalizedStringKey("Used"), used, StewardTheme.space.accent)]
        if let localMedia {
            parts = [(LocalizedStringKey("Photos"), library.localPhotoBytes ?? 0, StewardTheme.cleanup.accent),
                     (LocalizedStringKey("Videos"), library.localVideoBytes ?? 0, StewardTheme.files.accent),
                     (LocalizedStringKey("Apps and system"), max(used - localMedia, 0), StewardTheme.system.accent)]
        }
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(parts.indices, id: \.self) { index in
                        parts[index].color.frame(width: space.total > 0 ? geometry.size.width * CGFloat(parts[index].bytes) / CGFloat(space.total) : 0)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 14).background(.white.opacity(0.12), in: .capsule).clipShape(.capsule).accessibilityHidden(true)
            ForEach(parts.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Circle().fill(parts[index].color).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(parts[index].title).font(.footnote)
                    Spacer()
                    Text(formatted(parts[index].bytes)).font(.footnote).monospacedDigit().foregroundStyle(.white.opacity(0.8))
                }.accessibilityElement(children: .combine)
            }
        }
    }

    private var libraryCard: some View {
        GlassCard {
            Text("Your photos and videos").font(.headline)
            if let localMedia {
                let all = library.photoBytes + library.videoBytes
                LabeledContent("On this iPhone", value: formatted(localMedia))
                LabeledContent("Only in iCloud", value: formatted(max(all - localMedia, 0)))
                Text("Deleting something only in iCloud frees iCloud space, not space on this iPhone.").font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
            LabeledContent("Photos at full size", value: formatted(library.photoBytes))
            LabeledContent("Videos at full size", value: formatted(library.videoBytes))
        }
    }

    private var cleanCard: some View {
        GlassCard {
            Text("What could go").font(.headline)
            Text("Items can be in more than one group, so the total counts each once: \(formatted(library.everything)).").font(.footnote).foregroundStyle(.white.opacity(0.7))
            ForEach(PhotoCategory.allCases.filter { !library.items($0).isEmpty }.sorted { library.saving($0) > library.saving($1) }) { category in
                NavigationLink {
                    if category == .livePhotos { LivePhotosView() } else {
                        PhotoReviewView(title: category.title, note: category.note, theme: .space, groups: library.results[category] ?? [], category: category)
                    }
                } label: {
                    FeatureRow(icon: category.icon, title: category.title, value: formatted(library.saving(category)))
                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var yearsCard: some View {
        if !library.bytesByYear.isEmpty {
            GlassCard {
                Text("By year").font(.headline)
                Chart(library.bytesByYear.sorted { $0.key < $1.key }, id: \.key) { year, bytes in
                    BarMark(x: .value("Year", String(year)), y: .value("GB", Double(bytes) / 1e9)).foregroundStyle(StewardTheme.space.accent)
                }
                .chartYAxisLabel("GB").frame(height: 170)
            }
        }
    }

    @ViewBuilder private var biggestCard: some View {
        if !library.biggest.isEmpty {
            NavigationLink {
                PhotoReviewView(title: "Biggest items", note: "Your largest photos and videos. Nothing is ticked.", theme: .space, groups: [CleanupGroup(items: library.biggest)])
            } label: {
                GlassCard { FeatureRow(icon: "category-stack", title: "Biggest items", detail: Text("The \(library.biggest.count) largest"), value: formatted(library.biggest.reduce(0) { $0 + $1.bytes })) }
            }.buttonStyle(.plain)
        }
    }
}
