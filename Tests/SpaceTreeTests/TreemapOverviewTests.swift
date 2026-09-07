import Foundation
import Testing
@testable import SpaceTree

@Test func overviewAggregatesTinyFilesWithoutLosingBytesAndDrillsIntoFolder() throws {
    var builder = ScanTreeBuilder(rootName: "map", rootURL: URL(fileURLWithPath: "/tmp/map"))
    _ = builder.addNode(parent: builder.rootID, name: "large", kind: .file,
                        allocatedBytes: 1_000_000_000, logicalBytes: 1_000_000_000, modifiedAt: nil, identity: nil)
    let folder = builder.addNode(parent: builder.rootID, name: "small", kind: .directory,
                                 allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    for index in 0..<100 {
        _ = builder.addNode(parent: folder, name: "file-\(index)", kind: .file,
                            allocatedBytes: 1, logicalBytes: 1, modifiedAt: nil, identity: nil)
    }
    let tree = try builder.finalize()
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
    let overview = try TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID), in: bounds)
    #expect(overview.totalSize == 1_000_000_100)
    #expect(overview.representedFileCount == 101)
    #expect(overview.tiles.count < 101)
    let aggregate = try #require(overview.entries.first { $0.isAggregate })
    #expect(aggregate.nodeID == folder)
    #expect(aggregate.representedFileCount == 100)
    #expect(aggregate.allocatedBytes == 100)
    let area = overview.tiles.reduce(0) { $0 + $1.rect.width * $1.rect.height }
    #expect(abs(area - bounds.width * bounds.height) < 0.001)
    let detail = try TreemapScene.build(tree: tree, nodes: tree.children(of: folder), in: bounds)
    #expect(detail.tiles.count == 100)
    #expect(detail.entries.allSatisfy { !$0.isAggregate })
    #expect(detail.totalSize == 100)
}

@Test func overviewBoundsWideAndDeepTreesIncludingZeroByteFiles() throws {
    var builder = ScanTreeBuilder(rootName: "map", rootURL: URL(fileURLWithPath: "/tmp/map"))
    var parent = builder.rootID
    for index in 0..<100 {
        parent = builder.addNode(parent: parent, name: "folder-\(index)", kind: .directory,
                                 allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    }
    for index in 0..<20_000 {
        _ = builder.addNode(parent: parent, name: "file-\(index)", kind: .file,
                            allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    }
    let tree = try builder.finalize()
    let scene = try TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID),
                                      in: CGRect(x: 0, y: 0, width: 800, height: 500))
    #expect(scene.representedFileCount == 20_000)
    #expect(scene.totalSize == 0)
    #expect(scene.folders.count + scene.tiles.count <= TreemapScene.maximumRegions)
    #expect(scene.entries.contains { $0.isAggregate })
}

@Test func layoutChecksCancellationBeforeAllocatingAndDuringTraversal() async throws {
    var builder = ScanTreeBuilder(rootName: "map", rootURL: URL(fileURLWithPath: "/tmp/map"))
    _ = builder.addNode(parent: builder.rootID, name: "file", kind: .file,
                        allocatedBytes: 1, logicalBytes: 1, modifiedAt: nil, identity: nil)
    let tree = try builder.finalize()
    for beforeStart in [true, false] {
        let task = Task.detached {
            if beforeStart { withUnsafeCurrentTask { $0?.cancel() } }
            return try TreemapScene.build(tree: tree, nodes: [tree.rootID],
                                         in: CGRect(x: 0, y: 0, width: 800, height: 500)) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled layout returned a scene")
        } catch is CancellationError { }
    }
}

