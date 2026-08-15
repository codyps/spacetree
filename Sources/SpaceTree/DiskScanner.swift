import Darwin
import Foundation
import SpaceTreeNative

struct ScanProgress: Codable, Equatable, Sendable {
    var currentPath: String
    var itemCount: Int
    var bytesFound: Int64
    var unreadableCount: Int
    var duplicateReferenceCount: Int = 0
}

struct ScanRoot: Codable, Equatable, Sendable {
    let url: URL
    let name: String
}

enum DiskScannerError: LocalizedError {
    case rootIsSymbolicLink(URL)
    case rootIsNotDirectory(URL)
    case rootCannotBeRead(URL, Int32)
    case tooManyEntries

    var errorDescription: String? {
        switch self {
        case .rootIsSymbolicLink(let url): return "SpaceTree will not scan the symbolic-link root at \(url.path)."
        case .rootIsNotDirectory(let url): return "The scan root is not a directory: \(url.path)"
        case .rootCannotBeRead(let url, let error): return "The scan root cannot be read: \(url.path) (errno \(error))"
        case .tooManyEntries: return "The scan contains more entries than the compact tree can address."
        }
    }
}

enum DiskScanner {
    private enum EntryKind: Sendable {
        case file
        case directory
        case symlink
        case other

        var nodeKind: NodeKind {
            switch self {
            case .file: .file
            case .directory: .directory
            case .symlink: .symlink
            case .other: .other
            }
        }
    }

    private struct EntryMetadata: Sendable {
        let name: String
        let kind: EntryKind
        let size: Int64
        let logicalSize: Int64
        let modifiedAt: Date?
        let identity: FileIdentity?
    }

    private struct DirectoryWork: Sendable {
        let url: URL
        let nodeID: NodeID
        let rootDevice: UInt64?
    }

    private struct DirectoryBatch: Sendable {
        let work: DirectoryWork
        let entries: [EntryMetadata]
        let unreadable: Bool
    }

