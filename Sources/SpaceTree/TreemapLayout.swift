import SwiftUI

enum TreemapLayout {
    struct Item: Equatable, Sendable {
        let id: NodeID
        let weight: Double
    }

    static func rectangles(for items: [Item], in bounds: CGRect) -> [CGRect] {
        rectangles(for: items, in: bounds, weight: \.weight)
    }

    static func rectangles<Element>(
        for items: [Element],
        in bounds: CGRect,
        weight: (Element) -> Double
    ) -> [CGRect] {
        guard !items.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
        let total = items.reduce(0) { $0 + max(1, weight($1)) }
        let scale = Double(bounds.width * bounds.height) / total
        var nextIndex = 0
        var result = Array(repeating: CGRect.zero, count: items.count)
        var available = bounds
        var row: [(Int, Double)] = []
        var rowMetrics = RowMetrics()

        while nextIndex < items.count {
            let next = (nextIndex, max(1, weight(items[nextIndex])) * scale)
            let side = Double(min(available.width, available.height))
            let candidateMetrics = rowMetrics.adding(next.1)
            if row.isEmpty || worstAspect(of: candidateMetrics, on: side) <= worstAspect(of: rowMetrics, on: side) {
                row.append(next)
                rowMetrics = candidateMetrics
                nextIndex += 1
            } else {
                layout(row: row, totalArea: rowMetrics.sum, in: &available, result: &result)
                row.removeAll(keepingCapacity: true)
                rowMetrics = RowMetrics()
            }
        }
        if !row.isEmpty {
            layout(row: row, totalArea: rowMetrics.sum, in: &available, result: &result)
        }
        return result
    }

    private struct RowMetrics {
        var sum = 0.0
        var largest = 0.0
        var smallest = Double.infinity

        func adding(_ area: Double) -> RowMetrics {
            RowMetrics(
                sum: sum + area,
                largest: max(largest, area),
                smallest: min(smallest, area)
            )
        }
    }

    private static func worstAspect(of row: RowMetrics, on side: Double) -> Double {
        guard row.sum > 0, row.smallest > 0, side > 0 else { return .infinity }
        let sideSquared = side * side
        return max(
            (sideSquared * row.largest) / (row.sum * row.sum),
            (row.sum * row.sum) / (sideSquared * row.smallest)
        )
    }

    private static func layout(
        row: [(Int, Double)],
        totalArea: Double,
        in available: inout CGRect,
        result: inout [CGRect]
    ) {
        if available.width >= available.height {
            let stripWidth = totalArea / Double(available.height)
            var y = Double(available.minY)
            for (index, pair) in row.enumerated() {
                let height = index == row.count - 1 ? Double(available.maxY) - y : pair.1 / stripWidth
                result[pair.0] = CGRect(x: available.minX, y: y, width: stripWidth, height: height)
                y += height
            }
            available.origin.x += stripWidth
            available.size.width = max(0, available.width - stripWidth)
        } else {
            let stripHeight = totalArea / Double(available.width)
            var x = Double(available.minX)
            for (index, pair) in row.enumerated() {
                let width = index == row.count - 1 ? Double(available.maxX) - x : pair.1 / stripHeight
                result[pair.0] = CGRect(x: x, y: available.minY, width: width, height: stripHeight)
                x += width
            }
            available.origin.y += stripHeight
            available.size.height = max(0, available.height - stripHeight)
        }
    }
}

struct TreemapScene: Sendable {
    static let maximumRegions = 16_384
    let id = UUID()

    struct Entry: Identifiable, Sendable {
        let nodeID: NodeID
        let allocatedBytes: Int64
        let category: FileCategory
        var representedFileCount: Int = 1
        // Aggregates target their containing folder, never an arbitrary file.
        var isAggregate = false
        var id: NodeID { nodeID }
    }
    struct Tile: Sendable {
        let entryIndex: Int
        let rect: CGRect
    }
    struct Hit: Sendable {
        let entry: Entry
        let rect: CGRect
    }
    struct Folder: Sendable {
        let nodeID: NodeID
        let rect: CGRect
        let header: CGRect?
    }
    let folders: [Folder]
    var labeledFolders: [Folder] { folders }
    let raster: CGImage?
    let tree: ScanTree
    let entries: [Entry]
    let tiles: [Tile]
    let labeledTileIndices: [Int]
    let totalSize: Int64
    let representedFileCount: Int
    // Geometry lives in tiles/folders; the lookup stores only an index.
    private let tileLookup: [NodeID: Int]
    private let folderLookup: [NodeID: Int]
    private let hitIndex: TreemapHitIndex

