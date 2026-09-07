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
    struct Entry: Identifiable, Sendable {
        let nodeID: NodeID
        let allocatedBytes: Int64
        let category: FileCategory

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
    let labeledFolders: [Folder]
    let regionRects: [NodeID: CGRect]
    let lightEdges: Path
    let darkEdges: Path
    let tree: ScanTree
    let entries: [Entry]
    let tiles: [Tile]
    let fillPaths: [Path]
    let labeledTileIndices: [Int]
    let totalSize: Int64
    private let hitIndex: TreemapHitIndex

    static func build(tree: ScanTree, nodes: [NodeID], in bounds: CGRect) -> TreemapScene {
        var folders: [Folder] = []
        var regionRects: [NodeID: CGRect] = [:]
        var entries: [Entry] = []
        var tiles: [Tile] = []
        let estimatedFileCount = nodes.reduce(0) { $0 + tree.fileCount(of: $1) }
        entries.reserveCapacity(estimatedFileCount)
        tiles.reserveCapacity(estimatedFileCount)

        var pending = Array(arrangedNodes(tree: tree, nodes: nodes, in: bounds).reversed())
        while let region = pending.popLast() {
            regionRects[region.nodeID] = region.rect
            let kind = tree.kind(of: region.nodeID)
            if kind == .directory || kind == .syntheticRoot {
                let header = region.rect.width >= 48 && region.rect.height >= 40
                    ? CGRect(x: region.rect.minX, y: region.rect.minY, width: region.rect.width, height: 20) : nil
                folders.append(Folder(nodeID: region.nodeID, rect: region.rect, header: header))
                let content = CGRect(x: region.rect.minX, y: region.rect.minY + (header?.height ?? 0),
                                     width: region.rect.width, height: region.rect.height - (header?.height ?? 0))
                pending.append(contentsOf: arrangedNodes(
                    tree: tree,
                    nodes: tree.children(of: region.nodeID),
                    in: content
                ).reversed())
                continue
            }

            let entryIndex = entries.count
            entries.append(Entry(
                nodeID: region.nodeID,
                allocatedBytes: tree.allocatedBytes(of: region.nodeID),
                category: FilePalette.category(forExtension: tree.fileExtension(of: region.nodeID))
            ))
            tiles.append(Tile(entryIndex: entryIndex, rect: region.rect))
        }

        var fillPaths = FileCategory.allCases.map { _ in Path() }
        var labeledTileIndices: [Int] = []
        var lightEdges = Path()
        var darkEdges = Path()
        for (tileIndex, tile) in tiles.enumerated() {
            let rect = tile.rect
            if rect.width >= 3 && rect.height >= 3 {
                lightEdges.move(to: CGPoint(x: rect.minX + 0.5, y: rect.maxY - 0.5))
                lightEdges.addLine(to: CGPoint(x: rect.minX + 0.5, y: rect.minY + 0.5))
                lightEdges.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.minY + 0.5))
                darkEdges.move(to: CGPoint(x: rect.minX + 0.5, y: rect.maxY - 0.5))
                darkEdges.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.maxY - 0.5))
                darkEdges.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.minY + 0.5))
            }
            fillPaths[Int(entries[tile.entryIndex].category.rawValue)].addRect(rect)
            if rect.width >= 78, rect.height >= 34 {
                labeledTileIndices.append(tileIndex)
            }
        }
        return TreemapScene(
            folders: folders,
            labeledFolders: folders.filter { $0.header != nil },
            regionRects: regionRects,
            lightEdges: lightEdges,
            darkEdges: darkEdges,
            tree: tree,
            entries: entries,
            tiles: tiles,
            fillPaths: fillPaths,
            labeledTileIndices: labeledTileIndices,
            totalSize: entries.reduce(0) { saturatingSceneAdd($0, $1.allocatedBytes) },
            hitIndex: TreemapHitIndex(tiles: tiles, bounds: bounds)
        )
    }

    private struct NodeRegion {
        let nodeID: NodeID
        let rect: CGRect
    }

    private static func arrangedNodes(
        tree: ScanTree,
        nodes: [NodeID],
        in bounds: CGRect
    ) -> [NodeRegion] {
        var items: [TreemapLayout.Item] = []
        items.reserveCapacity(nodes.count)
        for nodeID in nodes {
            let kind = tree.kind(of: nodeID)
            let isDirectory = kind == .directory || kind == .syntheticRoot
            let fileCount = tree.fileCount(of: nodeID)
            if isDirectory, fileCount == 0 { continue }
            let allocatedBytes = tree.allocatedBytes(of: nodeID)
            let weight = isDirectory
                ? max(Double(allocatedBytes), Double(fileCount))
                : max(1, Double(allocatedBytes))
            items.append(TreemapLayout.Item(id: nodeID, weight: weight))
        }
        items.sort {
            if $0.weight == $1.weight { return $0.id < $1.id }
            return $0.weight > $1.weight
        }
        let rectangles = TreemapLayout.rectangles(for: items, in: bounds)
        return zip(items, rectangles).map { NodeRegion(nodeID: $0.id, rect: $1) }
    }

    func hit(at point: CGPoint) -> Hit? {
        if let folder = labeledFolders.first(where: { $0.header?.contains(point) == true }) {
            return Hit(entry: Entry(nodeID: folder.nodeID, allocatedBytes: tree.allocatedBytes(of: folder.nodeID), category: FilePalette.category(forExtension: "Folder")), rect: folder.rect)
        }
        guard let tileIndex = hitIndex.tileIndex(at: point, tiles: tiles) else { return nil }
        let tile = tiles[tileIndex]
        return Hit(entry: entries[tile.entryIndex], rect: tile.rect)
    }

    func rect(for nodeID: NodeID) -> CGRect? {
        regionRects[nodeID]
    }
}

private struct TreemapHitIndex: Sendable {
    private let bounds: CGRect
    private let columns: Int
    private let rows: Int
    private let buckets: [[Int]]

    init(tiles: [TreemapScene.Tile], bounds: CGRect) {
        self.bounds = bounds
        let aspect = max(0.2, min(5, bounds.width / max(1, bounds.height)))
        let targetBucketCount = max(64, min(4_096, tiles.count / 8))
        columns = max(1, Int(sqrt(Double(targetBucketCount) * aspect)))
        rows = max(1, Int(ceil(Double(targetBucketCount) / Double(columns))))

        var buckets = Array(repeating: [Int](), count: columns * rows)
        for (tileIndex, tile) in tiles.enumerated() {
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
