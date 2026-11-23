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

/// One project-root walk on its own thread. The scan stops waiting for it when it stalls; the thread itself
/// stays where macOS holds it, and whatever it finds afterwards is dropped.
final class StallWatch: @unchecked Sendable {
    let root: String
    private let lock = NSLock()
    private let release: () -> Void
    private var beat = Date(), top: String?, left = false, abandoned = false
    init(root: String, release: @escaping () -> Void) { self.root = root; self.release = release }
    func touch(top: String? = nil) { lock.lock(); beat = Date(); if let top { self.top = top }; lock.unlock() }
    var isAbandoned: Bool { lock.lock(); defer { lock.unlock() }; return abandoned }
    /// The folder the walk was last seen in.
    var path: String { lock.lock(); defer { lock.unlock() }; return top.map { root + "/" + $0 } ?? root }
    /// Seconds since the walk last moved; 0 once it is over.
    var silence: TimeInterval { lock.lock(); defer { lock.unlock() }; return left ? 0 : Date().timeIntervalSince(beat) }
    /// Frees the scan's wait for this walk, once however many times it is called.
    func finish() { lock.lock(); let first = !left; left = true; lock.unlock(); if first { release() } }
    func abandon() { lock.lock(); abandoned = true; lock.unlock(); finish() }
}
