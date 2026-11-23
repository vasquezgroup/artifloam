import Foundation

/// Lets the person skip a folder the scan is waiting on. macOS holds a folder's contents back until its
/// permission prompt is answered, and a held file-system call cannot be cancelled.
public final class ScanSkip: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false
    public init() {}
    public func request() { lock.lock(); asked = true; lock.unlock() }
    /// True once per request.
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; let was = asked; asked = false; return was }
}

/// One walk or check on its own thread. The scan stops waiting for it when it stalls; the thread itself
/// stays where macOS holds it, and whatever it finds afterwards is dropped.
final class StallWatch: @unchecked Sendable {
    let root: String
    private let lock = NSLock()
    private let release: () -> Void
    /// nil until the work starts: a check still queued is not stalled.
    private var beat: Date?, top: String?, left = false, abandoned = false
    init(root: String, started: Bool = true, release: @escaping () -> Void) { self.root = root; self.release = release; beat = started ? Date() : nil }
    func touch(top: String? = nil) { lock.lock(); beat = Date(); if let top { self.top = top }; lock.unlock() }
    var isAbandoned: Bool { lock.lock(); defer { lock.unlock() }; return abandoned }
    /// The folder the work was last seen in.
    var path: String { lock.lock(); defer { lock.unlock() }; return top.map { root + "/" + $0 } ?? root }
    /// Seconds since the work last moved; 0 before it starts and once it is over.
    var silence: TimeInterval { lock.lock(); defer { lock.unlock() }; guard !left, let beat else { return 0 }; return Date().timeIntervalSince(beat) }
    /// Frees the scan's wait for this work, once however many times it is called. True for the call that freed it.
    @discardableResult func finish() -> Bool { lock.lock(); let first = !left; left = true; lock.unlock(); if first { release() }; return first }
    /// True when this call ended the wait; false when the work had already finished.
    @discardableResult func abandon() -> Bool {
        lock.lock(); let first = !left; if first { abandoned = true }; lock.unlock()
        return first && finish()
    }
}
