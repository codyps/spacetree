import CryptoKit
import Darwin
import Foundation

struct BackupSnapshot: Identifiable, Hashable, Sendable {
    let id: String
    let root: String
    let device: String
}

struct BackupChange: Codable, Sendable {
    let path: String
    let kind: String
    let oldSize: Int64
    let newSize: Int64
    // nil means the snapshot could not be inspected; never imply it is a file.
    let subtree: Bool?
    var delta: Int64 { newSize - oldSize }
}

struct BackupComparison: Codable, Sendable, Identifiable {
    var id: String { older + " → " + newer }
    let older: String
    let newer: String
    let changes: [BackupChange]
    let warnings: [String]
}

enum BackupMetric: String, CaseIterable, Identifiable, Sendable {
    case affected = "Changed file sizes"
    case sizeDelta = "Cumulative size delta"
    case removed = "Removed sizes"
    var id: String { rawValue }
    var explanation: String {
        switch self {
        case .affected: "Sum of newer sizes for added or modified files in each interval. Includes same-size rewrites. An indicator of churn, not measured transfer or unique disk usage."
        case .sizeDelta: "Sum of absolute size differences in each interval, including additions and removals. Growth and shrinkage do not cancel out. Same-size rewrites contribute zero."
        case .removed: "Sum of sizes removed from later backups. Historical copies may still occupy space; this is not reclaimed storage."
        }
    }
    func bytes(_ change: BackupChange) -> Int64 {
        switch self {
        case .affected: change.newSize
        case .sizeDelta: abs(change.delta)
        case .removed: change.kind == "removed" ? change.oldSize : 0
        }
    }
}

struct BackupRanking: Identifiable, Sendable {
    let path: String
    var bytes: Double = 0
    var netDelta: Double = 0
    var intervals: Set<String> = []
    var isFolder = false
    var hasSubtree = false
    var unknownType = false
    var id: String { path }
}

