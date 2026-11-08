import BackgroundTasks
import Foundation

/// Lets work the person started keep going after they leave the app. On iOS 26 and later, iOS shows its progress
/// on the Lock Screen and can stop it there. Earlier iOS pauses the app soon after it leaves, so the work asks to stay open.
@MainActor final class BackgroundWork {
    static let shared = BackgroundWork()
    /// Matches `com.vasquezgroup.artifloam.iphone.work.*` in Info.plist.
    private static let prefix = "com.vasquezgroup.artifloam.iphone.work."

    private var running = false
    private var task: AnyObject?
    private var stop: (() -> Void)?
    private var fraction = 0.0
    private var title = ""
    private var subtitle = ""

    /// Returns true when iOS agreed to let it carry on in the background, so the person can switch apps.
    func begin(title: String, subtitle: String, stop: @escaping () -> Void) -> Bool {
        running = true
        self.stop = stop
        self.title = title
        self.subtitle = subtitle
        fraction = 0
        guard #available(iOS 26, *) else { return false }
        // A new identifier each time: a handler can only be registered once per identifier.
        let identifier = Self.prefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { BackgroundWork.shared.started(task) }
        }
        guard registered else { return false }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // Now or not at all: a queued task could start after the work is over.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }

    func update(_ fraction: Double, subtitle: String) {
        self.fraction = fraction
        self.subtitle = subtitle
        guard #available(iOS 26, *), let task = task as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = Int64(min(1, max(0, fraction)) * 1000)
        if task.subtitle != subtitle { task.updateTitle(title, subtitle: subtitle) }
    }

    func end(success: Bool) {
        running = false
        stop = nil
        if #available(iOS 26, *), let task = task as? BGContinuedProcessingTask { task.setTaskCompleted(success: success) }
        task = nil
    }

    @available(iOS 26, *)
    private func started(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else { return }
        // Finished before iOS got round to starting it.
        guard running else { task.setTaskCompleted(success: true); return }
        self.task = task
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(fraction * 1000)
        task.updateTitle(title, subtitle: subtitle)
        // Stop on the Lock Screen, or iOS needing the room back: the same as the app's own Stop.
        task.expirationHandler = { Task { @MainActor in BackgroundWork.shared.stop?() } }
    }
}