@Test @MainActor func supersededBuildExitsBeforeSuccessorStarts() async throws {
    let coordinator = TreemapBuildCoordinator()
    var builder = ScanTreeBuilder(rootName: "empty", rootURL: URL(fileURLWithPath: "/tmp/map"))
    let tree = try builder.finalize()
    let (events, continuation) = AsyncStream<String>.makeStream()
    let first = Task {
        try await coordinator.run {
            continuation.yield("started")
            defer { continuation.yield("exited") }
            // A cooperative CPU job: the successor must cancel and join it.
            while true {
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
    }
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() == "started")
    let second = Task {
        try await coordinator.run {
            continuation.yield("successor")
            return try TreemapScene.build(tree: tree, nodes: [], in: CGRect(x: 0, y: 0, width: 800, height: 500))
        }
    }
    #expect(await iterator.next() == "exited")
    #expect(await iterator.next() == "successor")
    _ = try await second.value
    do {
        _ = try await first.value
        Issue.record("Superseded worker succeeded")
    } catch is CancellationError { }
    continuation.finish()
}

@Test func groupedBlocksStaySmallShowDirectoryAndResolveIndividualHover() throws {
    var builder = ScanTreeBuilder(rootName: "Tiny Files", rootURL: URL(fileURLWithPath: "/tmp/tiny"))
    for index in 0..<40_000 {
        _ = builder.addNode(parent: builder.rootID, name: "file-\(index)", kind: .file,
                            allocatedBytes: 1, logicalBytes: 1, modifiedAt: nil, identity: nil)
    }
    let tree = try builder.finalize()
    let scene = try TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID),
                                      in: CGRect(x: 0, y: 0, width: 400, height: 200))
    #expect(scene.tiles.count > 10)
    #expect(scene.tiles.count < 40_000)
    #expect(scene.totalSize == 40_000)
    #expect(scene.representedFileCount == 40_000)
    for tile in scene.tiles {
        #expect(tile.rect.width * tile.rect.height <= 4_096.01)
        #expect(scene.label(for: scene.entries[tile.entryIndex]).hasPrefix("Tiny Files · "))
    }
    #expect(!scene.labeledTileIndices.isEmpty)
    let tile = try #require(scene.tiles.first)
    var found = Set<NodeID>()
    for x in 0..<8 {
        for y in 0..<8 {
            let point = CGPoint(x: tile.rect.minX + (Double(x) + 0.5) * tile.rect.width / 8,
                                y: tile.rect.minY + (Double(y) + 0.5) * tile.rect.height / 8)
            let hit = try #require(scene.hit(at: point))
            #expect(!hit.entry.isAggregate)
            #expect(tree.kind(of: hit.entry.nodeID) == .file)
            #expect(hit.entry.allocatedBytes == 1)
            #expect(hit.rect.contains(point))
            #expect(abs(hit.rect.width * hit.rect.height - 2) < 0.001)
            found.insert(hit.entry.nodeID)
        }
    }
    #expect(found.count == 64)
}

@Test func largeLaterFoldersKeepTheirInternalStructure() throws {
    var builder = ScanTreeBuilder(rootName: "map", rootURL: URL(fileURLWithPath: "/tmp/map"))
    let first = builder.addNode(parent: builder.rootID, name: "first", kind: .directory,
                                allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    let later = builder.addNode(parent: builder.rootID, name: "later", kind: .directory,
                                allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    let inner = builder.addNode(parent: later, name: "inner", kind: .directory,
                                allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    for index in 0..<20_000 {
        _ = builder.addNode(parent: first, name: "file-\(index)", kind: .file,
                            allocatedBytes: 1, logicalBytes: 1, modifiedAt: nil, identity: nil)
    }
    let file = builder.addNode(parent: inner, name: "visible.txt", kind: .file,
                               allocatedBytes: 20_000, logicalBytes: 20_000, modifiedAt: nil, identity: nil)
    let tree = try builder.finalize()
    let scene = try TreemapScene.build(tree: tree, nodes: [first, later],
                                      in: CGRect(x: 0, y: 0, width: 1200, height: 800), displayScale: 2)
    #expect(scene.folders.contains { $0.nodeID == later })
    #expect(scene.folders.contains { $0.nodeID == inner })
    #expect(scene.entries.contains { $0.nodeID == file && !$0.isAggregate })
    #expect(scene.tiles.count + scene.folders.count <= TreemapScene.maximumRegions)
    #expect(scene.totalSize == 40_000)
}

@Test func deletedVirtualFilesGetTheirExactHitRectangleWithoutRebuilding() throws {
    var builder = ScanTreeBuilder(rootName: "map", rootURL: URL(fileURLWithPath: "/tmp/map"))
    for index in 0..<100 {
        _ = builder.addNode(parent: builder.rootID, name: "file-\(index)", kind: .file,
                            allocatedBytes: 1, logicalBytes: 1, modifiedAt: nil, identity: nil)
    }
    let tree = try builder.finalize()
    let scene = try TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID),
                                      in: CGRect(x: 0, y: 0, width: 10, height: 10))
    let hit = try #require(scene.hit(at: CGPoint(x: 4.2, y: 3.7)))
    #expect(scene.rect(for: hit.entry.nodeID) == nil)
    let markers = try scene.deletionRects(for: [hit.entry.nodeID])
    #expect(markers == [hit.rect])
    #expect(try scene.deletionRects(for: []).isEmpty)
    #expect(scene.representedFileCount == 100)
    #expect(scene.totalSize == 100)
}
