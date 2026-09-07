import Foundation

struct ScanStatistics: Codable, Equatable, Sendable {
    struct Phase: Codable, Equatable, Sendable {
        let name: String
        let durationSeconds: Double
    }
    struct Directory: Codable, Equatable, Sendable {
        let path: String
        let durationSeconds: Double
        let entries: Int
    }
    var schemaVersion = 1
    let id: UUID
    let targetID: String
    let roots: [String]
    let mode: String
    let startedAt: Date
    let endedAt: Date
    let outcome: String
    let error: String?
    let durationSeconds: Double
    let phases: [Phase]
    let enumeratedDirectories: Int
    let enumeratedEntries: Int
    // Sum of worker durations; overlapping directory reads can exceed wall time.
    let directoryWorkerSeconds: Double
    let slowestDirectories: [Directory]
    let itemCount: Int
    let allocatedBytes: Int64
    let unreadableCount: Int
    let duplicateReferenceCount: Int
    let estimatedTreeStorageBytes: Int?
    let workerCount: Int
    let operatingSystem: String
    let buildConfiguration: String

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

// Shared by enumeration workers and the UI lifecycle. Closing a run freezes its
// measurements, even if a cancelled detached scanner takes time to wind down.
final class ScanStatisticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let id = UUID()
    private let startedAt = Date()
    private let start = ContinuousClock.now
    private let targetID: String
    private let roots: [String]
    private let mode: String
    private var phase = "Preparing scan"
    private var phaseStart: ContinuousClock.Instant
    private var phases: [ScanStatistics.Phase] = []
    private var directories = 0
    private var entries = 0
    private var workerSeconds = 0.0
    private var slowest: [ScanStatistics.Directory] = []
    private var closed = false

    init(targetID: String, roots: [String], mode: String) {
        self.targetID = targetID
        self.roots = roots
        self.mode = mode
        self.phaseStart = start
    }

    func beginPhase(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, name != phase else { return }
        let now = ContinuousClock.now
        phases.append(.init(name: phase, durationSeconds: phaseStart.duration(to: now).seconds))
        phase = name
        phaseStart = now
    }

    func directory(path: String, duration: Duration, entries count: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        directories += 1
        entries += count
        workerSeconds += duration.seconds
        slowest.append(.init(path: path, durationSeconds: duration.seconds, entries: count))
        slowest.sort { $0.durationSeconds > $1.durationSeconds }
        if slowest.count > 20 { slowest.removeLast() }
    }

    func finish(outcome: String, progress: ScanProgress, tree: ScanTree? = nil, error: String? = nil) -> ScanStatistics? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        closed = true
        let now = ContinuousClock.now
        phases.append(.init(name: phase, durationSeconds: phaseStart.duration(to: now).seconds))
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        return ScanStatistics(
            id: id, targetID: targetID, roots: roots, mode: mode,
            startedAt: startedAt, endedAt: Date(), outcome: outcome, error: error,
            durationSeconds: start.duration(to: now).seconds, phases: phases,
            enumeratedDirectories: directories, enumeratedEntries: entries,
            directoryWorkerSeconds: workerSeconds, slowestDirectories: slowest,
            itemCount: progress.itemCount, allocatedBytes: progress.bytesFound,
            unreadableCount: progress.unreadableCount,
            duplicateReferenceCount: progress.duplicateReferenceCount,
            estimatedTreeStorageBytes: tree?.estimatedStorageBytes,
            workerCount: DiskScanner.directoryWorkerCount,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            buildConfiguration: configuration
        )
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

actor ScanStatisticsStore {
    static let shared = ScanStatisticsStore()

    private let directory: URL

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? base.appendingPathComponent("SpaceTree/ScanHistory", isDirectory: true)
    }

    func save(_ statistics: ScanStatistics) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try statistics.jsonData().write(to: directory.appendingPathComponent("\(statistics.id).json"), options: .atomic)
    }
}
