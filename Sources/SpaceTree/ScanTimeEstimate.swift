import Darwin
import Foundation
import SpaceTreeNative

struct ScanWorkBudget: Equatable, Sendable {
    var items: Double?
    var directories: Double?
    var bytes: Double?
    var basis: String

    static func volumeCounts(roots: [ScanRoot]) -> ScanWorkBudget? {
        guard !roots.isEmpty else { return nil }
        var urls = roots.map { $0.url.standardizedFileURL }
        // The startup namespace traverses both System and Data, even when the
        // scanner coalesces Data's firmlink alias into the / root.
        if urls.contains(where: { $0.path == "/" }) {
            var system = stat(), data = stat()
            if lstat("/", &system) == 0, lstat("/System/Volumes/Data", &data) == 0,
               system.st_dev == data.st_dev {
                urls.append(URL(fileURLWithPath: "/System/Volumes/Data"))
            }
        }
        var seen = Set<String>()
        var files = 0.0, directories = 0.0
        for url in urls {
            var filesystem = statfs()
            guard statfs(url.path, &filesystem) == 0 else { return nil }
            let mount = withUnsafePointer(to: &filesystem.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            // getattrlist accepts folders too, but returns the ENTIRE volume's
            // counts. Never use that denominator for a selected folder.
            guard url.path == URL(fileURLWithPath: mount).standardizedFileURL.path else { return nil }
            let identity = "\(filesystem.f_fsid.val.0):\(filesystem.f_fsid.val.1)"
            guard seen.insert(identity).inserted else { continue }
            var fileCount: UInt64 = 0, directoryCount: UInt64 = 0
            guard st_volume_counts(url.path, &fileCount, &directoryCount) == 0,
                  directoryCount > 0 else { return nil }
            files += Double(fileCount)
            directories += Double(directoryCount)
        }
        return ScanWorkBudget(items: files + directories, directories: directories,
                              basis: "Volume file and directory counts")
    }
}

/// A deliberately approximate time estimate, with no extra filesystem walk.
/// Counts measure metadata work; allocated bytes are a lower-confidence fallback.
struct ScanTimeEstimate: Sendable {
    let startedAt: Date
    var budget: ScanWorkBudget?
    private(set) var fraction: Double?
    private(set) var remainingSeconds: Double?
    private(set) var isFinishing = false
    private var lastSampleAt: Date
    private var lastFraction = 0.0
    private var rate: Double?
    private var samples = 0
    private var lastAdvanceAt: Date

    init(startedAt: Date, budget: ScanWorkBudget?) {
        self.startedAt = startedAt
        self.lastSampleAt = startedAt
        self.lastAdvanceAt = startedAt
        self.budget = budget
    }

    mutating func update(_ progress: ScanProgress, at now: Date) {
        let raw: Double
        var overBudget = false
        if let finishing = progress.finishing {
            let stages = ["Resolving hard links", "Preparing totals", "Calculating directory sizes", "Sorting entries"]
            guard let stage = stages.firstIndex(of: finishing.stage) else { return }
            if !isFinishing {
                // Rebase the rate rather than interpret the phase transition as
                // a sudden burst of enumeration throughput.
                isFinishing = true
                rate = nil
                samples = 0
                lastSampleAt = now
                lastFraction = 0.9
                remainingSeconds = nil
            }
            let local = min(1, max(0, Double(finishing.completed) / Double(max(1, finishing.total))))
            raw = 0.9 + 0.1 * (Double(stage) + local) / Double(stages.count)
        } else if let budget {
            if let items = budget.items, items > 0,
               let directories = budget.directories, directories > 0,
               let completed = progress.enumeratedDirectories {
                // Directory reads dominate IO; item count also captures wide
                // directories with many batches of entries.
                let directoryFraction = Double(completed) / directories
                let itemFraction = Double(progress.itemCount) / items
                overBudget = directoryFraction >= 1 || itemFraction >= 1
                raw = 0.9 * min(0.98, 0.7 * directoryFraction + 0.3 * itemFraction)
            } else if let bytes = budget.bytes, bytes > 0 {
                let byteFraction = Double(progress.bytesFound) / bytes
                overBudget = byteFraction >= 1
                raw = 0.9 * min(0.98, byteFraction)
            } else { return }
        } else { return }

        // Never claim completion before the scanner publishes the result.
        let value = min(0.99, max(fraction ?? 0, raw))
        if value > (fraction ?? 0) { lastAdvanceAt = now }
        fraction = value
        let interval = now.timeIntervalSince(lastSampleAt)
        if interval >= 1 {
            let measured = max(0, value - lastFraction) / interval
            let weight = 1 - exp(-interval / 8)
            rate = rate.map { $0 + weight * (measured - $0) } ?? measured
            samples += 1
            lastSampleAt = now
            lastFraction = value
        }
        if !overBudget, samples >= 3, now.timeIntervalSince(startedAt) >= 3,
           let rate, rate > 0, value < 0.99 {
            let seconds = (1 - value) / rate
            remainingSeconds = seconds.isFinite ? seconds : nil
        } else {
            remainingSeconds = nil
        }
    }

    func timeRemainingLabel(at now: Date) -> String {
        guard now.timeIntervalSince(lastAdvanceAt) < 10,
              let seconds = remainingSeconds else {
            return isFinishing ? "Finishing…" : "Estimating time remaining…"
        }
        // Coarse rounding avoids implying second-level accuracy.
        if seconds >= 86_400 { return "More than a day remaining" }
        if seconds < 60 { return "About \(max(5, Int(ceil(seconds / 5)) * 5)) sec remaining" }
        if seconds < 3600 { return "About \(Int(ceil(seconds / 60))) min remaining" }
        return "About \(Int(ceil(seconds / 3600))) hr remaining"
    }
}
