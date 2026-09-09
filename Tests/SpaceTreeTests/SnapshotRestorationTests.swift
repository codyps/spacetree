import Foundation
import Testing
@testable import SpaceTree

private actor LoadGate {
    private var continuation: CheckedContinuation<ScanSnapshot?, Never>?
    private(set) var started = false
    private(set) var cancelled = false

    func load() async -> ScanSnapshot? {
        started = true
        let result = await withCheckedContinuation { continuation = $0 }
        cancelled = Task.isCancelled
        return result
    }

    func finish(_ snapshot: ScanSnapshot? = nil) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}

@MainActor
@Test func restorationShowsPendingStateAndClearsMissingSnapshot() async {
    let target = ScanTarget(id: UUID().uuidString, url: URL(fileURLWithPath: "/tmp"), name: "Test", kind: .folder)
    let gate = LoadGate()
    target.restoreSnapshot { _, report in
        report("Loading previous scan…")
        return await gate.load()
    }
    #expect(target.state == .restoring)
    while !(await gate.started) { await Task.yield() }
    await gate.finish()
    while target.state == .restoring { await Task.yield() }
    #expect(target.state == .idle)
    #expect(target.tree == nil)
}

@MainActor
@Test func newScanCancelsRestorationAndIgnoresLateResult() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = ScanTarget(id: UUID().uuidString, url: directory, name: "Test", kind: .folder)
    let gate = LoadGate()
    target.restoreSnapshot { _, _ in await gate.load() }
    while !(await gate.started) { await Task.yield() }
    var builder = ScanTreeBuilder(rootName: "Old", rootURL: directory)
    let oldTree = try builder.finalize()
    let snapshot = ScanSnapshot(version: ScanSnapshot.currentVersion, targetID: target.id,
                                tree: oldTree, progress: target.progress, scannedAt: .distantPast,
                                scanDuration: 1, fseventID: 0)
    target.scan()
    target.cancel()
    await gate.finish(snapshot)
    while !(await gate.cancelled) { await Task.yield() }
    await Task.yield()
    #expect(target.state == .idle)
    #expect(target.tree == nil)
}

@Test func cancelledSnapshotDecodeStopsBeforeParsing() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try SnapshotStore.decode(Data())
            Issue.record("Cancelled decode returned")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected cancellation, got \(error)")
        }
    }
    await task.value
}
