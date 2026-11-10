import Foundation

public enum SystemStatus: Sendable { case good, review, info, unknown }
public enum SystemArea: String, CaseIterable, Identifiable, Sendable {
    case protection = "Protection", updates = "Updates", remote = "Remote access", backup = "Backup"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .protection: return String(localized: "Protection")
        case .updates: return String(localized: "Updates")
        case .remote: return String(localized: "Remote access")
        case .backup: return String(localized: "Backup")
        }
    }
}
/// What Artifloam can put right itself, after macOS asks for the password.
public enum SystemFix: Sendable { case firewall }
public enum SystemFixResult: Sendable, Equatable { case done, cancelled, failed }
/// One finding, in plain language. `counts` puts it in "6 of 8 protections on".
public struct SecurityCheck: Identifiable, Sendable {
    public let id: String
    public let area: SystemArea
    public let title: String
    public let detail: String
    public let status: SystemStatus
    public var counts = false
    /// A System Settings page; nothing here changes a setting by itself.
    public var settings: String? = nil
    public var action: String? = nil
    /// The one thing left to do once `settings` is open.
    public var nextStep: String? = nil
    public var fix: SystemFix? = nil
}
/// Reads macOS settings with its own tools. Only `apply` changes one, when a person presses its button and macOS has their password.
/// A value that can't be read stays "unknown", never a pass.
public enum SystemAudit {
    private static let unread = String(localized: "Artifloam couldn't read this setting.")
    private static func toggle(_ id: String, _ area: SystemArea, _ title: String, _ value: Bool?, offTitle: String, on: String, off: String, settings: String? = nil, action: String? = nil, nextStep: String? = nil, fix: SystemFix? = nil) -> SecurityCheck {
        SecurityCheck(id: id, area: area, title: value == false ? offTitle : title, detail: value.map { $0 ? on : off } ?? unread, status: value.map { $0 ? .good : .review } ?? .unknown, counts: true,
                      settings: value == false ? settings : nil, action: value == false ? action : nil, nextStep: value == false ? nextStep : nil, fix: value == false ? fix : nil)
    }
    /// A fixed command with nothing from outside in it; `with administrator privileges` is macOS's own password dialog.
    /// Only the prompt is translated, and a translation holding `"` or `\` must not end the AppleScript string early.
    static func script(for fix: SystemFix) -> String {
        switch fix {
        case .firewall:
            let prompt = String(localized: "Artifloam needs your password to turn on the firewall.").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return #"do shell script "/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on" with prompt ""# + prompt + #"" with administrator privileges"#
        }
    }
    /// osascript reports the person pressing Cancel as error -128.
    static func outcome(code: Int32, text: String) -> SystemFixResult { code == 0 ? .done : text.contains("-128") ? .cancelled : .failed }
    /// Runs on a person's click. The caller reads the setting again, so the page shows what is true and not what was asked for.
    public static func apply(_ fix: SystemFix) -> SystemFixResult {
        let result = run("/usr/bin/osascript", ["-e", script(for: fix)], timeout: 180)
        return outcome(code: result.code, text: text(result))
    }
    private static func preferences(_ path: String) -> [String: Any]? {
        BoundedFile.read(URL(fileURLWithPath: path)).flatMap { (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any] }
    }
    private static func text(_ result: CommandResult) -> String { result.output + result.error }
    /// What deleting means on this disk: whether FileVault encrypts what stays behind, and whether
    /// local Time Machine snapshots still hold deleted files (their space returns when the snapshots expire).
    public static func deletionFacts() -> (fileVault: Bool?, localSnapshots: Bool) {
        let snapshots = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 5).output
        return (fileVault(text(run("/usr/bin/fdesetup", ["status"], timeout: 5))), snapshots.contains("com.apple.TimeMachine."))
    }

    static func gatekeeper(_ text: String) -> Bool? { text.contains("assessments enabled") ? true : text.contains("assessments disabled") ? false : nil }
    static func fileVault(_ text: String) -> Bool? { text.contains("FileVault is On") ? true : text.contains("FileVault is Off") ? false : nil }
    static func firewall(_ text: String) -> Bool? { text.contains("State = 1") || text.contains("State = 2") ? true : text.contains("State = 0") ? false : nil }
    static func integrity(_ text: String) -> Bool? { text.contains("status: enabled") ? true : text.contains("status: disabled") ? false : nil }
    /// "screenLock delay is immediate", "... is 300 seconds" or "... is off". Longer than five minutes needs a look.
    static func screenLock(_ text: String) -> Bool? {
        if text.contains("delay is immediate") { return true }
        if text.contains("screenLock is off") || text.contains("delay is off") { return false }
        guard let range = text.range(of: "delay is "), let seconds = Int(text[range.upperBound...].prefix { $0.isNumber }) else { return nil }
        return seconds <= 300
    }
    /// launchctl finds a system service only while it is enabled, so "not found" means off.
    static func service(code: Int32, text: String) -> Bool? { code == 0 ? true : text.contains("Could not find service") ? false : nil }
    /// Names of processes listening beyond this Mac, from `lsof -Fcn`. Loopback listeners can't be reached from a network.
    static func networkListeners(lsof output: String) -> [String] {
        var names = Set<String>(), current = ""
        for line in output.split(separator: "\n") {
            if line.first == "c" { current = line.dropFirst().replacingOccurrences(of: "\\x20", with: " ") }
            else if line.first == "n" {
                let address = line.dropFirst()
                if !address.hasPrefix("127.") && !address.hasPrefix("[::1]") && !address.hasPrefix("localhost") { names.insert(current.displaySafe) }
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    static func updateChecks(_ preferences: [String: Any]?, now: Date = Date()) -> [SecurityCheck] {
        let panel = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
        let pending = preferences?["LastRecommendedUpdatesAvailable"] as? Int
        let checked = (preferences?["LastSuccessfulDate"] as? Date)?.formatted(.relative(presentation: .named, unitsStyle: .wide))
        let current: SecurityCheck
        if let pending {
            let detail: String
            if pending == 0 { detail = checked.map { String(localized: "No recommended updates are waiting. Last checked \($0).") } ?? String(localized: "No recommended updates are waiting.") }
            else { detail = checked.map { String(localized: "Updates often fix security problems, so install this when you can. Last checked \($0).") } ?? String(localized: "Updates often fix security problems, so install this when you can.") }
            current = SecurityCheck(id: "macos-updates", area: .updates, title: pending == 0 ? String(localized: "macOS is up to date") : String(localized: "\(pending) macOS updates are ready"),
                                    detail: detail, status: pending == 0 ? .good : .review, counts: true, settings: pending == 0 ? nil : panel, action: pending == 0 ? nil : String(localized: "See update"), nextStep: pending == 0 ? nil : String(localized: "Then click Update Now. Your Mac may restart."))
        } else { current = SecurityCheck(id: "macos-updates", area: .updates, title: String(localized: "macOS updates"), detail: unread, status: .unknown, counts: true) }
        // Apple's default is on, so only an explicit "off" counts as off.
        let automatic = preferences.map { values in ["AutomaticCheckEnabled", "CriticalUpdateInstall", "ConfigDataInstall"].allSatisfy { values[$0] as? Bool != false } }
        return [current, toggle("automatic-updates", .updates, String(localized: "Automatic security updates"), automatic, offTitle: String(localized: "Automatic security updates are off"), on: String(localized: "macOS checks for security fixes and installs them by itself."), off: String(localized: "Security fixes wait until you install them by hand."), settings: panel, action: String(localized: "Open Settings"), nextStep: String(localized: "Then click the (i) next to Automatic Updates and turn everything on."))]
    }
    static func backupCheck(destinations: String, latest: () -> String, now: Date = Date()) -> SecurityCheck {
        let panel = "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"
        if destinations.contains("No destinations") {
            return SecurityCheck(id: "backup", area: .backup, title: String(localized: "Time Machine isn't set up"), detail: String(localized: "A backup is what saves you if this Mac is lost or fails. Skip this if you back up another way."), status: .review, settings: panel, action: String(localized: "Set up", comment: "Button: open Time Machine settings to set up backups"), nextStep: String(localized: "Connect a drive, then click Add Backup Disk."))
        }
        guard destinations.contains("ID") else { return SecurityCheck(id: "backup", area: .backup, title: String(localized: "Time Machine"), detail: unread, status: .unknown) }
        let path = latest(), format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd-HHmmss"; format.locale = Locale(identifier: "en_US_POSIX")
        // Backups are folders named by date; macOS keeps them private without Full Disk Access.
        guard let found = path.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression), let date = format.date(from: String(path[found])) else {
            return SecurityCheck(id: "backup", area: .backup, title: String(localized: "Time Machine is set up"), detail: String(localized: "macOS didn't share the date of the last backup."), status: .info, settings: panel, action: String(localized: "Open Settings"))
        }
        let days = Int(now.timeIntervalSince(date) / 86400)
        let title = days < 1 ? String(localized: "Last backup was today") : days == 1 ? String(localized: "Last backup was yesterday") : String(localized: "Last backup was \(days) days ago")
        return days > 14 ? SecurityCheck(id: "backup", area: .backup, title: title, detail: String(localized: "Connect the backup drive so recent work is covered too."), status: .review, settings: panel, action: String(localized: "Open Settings"), nextStep: String(localized: "Then click Back Up Now."))
                         : SecurityCheck(id: "backup", area: .backup, title: title, detail: String(localized: "Time Machine is keeping recent copies of your files."), status: .good)
    }
    static func remoteCheck(_ id: String, _ title: String, _ value: Bool?, on: String, off: String, nextStep: String = String(localized: "If you don't use this, turn it off.")) -> SecurityCheck {
        SecurityCheck(id: id, area: .remote, title: title, detail: value.map { $0 ? on : off } ?? unread, status: value.map { $0 ? .review : .good } ?? .unknown,
                      settings: value == true ? "x-apple.systempreferences:com.apple.Sharing-Settings.extension" : nil, action: value == true ? String(localized: "Open Settings") : nil, nextStep: value == true ? nextStep : nil)
    }

    public static func checks() -> [SecurityCheck] {
        let security = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        let autoLoginFile = "/Library/Preferences/com.apple.loginwindow.plist"
        // No file means nothing was ever configured, so no automatic login; an unreadable one stays unknown.
        let loginPreferences = preferences(autoLoginFile)
        let noAutoLogin: Bool? = loginPreferences.map { $0["autoLoginUser"] == nil } ?? (FileManager.default.fileExists(atPath: autoLoginFile) ? nil : true)
        var found = [
            toggle("gatekeeper", .protection, String(localized: "Gatekeeper"), gatekeeper(text(run("/usr/sbin/spctl", ["--status"]))), offTitle: String(localized: "Apps aren't being checked before they open"), on: String(localized: "Apps must come from known developers before they open."), off: String(localized: "Any app can open, even from an unknown source."), settings: security + "?Security", action: String(localized: "Open Settings"), nextStep: String(localized: "Then choose App Store & Known Developers.")),
            toggle("filevault", .protection, String(localized: "FileVault"), fileVault(text(run("/usr/bin/fdesetup", ["status"]))), offTitle: String(localized: "Your disk isn't encrypted"), on: String(localized: "Your disk is encrypted. A lost Mac doesn't expose your files."), off: String(localized: "Anyone holding this Mac could read your files."), settings: security + "?FileVault", action: String(localized: "Open Settings"), nextStep: String(localized: "Then click Turn On. Keep the recovery key safe.")),
            toggle("firewall", .protection, String(localized: "Firewall"), firewall(text(run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]))), offTitle: String(localized: "Your firewall is off"), on: String(localized: "Unwanted connections from other devices are blocked."), off: String(localized: "Other devices on your network can try to reach your apps. Turning it on matters most on public Wi-Fi."), action: String(localized: "Turn on", comment: "Button: turn on the firewall"), nextStep: String(localized: "macOS asks for your password, and that's it."), fix: .firewall),
            // macOS only allows this from Recovery, so there is no button; anyone who turned it off knows how to turn it on.
            toggle("integrity", .protection, String(localized: "System Integrity Protection"), integrity(text(run("/usr/bin/csrutil", ["status"]))), offTitle: String(localized: "macOS isn't protecting its own files"), on: String(localized: "macOS protects its own files, even from admin apps."), off: String(localized: "System Integrity Protection is off. This is usually done on purpose by developers; it can only be turned on again from Recovery.")),
            toggle("screen-lock", .protection, String(localized: "Password after sleep"), screenLock(text(run("/usr/sbin/sysadminctl", ["-screenLock", "status"]))), offTitle: String(localized: "Your Mac doesn't lock quickly"), on: String(localized: "Your Mac asks for a password soon after it sleeps."), off: String(localized: "Someone could use it for a while after it goes to sleep."), settings: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension", action: String(localized: "Open Settings"), nextStep: String(localized: "Then set Require password to Immediately.")),
            toggle("auto-login", .protection, String(localized: "Password at startup"), noAutoLogin, offTitle: String(localized: "Your Mac signs in by itself"), on: String(localized: "Nobody gets in by just turning this Mac on."), off: String(localized: "Anyone who turns it on reaches your files."), settings: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension", action: String(localized: "Open Settings"), nextStep: String(localized: "Then set Automatically log in as to Off."))
        ]
        found += updateChecks(preferences("/Library/Preferences/com.apple.SoftwareUpdate.plist"))
        for (id, title, label, on, off, step) in [
            ("remote-login", String(localized: "Remote Login (SSH)"), "com.openssh.sshd", String(localized: "Other computers can sign in to this Mac with a password or key."), String(localized: "No one can sign in to this Mac from another computer."), String(localized: "If you don't use this, turn Remote Login (SSH) off.")),
            ("screen-sharing", String(localized: "Screen Sharing"), "com.apple.screensharing", String(localized: "Other computers can see and control this screen."), String(localized: "Your screen can't be viewed or controlled remotely."), String(localized: "If you don't use this, turn Screen Sharing off.")),
            ("file-sharing", String(localized: "File Sharing"), "com.apple.smbd", String(localized: "Other computers can open your shared folders."), String(localized: "Your folders aren't shared on the network."), String(localized: "If you don't use this, turn File Sharing off."))
        ] {
            let result = run("/bin/launchctl", ["print", "system/" + label], timeout: 5)
            found.append(remoteCheck(id, title, service(code: result.code, text: text(result)), on: on, off: off, nextStep: step))
        }
        // lsof also exits 1 when nothing listens; output is what counts. Without admin rights it sees only this account's apps.
        let listeners = networkListeners(lsof: run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fcn"]).output)
        found.append(SecurityCheck(id: "listeners", area: .remote, title: listeners.isEmpty ? String(localized: "None of your apps accept connections") : String(localized: "\(listeners.count) of your apps accept connections"), detail: listeners.isEmpty ? String(localized: "No app in your account is waiting for connections from other devices.") : String(localized: "\(listeners.joined(separator: ", ")). Many apps do this to sync or to find nearby devices."), status: .info))
        found.append(backupCheck(destinations: text(run("/usr/bin/tmutil", ["destinationinfo"], timeout: 8)), latest: { run("/usr/bin/tmutil", ["latestbackup"], timeout: 8).output }))
        return found
    }
}

/// An app Gatekeeper wouldn't simply accept. Not a malware verdict: the page says what was found and leaves the decision to the person.
public struct AppTrustFinding: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable {
        case notNotarized, modified, revoked, unsigned, unverified
        public var title: String {
            switch self {
            case .notNotarized: return String(localized: "Not notarized by Apple")
            case .modified: return String(localized: "Changed since it was signed")
            case .revoked: return String(localized: "Developer certificate revoked")
            case .unsigned: return String(localized: "Not signed")
            case .unverified: return String(localized: "Couldn't be verified")
            }
        }
        public var detail: String {
            switch self {
            case .notNotarized: return String(localized: "Apple hasn't checked this version. Common for small developers and open-source apps.")
            case .modified: return String(localized: "Files inside differ from what the developer signed. Often a plugin or an update; reinstall if you didn't expect it.")
            case .revoked: return String(localized: "Apple or the developer withdrew the certificate that signed this copy. Get the latest version from the developer.")
            case .unsigned: return String(localized: "Nothing says who made this app. Keep it only if you trust where it came from.")
            case .unverified: return String(localized: "Gatekeeper gave an answer Artifloam doesn't recognize.")
            }
        }
    }
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let kind: Kind
}
public enum AppTrust {
    /// spctl's own words, so each reason can be explained. nil: accepted.
    static func classify(code: Int32, text: String) -> AppTrustFinding.Kind? {
        guard code != 0 else { return nil }
        let text = text.lowercased() // `--verbose` says "source=No Usable Signature".
        if text.contains("revoked") { return .revoked }
        if text.contains("not signed") || text.contains("no usable signature") { return .unsigned }
        if text.contains("sealed resource") || text.contains("no resources but signature") || text.contains("invalid signature") { return .modified }
        if text.contains("rejected") { return .notNotarized }
        return .unverified
    }
    /// spctl per app takes about a second and may ask Apple, as opening an app does, so this runs apart from the page. Apple's own apps are skipped.
    public static func audit(folders: [URL] = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]) -> (checked: Int, findings: [AppTrustFinding]) {
        let apps = folders.flatMap(children).filter { $0.pathExtension == "app" && !AppleCode.signedByApple($0) }
        let lock = NSLock()
        var findings = [AppTrustFinding]()
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let result = run("/usr/sbin/spctl", ["--assess", "--verbose", "--type", "execute", apps[index].path], timeout: 20)
            // The path is left out: an app must not choose its verdict with its own name.
            guard result.code != 124, var kind = classify(code: result.code, text: (result.output + result.error).replacingOccurrences(of: apps[index].path, with: "")) else { return }
            // spctl says only "rejected" for an ad-hoc app, which must not read as a small developer's missing notarization.
            if kind == .notNotarized, !AppleCode.hasDeveloper(apps[index]) { kind = .unsigned }
            lock.lock(); findings.append(AppTrustFinding(url: apps[index], name: apps[index].deletingPathExtension().lastPathComponent.displaySafe, kind: kind)); lock.unlock()
        }
        return (apps.count, findings.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }
}
