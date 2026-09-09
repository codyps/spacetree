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
    let area = overview.tiles.reduce(0) { $0 + $1.shape.reduce(0) { $0 + $1.width * $1.height } }
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

@Test func singleGroupedRegionShowsDirectoryAndResolvesIndividualHover() throws {
    var builder = ScanTreeBuilder(rootName: "Tiny Files", rootURL: URL(fileURLWithPath: "/tmp/tiny"))
    for index in 0..<40_000 {
        _ = builder.addNode(parent: builder.rootID, name: "file-\(index)", kind: .file,
                            allocatedBytes: 1, logicalBytes: 1, modifiedAt: nil, identity: nil)
    }
    let tree = try builder.finalize()
    let scene = try TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID),
                                      in: CGRect(x: 0, y: 0, width: 400, height: 200))
    #expect(scene.tiles.count == 1)
    #expect(scene.tiles.count < 40_000)
    #expect(scene.totalSize == 40_000)
    #expect(scene.representedFileCount == 40_000)
    for tile in scene.tiles {
        #expect(tile.rect == CGRect(x: 0, y: 0, width: 400, height: 200))
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

@Test func groupedTailSortsAfterVisibleFilesEvenWhenItsCombinedAreaIsLarger() throws {
    var builder = ScanTreeBuilder(rootName: "map", rootURL: URL(fileURLWithPath: "/tmp/map"))
    var visible: [NodeID] = []
    for size in [100, 300, 200] {
        visible.append(builder.addNode(parent: builder.rootID, name: "large-\(size)", kind: .file,
                                       allocatedBytes: Int64(size), logicalBytes: Int64(size), modifiedAt: nil, identity: nil))
    }
    for index in 0..<10_000 {
        _ = builder.addNode(parent: builder.rootID, name: "tiny-\(index)", kind: .file,
                            allocatedBytes: 1, logicalBytes: 1, modifiedAt: nil, identity: nil)
    }
    let tree = try builder.finalize()
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
    let scene = try TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID), in: bounds)
    #expect(scene.entries.filter { $0.isAggregate }.count == 1)
    #expect(scene.entries.map(\.nodeID) == [visible[1], visible[2], visible[0], tree.rootID])
    #expect(scene.entries.last?.allocatedBytes == 10_000)
    #expect(scene.totalSize == 10_600)
    #expect(scene.representedFileCount == 10_003)
    let area = scene.tiles.reduce(0) { $0 + $1.shape.reduce(0) { $0 + $1.width * $1.height } }
    #expect(abs(area - bounds.width * bounds.height) < 0.001)
    for tile in scene.tiles {
        let bytes = scene.entries[tile.entryIndex].allocatedBytes
        #expect(abs(tile.shape.reduce(0) { $0 + $1.width * $1.height } / area - Double(bytes) / 10_600) < 0.000001)
    }
}

@Test func groupedTailFollowsRemainingSpaceWithoutOverlap() {
    for bounds in [CGRect(x: 17, y: 23, width: 200, height: 100),
                   CGRect(x: -20, y: 12, width: 100, height: 200)] {
        let weights = [300.0, 200, 100, 10_000]
        let regions = TreemapLayout.regions(weights: weights, groupedTail: true, in: bounds)
        #expect(regions.count == 4)
        let tail = regions[3]
        #expect(tail.count == 2)
        let tailArea = tail.reduce(0) { $0 + $1.width * $1.height }
        let box = tail.reduce(CGRect.null) { $0.union($1) }
        #expect(tailArea < box.width * box.height)
        #expect(tail[0].insetBy(dx: -0.00001, dy: -0.00001).intersects(tail[1]))
        for (index, region) in regions.enumerated() {
            let area = region.reduce(0) { $0 + $1.width * $1.height }
            #expect(abs(area / (bounds.width * bounds.height) - weights[index] / 10_600) < 0.000001)
        }
        let pieces = regions.flatMap { $0 }
        for (index, piece) in pieces.enumerated() {
            #expect(piece.width > 0 && piece.height > 0)
            #expect(bounds.insetBy(dx: -0.00001, dy: -0.00001).contains(piece))
            for other in pieces.dropFirst(index + 1) {
                let overlap = piece.intersection(other)
                #expect(overlap.isNull || overlap.width * overlap.height < 0.000001)
            }
        }
    }
    #expect(TreemapLayout.regions(weights: [100], groupedTail: true,
                                   in: CGRect(x: 0, y: 0, width: 10, height: 10)).count == 1)
    #expect(TreemapLayout.regions(weights: [100, 10], groupedTail: true, in: .zero).isEmpty)
}

@Test func bentGroupedTailResolvesFilesAndDeletionMarkersInBothArms() throws {
    var builder = ScanTreeBuilder(rootName: "map", rootURL: URL(fileURLWithPath: "/tmp/map"))
    for size in [300, 200, 100] {
        _ = builder.addNode(parent: builder.rootID, name: "large-\(size)", kind: .file,
                            allocatedBytes: Int64(size), logicalBytes: Int64(size), modifiedAt: nil, identity: nil)
    }
    for index in 0..<10_000 {
        _ = builder.addNode(parent: builder.rootID, name: "tiny-\(index)", kind: .file,
                            allocatedBytes: 1, logicalBytes: 1, modifiedAt: nil, identity: nil)
    }
    let tree = try builder.finalize()
    let scene = try TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID),
                                      in: CGRect(x: 17, y: 23, width: 200, height: 100))
    let tile = try #require(scene.tiles.last)
    #expect(tile.shape.count == 2)
    #expect(scene.entries.filter { $0.isAggregate }.count == 1)
    #expect(scene.entries[tile.entryIndex].nodeID == tree.rootID)
    #expect(tile.shape.contains(tile.labelRect))
    for piece in tile.shape {
        for fraction in [0.1, 0.5, 0.9] {
            let point = CGPoint(x: piece.minX + piece.width * fraction, y: piece.midY)
            let hit = try #require(scene.hit(at: point))
            #expect(tree.name(of: hit.entry.nodeID).hasPrefix("tiny-"))
            #expect(hit.rect.contains(point))
            let markers = try scene.deletionRects(for: [hit.entry.nodeID])
            #expect(markers.contains(hit.rect))
            #expect(abs(markers.reduce(0) { $0 + $1.width * $1.height } - 20_000.0 / 10_600) < 0.000001)
            for marker in markers { #expect(tile.shape.contains { $0.insetBy(dx: -0.000001, dy: -0.000001).contains(marker) }) }
        }
    }
    for visible in scene.tiles.dropLast() {
        #expect(scene.hit(at: CGPoint(x: visible.rect.midX, y: visible.rect.midY))?.entry.nodeID == scene.entries[visible.entryIndex].nodeID)
    }
}