    struct BuildProgress: Sendable {
        let stage: String
        var completed: Int = 0
        var total: Int? = nil
        var fraction: Double? {
            total.map { min(1, Double(completed) / Double(max(1, $0))) }
        }
    }

    static func build(
        tree: ScanTree, nodes: [NodeID], in bounds: CGRect, displayScale: CGFloat = 1,
        onProgress: (BuildProgress) -> Void = { _ in }
    ) throws -> TreemapScene {
        try Task.checkCancellation()
        let scale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
        var folders: [Folder] = []
        var entries: [Entry] = []
        var tiles: [Tile] = []
        var tileLookup: [NodeID: Int] = [:]
        var folderLookup: [NodeID: Int] = [:]
        let totalFiles = nodes.reduce(0) { $0 + tree.fileCount(of: $1) }
        var completed = 0
        onProgress(BuildProgress(stage: "Laying out tree…", total: totalFiles))
        let owner = nodes.first.flatMap { tree.parent(of: $0) } ?? tree.rootID
        var pending = Array(try arrangedNodes(tree: tree, nodes: nodes, owner: owner,
                                              in: bounds, scale: scale, limit: maximumRegions).reversed())
        // Includes pending, emitted, and expanded regions, so deep trees are bounded too.
        var remaining = maximumRegions - pending.count
        while let region = pending.popLast() {
            try Task.checkCancellation()
            let kind = tree.kind(of: region.entry.nodeID)
            let isDirectory = kind == .directory || kind == .syntheticRoot
            if !region.entry.isAggregate, isDirectory,
               region.rect.width * scale >= 4, region.rect.height * scale >= 4,
               remaining > 0, region.depth < 64 {
                let header = region.rect.width >= 48 && region.rect.height >= 40
                    ? CGRect(x: region.rect.minX, y: region.rect.minY, width: region.rect.width, height: 20) : nil
                // Retain ancestors for highlighting, but never a second rectangle dictionary.
                folderLookup[region.entry.nodeID] = folders.count
                folders.append(Folder(nodeID: region.entry.nodeID, rect: region.rect, header: header))
                let content = CGRect(x: region.rect.minX, y: region.rect.minY + (header?.height ?? 0),
                                     width: region.rect.width, height: region.rect.height - (header?.height ?? 0))
                let children = try arrangedNodes(tree: tree, nodes: tree.childIDs(of: region.entry.nodeID),
                                                 owner: region.entry.nodeID, in: content, scale: scale,
                                                 limit: remaining, depth: region.depth + 1)
                remaining -= children.count
                pending.append(contentsOf: children.reversed())
                continue
            }
            var entry = region.entry
            if isDirectory { entry.isAggregate = true }
            if !entry.isAggregate { entry = Entry(nodeID: entry.nodeID, allocatedBytes: entry.allocatedBytes,
                                                  category: FilePalette.category(forExtension: tree.fileExtension(of: entry.nodeID))) }
            tileLookup[entry.nodeID] = tiles.count
            entries.append(entry)
            tiles.append(Tile(entryIndex: entries.count - 1, rect: region.rect))
            completed += entry.representedFileCount
            if tiles.count.isMultiple(of: 256) {
                onProgress(BuildProgress(stage: "Laying out tree…", completed: completed, total: totalFiles))
            }
        }
        onProgress(BuildProgress(stage: "Laying out tree…", completed: completed, total: totalFiles))
        onProgress(BuildProgress(stage: "Rendering tree…"))
        let raster = try rasterize(entries: entries, tiles: tiles, in: bounds, scale: scale)
        onProgress(BuildProgress(stage: "Finishing tree…"))
        let hitIndex = try TreemapHitIndex(tiles: tiles, bounds: bounds)
        return TreemapScene(folders: folders, raster: raster, tree: tree, entries: entries, tiles: tiles,
                            labeledTileIndices: tiles.indices.filter { tiles[$0].rect.width >= 78 && tiles[$0].rect.height >= 34 },
                            totalSize: entries.reduce(0) { saturatingSceneAdd($0, $1.allocatedBytes) },
                            representedFileCount: completed, tileLookup: tileLookup, folderLookup: folderLookup, hitIndex: hitIndex)
    }

