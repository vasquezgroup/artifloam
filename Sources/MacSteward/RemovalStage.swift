import SwiftUI
import AppKit
import os
import MacStewardCore

/// The words a stage uses: deleting reviewed items, emptying the Trash, browser data and worktrees each have their own.
struct StageCopy: Equatable {
    let working: String
    let done: String
    /// Under the byte counter: "freed", "memory freed"…
    let amount: String
    /// Shown after the result, e.g. how to undo.
    let note: String?
    /// What is counted: files and folders, or apps being quit.
    enum Unit: Equatable { case items, apps }
    var unit = Unit.items
    // Computed so the words follow the app language each time a stage starts.
    static var trash: StageCopy { StageCopy(working: String(localized: "Deleting…"), done: String(localized: "Cleanup complete"), amount: String(localized: "freed", comment: "Under a byte counter: how much space was freed"), note: nil) }
    static var emptyTrash: StageCopy { StageCopy(working: String(localized: "Emptying the Trash…"), done: String(localized: "Trash emptied"), amount: String(localized: "freed", comment: "Under a byte counter: how much space was freed"), note: nil) }
    static var browsers: StageCopy { StageCopy(working: String(localized: "Cleaning browser data…"), done: String(localized: "Browser data cleaned"), amount: String(localized: "freed", comment: "Under a byte counter: how much space was freed"), note: String(localized: "Browsers rebuild caches as you browse.")) }
    static var quitApps: StageCopy { StageCopy(working: String(localized: "Quitting idle apps…"), done: String(localized: "Idle apps quit"), amount: String(localized: "memory freed", comment: "Under a byte counter: memory freed by quitting apps"), note: nil, unit: .apps) }
    static var worktrees: StageCopy { StageCopy(working: String(localized: "Deleting finished worktrees…"), done: String(localized: "Worktrees deleted"), amount: String(localized: "freed", comment: "Under a byte counter: how much space was freed"), note: String(localized: "Restore a branch with git branch <name> <commit>.")) }
}

/// Live state of a stage run, shown by `RemovalStage` in place of the page.
struct RemovalProgress: Equatable {
    let copy: StageCopy
    let total: Int
    /// One operation without per-item updates: the bar animates and the totals appear at the end.
    var indeterminate = false
    var stoppable = true
    var completed = 0
    var bytes: UInt64 = 0
    var current = ""
    var finished = false
    var stopped = false
    var failures = [String]()
}

/// What a stage's work returns.
struct StageOutcome: Sendable {
    var completed: Int
    var bytes: UInt64
    var failures: [String]
}

/// The macOS system sounds Artifloam plays. Silent when "Play user interface sound effects" is off.
enum StewardSound {
    case start, done
    func play() {
        guard UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true else { return }
        // The first sound of a session can wake the audio hardware; that must not hold up the window.
        let name = self == .start ? "Pop" : "Glass"
        DispatchQueue.global(qos: .userInitiated).async { NSSound(named: name)?.play() }
    }
}

/// Shared between the main thread (Stop) and the background move.
final class StopFlag: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { lock.withLock { $0 } }
    func set() { lock.withLock { $0 = true } }
}

