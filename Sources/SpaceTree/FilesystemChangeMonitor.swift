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
                var requiresFullScan = false
                var latestID: UInt64 = 0
                for index in 0..<count {
                    let flags = flagsPointer[index]
                    latestID = max(latestID, idsPointer[index])
                    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                        || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
                        || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
                        || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0
                        || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                        requiresFullScan = true
                    }
                }
                guard !paths.isEmpty || requiresFullScan else { return }
                monitor.callback(Change(paths: paths, requiresFullScan: requiresFullScan, latestEventID: latestID))
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