    private actor EnumerationLimiter {
        private var permits: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(permits: Int) { self.permits = permits }

        func acquire() async {
            if permits > 0 {
                permits -= 1
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty {
                permits += 1
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    private static let enumerationLimiter = EnumerationLimiter(
        permits: min(8, max(4, ProcessInfo.processInfo.activeProcessorCount))
    )

    static var directoryWorkerCount: Int {
        min(8, max(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    static func scan(
        url: URL,
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> ScanTree {
        let root = url.standardizedFileURL
        let name = root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
        return try await scan(
            roots: [ScanRoot(url: root, name: name)],
            displayName: name,
            identifier: root.path,
            progress: progress
        )
    }

    static func refresh(
        root existingRoot: ScanTree,
        changedPaths: [String],
        scanRoots: [ScanRoot],
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> ScanTree {
        guard !changedPaths.isEmpty else { return existingRoot }
        let rootPaths = scanRoots.map { $0.url.standardizedFileURL.path }
        let candidates = changedPaths.compactMap { changedPath -> String? in
            let url = URL(fileURLWithPath: changedPath).standardizedFileURL
            let directory = rootPaths.contains(url.path) ? url.path : url.deletingLastPathComponent().path
            return rootPaths.contains(where: { directory == $0 || directory.hasPrefix($0 + "/") }) ? directory : nil
        }
        let ordered = Array(Set(candidates)).sorted { $0.count < $1.count }
        var coalesced: [String] = []
        for path in ordered where !coalesced.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            coalesced.append(path)
        }
        guard !coalesced.isEmpty else { return existingRoot }

        var replacements: [String: ScanTree] = [:]
        for path in coalesced {
            let replacement = try await scan(url: URL(fileURLWithPath: path, isDirectory: true), progress: progress)
            if replacement.hardLinkReferenceCount > 0 {
                let name = existingRoot.metadata(for: existingRoot.rootID).name
                return try await scan(
                    roots: scanRoots,
                    displayName: name,
                    identifier: existingRoot.displayURL.absoluteString,
                    progress: progress
                )
            }
            replacements[path] = replacement
        }
        return try rebuild(existingRoot, replacing: replacements)
    }

    static func scan(
        roots: [ScanRoot],
        displayName: String,
        identifier: String,
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> ScanTree {
        guard !roots.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        let standardizedRoots = roots.map { ScanRoot(url: $0.url.standardizedFileURL, name: $0.name) }
        let rootStats = try standardizedRoots.map { root in
            (root, try rootMetadata(at: root.url))
        }
        let safeIdentifier = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? UUID().uuidString
        let displayURL = standardizedRoots.count == 1
            ? standardizedRoots[0].url
            : URL(string: "spacetree://mount-group/\(safeIdentifier)")!

        return try await Task.detached(priority: .userInitiated) {
            var builder = ScanTreeBuilder(
                rootName: standardizedRoots.count == 1
                    ? (standardizedRoots[0].url.lastPathComponent.isEmpty ? standardizedRoots[0].url.path : standardizedRoots[0].url.lastPathComponent)
                    : displayName,
                rootURL: displayURL,
                synthetic: standardizedRoots.count > 1
            )
            var pending: [DirectoryWork] = []
            for (root, metadata) in rootStats {
                let nodeID = standardizedRoots.count == 1
                    ? builder.rootID
                    : builder.addPhysicalRoot(name: root.name, url: root.url, parent: builder.rootID)
                pending.append(DirectoryWork(url: root.url, nodeID: nodeID, rootDevice: metadata.device))
            }

            var seenIdentities = Set<FileIdentity>()
            var state = ScanProgress(
                currentPath: standardizedRoots[0].url.path,
                itemCount: pending.count,
                bytesFound: 0,
                unreadableCount: 0
            )
            var lastUpdate = ContinuousClock.now

            try await withThrowingTaskGroup(of: DirectoryBatch.self) { group in
                var activeWorkers = 0

                func submitAvailableWork() {
                    while activeWorkers < directoryWorkerCount, let work = pending.popLast() {
                        activeWorkers += 1
                        group.addTask {
                            try Task.checkCancellation()
                            await enumerationLimiter.acquire()
                            let result = enumerate(work)
                            await enumerationLimiter.release()
                            return result
                        }
                    }
                }

                submitAvailableWork()
                while activeWorkers > 0 {
                    try Task.checkCancellation()
                    guard let batch = try await group.next() else { break }
                    activeWorkers -= 1
                    if batch.unreadable {
                        builder.markUnreadable(batch.work.nodeID)
                        state.unreadableCount += 1
                    }

                    for entry in batch.entries {
                        guard builder.nodes.count < Int(UInt32.max) else { throw DiskScannerError.tooManyEntries }
                        let nodeID = builder.addNode(
                            parent: batch.work.nodeID,
                            name: entry.name,
                            kind: entry.kind.nodeKind,
                            allocatedBytes: entry.kind == .symlink ? 0 : entry.size,
                            logicalBytes: entry.kind == .symlink ? 0 : entry.logicalSize,
                            modifiedAt: entry.modifiedAt,
                            identity: entry.identity
                        )
                        if entry.kind == .directory {
                            pending.append(DirectoryWork(
                                url: batch.work.url.appendingPathComponent(entry.name, isDirectory: true),
                                nodeID: nodeID,
                                rootDevice: batch.work.rootDevice
                            ))
                        } else if entry.kind == .file {
                            if let identity = entry.identity, !seenIdentities.insert(identity).inserted {
                                state.duplicateReferenceCount += 1
                            } else {
                                state.bytesFound = saturatingProgressAdd(state.bytesFound, entry.size)
                            }
                        }
                    }
                    state.itemCount += batch.entries.count
                    state.currentPath = batch.work.url.path

                    let now = ContinuousClock.now
                    if lastUpdate.duration(to: now) >= .milliseconds(120) {
                        lastUpdate = now
                        await progress(state)
                    }
                    submitAvailableWork()
                }
            }

            let tree = try builder.finalize()
            let root = tree.metadata(for: tree.rootID)
            state.itemCount = root.fileCount + root.directoryCount
            state.bytesFound = root.allocatedBytes
            state.duplicateReferenceCount = root.duplicateReferenceCount
            state.unreadableCount = tree.unreadableCount
            await progress(state)
            return tree
        }.value
    }

    private static func enumerate(_ work: DirectoryWork) -> DirectoryBatch {
        if let entries = bulkEntries(at: work.url, rootDevice: work.rootDevice) {
            return DirectoryBatch(work: work, entries: entries, unreadable: false)
        }
        return DirectoryBatch(work: work, entries: [], unreadable: true)
    }

    private static func bulkEntries(at directory: URL, rootDevice: UInt64?) -> [EntryMetadata]? {
        var pointer: UnsafeMutablePointer<st_directory_entry_t>?
        var count = 0
        let error = directory.withUnsafeFileSystemRepresentation { path in
            st_list_directory(path, &pointer, &count)
        }
        guard error == 0 else { return nil }
        defer { st_free_directory_entries(pointer, count) }
        guard let pointer else { return [] }

        var results: [EntryMetadata] = []
        results.reserveCapacity(count)
        for index in 0..<count {
            let record = pointer[index]
            guard let namePointer = record.name else { continue }
            let name = String(cString: namePointer)
            guard name != ".", name != ".." else { continue }
            if let rootDevice, record.device_id != 0, record.device_id != rootDevice { continue }
            let kind: EntryKind = switch record.kind {
            case ST_ENTRY_FILE: .file
            case ST_ENTRY_DIRECTORY: .directory
            case ST_ENTRY_SYMLINK: .symlink
            default: .other
            }
            let modifiedAt = record.modified_seconds == 0
                ? nil
                : Date(timeIntervalSince1970: TimeInterval(record.modified_seconds) + TimeInterval(record.modified_nanoseconds) / 1_000_000_000)
            results.append(EntryMetadata(
                name: name,
                kind: kind,
                size: max(0, record.allocated_size),
                logicalSize: max(0, record.logical_size),
                modifiedAt: modifiedAt,
                identity: kind == .file && record.file_id != 0 && record.link_count > 1
                    ? FileIdentity(device: record.device_id, inode: record.file_id)
                    : nil
            ))
        }
        return results
    }

    private static func rootMetadata(at url: URL) throws -> (device: UInt64, inode: UInt64) {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(EINVAL) }
            return lstat(path, &metadata)
        }
        guard result == 0 else { throw DiskScannerError.rootCannotBeRead(url, errno) }
        if (metadata.st_mode & S_IFMT) == S_IFLNK { throw DiskScannerError.rootIsSymbolicLink(url) }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else { throw DiskScannerError.rootIsNotDirectory(url) }
        return (UInt64(metadata.st_dev), UInt64(metadata.st_ino))
    }

    private static func rebuild(_ existing: ScanTree, replacing replacements: [String: ScanTree]) throws -> ScanTree {
        let rootMetadata = existing.metadata(for: existing.rootID)
        let synthetic = existing.kind(of: existing.rootID) == .syntheticRoot
        var builder = ScanTreeBuilder(
            rootName: rootMetadata.name,
            rootURL: existing.displayURL,
            synthetic: synthetic
        )

        func copyContents(
            from source: ScanTree,
            sourceParent: NodeID,
            to destinationParent: NodeID,
            builder: inout ScanTreeBuilder
        ) {
            for child in source.children(of: sourceParent) {
                let metadata = source.metadata(for: child)
                if metadata.isDirectory, let replacement = replacements[metadata.url.standardizedFileURL.path] {
                    let destination = builder.addNode(
                        parent: destinationParent,
                        name: metadata.name,
                        kind: metadata.kind,
                        allocatedBytes: 0,
                        logicalBytes: 0,
                        modifiedAt: replacement.metadata(for: replacement.rootID).modifiedAt,
                        identity: nil,
                        unreadable: replacement.isUnreadable(replacement.rootID)
                    )
                    copyContents(from: replacement, sourceParent: replacement.rootID, to: destination, builder: &builder)
                    continue
                }

                let destination = builder.addNode(
                    parent: destinationParent,
                    name: metadata.name,
                    kind: metadata.kind,
                    allocatedBytes: metadata.intrinsicAllocatedBytes,
                    logicalBytes: metadata.logicalBytes,
                    modifiedAt: metadata.modifiedAt,
                    identity: nil,
                    unreadable: source.isUnreadable(child)
                )
                if metadata.isDirectory {
                    copyContents(from: source, sourceParent: child, to: destination, builder: &builder)
                }
            }
        }

        if synthetic {
            for child in existing.children(of: existing.rootID) {
                let metadata = existing.metadata(for: child)
                let physicalURL = existing.roots.first(where: { $0.nodeID == child })?.url ?? metadata.url
                let destination = builder.addPhysicalRoot(name: metadata.name, url: physicalURL, parent: builder.rootID)
                if let replacement = replacements[physicalURL.standardizedFileURL.path] {
                    copyContents(from: replacement, sourceParent: replacement.rootID, to: destination, builder: &builder)
                } else {
                    copyContents(from: existing, sourceParent: child, to: destination, builder: &builder)
                }
            }
        } else if let replacement = replacements[existing.displayURL.standardizedFileURL.path] {
            copyContents(from: replacement, sourceParent: replacement.rootID, to: builder.rootID, builder: &builder)
        } else {
            copyContents(from: existing, sourceParent: existing.rootID, to: builder.rootID, builder: &builder)
        }
        return try builder.finalize()
    }
}

private func saturatingProgressAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let positive = max(0, rhs)
    let result = lhs.addingReportingOverflow(positive)
    return result.overflow ? .max : result.partialValue
}
