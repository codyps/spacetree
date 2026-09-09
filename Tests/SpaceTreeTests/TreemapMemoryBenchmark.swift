import Darwin
import Foundation
import Testing
@testable import SpaceTree

// Opt-in, bounded reproduction: no filesystem scan or user file contents.
@Test func optionalTreemapMemoryBenchmark() throws {
    guard let shape = ProcessInfo.processInfo.environment["SPACETREE_MEMORY_BENCHMARK"] else { return }
    let start = ContinuousClock.now
    func report(_ stage: String) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("Treemap memory [\(shape)] \(stage): elapsed=\(start.duration(to: .now)) peakRSSMiB=\(Double(usage.ru_maxrss) / 1_048_576)")
    }
    var builder = ScanTreeBuilder(rootName: "benchmark", rootURL: URL(fileURLWithPath: "/tmp/treemap-memory"))
    if shape == "clustered" {
        _ = builder.addNode(parent: builder.rootID, name: "dominant.bin", kind: .file,
                            allocatedBytes: 1_000_000_000_000_000, logicalBytes: 1_000_000_000_000_000,
                            modifiedAt: nil, identity: nil)
    }
    let directoryCount = shape == "flat" ? 1 : 100_000
    let filesPerDirectory = 1_000_000 / directoryCount
    for directory in 0..<directoryCount {
        let parent = builder.addNode(parent: builder.rootID, name: "folder-\(directory)", kind: .directory,
                                     allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
        for file in 0..<filesPerDirectory {
            _ = builder.addNode(parent: parent, name: "file-\(file).txt", kind: .file,
                                allocatedBytes: 4_096, logicalBytes: 4_096, modifiedAt: nil, identity: nil)
        }
    }
    let tree = try builder.finalize()
    report("tree ready (storageMiB=\(Double(tree.estimatedStorageBytes) / 1_048_576))")
    var lastStage = ""
    let scene = try TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID),
                                   in: CGRect(x: 0, y: 0, width: 1_200, height: 800), displayScale: 2) {
        if lastStage != $0.stage {
            report($0.stage)
            lastStage = $0.stage
        }
    }
    report("scene ready")
    let subpixel = scene.tiles.filter { $0.rect.width * 2 < 1 || $0.rect.height * 2 < 1 }.count
    print("Treemap geometry: entries=\(scene.entries.count) folders=\(scene.folders.count) subpixelTiles=\(subpixel) entryStride=\(MemoryLayout<TreemapScene.Entry>.stride) tileStride=\(MemoryLayout<TreemapScene.Tile>.stride) folderStride=\(MemoryLayout<TreemapScene.Folder>.stride)")
    #expect(scene.representedFileCount == (shape == "clustered" ? 1_000_001 : 1_000_000))
    #expect(scene.tiles.count + scene.folders.count <= TreemapScene.maximumRegions)
}

@Test func optionalSavedSnapshotLayoutBenchmark() throws {
    guard let path = ProcessInfo.processInfo.environment["SPACETREE_LAYOUT_SNAPSHOT"] else { return }
    let tree = try autoreleasepool {
        try SnapshotStore.decode(Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)).tree
    }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print("Saved snapshot ready: nodes=\(tree.nodeCount) storageMiB=\(Double(tree.estimatedStorageBytes) / 1_048_576) peakRSSMiB=\(Double(usage.ru_maxrss) / 1_048_576)")
    let runs = max(1, Int(ProcessInfo.processInfo.environment["SPACETREE_LAYOUT_RUNS"] ?? "7") ?? 7)
    var scene: TreemapScene!
    var timings: [[Double]] = []
    func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
    let start = ContinuousClock.now
    for run in 0..<runs {
        scene = nil // Do not retain the previous bitmap/index during the next build.
        var stageStart = ContinuousClock.now
        var stages: [Double] = []
        scene = try TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID),
                                      in: CGRect(x: 0, y: 0, width: 1200, height: 800), displayScale: 2) { progress in
            if progress.stage == "Rendering tree…" || progress.stage == "Finishing tree…" {
                let now = ContinuousClock.now
                stages.append(milliseconds(stageStart.duration(to: now)))
                stageStart = now
            }
        }
        stages.append(milliseconds(stageStart.duration(to: .now)))
        timings.append(stages)
        print("Grid profile run \(run): layout/index=\(stages[0])ms raster=\(stages[1])ms finishing=\(stages[2])ms")
    }
    let medians = (0..<3).map { stage in timings.map { $0[stage] }.sorted()[runs / 2] }
    print("Grid profile median (\(runs) runs): layout/index=\(medians[0])ms raster=\(medians[1])ms finishing=\(medians[2])ms")
    getrusage(RUSAGE_SELF, &usage)
    print("Saved snapshot scene: elapsed=\(start.duration(to: .now)) regions=\(scene.tiles.count + scene.folders.count) representedFiles=\(scene.representedFileCount) peakRSSMiB=\(Double(usage.ru_maxrss) / 1_048_576)")
    if let tile = scene.tiles.last(where: { scene.entries[$0.entryIndex].virtualRange != nil }),
       let hit = scene.hit(at: CGPoint(x: tile.rect.midX, y: tile.rect.midY)) {
        let markerStart = ContinuousClock.now
        let markers = try scene.deletionRects(for: [hit.entry.nodeID])
        print("Saved snapshot deletion marker near end of virtual index: \(markerStart.duration(to: .now))")
        #expect(markers == [hit.rect])
    }
    #expect(scene.representedFileCount == tree.fileCount(of: tree.rootID))
    #expect(scene.totalSize == tree.allocatedBytes(of: tree.rootID))
    #expect(scene.tiles.count + scene.folders.count <= TreemapScene.maximumRegions)
}
