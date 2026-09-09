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
