import CoreServices
import Foundation

final class FilesystemChangeMonitor: @unchecked Sendable {
    struct Change: Sendable {
        let paths: [String]
        let requiresFullScan: Bool
        let latestEventID: UInt64
    }

    private let callback: @Sendable (Change) -> Void
    private let queue = DispatchQueue(label: "com.spacetree.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    var isRunning: Bool { stream != nil }

    init(paths: [String], since eventID: UInt64, callback: @escaping @Sendable (Change) -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagIgnoreSelf
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, pathsPointer, flagsPointer, idsPointer in
                guard let info else { return }
                let monitor = Unmanaged<FilesystemChangeMonitor>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(pathsPointer, to: NSArray.self) as? [String] ?? []
                if let change = FilesystemChangeMonitor.change(
                    paths: paths,
                    flags: Array(UnsafeBufferPointer(start: flagsPointer, count: count)),
                    ids: Array(UnsafeBufferPointer(start: idsPointer, count: count))
                ) {
                    monitor.callback(change)
                }
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(eventID),
            0.35,
            flags
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }

    // HistoryDone is a stream sentinel; its path does not describe a change.
    static func change(paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) -> Change? {
        var changedPaths: [String] = []
        var requiresFullScan = false
        var latestID: UInt64 = 0
        for index in flags.indices {
            let flag = flags[index]
            guard flag & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0 else { continue }
            latestID = max(latestID, ids[index])
            changedPaths.append(paths[index])
            let fullScanFlags = kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged
            requiresFullScan = requiresFullScan || flag & FSEventStreamEventFlags(fullScanFlags) != 0
        }
        guard !changedPaths.isEmpty || requiresFullScan else { return nil }
        return Change(paths: changedPaths, requiresFullScan: requiresFullScan, latestEventID: latestID)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
