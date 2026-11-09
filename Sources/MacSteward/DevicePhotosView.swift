import AppKit
import MacStewardCore
import QuickLook
import SwiftUI

/// The tiles' small pictures, kept while Photos is open so scrolling back doesn't ask the device again.
@MainActor private let deviceThumbnails: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 800
    return cache
}()

/// The photos and videos on a connected iPhone or iPad, in a grid like the Mac's: sorted by size or date, grouped by month like Photos.
struct DevicePhotosView: View {
    enum Kind: String, CaseIterable { case photos, videos }
    enum Order: String, CaseIterable { case largest, newest, oldest }
    private var device: DevicePhotos { DevicePhotos.shared }
    @State private var kind = Kind.videos
    @State private var order = Order.largest
    @State private var byMonth = true
    @State private var selection = Set<ObjectIdentifier>()
    @State private var hovered: ObjectIdentifier?
    @State private var working: String?
    @State private var result: String?
    @State private var preview: URL?
    @FocusState private var gridFocused: Bool

    private var shown: [DeviceMedia] {
        let items = device.items.filter { $0.video == (kind == .videos) }
        switch order {
        case .largest: return items.sorted { $0.bytes > $1.bytes }
        case .newest: return items.sorted { $0.date > $1.date }
        case .oldest: return items.sorted { $0.date < $1.date }
        }
    }
    /// Months in the order the sort puts their first item, like Photos' Months view.
    private var months: [(title: String, items: [DeviceMedia])] {
        guard byMonth else { return [("", shown)] }
        var order = [DateComponents](), groups = [DateComponents: [DeviceMedia]]()
        for item in shown {
            let month = Calendar.current.dateComponents([.year, .month], from: item.date)
            if groups[month] == nil { order.append(month) }
            groups[month, default: []].append(item)
        }
        // By size, the biggest months first; by date, in the sort's direction.
        if order.count > 1, self.order == .largest { order.sort { groups[$0]!.reduce(0) { $0 + $1.bytes } > groups[$1]!.reduce(0) { $0 + $1.bytes } } }
        return order.map { month in
            let date = Calendar.current.date(from: month) ?? .distantPast
            return (date.formatted(.dateTime.month(.wide).year()), groups[month]!)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if device.locked || !device.ready {
                Label(device.locked ? String(localized: "Unlock your \(device.name) and tap Trust. Its photos appear here.") : String(localized: "Reading \(device.name)…"), systemImage: device.locked ? "lock.iphone" : "hourglass")
                    .stewardFont(.callout)
            } else {
                summary
                controls
                if shown.isEmpty { Text(kind == .videos ? "No videos are stored on it." : "No photos are stored on it.").stewardFont(.callout).foregroundStyle(.secondary) }
                else { grid }
            }
            if let result { Text(result).stewardFont(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)) }
        }
        .quickLookPreview($preview)
        .alert("Couldn't do that", isPresented: Binding(get: { device.failure != nil }, set: { if !$0 { device.failure = nil } })) { Button("OK", role: .cancel) {} } message: { Text(device.failure ?? "") }
        .onChange(of: kind) { _, _ in selection = [] }
    }

    private var summary: some View {
        let photos = device.items.filter { !$0.video }, videos = device.items.filter(\.video)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Stored on \(device.name): photos \(size(photos)), videos \(size(videos))").stewardFont(.callout).foregroundStyle(.secondary)
            // iOS shares only the originals kept on the device. Explaining this saves a lot of confusion when the list is short.
            Text("Only what's kept on the device itself. With iCloud Photos and Optimize Storage, most of a library stays in iCloud and doesn't appear here. Nothing is changed on it unless you delete.")
                .stewardFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        let items = shown, chosen = items.filter { selection.contains($0.id) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Show", selection: $kind) {
                    Text("Photos \(device.items.filter { !$0.video }.count)").tag(Kind.photos)
                    Text("Videos \(device.items.filter(\.video).count)").tag(Kind.videos)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("Sort", selection: $order) {
                    Text("Largest first").tag(Order.largest)
                    Text("Newest first").tag(Order.newest)
                    Text("Oldest first").tag(Order.oldest)
                }.fixedSize()
                Toggle("Group by month", isOn: $byMonth).toggleStyle(.switch).controlSize(.small)
                Spacer()
            }
            BulkBar(title: String(localized: "Select all"), isOn: Binding(get: { !items.isEmpty && chosen.count == items.count }, set: { selection = $0 ? Set(items.map(\.id)) : [] }), enabled: working == nil,
                    summary: String(localized: "\(chosen.count) chosen · \(size(chosen))")) {
                if let working { ProgressView().controlSize(.small); Text(working).stewardFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Button("Export…") { Task { await export(chosen) } }.disabled(chosen.isEmpty || working != nil)
                    .help("Copies the chosen originals into a folder you pick. Nothing is changed on the device.")
                if device.canDelete {
                    Button("Delete", role: .destructive) { Task { await delete(chosen) } }.buttonStyle(.borderedProminent).disabled(chosen.isEmpty || working != nil)
                }
            }
        }
    }

    private var grid: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(months, id: \.title) { month in
                if byMonth {
                    HStack(alignment: .firstTextBaseline) {
                        Text(month.title).stewardFont(.headline)
                        Text("\(month.items.count) · \(size(month.items))").stewardFont(.caption).foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(month.items) { item in
                        DeviceTile(item: item, selected: Binding(get: { selection.contains(item.id) }, set: { if $0 { selection.insert(item.id) } else { selection.remove(item.id) } }),
                                   open: { Task { await open(item) } }, hovered: $hovered)
                    }
                }
            }
        }
        // Space opens the picture under the pointer, like the Mac's own grid.
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onAppear { gridFocused = true }
        .onKeyPress(.space) {
            guard let hovered, let item = device.items.first(where: { $0.id == hovered }) else { return .ignored }
            Task { await open(item) }
            return .handled
        }
    }

    // MARK: - Actions

    /// Quick Look needs the file, so it's copied first. Large videos take a moment.
    private func open(_ item: DeviceMedia) async {
        guard working == nil else { return }
        working = String(localized: "Copying \(item.name) to look at it…")
        defer { working = nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Artifloam device preview", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do { preview = try await DevicePhotos.copy(item, to: folder) } catch { device.failure = error.localizedDescription }
    }

    private func export(_ chosen: [DeviceMedia]) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export Here")
        panel.message = String(localized: "Choose where the copies go. The originals stay on \(device.name).")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        result = nil
        var copied = 0, bytes: Int64 = 0, failed = [String]()
        for (index, item) in chosen.enumerated() {
            working = String(localized: "Exporting \(index + 1) of \(chosen.count): \(item.name)")
            do { _ = try await DevicePhotos.copy(item, to: folder); copied += 1; bytes += item.bytes } catch { failed.append(item.name) }
        }
        working = nil
        selection = []
        result = String(localized: "Exported \(copied) items (\(formattedBytes(UInt64(max(0, bytes))))) to \(folder.lastPathComponent). Nothing was changed on \(device.name).")
            + (failed.isEmpty ? "" : " " + String(localized: "Not copied: \(failed.joined(separator: ", "))."))
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func delete(_ chosen: [DeviceMedia]) async {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete \(chosen.count) items from \(device.name)?")
        alert.informativeText = String(localized: "They're removed from the device's library. Export them first if you want to keep a copy.")
        alert.addButton(withTitle: String(localized: "Delete")); alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        working = String(localized: "Deleting from \(device.name)…")
        defer { working = nil }
        if await device.delete(chosen) { selection = [] }
    }

    private func size(_ items: [DeviceMedia]) -> String { formattedBytes(UInt64(max(0, items.reduce(0) { $0 + $1.bytes }))) }
}

