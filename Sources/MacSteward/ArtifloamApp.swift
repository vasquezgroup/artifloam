import SwiftUI
import AppKit
import Carbon.HIToolbox
import Combine
import MacStewardCore
import UserNotifications

@main
@MainActor
struct MacStewardApp {
    static func main() {
        let app = NSApplication.shared
        let lock = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacSteward/main-window.lock")
        let lease: AppInstanceLease
        do {
            guard let acquired = try AppInstanceLease(at: lock) else {
                let peers = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && ($0.bundleIdentifier == Bundle.main.bundleIdentifier || $0.bundleIdentifier == StewardPreferences.legacyDomain) }
                if let existing = peers.first {
                    existing.activate(options: [.activateAllWindows])
                    if let url = existing.bundleURL {
                        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true; configuration.createsNewApplicationInstance = false
                        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                    }
                }
                return
            }
            lease = acquired
        } catch {
            let alert = NSAlert(); alert.messageText = String(localized: "Artifloam could not open its window")
            alert.informativeText = String(localized: "The single-window lock could not be opened. \(error.localizedDescription)")
            alert.runModal(); return
        }
        // Before anything reads the schedule: a schedule from an older version moves to the new label.
        if Bundle.main.bundleIdentifier == StewardPreferences.domain, Scheduler.retireLegacy() {
            try? Scheduler.enable(helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/stewardctl"))
        }
        let delegate = StewardApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime((delegate, lease)) { app.run() }
    }
}

/// The same colours as MacDashboardView's background.
private final class DashboardFrameTint: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let gradient = CAGradientLayer()
        gradient.colors = [NSColor(red: 0.19, green: 0.075, blue: 0.34, alpha: 1).cgColor, NSColor(red: 0.055, green: 0.04, blue: 0.12, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 1); gradient.endPoint = CGPoint(x: 1, y: 0)
        layer = gradient; wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
}