    // Draw each bounded tile directly. No category rectangle arrays or retained CGPaths.
    private static func rasterize(entries: [Entry], tiles: [Tile], in bounds: CGRect, scale: CGFloat) throws -> CGImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let width = ceil(bounds.width * scale), height = ceil(bounds.height * scale)
        guard width.isFinite, height.isFinite, width * height <= 16_000_000,
              let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setShouldAntialias(false)
        let colors = FileCategory.allCases.map { FilePalette.color(for: $0).cgColor! }
        for (index, tile) in tiles.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            context.setFillColor(colors[Int(entries[tile.entryIndex].category.rawValue)])
            context.fill(tile.rect)
        }
        context.setShouldAntialias(true)
        context.setLineWidth(1)
        for (index, tile) in tiles.enumerated() where tile.rect.width >= 3 && tile.rect.height >= 3 {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let rect = tile.rect
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.30))
            context.move(to: CGPoint(x: rect.minX + 0.5, y: rect.maxY - 0.5))
            context.addLine(to: CGPoint(x: rect.minX + 0.5, y: rect.minY + 0.5))
            context.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.minY + 0.5))
            context.strokePath()
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
            context.move(to: CGPoint(x: rect.minX + 0.5, y: rect.maxY - 0.5))
            context.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.maxY - 0.5))
            context.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.minY + 0.5))
            context.strokePath()
        }
        try Task.checkCancellation()
        return context.makeImage()
    }

    private struct NodeRegion {
        var entry: Entry
        let rect: CGRect
        var depth: Int = 0
    }
    private struct WeightedEntry {
        let entry: Entry
        let weight: Double
    }

    private static func arrangedNodes<IDs: Sequence>(
        tree: ScanTree, nodes: IDs, owner: NodeID, in bounds: CGRect,
        scale: CGFloat, limit: Int, depth: Int = 0
    ) throws -> [NodeRegion] where IDs.Element == NodeID {
        guard bounds.width > 0, bounds.height > 0, limit > 0 else { return [] }
        // Two linear passes over sibling IDs, with no full sibling array or unbounded sort.
        func weight(_ id: NodeID) -> Double {
            max(Double(tree.allocatedBytes(of: id)), Double(tree.fileCount(of: id)))
        }
        var total = 0.0
        for (index, id) in nodes.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            if tree.fileCount(of: id) > 0 { total += weight(id) }
        }
        guard total > 0 else { return [] }
        let pixels = bounds.width * bounds.height * scale * scale
        // Reserve one slot for the aggregate. Qualifying candidates are mathematically
        // bounded by limit - 1; four physical pixels is the minimum useful tile area.
        let cutoff = max(total / Double(max(1, limit - 1)), total * 4 / max(1, pixels))
        var items: [WeightedEntry] = []
        var smallWeight = 0.0
        var smallBytes: Int64 = 0
        var smallFiles = 0
        var smallNode: NodeID?
        var smallItemCount = 0
        for (index, id) in nodes.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let count = tree.fileCount(of: id)
            guard count > 0 else { continue }
            let bytes = tree.allocatedBytes(of: id), value = weight(id)
            if limit > 1, value >= cutoff, items.count < limit - 1 {
                items.append(WeightedEntry(entry: Entry(nodeID: id, allocatedBytes: bytes, category: .other,
                                                         representedFileCount: count), weight: value))
            } else {
                smallNode = id
                smallItemCount += 1
                smallWeight += value
                smallBytes = saturatingSceneAdd(smallBytes, bytes)
                smallFiles += count
            }
        }
        if smallFiles > 0 {
            let destination: NodeID
            if smallItemCount == 1, let smallNode,
               tree.kind(of: smallNode) == .directory || tree.kind(of: smallNode) == .syntheticRoot {
                destination = smallNode
            } else { destination = owner }
            items.append(WeightedEntry(entry: Entry(nodeID: destination, allocatedBytes: smallBytes, category: .other,
                                                     representedFileCount: smallFiles, isAggregate: true), weight: smallWeight))
        }
        try Task.checkCancellation()
        items.sort { $0.weight == $1.weight ? $0.entry.nodeID < $1.entry.nodeID : $0.weight > $1.weight }
        let rectangles = TreemapLayout.rectangles(for: items, in: bounds, weight: \.weight)
        try Task.checkCancellation()
        return zip(items, rectangles).map { NodeRegion(entry: $0.entry, rect: $1, depth: depth) }
    }

    func hit(at point: CGPoint) -> Hit? {
        if let folder = folders.first(where: { $0.header?.contains(point) == true }) {
            return Hit(entry: Entry(nodeID: folder.nodeID, allocatedBytes: tree.allocatedBytes(of: folder.nodeID), category: .other), rect: folder.rect)
        }
        guard let index = hitIndex.tileIndex(at: point, tiles: tiles) else { return nil }
        return Hit(entry: entries[tiles[index].entryIndex], rect: tiles[index].rect)
    }
    func rect(for nodeID: NodeID) -> CGRect? {
        if let index = folderLookup[nodeID] { return folders[index].rect }
        return tileLookup[nodeID].map { tiles[$0].rect }
    }
}
private struct TreemapHitIndex: Sendable {
    private let bounds: CGRect
    private let columns: Int
    private let rows: Int
    private let buckets: [[Int]]

