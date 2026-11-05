import AppKit
import SwiftUI
import MacStewardCore

/// Reads the latest version from vasquezgroup.ch. A download is used only if it matches the hash our key signed,
/// so a hacked website can't offer a different app. It installs only when the person clicks.
@MainActor
final class UpdateChecker: ObservableObject {
    /// Published from the vasquezgroup.ch repository: `public/updates/artifloam.json`.
    struct Release: Decodable { let version: String; let url: URL; let sha256: String; let signature: String }
    static let feed = URL(string: "https://vasquezgroup.ch/updates/artifloam.json")!
    /// Only builds released through `scripts/prepare-distribution.sh` carry this flag. Forks and local builds connect to nothing.
    static var current: String? {
        guard Bundle.main.object(forInfoDictionaryKey: "ArtifloamOfficialBuild") as? Bool == true else { return nil }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
    @Published private(set) var available: Release?
    @Published private(set) var downloading = false
    private var timer: Timer?

    init() {
        guard Self.current != nil else { return }
        Task { await check(reportResult: false); await Self.sendUsagePingIfDue() }
        timer = .scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in Task { await self?.check(reportResult: false); await Self.sendUsagePingIfDue() } }
    }

    /// Off unless turned on in Settings. A failed send is quietly retried at the next daily check.
    private static func sendUsagePingIfDue() async {
        guard let current else { return }
        let defaults = StewardPreferences.defaults
        let unsolved = UsagePing.Payload(version: current)
        guard UsagePing.isDue(enabled: defaults.bool(forKey: UsagePing.enabledKey), lastSent: defaults.string(forKey: UsagePing.lastPeriodKey), period: unsolved.period) else { return }
        let payload = await Task.detached(priority: .background) { var solved = unsolved; solved.solve(); return solved }.value
        guard let body = try? JSONEncoder().encode(payload) else { return }
        var request = URLRequest(url: UsagePing.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = URLSession(configuration: .ephemeral) // No cookies or cache between pings.
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 204 else { return }
        defaults.set(payload.period, forKey: UsagePing.lastPeriodKey)
    }

    static func isNewer(_ version: String, than current: String) -> Bool { version.compare(current, options: .numeric) == .orderedDescending }

    /// `reportResult` is for the menu item: say "up to date" or the failure instead of staying quiet.
    func check(reportResult: Bool) async {
        guard let current = Self.current else { return alert("Not an official build", "This build doesn't check for updates. Update it from where you got its source.") }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard UpdateFeed.verified(version: release.version, url: release.url, sha256: release.sha256, signature: release.signature) else { throw URLError(.badServerResponse) }
            if Self.isNewer(release.version, than: current) {
                available = release
                if reportResult { offer() }
            } else {
                available = nil
                if reportResult { alert("Artifloam is up to date", "Version \(current) is the latest version.") }
            }
        } catch {
            if reportResult { alert("Could not check for updates", error.localizedDescription) }
        }
    }

    /// One click, and only when the person clicks. See AppUpdate for what must pass before anything changes.
    func offer() {
        guard let available, !downloading else { return }
        let alert = NSAlert()
        alert.messageText = "Update to Artifloam \(available.version)?"
        alert.informativeText = "You have version \(Self.current ?? "?"). Artifloam downloads the update, checks that it's genuine, and reopens."
        alert.addButton(withTitle: "Update and Reopen"); alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        downloading = true
        Task {
            defer { downloading = false }
            do {
                try await install(available)
                try Self.reopen(Bundle.main.bundleURL)
            } catch {
                self.alert("Couldn't update Artifloam", error.localizedDescription)
            }
        }
    }

    private func install(_ release: Release) async throws {
        let (file, response) = try await URLSession.shared.download(for: URLRequest(url: release.url, cachePolicy: .reloadIgnoringLocalCacheData))
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let app = Bundle.main.bundleURL
        try await Task.detached {
            guard try UpdateFeed.sha256(ofFile: file) == release.sha256 else {
                throw StewardError.blocked("The download doesn't match the signed release, so it was discarded. Nothing was changed.")
            }
            try AppUpdate.install(archive: file, version: release.version, over: app)
        }.value
    }

    /// The single-window lock is ours until this process exits, so the new copy opens just after.
    static func reopen(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let launchArguments = CommandLine.arguments.dropFirst()
        process.arguments = ["-c", "app=\"$1\"; shift; sleep 1; if [ $# -gt 0 ]; then /usr/bin/open \"$app\" --args \"$@\"; else /usr/bin/open \"$app\"; fi", "sh", app.path] + launchArguments
        try process.run()
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.runModal()
    }
}

/// Corner button for an available update: dark glass with a turning light ring in the page's accent, so it
/// reads on every page colour. A hint bubble opens once per new version and goes away when the pointer touches it.
struct UpdateBadge: View {
    let version: String
    let accent: Color
    let scale: Double
    var downloading = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var turn = 0.0
    @State private var bob = false
    @State private var hintSeen = StewardPreferences.defaults.string(forKey: "updateHintSeen")

    var body: some View {
        let ring = AngularGradient(colors: [.white, accent, .white.opacity(0.25), accent, .white], center: .center, angle: .degrees(turn))
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 14 * scale, weight: .semibold))
                    .symbolRenderingMode(.palette).foregroundStyle(.white, accent)
                    .offset(y: bob ? 1.5 : -1)
                Text(downloading ? "Downloading…" : "Update").font(.system(size: 12 * scale, weight: .semibold))
            }
            .foregroundStyle(.white).padding(.horizontal, 11).frame(height: 28)
            .background {
                Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    .overlay { Capsule().fill(LinearGradient(colors: [.black.opacity(0.30), accent.opacity(hovered ? 0.55 : 0.35)], startPoint: .top, endPoint: .bottom)) }
            }
            .overlay { Capsule().strokeBorder(ring, lineWidth: 1.4) }
            .shadow(color: accent.opacity(hovered ? 0.9 : 0.6), radius: hovered ? 12 : 8)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .scaleEffect(hovered ? 1.05 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if hintSeen != version {
                // White bubble with a tail pointing up at the button's centre.
                VStack(spacing: 0) {
                    Path { p in p.move(to: CGPoint(x: 0, y: 7)); p.addLine(to: CGPoint(x: 7, y: 0)); p.addLine(to: CGPoint(x: 14, y: 7)); p.closeSubpath() }
                        .fill(.white).frame(width: 14, height: 7)
                    Text("Version \(version) is ready")
                        .font(.system(size: 11.5 * scale, weight: .semibold)).foregroundStyle(.black.opacity(0.85)).fixedSize()
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .compositingGroup().shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .offset(y: 28 * scale + 6).allowsHitTesting(false)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.2)) {
                hovered = inside
                if inside && hintSeen != version { hintSeen = version; StewardPreferences.defaults.set(version, forKey: "updateHintSeen") }
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) { turn = 360 }
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { bob = true }
        }
        .help("Artifloam \(version) is available").accessibilityLabel("Update available: \(version)")
    }
}
