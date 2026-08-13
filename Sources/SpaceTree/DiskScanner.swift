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

enum DiskScanner {
    private struct FileIdentity: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private enum EntryKind: Sendable {
        case file
        case directory
        case symlink
        case other
    }

    private struct EntryMetadata: Sendable {
        let url: URL
        let name: String
        let kind: EntryKind
        let size: Int64
        let logicalSize: Int64
        let modifiedAt: Date?
        let identity: FileIdentity?
        var isDuplicate = false
    }

    private struct DirectoryWork: Sendable {
        let url: URL
        let modifiedAt: Date?
    }

    private struct DirectoryBatch: Sendable {
        let url: URL
        let modifiedAt: Date?
        var entries: [EntryMetadata]
        let unreadableCount: Int
    }

    private final class IdentityRegistry: @unchecked Sendable {
        private var identities: Set<FileIdentity> = []
        private let lock = NSLock()

        func claim(_ identity: FileIdentity) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return identities.insert(identity).inserted
        }
    }

    private actor ContainerProgress {
        private var updates: [Int: ScanProgress] = [:]
        private let callback: @Sendable (ScanProgress) async -> Void

        init(callback: @escaping @Sendable (ScanProgress) async -> Void) {
            self.callback = callback
        }

        func update(rootIndex: Int, rootName: String, progress: ScanProgress) async {
            updates[rootIndex] = progress
            await callback(ScanProgress(
                currentPath: "\(rootName): \(progress.currentPath)",
                itemCount: updates.values.reduce(0) { $0 + $1.itemCount },
                bytesFound: updates.values.reduce(0) { $0 + $1.bytesFound },
                unreadableCount: updates.values.reduce(0) { $0 + $1.unreadableCount },
                duplicateReferenceCount: updates.values.reduce(0) { $0 + $1.duplicateReferenceCount }
            ))
        }
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

    private static let fallbackKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey,
        .fileResourceIdentifierKey,
        .volumeIdentifierKey
    ]

    static var directoryWorkerCount: Int {
        min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    static func scan(
        url: URL,
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> FileNode {
        try await scan(url: url, identities: IdentityRegistry(), progress: progress)
    }

    static func refresh(
        root existingRoot: FileNode,
        changedPaths: [String],
        scanRoots: [ScanRoot],
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> FileNode {
        let rootPaths = scanRoots.map { $0.url.standardizedFileURL.path }
        let candidates = changedPaths.compactMap { changedPath -> String? in
            let url = URL(fileURLWithPath: changedPath).standardizedFileURL
            // FSEvents reports the changed entry. Refresh its parent so additions,
            // deletions, and renames can change the parent's child list correctly.
            let directory = rootPaths.contains(url.path) ? url.path : url.deletingLastPathComponent().path
            return rootPaths.contains(where: { directory == $0 || directory.hasPrefix($0 + "/") }) ? directory : nil
        }
        let ordered = Array(Set(candidates)).sorted { $0.count < $1.count }
        var coalesced: [String] = []
        for path in ordered where !coalesced.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            coalesced.append(path)
        }
        guard !coalesced.isEmpty else { return existingRoot }

        let aggregate = ContainerProgress(callback: progress)
        let replacements = try await withThrowingTaskGroup(of: (String, FileNode).self) { group in
            for (index, path) in coalesced.enumerated() {
                group.addTask {
                    let url = URL(fileURLWithPath: path, isDirectory: true)
                    let result = try await scan(url: url, identities: IdentityRegistry()) { update in
                        await aggregate.update(rootIndex: index, rootName: url.lastPathComponent, progress: update)
                    }
                    return (path, result)
                }
            }
            var values: [(String, FileNode)] = []
            for try await value in group { values.append(value) }
            return values
        }

        return replacements.reduce(existingRoot) { tree, replacement in
            replacingDirectory(in: tree, path: replacement.0, with: replacement.1)
        }
    }

    static func scan(
        roots: [ScanRoot],
        displayName: String,
        identifier: String,
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> FileNode {
        guard !roots.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        if roots.count == 1, let root = roots.first {
            return try await scan(url: root.url, progress: progress)
        }

        let aggregate = ContainerProgress(callback: progress)
        let scannedRoots = try await withThrowingTaskGroup(of: (Int, FileNode).self) { group in
            for (index, root) in roots.enumerated() {
                group.addTask {
                    let node = try await scan(url: root.url, identities: IdentityRegistry()) { update in
                        await aggregate.update(rootIndex: index, rootName: root.name, progress: update)
                    }
                    return (index, node)
                }
            }
            var results: [(Int, FileNode)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        let children = zip(roots, scannedRoots.map(\.1)).map { root, scanned in
            FileNode.directory(
                url: root.url,
                name: root.name,
                children: scanned.children,
                modifiedAt: scanned.modifiedAt
            )
        }
        let safeIdentifier = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? UUID().uuidString
        return FileNode.directory(
            url: URL(string: "spacetree://mount-group/\(safeIdentifier)")!,
            name: displayName,
            children: children
        )
    }

    private static func scan(
        url: URL,
        identities: IdentityRegistry,
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> FileNode {
        let root = url.standardizedFileURL
        return try await Task.detached(priority: .userInitiated) {
            let rootDevice = deviceIdentifier(at: root)
            let rootModifiedAt = try? root.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            var pending = [DirectoryWork(url: root, modifiedAt: rootModifiedAt)]
            var batches: [String: DirectoryBatch] = [:]
            var state = ScanProgress(currentPath: root.path, itemCount: 0, bytesFound: 0, unreadableCount: 0)
            var lastUpdate = ContinuousClock.now

            try await withThrowingTaskGroup(of: DirectoryBatch.self) { group in
                var activeWorkers = 0

                func submitAvailableWork() {
                    while activeWorkers < directoryWorkerCount, let work = pending.popLast() {
                        activeWorkers += 1
                        group.addTask {
                            try Task.checkCancellation()
                            await enumerationLimiter.acquire()
                            let result = enumerate(work, rootDevice: rootDevice)
                            await enumerationLimiter.release()
                            return result
                        }
                    }
                }

                submitAvailableWork()
                while activeWorkers > 0 {
                    try Task.checkCancellation()
                    guard var batch = try await group.next() else { break }
                    activeWorkers -= 1

                    for index in batch.entries.indices where batch.entries[index].kind == .file {
                        if let identity = batch.entries[index].identity,
                           !identities.claim(identity) {
                            batch.entries[index].isDuplicate = true
                            state.duplicateReferenceCount += 1
                        } else {
                            state.bytesFound += batch.entries[index].size
                        }
                    }
                    for entry in batch.entries where entry.kind == .directory {
                        pending.append(DirectoryWork(url: entry.url, modifiedAt: entry.modifiedAt))
                    }
                    state.itemCount += batch.entries.count + 1
                    state.unreadableCount += batch.unreadableCount
                    state.currentPath = batch.url.path
                    batches[batch.url.path] = batch

                    let now = ContinuousClock.now
                    if lastUpdate.duration(to: now) >= .milliseconds(120) {
                        lastUpdate = now
                        await progress(state)
                    }
                    submitAvailableWork()
                }
            }

            func buildDirectory(_ work: DirectoryWork) -> FileNode {
                // Consume each flat batch as it is materialized into the final tree so a
                // large scan does not retain two complete copies of its metadata.
                guard let batch = batches.removeValue(forKey: work.url.path) else {
                    return FileNode.directory(url: work.url, children: [], modifiedAt: work.modifiedAt)
                }
                let children = batch.entries.compactMap { entry -> FileNode? in
                    switch entry.kind {
                    case .directory:
                        return buildDirectory(DirectoryWork(url: entry.url, modifiedAt: entry.modifiedAt))
                    case .file:
                        return FileNode.file(
                            url: entry.url,
                            size: entry.isDuplicate ? 0 : entry.size,
                            logicalSize: entry.isDuplicate ? 0 : entry.logicalSize,
                            modifiedAt: entry.modifiedAt,
                            isDuplicateReference: entry.isDuplicate
                        )
                    case .symlink:
                        return FileNode.file(url: entry.url, size: 0, logicalSize: 0, modifiedAt: entry.modifiedAt)
                    case .other:
                        return nil
                    }
                }
                return FileNode.directory(url: work.url, children: children, modifiedAt: batch.modifiedAt)
            }

            let result = buildDirectory(DirectoryWork(url: root, modifiedAt: rootModifiedAt))
            await progress(state)
            return result
        }.value
    }

    private static func enumerate(_ work: DirectoryWork, rootDevice: UInt64?) -> DirectoryBatch {
        if let entries = bulkEntries(at: work.url, rootDevice: rootDevice) {
            return DirectoryBatch(url: work.url, modifiedAt: work.modifiedAt, entries: entries, unreadableCount: 0)
        }
        return fallbackEntries(at: work, rootDevice: rootDevice)
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
            let kind: EntryKind
            switch record.kind {
            case ST_ENTRY_FILE: kind = .file
            case ST_ENTRY_DIRECTORY: kind = .directory
            case ST_ENTRY_SYMLINK: kind = .symlink
            default: kind = .other
            }
            let modifiedAt = record.modified_seconds == 0
                ? nil
                : Date(timeIntervalSince1970: TimeInterval(record.modified_seconds) + TimeInterval(record.modified_nanoseconds) / 1_000_000_000)
            results.append(EntryMetadata(
                url: directory.appendingPathComponent(name, isDirectory: kind == .directory),
                name: name,
                kind: kind,
                size: max(0, record.allocated_size),
                logicalSize: max(0, record.logical_size),
                modifiedAt: modifiedAt,
                identity: record.file_id == 0 ? nil : FileIdentity(device: record.device_id, inode: record.file_id)
            ))
        }
        return results
    }

    private static func fallbackEntries(at work: DirectoryWork, rootDevice: UInt64?) -> DirectoryBatch {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: work.url,
                includingPropertiesForKeys: Array(fallbackKeys),
                options: []
            )
            let entries = urls.compactMap { url -> EntryMetadata? in
                guard let values = try? url.resourceValues(forKeys: fallbackKeys) else { return nil }
                let kind: EntryKind
                if values.isSymbolicLink == true { kind = .symlink }
                else if values.isDirectory == true { kind = .directory }
                else if values.isRegularFile == true { kind = .file }
                else { kind = .other }
                let identifierHash = (values.fileResourceIdentifier as? NSObject)?.hash
                let identity = identifierHash.map {
                    FileIdentity(device: rootDevice ?? 0, inode: UInt64(bitPattern: Int64($0)))
                }
                return EntryMetadata(
                    url: url,
                    name: url.lastPathComponent,
                    kind: kind,
                    size: Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0),
                    logicalSize: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate,
                    identity: identity
                )
            }
            return DirectoryBatch(url: work.url, modifiedAt: work.modifiedAt, entries: entries, unreadableCount: 0)
        } catch {
            return DirectoryBatch(url: work.url, modifiedAt: work.modifiedAt, entries: [], unreadableCount: 1)
        }
    }

    private static func deviceIdentifier(at url: URL) -> UInt64? {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        return result == 0 ? UInt64(metadata.st_dev) : nil
    }

    private static func replacingDirectory(in node: FileNode, path: String, with replacement: FileNode) -> FileNode {
        if node.url.standardizedFileURL.path == path {
            return FileNode.directory(
                url: replacement.url,
                name: node.name,
                children: replacement.children,
                modifiedAt: replacement.modifiedAt
            )
        }
        guard node.isDirectory else { return node }
        var changed = false
        let children = node.children.map { child -> FileNode in
            let childPath = child.url.standardizedFileURL.path
            let mayContainPath = path == childPath || path.hasPrefix(childPath + "/")
            guard mayContainPath else { return child }
            let updated = replacingDirectory(in: child, path: path, with: replacement)
            if updated != child { changed = true }
            return updated
        }
        guard changed else { return node }
        return FileNode.directory(
            url: node.url,
            name: node.name,
            children: children,
            modifiedAt: node.modifiedAt
        )
    }
}
