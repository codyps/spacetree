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
    let scene = TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID),
                                   in: CGRect(x: 30, y: 20, width: 1_200, height: 800))
    #expect(scene.raster?.width == 1_200)
    #expect(scene.raster?.height == 800)
    for tile in scene.tiles {
        let point = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
        let entry = scene.entries[tile.entryIndex]
        #expect(scene.fillPaths[Int(entry.category.rawValue)].contains(point))
        #expect(scene.hit(at: point)?.entry.nodeID == entry.nodeID)
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
    let scene = TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID), in: bounds, displayScale: 2)
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