extension StewardModel {
    /// Runs destructive work in the background on the stage: sidebar hidden, artwork moving, live counters, then a result.
    /// `work` reports (items done, bytes so far, current item) and should check the stop flag between items.
    func runStage(_ copy: StageCopy, total: Int, first: String = "", indeterminate: Bool = false, stoppable: Bool = true,
                  work: @escaping @Sendable (_ report: @escaping @Sendable (Int, UInt64, String) -> Void, _ stop: StopFlag) async -> StageOutcome,
                  completed: @escaping (StageOutcome) -> Void) {
        guard removal == nil else { return }
        let stop = StopFlag(); removalStop = stop
        removal = RemovalProgress(copy: copy, total: max(1, total), indeterminate: indeterminate, stoppable: stoppable, current: first)
        StewardSound.start.play()
        let step = max(1, total / 25)
        let report: @Sendable (Int, UInt64, String) -> Void = { [weak self] done, bytes, current in
            // about 25 updates per run, not one per item, so thousands of files don't flood the main thread.
            guard done == total || done % step == 0 else { return }
            Task { @MainActor [weak self] in self?.removal?.completed = done; self?.removal?.bytes = bytes; self?.removal?.current = current }
        }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { await work(report, stop) }.value
            var final = removal ?? RemovalProgress(copy: copy, total: max(1, total))
            final.completed = outcome.completed; final.bytes = outcome.bytes; final.failures = outcome.failures
            final.stopped = stop.isSet; final.finished = true
            removal = final
            disk = .read()
            StewardSound.done.play()
            completed(outcome)
        }
    }
    /// Deletes reviewed items for good on the stage.
    func startRemoval(_ candidates: [TrashCandidate], allowApplications: Bool, allowLeftovers: Bool, duplicateGroups: [DuplicateGroup] = [], completed: @escaping ([TrashOutcome]) -> Void) {
        guard !candidates.isEmpty else { return }
        let box = OutcomeBox()
        runStage(.trash, total: candidates.count, first: candidates[0].url.lastPathComponent, work: { report, stop in
            let moved = OSAllocatedUnfairLock(initialState: UInt64(0))
            let results = ReviewedTrash.move(candidates, allowApplications: allowApplications, allowLeftovers: allowLeftovers, duplicateGroups: duplicateGroups,
                                             progress: { done, bytes, current in moved.withLock { $0 = bytes }; report(done, bytes, current) }, shouldStop: { stop.isSet })
            box.set(results)
            return StageOutcome(completed: results.count, bytes: moved.withLock { $0 }, failures: results.compactMap { outcome in outcome.error.map { String(localized: "\(URL(fileURLWithPath: outcome.path).lastPathComponent) · \($0)") } })
        }, completed: { _ in completed(box.value) })
    }
    /// Quits the idle apps Performance suggests, on the stage: every app is asked at once, then each one counts as it goes.
    /// Nothing is forced. An app asking to save stays open and is listed, so the person can answer it.
    func quitIdleAppsOnStage() {
        guard removal == nil, !busy, !scanning, cleaning == nil, let reading = memory.reading else { return }
        let apps = MemoryVerdict.suggestions(reading.apps, recentlyUsed: memory.recentlyUsed, canQuit: memory.canQuit)
        guard !apps.isEmpty else { memory.message = String(localized: "No idle apps"); return }
        let memory = memory
        runStage(.quitApps, total: apps.count, first: apps.map(\.app.name.displaySafe).joined(separator: ", "), stoppable: false, work: { report, _ in
            let asked = await MainActor.run { apps.filter { memory.quit($0) } }
            var gone = [MemoryAppUsage]()
            // Up to 10 s: most apps are gone in one. Waiting longer would only hold the stage for one asking to save.
            for _ in 0..<40 {
                let still = await MainActor.run { asked.filter { NSRunningApplication(processIdentifier: $0.id) != nil } }
                gone = asked.filter { app in !still.contains { $0.id == app.id } }
                report(gone.count, gone.reduce(0) { $0 + $1.bytes }, still.map(\.app.name.displaySafe).joined(separator: ", "))
                if still.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            await memory.refresh()
            let open = apps.filter { app in !gone.contains { $0.id == app.id } }
            return StageOutcome(completed: apps.count, bytes: gone.reduce(0) { $0 + $1.bytes },
                                failures: open.map { String(localized: "\($0.app.name.displaySafe) is still open. It may be asking you to save.") })
        }, completed: { _ in })
    }
    func stopRemoval() { removalStop?.set() }
    func finishRemoval() {
        if removal?.stopped == true { removalQueue = [] } // Stop means stop, including what was queued after this.
        removal = nil; removalStop = nil; runNextRemoval()
    }
    /// Remove selected can span several removers, each with its own stage: Done on one starts the next.
    func runNextRemoval() { if !removalQueue.isEmpty { removalQueue.removeFirst()() } }
}

/// Hands the Trash results from the background run back to the caller.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock(); private var results = [TrashOutcome]()
    var value: [TrashOutcome] { lock.lock(); defer { lock.unlock() }; return results }
    func set(_ new: [TrashOutcome]) { lock.lock(); results = new; lock.unlock() }
}

