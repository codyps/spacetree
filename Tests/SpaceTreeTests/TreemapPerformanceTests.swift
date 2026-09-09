import Foundation
import SwiftUI
import Testing
@testable import SpaceTree

@Test func treemapPathsPreserveAllFileRegions() throws {
    var builder = ScanTreeBuilder(rootName: "map", rootURL: URL(fileURLWithPath: "/tmp/map"))
    for index in 0..<2_000 {
        _ = builder.addNode(parent: builder.rootID, name: "file-\(index).\(index.isMultiple(of: 2) ? "jpg" : "txt")",
                            kind: .file, allocatedBytes: Int64(index + 1), logicalBytes: Int64(index + 1),
                            modifiedAt: nil, identity: nil)
    }
    let tree = try builder.finalize()
    let scene = try TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID),
                                   in: CGRect(x: 30, y: 20, width: 1_200, height: 800))
    #expect(scene.raster?.width == 1_200)
    #expect(scene.raster?.height == 800)
    for tile in scene.tiles {
        let point = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
        let entry = scene.entries[tile.entryIndex]
        let hit = try #require(scene.hit(at: point))
        if !entry.isAggregate { #expect(hit.entry.nodeID == entry.nodeID) }
        #expect(hit.rect.contains(point))
        #expect(!hit.entry.isAggregate)
    }
    #expect(scene.hit(at: .zero) == nil)
}


@Test func treemapRasterMatchesTileColorsAtDisplayScale() throws {
    var builder = ScanTreeBuilder(rootName: "map", rootURL: URL(fileURLWithPath: "/tmp/map"))
    for name in ["photo.jpg", "notes.txt", "video.mp4"] {
        _ = builder.addNode(parent: builder.rootID, name: name, kind: .file,
                            allocatedBytes: 100, logicalBytes: 100, modifiedAt: nil, identity: nil)
    }
    let tree = try builder.finalize()
    let bounds = CGRect(x: 30, y: 20, width: 120, height: 160)
    let scene = try TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID), in: bounds, displayScale: 2)
    let image = try #require(scene.raster)
    #expect(image.width == 240)
    #expect(image.height == 320)
    let data = try #require(image.dataProvider?.data)
    let bytes = try #require(CFDataGetBytePtr(data))
    for tile in scene.tiles {
        let x = Int((tile.rect.midX - bounds.minX) * 2)
        let y = Int((tile.rect.midY - bounds.minY) * 2)
        let offset = y * image.bytesPerRow + x * 4
        let components = try #require(FilePalette.color(for: scene.entries[tile.entryIndex].category).cgColor?.components)
        for channel in 0..<3 {
            #expect(abs(Int(bytes[offset + channel]) - Int((components[channel] * 255).rounded())) <= 2)
        }
        #expect(bytes[offset + 3] == 255)
    }
}

@Test func treemapProgressCountsNestedFilesAndReportsRendering() throws {
    var builder = ScanTreeBuilder(rootName: "map", rootURL: URL(fileURLWithPath: "/tmp/map"))
    let folder = builder.addNode(parent: builder.rootID, name: "nested", kind: .directory,
                                 allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    for index in 0..<2_050 {
        _ = builder.addNode(parent: folder, name: "file-\(index)", kind: .file,
                            allocatedBytes: 1, logicalBytes: 1, modifiedAt: nil, identity: nil)
    }
    let tree = try builder.finalize()
    var updates: [TreemapScene.BuildProgress] = []
    let scene = try TreemapScene.build(tree: tree, nodes: [folder],
                                   in: CGRect(x: 0, y: 0, width: 800, height: 600)) {
        updates.append($0)
    }
    for stage in ["Laying out tree…"] {
        let progress = updates.filter { $0.stage == stage }
        #expect(progress.first?.completed == 0)
        #expect(progress.last?.completed == scene.tiles.count)
        #expect(progress.last?.fraction == 1)
        #expect(progress.contains { $0.completed > 0 && $0.completed < 2_050 })
        #expect(progress.allSatisfy { $0.total == 2_050 })
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.completed <= $1.completed })
    }
    #expect(updates.suffix(2).map(\.stage) == ["Rendering tree…", "Finishing tree…"])
    #expect(updates.suffix(2).allSatisfy { $0.fraction == nil })
}

@Test func gridSiblingTraversalIsRestartableAndIteratorsAreIndependent() throws {
    var builder = ScanTreeBuilder(rootName: "map", rootURL: URL(fileURLWithPath: "/tmp/map"))
    let empty = builder.addNode(parent: builder.rootID, name: "empty", kind: .directory,
                                allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    for index in 0..<100 {
        _ = builder.addNode(parent: builder.rootID, name: "file-\(index)", kind: .file,
                            allocatedBytes: Int64(index), logicalBytes: Int64(index), modifiedAt: nil, identity: nil)
    }
    let tree = try builder.finalize()
    let children = tree.childIDs(of: tree.rootID)
    let expected = tree.children(of: tree.rootID)
    #expect(Array(children) == expected)
    #expect(Array(children) == expected)
    var first = children.makeIterator()
    var second = children.makeIterator()
    #expect(first.next() == expected[0])
    #expect(first.next() == expected[1])
    #expect(second.next() == expected[0])
    #expect(Array(tree.childIDs(of: empty)).isEmpty)
}

@Test func gridOnlyDebouncesSizeChangesWithinTheSameContent() throws {
    var builder = ScanTreeBuilder(rootName: "map", rootURL: URL(fileURLWithPath: "/tmp/map"))
    let tree = try builder.finalize()
    func request(_ size: CGFloat = 800, nodes: [NodeID] = [], scale: CGFloat = 2) -> LayoutRequest {
        LayoutRequest(tree: tree, nodeIDs: nodes, size: CGSize(width: size, height: 600), displayScale: scale)
    }
    let original = request()
    #expect(!original.isResize(of: nil))
    #expect(!original.isResize(of: original))
    #expect(request(900).isResize(of: original))
    #expect(!request(900, nodes: [tree.rootID]).isResize(of: original))
    #expect(!request(900, scale: 1).isResize(of: original))
    let otherTree = try builder.finalize()
    let replacement = LayoutRequest(tree: otherTree, nodeIDs: [], size: CGSize(width: 900, height: 600), displayScale: 2)
    #expect(!replacement.isResize(of: original))
}