    init(tiles: [TreemapScene.Tile], bounds: CGRect) throws {
        self.bounds = bounds
        let aspect = max(0.2, min(5, bounds.width / max(1, bounds.height)))
        let targetBucketCount = max(64, min(4_096, tiles.count / 8))
        columns = max(1, Int(sqrt(Double(targetBucketCount) * aspect)))
        rows = max(1, Int(ceil(Double(targetBucketCount) / Double(columns))))

        var buckets = Array(repeating: [Int](), count: columns * rows)
        for (tileIndex, tile) in tiles.enumerated() {
            if tileIndex.isMultiple(of: 256) { try Task.checkCancellation() }
            let range = Self.bucketRange(for: tile.rect, bounds: bounds, columns: columns, rows: rows)
            for row in range.minRow...range.maxRow {
                for column in range.minColumn...range.maxColumn {
                    buckets[row * columns + column].append(tileIndex)
                }
            }
        }
        self.buckets = buckets
    }

    func tileIndex(at point: CGPoint, tiles: [TreemapScene.Tile]) -> Int? {
        guard bounds.contains(point), bounds.width > 0, bounds.height > 0 else { return nil }
        let column = min(columns - 1, max(0, Int((point.x - bounds.minX) / bounds.width * Double(columns))))
        let row = min(rows - 1, max(0, Int((point.y - bounds.minY) / bounds.height * Double(rows))))
        return buckets[row * columns + column].first { tiles[$0].rect.contains(point) }
    }

    private static func bucketRange(
        for rect: CGRect,
        bounds: CGRect,
        columns: Int,
        rows: Int
    ) -> (minColumn: Int, maxColumn: Int, minRow: Int, maxRow: Int) {
        let minColumn = min(columns - 1, max(0, Int((rect.minX - bounds.minX) / max(1, bounds.width) * Double(columns))))
        let maxColumn = min(columns - 1, max(0, Int((rect.maxX - bounds.minX) / max(1, bounds.width) * Double(columns))))
        let minRow = min(rows - 1, max(0, Int((rect.minY - bounds.minY) / max(1, bounds.height) * Double(rows))))
        let maxRow = min(rows - 1, max(0, Int((rect.maxY - bounds.minY) / max(1, bounds.height) * Double(rows))))
        return (minColumn, maxColumn, minRow, maxRow)
    }
}

private func saturatingSceneAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? .max : result.partialValue
}
