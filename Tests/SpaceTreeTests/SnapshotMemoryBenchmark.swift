import Darwin
import Foundation
import Testing
@testable import SpaceTree

// Run each mode in a fresh release test process so peak RSS is comparable.
@Test func optionalSnapshotMemoryBenchmark() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["SPACETREE_MEMORY_SNAPSHOT"] else { return }
    let mode = environment["SPACETREE_SNAPSHOT_MODE"] ?? "load"
    let start = ContinuousClock.now
    func report(_ stage: String) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var heap = malloc_statistics_t()
        malloc_zone_statistics(nil, &heap)
        print("Snapshot memory [\(mode)] \(stage): elapsed=\(start.duration(to: .now)) peakRSSMiB=\(Double(usage.ru_maxrss) / 1_048_576) heapInUseMiB=\(Double(heap.size_in_use) / 1_048_576)")
    }
    report("start")
    let snapshot = try autoreleasepool {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        report("input read")
        let snapshot = try SnapshotStore.decode(data)
        report("decoded (input retained)")
        return snapshot
    }
    report("load returned nodes=\(snapshot.tree.nodeCount) storageMiB=\(Double(snapshot.tree.estimatedStorageBytes) / 1_048_576)")
    if mode == "save" {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        try SnapshotStore.write(snapshot, to: destination)
        report("streamed to disk")
    }
    if mode == "grid" {
        let scene = try TreemapScene.build(tree: snapshot.tree, nodes: snapshot.tree.children(of: snapshot.tree.rootID),
                                          in: CGRect(x: 0, y: 0, width: 1200, height: 800), displayScale: 2)
        report("grid ready regions=\(scene.tiles.count + scene.folders.count)")
        withExtendedLifetime(scene) {}
    }
    withExtendedLifetime(snapshot) {}
}


@Test func optionalScanMemoryBenchmark() async throws {
    guard let path = ProcessInfo.processInfo.environment["SPACETREE_MEMORY_SCAN"] else { return }
    let tree = try await DiskScanner.scan(url: URL(fileURLWithPath: path)) { progress in
        if let finishing = progress.finishing, finishing.completed == 0 {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            print("Scan memory \(finishing.stage): peakRSSMiB=\(Double(usage.ru_maxrss) / 1_048_576)")
        }
    }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    var heap = malloc_statistics_t()
    malloc_zone_statistics(nil, &heap)
    print("Scan memory complete: nodes=\(tree.nodeCount) storageMiB=\(Double(tree.estimatedStorageBytes) / 1_048_576) peakRSSMiB=\(Double(usage.ru_maxrss) / 1_048_576) heapInUseMiB=\(Double(heap.size_in_use) / 1_048_576)")
    withExtendedLifetime(tree) {}
}

// Prepare separately, then run only this test in a fresh release process:
// SPACETREE_LOAD_REGRESSION=/tmp/load.spacetree SPACETREE_LOAD_PREPARE=1 swift test ... --filter snapshotLoadPeakMemoryRegression
// SPACETREE_LOAD_REGRESSION=/tmp/load.spacetree swift test ... --filter snapshotLoadPeakMemoryRegression
@Test func snapshotLoadPeakMemoryRegression() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["SPACETREE_LOAD_REGRESSION"] else { return }
    let url = URL(fileURLWithPath: path)
    if environment["SPACETREE_LOAD_PREPARE"] == "1" {
        var builder = ScanTreeBuilder(rootName: "memory", rootURL: URL(fileURLWithPath: "/tmp/memory"))
        for index in 0..<131_072 {
            _ = builder.addNode(parent: builder.rootID, name: "\(index)-" + String(repeating: "x", count: 1024),
                                kind: .file, allocatedBytes: 4096, logicalBytes: 4096, modifiedAt: nil, identity: nil)
        }
        let snapshot = ScanSnapshot(version: ScanSnapshot.currentVersion, targetID: "memory-regression",
                                    tree: try builder.finalize(),
                                    progress: ScanProgress(currentPath: "", itemCount: 131_073, bytesFound: 0, unreadableCount: 0),
                                    scannedAt: .distantPast, scanDuration: 1, fseventID: 0)
        try SnapshotStore.write(snapshot, to: url)
        return
    }
    var before = rusage()
    getrusage(RUSAGE_SELF, &before)
    // Force mapping for reproducibility; production uses mappedIfSafe.
    let data = try Data(contentsOf: url, options: .alwaysMapped)
    var heapBefore = malloc_statistics_t()
    malloc_zone_statistics(nil, &heapBefore)
    let initialHeap = heapBefore.size_in_use
    let heapBudget = data.count + 32 * 1_048_576
    let snapshot = try SnapshotStore.decode(data) { stage in
        if stage == "Validating previous scan…" {
            var heap = malloc_statistics_t()
            malloc_zone_statistics(nil, &heap)
            let growth = Int(heap.size_in_use) - Int(initialHeap)
            print("Snapshot load regression: heapGrowthMiB=\(Double(growth) / 1_048_576) heapBudgetMiB=\(Double(heapBudget) / 1_048_576)")
            #expect(growth <= heapBudget)
        }
    }
    var after = rusage()
    getrusage(RUSAGE_SELF, &after)
    let increase = after.ru_maxrss - before.ru_maxrss
    // Allow the mapped file, final tree, and 32 MiB for validation/runtime work.
    // The heap check above catches copies even if macOS shares physical pages.
    let budget = data.count + Int(snapshot.tree.estimatedStorageBytes) + 32 * 1_048_576
    print("Snapshot load regression: peakIncreaseMiB=\(Double(increase) / 1_048_576) budgetMiB=\(Double(budget) / 1_048_576)")
    #expect(snapshot.tree.nodeCount == 131_073)
    #expect(data.count > 128 * 1_048_576)
    #expect(increase <= budget)
    withExtendedLifetime((data, snapshot)) {}
}
