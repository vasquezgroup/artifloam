import Foundation
import CoreServices

/// Recursive native change notifications. A lost-event/root-change flag forces
/// a full rescan; an unavailable stream never permits cached data to claim freshness.
public final class FolderChangeMonitor: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable ([URL], Bool) -> Void
    public init(root: URL, onChange: @escaping @Sendable ([URL], Bool) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, eventFlags, _ in
            guard let info else { return }
            let owner = Unmanaged<FolderChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let resetFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
            let reset = (0..<count).contains { eventFlags[$0] & resetFlags != 0 }
            owner.onChange(paths.map { URL(fileURLWithPath: $0) }, reset)
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.35, flags)
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil } }
    }
    public var available: Bool { stream != nil }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}
