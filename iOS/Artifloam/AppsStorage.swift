import PhotosUI
import SwiftUI
import Vision

enum StorageSource: String, CaseIterable, Identifiable {
    case apps, whatsapp
    var id: Self { self }
    var title: LocalizedStringKey { self == .apps ? "Apps" : "WhatsApp chats" }
    var steps: LocalizedStringKey {
        self == .apps
            ? "1. Open Settings, General, iPhone Storage and wait for the list.\n2. Take screenshots, scrolling down between them.\n3. Choose them here."
            : "1. Open WhatsApp, Settings, Storage and data, Manage storage.\n2. Take screenshots of the chat list, scrolling between them.\n3. Choose them here."
    }
}

/// ponytail: results stay in memory, because chat names are private. Add saving only if people ask for history.
struct AppsStorageView: View {
    @State private var source = StorageSource.apps
    @State private var rows: [StorageSource: [SizedRow]] = [:]
    @State private var picks: [PhotosPickerItem] = []
    @State private var reading = false
    @State private var message: LocalizedStringKey?

    private var current: [SizedRow] { rows[source] ?? [] }

    var body: some View {
        StagePage(theme: .system, title: "Apps", subtitle: "What apps use, and how to clean each one.", moving: reading) {
            GlassCard {
                Label("See every app automatically", systemImage: "laptopcomputer.and.iphone").font(.headline)
                Text("iOS doesn't show other apps' sizes to an iPhone app. Connect this iPhone to Artifloam on your Mac to list every app, and WhatsApp by person or group, without doing anything here.").font(.subheadline)
            }
            GlassCard {
                Text("No Mac nearby? Read a screenshot").font(.headline)
                Picker("Show", selection: $source) {
                    ForEach(StorageSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(source.steps).font(.subheadline)
                PhotosPicker(selection: $picks, maxSelectionCount: 30, matching: .screenshots) {
                    if reading { Label("Reading screenshots", systemImage: "hourglass") } else { Label("Choose screenshots", systemImage: "photo.badge.plus") }
                }
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .disabled(reading)
                if let message { Text(message).font(.footnote).foregroundStyle(.white.opacity(0.75)) }
                Text("Screenshots are read on this iPhone. Nothing is sent or saved.").font(.footnote).foregroundStyle(.white.opacity(0.65))
            }
            if !current.isEmpty {
                GlassCard {
                    Text("\(current.count) found, \(formatted(current.reduce(0) { $0 + $1.bytes }))").font(.headline)
                    ForEach(current) { row in
                        HStack(spacing: 10) {
                            NavigationLink { AdviceView(name: row.name, bytes: row.bytes, advice: StorageAdvice.lookup(row.name, source: source)) } label: {
                                FeatureRow(icon: "category-drive", title: LocalizedStringKey(row.name), value: formatted(row.bytes))
                            }
                            .buttonStyle(.plain)
                            Button { rows[source]?.removeAll { $0.id == row.id } } label: { Image(systemName: "xmark.circle") }
                                .accessibilityLabel("Remove \(row.name), read wrongly")
                        }
                    }
                    Text("Sizes are as shown in your screenshots. If a row was read wrongly, remove it.").font(.footnote).foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .onChange(of: picks) { _, new in
            guard !new.isEmpty else { return }
            Task { await read(new, for: source) }
        }
    }

    private func read(_ items: [PhotosPickerItem], for source: StorageSource) async {
        reading = true
        message = nil
        var found = rows[source] ?? []
        var failed = 0
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let lines = await Self.recognize(data) else { failed += 1; continue }
            found += StorageScreenshot.rows(from: lines)
        }
        rows[source] = StorageScreenshot.merged(found)
        if failed > 0 {
            message = "\(failed) screenshots couldn't be read."
        } else if rows[source]?.isEmpty != false {
            message = "No sizes found. Check the screenshots show the list with sizes."
        }
        picks = []
        reading = false
    }

    nonisolated static func recognize(_ data: Data) async -> [OCRLine]? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data)?.cgImage else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
            return (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first.map {
                    let box = observation.boundingBox
                    return OCRLine(text: $0.string, midY: box.midY, minX: box.minX, height: box.height)
                }
            }
        }.value
    }
}

struct StorageAdvice {
    var steps: [LocalizedStringKey]
    var warning: LocalizedStringKey? = nil
    var scheme: String? = nil

