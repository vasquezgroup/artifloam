import SwiftUI

/// iOS doesn't show other apps' sizes to an app, and this only offers what works automatically. So here: where the full list is, and how to clean the usual big apps.
struct AppsStorageView: View {
    private static let common = ["WhatsApp", "Netflix", "YouTube", "Roblox", "TikTok", "Instagram", "Facebook", "Spotify", "Telegram", "Prime Video", "Messages", "Games and other apps"]

    @State private var list = MacAppList.load()
    @State private var receiver: AppListReceiver?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        StagePage(theme: .iphone, title: "Apps", subtitle: "Connect to your Mac to see and delete every app.", artwork: "iphone-connect") {
            if let list {
                GlassCard {
                    Text("See every app, by size").font(.headline)
                    Text("Read by your Mac on \(list.readAt, style: .date)").font(.footnote).foregroundStyle(.white.opacity(0.7))
                    LazyVStack(spacing: 12) {
                        ForEach(list.apps) { app in
                            NavigationLink { AdviceView(name: app.name, advice: StorageAdvice.lookup(app.name)) } label: {
                                FeatureRow(icon: "category-drive", title: "\(app.name)", detail: Text("App \(formatted(app.appBytes)) · Data \(formatted(app.dataBytes))"), value: formatted(app.appBytes + app.dataBytes))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                GlassCard {
                    Text("See every app, by size").font(.headline)
                    Text("iOS doesn't show other apps' sizes to an iPhone app. Connect this iPhone to Artifloam on your Mac to list every app, delete the ones you don't need, and see WhatsApp by person or group.").font(.subheadline)
                }
                GlassCard {
                    Text("Cleaning common apps").font(.headline)
                    ForEach(Self.common, id: \.self) { name in
                        NavigationLink { AdviceView(name: name, advice: StorageAdvice.lookup(name)) } label: {
                            FeatureRow(icon: "category-drive", title: LocalizedStringKey(name))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onAppear { list = MacAppList.load(); listen() }
        .onDisappear { receiver?.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .appListArrived)) { _ in list = MacAppList.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { list = MacAppList.load(); listen() } else { receiver?.stop() }
        }
    }
}

/// The list Artifloam on the Mac sends over Wi-Fi, because an iPhone app can't see other apps. See IPhoneAppList on the Mac.
struct MacAppList: Decodable {
    struct App: Decodable, Identifiable {
        let name: String
        let appBytes: Int64
        let dataBytes: Int64
        var id: String { name }
    }
    let readAt: Date
    let apps: [App]

    static func decode(_ data: Data) -> MacAppList? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MacAppList.self, from: data)
    }
    static var file: URL { URL.documentsDirectory.appending(path: "mac-app-list.json") }

    static func load() -> MacAppList? {
        guard let data = try? Data(contentsOf: file), let list = decode(data), !list.apps.isEmpty else { return nil }
        return list
    }
}

extension AppsStorageView {
    private func listen() {
        if receiver == nil {
            receiver = AppListReceiver { Task { @MainActor in NotificationCenter.default.post(name: .appListArrived, object: nil) } }
        }
        receiver?.start()
    }
}

extension Notification.Name {
    static let appListArrived = Notification.Name("appListArrived")
}

struct StorageAdvice {
    var steps: [LocalizedStringKey]
    var warning: LocalizedStringKey? = nil
    var scheme: String? = nil

    static func lookup(_ name: String) -> StorageAdvice {
        let name = name.lowercased()
        func has(_ words: String...) -> Bool { words.contains { name.contains($0) } }
        if has("whatsapp") {
            return StorageAdvice(
                steps: ["Open WhatsApp, then Settings, Storage and data, Manage storage. Names can differ between versions.", "It lists your chats by size. Open one, then choose the media you want to remove."],
                warning: "Avoid Clear chat if you only want to free space. It removes the messages too.",
                scheme: "whatsapp://")
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
    let advice: StorageAdvice
    @Environment(\.openURL) private var openURL
    @State private var couldNotOpen = false

    var body: some View {
        DetailPage(theme: .iphone, title: LocalizedStringKey(name)) {
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