/// A move to the Trash, staged like a scan: the page's artwork centred and moving, the sidebar hidden,
/// a live byte counter while files move, then a bouncy "complete" state with Done.
struct RemovalStage: View {
    let progress: RemovalProgress
    let stop: () -> Void
    let done: () -> Void
    @Environment(\.stewardTheme) private var theme
    @Environment(\.stewardTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false
    @State private var showingDetails = false
    private var fraction: Double { Double(progress.completed) / Double(max(1, progress.total)) }
    var body: some View {
        GeometryReader { geometry in
            // Same sizing as the scan stage, so the artwork sits in the same place.
            let hero = max(120, min(330, geometry.size.height * 0.62, geometry.size.height - 260 * textScale))
            ScrollView {
                VStack(spacing: 12) {
                    ScanMovieArtwork(animated: !progress.finished, asset: "sculpture-motion-" + theme.rawValue)
                        .frame(width: hero, height: hero)
                        .shadow(color: theme.accent.opacity(0.18), radius: 32, y: 10)
                        .scaleEffect(progress.finished && settled && !reduceMotion ? 1.12 : 1)
                        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.5), value: settled)
                    Text(progress.finished ? (progress.stopped ? String(localized: "Stopped", comment: "Title: the operation was stopped") : progress.copy.done) : progress.copy.working)
                        .stewardFont(.title).multilineTextAlignment(.center).contentTransition(.opacity)
                    Text(progress.finished ? summary : progress.current).stewardFont(.body).foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center).frame(maxWidth: 620).contentTransition(.opacity)
                    HStack(spacing: 30) {
                        if !(progress.indeterminate && !progress.finished) {
                            metric(formattedBytes(progress.bytes), progress.finished ? progress.copy.amount : String(localized: "so far", comment: "Under a byte counter: amount handled until now"), tint: theme.accent)
                            metric(progress.indeterminate ? progress.completed.formatted() : String(localized: "\(progress.completed) of \(progress.total)"), progress.copy.unit == .apps ? String(localized: "apps", comment: "Label under a count of apps") : String(localized: "items", comment: "Label under a count of items"))
                        }
                        if !progress.failures.isEmpty { metric(progress.failures.count.formatted(), progress.copy.unit == .apps ? String(localized: "still open", comment: "Label under a count of apps that did not quit") : String(localized: "not moved", comment: "Label under a count of items that could not be moved"), tint: .orange) }
                    }.padding(.top, 4)
                    if !progress.finished {
                        if progress.indeterminate { ProgressView().progressViewStyle(.linear).tint(theme.accent).frame(maxWidth: 360) }
                        else { ProgressView(value: fraction).tint(theme.accent).frame(maxWidth: 360).animation(.easeOut(duration: 0.25), value: fraction) }
                    }
                    if showingDetails && !progress.failures.isEmpty {
                        ScrollView { LazyVStack(alignment: .leading, spacing: 4) { ForEach(progress.failures, id: \.self) { Text($0).stewardFont(.caption).foregroundStyle(.orange) } } }
                            .frame(maxWidth: 560, maxHeight: 110)
                    }
                    HStack(spacing: 12) {
                        if progress.finished {
                            if !progress.failures.isEmpty {
                                Button(showingDetails ? String(localized: "Hide details") : progress.copy.unit == .apps ? String(localized: "Show \(progress.failures.count) still open") : String(localized: "Show \(progress.failures.count) not moved")) { showingDetails.toggle() }
                                    .buttonStyle(CleanupGlassButtonStyle(secondary: true))
                            }
                            Button("Done", action: done).buttonStyle(CleanupGlassButtonStyle()).keyboardShortcut(.defaultAction)
                        } else if progress.stoppable {
                            Button(action: stop) { Label("Stop", systemImage: "stop.fill") }.buttonStyle(CleanupGlassButtonStyle(secondary: true))
                        }
                    }.stewardFont(.body, weight: .semibold).padding(.top, 10)
                }.padding(.horizontal, 45).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }.scrollIndicators(.hidden)
        }
        .onChange(of: progress.finished) { _, finished in if finished { settled = true } }
        .onAppear { if progress.finished { settled = true } }
    }
    private func metric(_ value: String, _ label: String, tint: Color = .white) -> some View {
        VStack(spacing: 3) {
            Text(value).stewardFont(.title3, weight: .semibold).monospacedDigit().foregroundStyle(tint).contentTransition(.numericText())
            Text(label).stewardFont(.caption).foregroundStyle(.white.opacity(0.55))
        }
    }
    private var summary: String {
        let moved = progress.completed - progress.failures.count
        let count = progress.copy.unit == .apps ? String(localized: "\(moved) apps quit.") : progress.stopped ? String(localized: "\(moved) items before you stopped.") : String(localized: "\(moved) items.")
        return count + (progress.copy.note.map { " " + $0 } ?? "")
    }
}