enum BackupAnalysis {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func snapshots(mounts: [MountedFilesystem]) -> [BackupSnapshot] {
        let pattern = #"^com\.apple\.TimeMachine\.(\d{4}-\d{2}-\d{2}-\d{6})\.backup@(.+)$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        return mounts.compactMap { mount in
            guard mount.isReadOnly,
                  let match = regex.firstMatch(in: mount.device, range: NSRange(mount.device.startIndex..., in: mount.device)),
                  let stampRange = Range(match.range(at: 1), in: mount.device),
                  let deviceRange = Range(match.range(at: 2), in: mount.device) else { return nil }
            let stamp = String(mount.device[stampRange])
            return BackupSnapshot(id: stamp, root: mount.url.appendingPathComponent(stamp + ".backup").path,
                                  device: String(mount.device[deviceRange]))
        }.sorted { $0.id < $1.id }
    }

    static func relative(_ path: String, root: String) throws -> String {
        // NSString standardization is lexical: do not resolve symlinks into live files.
        let normalized = (path as NSString).standardizingPath
        let prefix = (root as NSString).standardizingPath + "/"
        guard normalized.hasPrefix(prefix), normalized.count > prefix.count else {
            throw Failure(message: "Comparison returned a path outside its snapshot: \(path)")
        }
        return String(normalized.dropFirst(prefix.count))
    }

    static func parse(_ data: Data, older: BackupSnapshot, newer: BackupSnapshot,
                      stderr: String = "", inspect: (String) -> Bool? = directoryType,
                      checkCancellation: () throws -> Void = {},
                      onProgress: (Int, Int) -> Void = { _, _ in }) throws -> BackupComparison {
        try checkCancellation()
        let data = preserveFilenameCarriageReturns(data)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let records = plist["Changes"] as? [[String: Any]], plist["Totals"] is [String: Any] else {
            throw Failure(message: "Incomplete tmutil comparison: missing Changes or Totals.")
        }
        var changes: [BackupChange] = []
        var unknown = 0
        changes.reserveCapacity(records.count)
        onProgress(0, records.count)
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 512) {
                try checkCancellation()
                onProgress(index, records.count)
            }
            let item: [String: Any], before: [String: Any], kind: String, root: String
            if let added = record["AddedItem"] as? [String: Any] {
                (item, before, kind, root) = (added, [:], "added", newer.root)
            } else if let removed = record["RemovedItem"] as? [String: Any] {
                (item, before, kind, root) = (removed, [:], "removed", older.root)
            } else if let new = record["NewerItem"] as? [String: Any], let old = record["OlderItem"] as? [String: Any] {
                (item, before, kind, root) = (new, old, "modified", newer.root)
            } else { throw Failure(message: "Unrecognized tmutil change record.") }
            guard let absolute = item["Path"] as? String else { throw Failure(message: "Missing change path.") }
            let path = try relative(absolute, root: root)
            if kind == "modified" {
                guard let oldPath = before["Path"] as? String, try relative(oldPath, root: older.root) == path else {
                    throw Failure(message: "Mismatched paths in modification record.")
                }
            }
            if item["Size"] == nil && before["Size"] == nil { continue }
            func size(_ value: Any?) throws -> Int64 {
                guard let value else { return 0 }
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue >= 0, number.doubleValue < Double(Int64.max),
                      number.doubleValue.rounded(.towardZero) == number.doubleValue else {
                    throw Failure(message: "Invalid file size in comparison.")
                }
                return number.int64Value
            }
            let oldSize = try size(kind == "modified" ? before["Size"] : (kind == "removed" ? item["Size"] : nil))
            let newSize = try size(kind == "removed" ? nil : item["Size"])
            let subtree = inspect(absolute)
            if subtree == nil { unknown += 1 }
            changes.append(BackupChange(path: path, kind: kind, oldSize: oldSize, newSize: newSize, subtree: subtree))
        }
        onProgress(records.count, records.count)
        try checkCancellation()
        var warnings = stderr.isEmpty ? [] : [stderr]
        if unknown > 0 { warnings.append("Could not inspect the type of \(unknown) changed paths; these may include subtree summaries.") }
        return BackupComparison(older: older.id, newer: newer.id, changes: changes, warnings: warnings)
    }

    // One pass over UTF-8, copying chunks only for literal CRs inside strings.
    // Replacing every <string> in a Swift String was quadratic on large diffs.
    static func preserveFilenameCarriageReturns(_ data: Data) -> Data {
        guard !data.starts(with: Data("bplist".utf8)),
              data.contains(13) else { return data }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let opening = Array("<string>".utf8), closing = Array("</string>".utf8)
            let replacement = Array("&#13;".utf8)
            var output = Data()
            output.reserveCapacity(data.count)
            var insideString = false
            var copiedThrough = 0
            var index = 0
            while index < bytes.count {
                if bytes[index] == 60 {
                    let tag = insideString ? closing : opening
                    if index + tag.count <= bytes.count && bytes[index..<(index + tag.count)].elementsEqual(tag) {
                        insideString.toggle()
                        index += tag.count
                        continue
                    }
                }
                if insideString && bytes[index] == 13 {
                    output.append(contentsOf: bytes[copiedThrough..<index])
                    output.append(contentsOf: replacement)
                    copiedThrough = index + 1
                }
                index += 1
            }
            if copiedThrough == 0 { return data }
            output.append(contentsOf: bytes[copiedThrough..<bytes.count])
            return output
        }
    }

    static func directoryType(_ path: String) -> Bool? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func rankings(_ comparisons: [BackupComparison], metric: BackupMetric, folder: String = "", search: String = "") -> [BackupRanking] {
        var result: [String: BackupRanking] = [:]
        let prefix = folder.isEmpty ? "" : folder + "/"
        for comparison in comparisons {
            for change in comparison.changes {
                guard (change.path == folder || change.path.hasPrefix(prefix)), search.isEmpty || change.path.localizedCaseInsensitiveContains(search) else { continue }
                if change.path == folder {
                    var row = result[folder] ?? BackupRanking(path: folder)
                    row.bytes += Double(metric.bytes(change))
                    row.netDelta += Double(change.delta)
                    row.intervals.insert(comparison.id)
                    row.hasSubtree = row.hasSubtree || change.subtree == true
                    row.unknownType = row.unknownType || change.subtree == nil
                    result[folder] = row
                    continue
                }
                let remainder = String(change.path.dropFirst(prefix.count))
                let component = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                guard let first = component.first, !first.isEmpty else { continue }
                let path = prefix + first
                var row = result[path] ?? BackupRanking(path: path)
                row.bytes += Double(metric.bytes(change))
                row.netDelta += Double(change.delta)
                row.intervals.insert(comparison.id)
                row.isFolder = row.isFolder || component.count > 1
                row.hasSubtree = row.hasSubtree || change.subtree == true
                row.unknownType = row.unknownType || change.subtree == nil
                result[path] = row
            }
        }
        return result.values.filter { $0.bytes > 0 }.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
    }

    static func cacheKey(older: BackupSnapshot, newer: BackupSnapshot) -> String {
        let identity = ["native-v1", older.device, older.root, newer.device, newer.root, "-s -t -E -X"].joined(separator: "\n")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// Owned by one background operation; cancellation may arrive from the UI thread.
final class BackupCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    struct Progress: Sendable {
        enum Stage: Sendable { case scanning, parsing, classifying, saving, cached }
        let stage: Stage
        let elapsed: TimeInterval
        var outputBytes: Int64 = 0
        var completed: Int = 0
        var total: Int = 0

        var label: String {
            let seconds = max(0, Int(elapsed))
            let duration = "\(seconds / 60)m \(seconds % 60)s"
            switch stage {
            case .scanning: return "Scanning snapshots · \(duration) elapsed · \(outputBytes.formattedByteCount) comparison output · scan percentage unavailable"
            case .parsing: return "Reading comparison data · \(duration) elapsed"
            case .classifying: return "Inspecting changes · \(completed.formatted()) of \(total.formatted()) records · \(duration) elapsed"
            case .saving: return "Saving completed comparison · \(duration) elapsed"
            case .cached: return "Loaded completed comparison from cache"
            }
        }
    }

    private func checkCancellation() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }

    func run(older: BackupSnapshot, newer: BackupSnapshot, cacheDirectory: URL? = nil,
             onProgress: (@Sendable (Progress) -> Void)? = nil) throws -> BackupComparison {
        let started = Date()
        lock.lock()
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { throw CancellationError() }
        let fm = FileManager.default
        let cache = try cacheDirectory ?? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpaceTree/BackupChanges", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let saved = cache.appendingPathComponent(BackupAnalysis.cacheKey(older: older, newer: newer) + ".json")
        if let data = try? Data(contentsOf: saved), let comparison = try? JSONDecoder().decode(BackupComparison.self, from: data) {
            try checkCancellation()
            onProgress?(Progress(stage: .cached, elapsed: Date().timeIntervalSince(started)))
            return comparison
        }
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("compare.plist")
        let errors = temporary.appendingPathComponent("stderr")
        fm.createFile(atPath: output.path, contents: nil)
        fm.createFile(atPath: errors.path, contents: nil)
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errors)
        defer { try? out.close(); try? err.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        child.arguments = ["compare", "-s", "-t", "-E", "-X", older.root, newer.root]
        child.standardOutput = out
        child.standardError = err
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw error }
        // tmutil has no reliable percentage. Report elapsed time and actual output
        // growth, then distinct parsing/classification/cache stages.
        let progressQueue = DispatchQueue(label: "SpaceTree.backup-progress")
        let timer = DispatchSource.makeTimerSource(queue: progressQueue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler {
            let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
            onProgress?(Progress(stage: .scanning, elapsed: Date().timeIntervalSince(started), outputBytes: size))
        }
        timer.resume()
        child.waitUntilExit()
        timer.cancel()
        progressQueue.sync {}
        lock.lock()
        process = nil
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        let stderr = String(decoding: try Data(contentsOf: errors), as: UTF8.self)
        guard child.terminationStatus == 0 else {
            let diagnostics = [older.root, newer.root].map { path -> String in
                var info = stat()
                let status = lstat(path, &info)
                let statError = status == 0 ? "directory exists" : String(cString: strerror(errno))
                let metadata = getxattr(path, "com.apple.backupd.SnapshotState", nil, 0, 0, XATTR_NOFOLLOW)
                let metadataStatus = metadata >= 0 ? "backup metadata readable" : String(cString: strerror(errno))
                return "\(path)\n\(statError); \(metadataStatus)"
            }.joined(separator: "\n\n")
            throw BackupAnalysis.Failure(message: "tmutil exited \(child.terminationStatus). \(stderr.suffix(4000))\n\(diagnostics)")
        }
        try checkCancellation()
        onProgress?(Progress(stage: .parsing, elapsed: Date().timeIntervalSince(started)))
        let comparison = try BackupAnalysis.parse(Data(contentsOf: output), older: older, newer: newer, stderr: stderr,
            checkCancellation: checkCancellation) { completed, total in
                onProgress?(Progress(stage: .classifying, elapsed: Date().timeIntervalSince(started), completed: completed, total: total))
            }
        try checkCancellation()
        onProgress?(Progress(stage: .saving, elapsed: Date().timeIntervalSince(started)))
        try JSONEncoder().encode(comparison).write(to: saved, options: .atomic)
        return comparison
    }
}