private struct DeviceTile: View {
    let item: DeviceMedia
    @Binding var selected: Bool
    let open: () -> Void
    @Binding var hovered: ObjectIdentifier?
    @State private var image: NSImage?

    var body: some View {
        Color.white.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if item.video { Image(systemName: "play.fill"); if item.duration > 0 { Text(Duration.seconds(item.duration).formatted(.time(pattern: item.duration >= 3600 ? .hourMinuteSecond : .minuteSecond))) } }
                    Text(formattedBytes(UInt64(max(0, item.bytes))))
                }
                .stewardFont(.caption, weight: .semibold).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5)).padding(6)
            }
            .overlay(alignment: .topTrailing) { Toggle("Select", isOn: $selected).toggleStyle(.stewardCheckboxOnly).padding(6) }
            .overlay { if selected { RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2) } }
            .overlay {
                if hovered == item.id {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .padding(10).background(.black.opacity(0.45), in: Circle()).allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .onHover { inside in if inside { hovered = item.id } else if hovered == item.id { hovered = nil } }
            .help(Text("\(item.name) · \(item.date.formatted(date: .abbreviated, time: .shortened))"))
            .task(id: item.id) {
                let key = "\(item.name)-\(item.bytes)" as NSString
                if let known = deviceThumbnails.object(forKey: key) { image = known; return }
                if let data = await DevicePhotos.thumbnail(item.file), let picture = NSImage(data: data) { deviceThumbnails.setObject(picture, forKey: key); image = picture }
            }
    }
}