/// Create the transparent window before attaching SwiftUI. Changing a SwiftUI
/// scene's frame style afterwards can detach its hosting view on newer macOS.
@MainActor
final class StewardApplicationDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private let model = StewardModel()
    private let activity = StewardWindowActivity()
    private var dashboard: MacDashboardMonitor { model.dashboard }
    private var window: NSWindow?
    private var textShortcutMonitor: Any?
    private var memoryStatusItem: NSStatusItem?
    private let memoryPopover = NSPopover()
    private let memoryDetailsPopover = NSPopover()
    /// Clicks in other apps and on the desktop never reach our run loop, so `.transient` alone misses them.
    private var outsideClickMonitors = [Any]()
    private var healthWatch: AnyCancellable?
    private var hotKey: EventHotKeyRef?
    private let attentionDot = NSView()
    private var memoryPopoverClosedAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        installMemoryMenu()
        installHotKey()
        // Notifications need a real app bundle; `swift run` builds have none.
        if Bundle.main.bundleURL.pathExtension == "app" { UNUserNotificationCenter.current().delegate = self }
        model.health.start()
        healthWatch = model.health.$health.sink { [weak self] health in self?.attentionDot.isHidden = health?.issues.isEmpty ?? true }
        textShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command), !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control) else { return event }
            let character = event.charactersIgnoringModifiers ?? ""
            let direction: Int? = character == "=" || character == "+" || event.keyCode == 24 ? 1 : character == "-" || event.keyCode == 27 ? -1 : character == "0" ? 0 : nil
            guard let direction else { return event }
            if direction == 0 { self?.model.setTextScale(1) }
            else { self?.model.changeTextScale(Double(direction) * 0.15) }
            return nil
        }
        showWindow()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        completionHandler()
        guard identifier == SpaceKeeperRunner.reviewNotification else { return }
        Task { @MainActor in showWindow(); model.reviewLowSpace() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }
    func applicationDidBecomeActive(_ notification: Notification) { updatePhase() }
    func applicationDidResignActive(_ notification: Notification) { updatePhase() }
    /// Artwork loops and timelines run only while `.active`: they also stop while the window cannot be seen
    /// (minimised, fully covered or on another Space) even though Artifloam is still the frontmost app.
    @objc private func updatePhase() {
        activity.phase = window?.occlusionState.contains(.visible) == false ? .background : NSApp.isActive ? .active : .inactive
    }
    @objc private func showWindow() {
        if window == nil {
            let view = StewardRootView(activity: activity).environmentObject(model)
                .frame(minWidth: 840, minHeight: 600).preferredColorScheme(.dark).environment(\.layoutDirection, appLayoutDirection)
            let window = StewardGlassWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 678),
                                  styleMask: [.titled, .fullSizeContentView, .resizable, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Artifloam"
            window.identifier = NSUserInterfaceItemIdentifier("ArtifloamMainWindow")
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovableByWindowBackground = true
            window.collectionBehavior = [.fullScreenPrimary]
            window.contentMinSize = NSSize(width: 840, height: 600)
            window.contentView = StewardHostingView(rootView: view)
            let restored = window.setFrameUsingName("MacStewardGlassWindow")
            window.setFrameAutosaveName("MacStewardGlassWindow")
            let preferences = StewardPreferences.defaults
            let migrate = !preferences.bool(forKey: "wideWindowDefaultV1")
            if !restored { window.center() }
            if let screen = window.screen ?? NSScreen.main {
                window.setFrame(WindowGeometry.fitted(window.frame, visible: screen.visibleFrame,
                    size: migrate ? WindowGeometry.preferredSize : nil), display: false)
            }
            preferences.set(true, forKey: "wideWindowDefaultV1")
            window.saveFrame(usingName: "MacStewardGlassWindow")
            // The first launch happens in the middle of the screen, wherever a window was last.
            if model.welcoming, let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
            }
            self.window = window
            NotificationCenter.default.addObserver(self, selector: #selector(updatePhase), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func settings() { model.section = "Settings"; showWindow() }
    /// The same scan as the Overview orb: on Overview, where its results appear, and through the Full Disk Access gate.
    @objc private func scan() {
        guard !model.scanning else { return }
        model.section = "Overview"; showWindow()
        model.withFullDisk { [model] in model.scan(allTools: true) }
    }
    @objc private func checkForUpdates() { Task { await model.updates.check(reportResult: true) } }
    @objc private func uninstall() { showWindow(); model.requestUninstall() }
    @objc private func biggerText() { model.changeTextScale(0.15) }
    @objc private func smallerText() { model.changeTextScale(-0.15) }
    @objc private func resetText() { model.setTextScale(1) }

    private func installMemoryMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let symbol = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: String(localized: "Artifloam Mac dashboard"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        symbol?.isTemplate = true
        item.button?.image = symbol
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.toolTip = String(localized: "Artifloam · Mac dashboard")
        item.button?.target = self
        item.button?.action = #selector(toggleMemoryMenu(_:))
        memoryStatusItem = item
        // An amber dot on the leaf while something needs attention.
        if let button = item.button {
            attentionDot.wantsLayer = true
            attentionDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            attentionDot.layer?.cornerRadius = 3.5
            attentionDot.frame = NSRect(x: button.bounds.maxX - 9, y: button.isFlipped ? 2 : button.bounds.maxY - 9, width: 7, height: 7)
            attentionDot.autoresizingMask = [.minXMargin, button.isFlipped ? .maxYMargin : .minYMargin]
            attentionDot.isHidden = true
            button.addSubview(attentionDot)
        }
        memoryPopover.appearance = NSAppearance(named: .darkAqua)
        // Transient: clicks anywhere in Artifloam outside the dashboard (main window included) close it.
        memoryPopover.behavior = .transient
        memoryPopover.contentSize = NSSize(width: 460, height: 700)
        memoryPopover.delegate = self
    }
    func popoverDidClose(_ notification: Notification) {
        if notification.object as? NSPopover === memoryPopover {
            memoryPopoverClosedAt = Date()
            outsideClickMonitors.forEach(NSEvent.removeMonitor); outsideClickMonitors = []
            memoryDetailsPopover.performClose(nil)
            memoryPopover.contentViewController = nil
        } else { memoryDetailsPopover.contentViewController = nil; dashboard.detail = nil }
    }
    private func showDetails(_ kind: DashboardDetail) {
        guard let anchor = memoryPopover.contentViewController?.view, anchor.window != nil else { return }
        // Clicking the open card again closes it; another card replaces the flyout without animation.
        if memoryDetailsPopover.isShown {
            let same = dashboard.detail == kind
            memoryDetailsPopover.animates = same
            memoryDetailsPopover.close()
            memoryDetailsPopover.animates = true
            if same { return }
        }
        dashboard.detail = kind
        let content = NSHostingController(rootView: DashboardDetailView(kind: kind, dashboard: dashboard, memory: model.memory, health: model.health, openWindow: { [weak self] section in
            self?.memoryDetailsPopover.performClose(nil)
            self?.memoryPopover.performClose(nil)
            self?.model.section = section; self?.showWindow()
        }).preferredColorScheme(.dark).environment(\.layoutDirection, appLayoutDirection))
        // Closed by the dashboard (same card again, or the dashboard itself closing), never by its own
        // outside-click rule: that would close it on the very click that should switch cards.
        memoryDetailsPopover.behavior = .applicationDefined
        memoryDetailsPopover.appearance = NSAppearance(named: .darkAqua)
        memoryDetailsPopover.delegate = self
        memoryDetailsPopover.contentSize = NSSize(width: 460, height: 700)
        memoryDetailsPopover.contentViewController = content
        // Center beside the whole dashboard so details do not cover its cards.
        let positioningView = anchor.window?.contentView ?? anchor
        memoryDetailsPopover.show(relativeTo: positioningView.bounds, of: positioningView, preferredEdge: .minX)
        memoryDetailsPopover.contentViewController?.view.window?.appearance = NSAppearance(named: .darkAqua)
    }
    func openMemoryMonitor() { toggleMemoryMenu(nil) }
    @objc private func toggleMemoryMenu(_ sender: Any?) {
        if memoryPopover.isShown { memoryPopover.performClose(nil) }
        // The status-button mouse-down already closed the transient popover; don't reopen it on mouse-up.
        else if sender is NSStatusBarButton, Date().timeIntervalSince(memoryPopoverClosedAt) < 0.3 { return }
        else if let button = memoryStatusItem?.button {
            memoryPopover.contentViewController = NSHostingController(rootView:
                MacDashboardView(monitor: dashboard, memory: model.memory, health: model.health, openWindow: { [weak self] section in
                    self?.memoryPopover.performClose(nil); self?.model.section = section; self?.showWindow()
                }, openDetail: { [weak self] kind in self?.showDetails(kind) }).environment(\.layoutDirection, appLayoutDirection)
            )
            if sender is NSStatusBarButton {
                memoryPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            } else {
                showWindow()
                if let content = window?.contentView {
                    let y = content.isFlipped ? CGFloat(56) : content.bounds.maxY - 56
                    memoryPopover.show(relativeTo: NSRect(x: content.bounds.maxX - 50, y: y, width: 1, height: 1), of: content, preferredEdge: .minY)
                }
            }
            // The native arrow belongs to the popover window, not its SwiftUI content.
            memoryPopover.contentViewController?.view.window?.appearance = NSAppearance(named: .darkAqua)
            paintPopoverFrame()
            memoryPopover.contentViewController?.view.window?.makeKey()
            // The dashboard refuses to close while its flyout is attached, so close the flyout first.
            let close: () -> Void = { [weak self] in self?.memoryDetailsPopover.close(); self?.memoryPopover.performClose(nil) }
            let popoverWindows: () -> [NSWindow?] = { [weak self] in [self?.memoryPopover.contentViewController?.view.window, self?.memoryDetailsPopover.contentViewController?.view.window] }
            // Other apps and the desktop: never delivered to us, so watch globally.
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { _ in Task { @MainActor in close() } }) { outsideClickMonitors.append(global) }
            // Our own windows: `.transient` stops working while the flyout (a child popover) is open.
            if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { event in
                if event.window is NSPanel || popoverWindows().contains(where: { $0 === event.window }) || event.window?.className.contains("StatusBar") == true { return event }
                close(); return event
            }) { outsideClickMonitors.append(local) }
        }
    }

    /// The arrow and rim are drawn by the popover's own frame, outside the SwiftUI content, so they get the dashboard's gradient here.
    /// the frame is the content view's private superview; if macOS changes it, the arrow simply keeps the system colour.
    private func paintPopoverFrame() {
        guard let frame = memoryPopover.contentViewController?.view.window?.contentView?.superview else { return }
        frame.subviews.filter { $0 is DashboardFrameTint }.forEach { $0.removeFromSuperview() }
        let tint = DashboardFrameTint(frame: frame.bounds)
        tint.autoresizingMask = [.width, .height]
        frame.addSubview(tint, positioned: .below, relativeTo: frame.subviews.first)
    }

    /// ⌃⌥L opens the dashboard from anywhere. Carbon hot keys need no Accessibility permission.
    private func installHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let delegate = Unmanaged<StewardApplicationDelegate>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { delegate.toggleMemoryMenu(delegate.memoryStatusItem?.button) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey), EventHotKeyID(signature: OSType(0x4152_5446), id: 1), GetApplicationEventTarget(), 0, &hotKey)
    }

    private func installMenus() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            menu.addItem(item)
            return submenu
        }
        let application = submenu("Artifloam")
        application.addItem(withTitle: String(localized: "About Artifloam"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updates = application.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        let settings = application.addItem(withTitle: String(localized: "Settings…"), action: #selector(self.settings), keyEquivalent: ",")
        settings.target = self
        let uninstall = application.addItem(withTitle: String(localized: "Uninstall Artifloam…"), action: #selector(self.uninstall), keyEquivalent: "")
        uninstall.target = self
        application.addItem(.separator())
        application.addItem(withTitle: String(localized: "Hide Artifloam"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        application.addItem(withTitle: String(localized: "Quit Artifloam"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = submenu(String(localized: "File"))
        let open = file.addItem(withTitle: String(localized: "Show Artifloam"), action: #selector(showWindow), keyEquivalent: "n")
        open.target = self
        let scan = file.addItem(withTitle: String(localized: "Scan Mac"), action: #selector(self.scan), keyEquivalent: "r")
        scan.target = self
        file.addItem(withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = submenu(String(localized: "Edit"))
        for (title, action, key) in [(String(localized: "Undo"), "undo:", "z"), (String(localized: "Cut"), "cut:", "x"), (String(localized: "Copy"), "copy:", "c"), (String(localized: "Paste"), "paste:", "v"), (String(localized: "Select All"), "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let view = submenu(String(localized: "View"))
        for (title, action, key) in [(String(localized: "Bigger Text"), #selector(biggerText), "="), (String(localized: "Smaller Text"), #selector(smallerText), "-"), (String(localized: "Actual Text Size"), #selector(resetText), "0")] {
            let item = view.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        let memoryMenu = view.addItem(withTitle: String(localized: "Mac Dashboard"), action: #selector(toggleMemoryMenu(_:)), keyEquivalent: "m")
        memoryMenu.target = self; memoryMenu.keyEquivalentModifierMask = [.command, .shift]
        let equal = view.addItem(withTitle: String(localized: "Bigger Text"), action: #selector(biggerText), keyEquivalent: "+")
        equal.target = self; equal.isHidden = true; equal.allowsKeyEquivalentWhenHidden = true
        let windows = submenu(String(localized: "Window"))
        windows.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windows
        NSApp.mainMenu = menu
    }
}

@MainActor
private final class StewardHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}
@MainActor
private final class StewardGlassWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
@MainActor
private final class StewardWindowActivity: ObservableObject {
    @Published var phase: ScenePhase = .active
}
private struct StewardRootView: View {
    @ObservedObject var activity: StewardWindowActivity
    @EnvironmentObject private var model: StewardModel
    var body: some View {
        MainView().ignoresSafeArea(.container, edges: .top).stewardFont(.body)
            .environment(\.stewardTextScale, model.textScale)
            .environment(\.scenePhase, activity.phase)
    }
}