    static func lookup(_ name: String, source: StorageSource) -> StorageAdvice {
        if source == .whatsapp {
            return StorageAdvice(
                steps: ["Open WhatsApp, then Settings, Storage and data, Manage storage. Names can differ between versions.", "Open this chat, then choose the media you want to remove. The largest files are easy to find there."],
                warning: "Avoid Clear chat if you only want to free space. It removes the messages too.",
                scheme: "whatsapp://")
        }
        let name = name.lowercased()
        func has(_ words: String...) -> Bool { words.contains { name.contains($0) } }
        if has("whatsapp") {
            return StorageAdvice(steps: ["Most of this is usually media in your chats.", "Use WhatsApp chats at the top of this screen to see which person or group uses the most."], scheme: "whatsapp://")
        }
        if has("netflix") { return .downloads("Open Netflix, My Netflix, the menu, App Settings, Delete All Downloads. Or delete single titles in Downloads.", scheme: "nflx://") }
        if has("youtube") { return .downloads("Open YouTube, You, Downloads, and delete what you no longer need.", scheme: "youtube://") }
        if has("prime video", "disney", "apple tv", "hbo") || name == "max" { return .downloads("Open the app's Downloads section and delete what you've already watched.") }
        if has("roblox") {
            return StorageAdvice(
                steps: ["In Settings, General, iPhone Storage, Roblox, compare the app size with Documents & Data.", "If Documents & Data is large, deleting and reinstalling Roblox is the way to clear it. It fills up again as you play."],
                warning: "Offload App won't help here, because it keeps Documents & Data. Before deleting, make sure you know your Roblox login.",
                scheme: nil)
        }
        if has("tiktok") { return StorageAdvice(steps: ["Open TikTok, Profile, the menu, Settings and privacy, Cache & Cellular, Free up space. Names can differ between versions."]) }
        if has("instagram", "facebook") { return StorageAdvice(steps: ["These apps have no clear button for their whole cache.", "Deleting and reinstalling the app clears it. You'll need to sign in again, and it fills up again as you use it."], warning: "Offload App keeps this data, so it won't shrink it.") }
        if has("spotify") { return StorageAdvice(steps: ["Open Spotify, Settings, Storage, Clear cache. Your downloads stay.", "Remove downloads there too if you need more room."], scheme: "spotify://") }
        if has("telegram") { return StorageAdvice(steps: ["Open Telegram, Settings, Data and Storage, Storage Usage, and clear the cache. It can download again what's still on Telegram."], scheme: "tg://") }
        if has("photos", "fotos") { return StorageAdvice(steps: ["Use Photos and videos in Artifloam to find what's large."]) }
        if has("messages", "nachrichten") { return StorageAdvice(steps: ["Open Settings, General, iPhone Storage, Messages, and review large attachments there."]) }
        if name == "ios" || has("system data", "systemdaten") { return StorageAdvice(steps: ["This is managed by iOS and can't be removed by you or any app. iOS frees part of it when space runs low."]) }
        return StorageAdvice(
            steps: ["Check the app's own settings for downloads or a cache. Games often keep downloaded levels you can remove in the game.", "In Settings, General, iPhone Storage, open the app. Offload App frees only the app's size and keeps its data. Delete App removes both."],
            warning: "Deleting an app can lose data that isn't saved to an account or iCloud. Check first, especially for game progress.")
    }

    private static func downloads(_ step: LocalizedStringKey, scheme: String? = nil) -> StorageAdvice {
        StorageAdvice(steps: [step, "If it's still large after that, offload or delete the app in Settings, General, iPhone Storage. Downloads can be fetched again."], scheme: scheme)
    }
}

struct AdviceView: View {
    let name: String
    let bytes: Int64
    let advice: StorageAdvice
    @Environment(\.openURL) private var openURL
    @State private var couldNotOpen = false

    var body: some View {
        DetailPage(theme: .system, title: LocalizedStringKey(name)) {
            Text(formatted(bytes)).font(.largeTitle.weight(.light))
            GlassCard {
                Text("What you can do").font(.headline)
                ForEach(advice.steps.indices, id: \.self) { Text(advice.steps[$0]) }
            }
            if let warning = advice.warning {
                GlassCard { Label(warning, systemImage: "exclamationmark.triangle") }
            }
            if let scheme = advice.scheme, let url = URL(string: scheme) {
                Button("Open app") { openURL(url) { couldNotOpen = !$0 } }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .alert("Couldn't open the app", isPresented: $couldNotOpen) { Button("OK", role: .cancel) {} }
    }
}
