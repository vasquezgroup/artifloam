import Contacts
import Photos
import SwiftUI

/// The gear at the top right of every tab.
struct SettingsButton: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape.fill") }
                    .accessibilityLabel("Settings")
            }
        }
    }
}

extension View {
    func settingsButton() -> some View { modifier(SettingsButton()) }
}

struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var reminder = SpaceReminder.enabled
    @State private var photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var contacts = CNContactStore.authorizationStatus(for: .contacts)

    @AppStorage(AppLanguage.key) private var chosen: String?
    private var language: String {
        chosen.map(AppLanguage.name) ?? String(app: "Same as iPhone")
    }
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        DetailPage(theme: .care, title: "Settings") {
            GlassCard {
                NavigationLink { LanguagePicker() } label: {
                    FeatureRow(icon: "category-globe", title: "Language", detail: Text(verbatim: language))
                }
                .buttonStyle(.plain)
            }
            GlassCard {
                Toggle("Remind me when space runs low", isOn: $reminder)
                    .onChange(of: reminder) { _, on in Task { reminder = await SpaceReminder.set(on) } }
                Text("iOS decides when this check runs, so a reminder can come late.").font(.footnote).foregroundStyle(.white.opacity(0.7))
                Divider()
                Text("Add the free space widget by holding your Home Screen, then tapping Edit and Add Widget.").font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
            GlassCard {
                Text("Access").font(.headline)
                settingsLink { FeatureRow(icon: "category-sparkles", title: "Photos", value: status(photos)) }
                settingsLink { FeatureRow(icon: "category-branch", title: "Contacts", value: status(contacts)) }
            }
            if !library.protected.isEmpty {
                GlassCard {
                    Text("Never suggested").font(.headline)
                    Text("^[\(library.protected.count) item](inflect: true) you asked never to see again.").font(.footnote).foregroundStyle(.white.opacity(0.7))
                    Button("Suggest them again") { library.clearProtected() }.fontWeight(.medium)
                }
            }
            GlassCard {
                Text("Artifloam \(version)").font(.headline)
                Text("Everything is checked on this iPhone. Your photos, contacts and the app list never leave your devices.").font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            contacts = CNContactStore.authorizationStatus(for: .contacts)
        }
    }

    @ViewBuilder private func settingsLink<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            Link(destination: url) { label() }.buttonStyle(.plain)
        }
    }

    private func status(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: String(app: "Allowed")
        case .limited: String(app: "Some photos")
        case .notDetermined: String(app: "Not asked yet")
        default: String(app: "Not allowed")
        }
    }
    private func status(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .authorized: String(app: "Allowed")
        case .limited: String(app: "Some contacts")
        case .notDetermined: String(app: "Not asked yet")
        default: String(app: "Not allowed")
        }
    }
}
