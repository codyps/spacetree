import Foundation
import Testing
@testable import SpaceTree

private func sample(items: Int, directories: Int, bytes: Int64 = 0) -> ScanProgress {
    ScanProgress(currentPath: "/", itemCount: items, bytesFound: bytes, unreadableCount: 0,
                 enumeratedDirectories: directories)
}

@Test func scanEstimateUsesCountsInsteadOfFileSizesAndWarmsUp() throws {
    let start = Date(timeIntervalSince1970: 0)
    let budget = ScanWorkBudget(items: 1000, directories: 100, bytes: 1000, basis: "test")
    var small = ScanTimeEstimate(startedAt: start, budget: budget)
    var large = small
    for second in 1...5 {
        small.update(sample(items: second * 100, directories: second * 10, bytes: 1),
                     at: start.addingTimeInterval(Double(second)))
        large.update(sample(items: second * 100, directories: second * 10, bytes: 1_000_000),
                     at: start.addingTimeInterval(Double(second)))
        if second < 3 { #expect(small.remainingSeconds == nil) }
    }
    #expect(small.fraction == large.fraction)
    #expect(small.remainingSeconds == large.remainingSeconds)
    #expect(abs(try #require(small.fraction) - 0.45) < 0.001)
    #expect(try #require(small.remainingSeconds) > 0)
    #expect(small.timeRemainingLabel(at: start.addingTimeInterval(5)).contains("remaining"))
    #expect(small.timeRemainingLabel(at: start.addingTimeInterval(20)) == "Estimating time remaining…")
}

@Test func scanEstimateHandlesMissingAndExceededBudgets() {
    let start = Date(timeIntervalSince1970: 0)
    var unknown = ScanTimeEstimate(startedAt: start, budget: nil)
    unknown.update(sample(items: 100, directories: 10), at: start.addingTimeInterval(10))
    #expect(unknown.fraction == nil)
    #expect(unknown.remainingSeconds == nil)

    var bytes = ScanTimeEstimate(startedAt: start,
                                 budget: ScanWorkBudget(bytes: 100, basis: "bytes"))
    for second in 1...5 {
        bytes.update(sample(items: 10, directories: 1, bytes: Int64(second * 30)),
                     at: start.addingTimeInterval(Double(second)))
    }
    #expect((bytes.fraction ?? 1) < 0.9)
    #expect(bytes.remainingSeconds == nil)
    let fraction = bytes.fraction
    bytes.update(sample(items: 10, directories: 1, bytes: 1), at: start.addingTimeInterval(6))
    #expect(bytes.fraction == fraction) // No backwards jump after revised observations.
}

@Test func scanEstimateReservesFinishingAndNeverReportsCompleteEarly() throws {
    let start = Date(timeIntervalSince1970: 0)
    var estimate = ScanTimeEstimate(startedAt: start,
                                    budget: ScanWorkBudget(items: 100, directories: 10, basis: "test"))
    estimate.update(sample(items: 50, directories: 5), at: start.addingTimeInterval(10))
    var progress = sample(items: 100, directories: 10)
    progress.finishing = .init(stage: "Resolving hard links", completed: 0, total: 0)
    estimate.update(progress, at: start.addingTimeInterval(11))
    #expect(estimate.fraction == 0.9)
    #expect(estimate.remainingSeconds == nil)
    #expect(estimate.isFinishing)
    progress.finishing = .init(stage: "Calculating directory sizes", completed: 50, total: 100)
    estimate.update(progress, at: start.addingTimeInterval(12))
    #expect(try #require(estimate.fraction) > 0.95)
    progress.finishing = .init(stage: "Sorting entries", completed: 100, total: 100)
    estimate.update(progress, at: start.addingTimeInterval(13))
    #expect(estimate.fraction == 0.99)
    #expect(estimate.remainingSeconds == nil)
}

@Test func scanCountBudgetRejectsFoldersAndDeduplicatesVolumes() throws {
    // Probe counts only; do not walk the disk or use volume totals for a folder.
    #expect(ScanWorkBudget.volumeCounts(roots: [ScanRoot(url: URL(fileURLWithPath: "/private/tmp"), name: "tmp")]) == nil)
    let root = ScanRoot(url: URL(fileURLWithPath: "/"), name: "Startup")
    let data = ScanRoot(url: URL(fileURLWithPath: "/System/Volumes/Data"), name: "Data")
    let single = try #require(ScanWorkBudget.volumeCounts(roots: [root]))
    let repeated = try #require(ScanWorkBudget.volumeCounts(roots: [root, root, data]))
    #expect(try #require(single.items) > 0)
    #expect(try #require(single.directories) > 0)
    // Live filesystems can change between queries; duplicate roots must not
    // multiply the budget. Allow modest concurrent filesystem activity.
    let ratio = try #require(repeated.items) / #require(single.items)
    #expect(ratio > 0.95 && ratio < 1.05)
}

@Test func scanEstimateAdaptsToSlowerThroughput() throws {
    let start = Date(timeIntervalSince1970: 0)
    var estimate = ScanTimeEstimate(startedAt: start,
                                    budget: ScanWorkBudget(items: 10000, directories: 1000, basis: "test"))
    for second in 1...5 {
        estimate.update(sample(items: second * 100, directories: second * 10),
                        at: start.addingTimeInterval(Double(second)))
    }
    let initial = try #require(estimate.remainingSeconds)
    for second in 6...10 {
        estimate.update(sample(items: 500 + second, directories: 50),
                        at: start.addingTimeInterval(Double(second)))
    }
    #expect(try #require(estimate.remainingSeconds) > initial)
    let fresh = ScanTimeEstimate(startedAt: start.addingTimeInterval(20), budget: estimate.budget)
    #expect(fresh.fraction == nil)
    #expect(fresh.remainingSeconds == nil)
}

@Test func scannerReportsCompletedDirectoryWork() async throws {
    actor Updates {
        var final: ScanProgress?
        func record(_ progress: ScanProgress) { final = progress }
    }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base.appendingPathComponent("a/b"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try Data([1]).write(to: base.appendingPathComponent("a/file"))
    let updates = Updates()
    _ = try await DiskScanner.scan(url: base) { await updates.record($0) }
    let final = await updates.final
    #expect(final?.enumeratedDirectories == 3)
    #expect(final?.itemCount == 4)
}
