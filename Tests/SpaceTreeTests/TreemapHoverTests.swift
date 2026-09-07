import Foundation
import Observation
import Testing
@testable import SpaceTree

@Test func displayPathsPreserveNamesAndPhysicalRoots() throws {
    var builder = ScanTreeBuilder(rootName: "root", rootURL: URL(fileURLWithPath: "/"))
    var parent = builder.rootID
    for name in ["Volumes", "disk with spaces", "folder%20#?", "日本語", "file.txt"] {
        parent = builder.addNode(parent: parent, name: name, kind: .directory,
                                 allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    }
    let tree = try builder.finalize()
    #expect(tree.displayPath(of: tree.rootID) == "/")
    #expect(tree.displayPath(of: parent) == "/Volumes/disk with spaces/folder%20#?/日本語/file.txt")
    #expect(tree.displayPath(of: parent) == tree.url(of: parent).path)

    var multiple = ScanTreeBuilder(rootName: "Disks", rootURL: URL(fileURLWithPath: "/Volumes"), synthetic: true)
    let disk = multiple.addPhysicalRoot(name: "External", url: URL(fileURLWithPath: "/Volumes/External"), parent: multiple.rootID)
    let file = multiple.addNode(parent: disk, name: "a.txt", kind: .file, allocatedBytes: 1, logicalBytes: 1, modifiedAt: nil, identity: nil)
    let multiTree = try multiple.finalize()
    #expect(multiTree.displayPath(of: multiTree.rootID) == multiTree.url(of: multiTree.rootID).path)
    #expect(multiTree.displayPath(of: file) == "/Volumes/External/a.txt")
}

@Test @MainActor func hoverChangesPathImmediatelyAndClearsOutsideMap() throws {
    var builder = ScanTreeBuilder(rootName: "map", rootURL: URL(fileURLWithPath: "/tmp/map"))
    for name in ["first.txt", "second.txt"] {
        _ = builder.addNode(parent: builder.rootID, name: name, kind: .file,
                            allocatedBytes: 100, logicalBytes: 100, modifiedAt: nil, identity: nil)
    }
    let tree = try builder.finalize()
    let scene = TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID), in: CGRect(x: 0, y: 0, width: 800, height: 500))
    let hover = TreemapHoverState()
    for tile in scene.tiles {
        hover.update(at: CGPoint(x: tile.rect.midX, y: tile.rect.midY), in: scene)
        let entry = scene.entries[tile.entryIndex]
        #expect(hover.details?.nodeID == entry.nodeID)
        #expect(hover.details?.label.hasPrefix(tree.displayPath(of: entry.nodeID) + " · ") == true)
        #expect(hover.details?.highlightRects.contains(tile.rect) == true)
    }
    hover.update(at: CGPoint(x: -1, y: -1), in: scene)
    #expect(hover.details == nil)
    let tile = scene.tiles[0]
    hover.update(at: CGPoint(x: tile.rect.midX, y: tile.rect.midY), in: scene)
    hover.clear()
    #expect(hover.details == nil)
}

@Test @MainActor func optionalHoverLatencyBenchmark() throws {
    guard ProcessInfo.processInfo.environment["SPACETREE_RUN_HOVER_BENCHMARK"] == "1" else { return }
    for (name, count, dominantFile) in [("million equal files", 1_000_000, false), ("100k clustered files", 100_000, true)] {
        var builder = ScanTreeBuilder(rootName: "map", rootURL: URL(fileURLWithPath: "/tmp/map"))
        var parent = builder.rootID
        for depth in 0..<24 {
            parent = builder.addNode(parent: parent, name: "directory-\(depth)", kind: .directory,
                                     allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
        }
        if dominantFile {
            _ = builder.addNode(parent: parent, name: "large.bin", kind: .file, allocatedBytes: 1_000_000_000_000,
                                logicalBytes: 1_000_000_000_000, modifiedAt: nil, identity: nil)
        }
        for index in 0..<count {
            _ = builder.addNode(parent: parent, name: "file-\(index).txt", kind: .file,
                                allocatedBytes: 1, logicalBytes: 1, modifiedAt: nil, identity: nil)
        }
        let tree = try builder.finalize()
        let scene = TreemapScene.build(tree: tree, nodes: [parent], in: CGRect(x: 0, y: 0, width: 1_200, height: 800))
        let hover = TreemapHoverState()
        var samples: [Double] = []
        // Sample tiny tiles as well as visible ones, stressing crowded hit buckets.
        for sample in 0..<2_000 {
            let tile = scene.tiles[(sample * 7919) % scene.tiles.count]
            let point = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
            let start = ContinuousClock.now
            hover.update(at: point, in: scene)
            let duration = start.duration(to: .now).components
            samples.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
            #expect(hover.details?.nodeID == scene.entries[tile.entryIndex].nodeID)
        }
        samples.sort()
        print("Hover event processing (\(name), 24 ancestors, 2000 moves): p50=\(samples[1000])ms p99=\(samples[1980])ms max=\(samples.last!)ms")
        #expect(samples.last! < 100)
    }
}
