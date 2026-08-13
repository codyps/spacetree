import CoreGraphics

enum TreemapLayout {
    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let weight: Double
    }

    static func rectangles(for items: [Item], in bounds: CGRect) -> [String: CGRect] {
        guard !items.isEmpty, bounds.width > 0, bounds.height > 0 else { return [:] }
        let positiveItems = items.map { Item(id: $0.id, weight: max(1, $0.weight)) }
        let total = positiveItems.reduce(0) { $0 + $1.weight }
        let scale = Double(bounds.width * bounds.height) / total
        let remaining = positiveItems.map { ($0, $0.weight * scale) }
        var nextIndex = 0
        var result: [String: CGRect] = [:]
        var available = bounds
        var row: [(Item, Double)] = []

        while nextIndex < remaining.count {
            let next = remaining[nextIndex]
            let side = Double(min(available.width, available.height))
            if row.isEmpty || worstAspect(of: row + [next], on: side) <= worstAspect(of: row, on: side) {
                row.append(next)
                nextIndex += 1
            } else {
                layout(row: row, in: &available, result: &result)
                row.removeAll(keepingCapacity: true)
            }
        }
        if !row.isEmpty { layout(row: row, in: &available, result: &result) }
        return result
    }

    private static func worstAspect(of row: [(Item, Double)], on side: Double) -> Double {
        guard !row.isEmpty, side > 0 else { return .infinity }
        let sum = row.reduce(0) { $0 + $1.1 }
        let largest = row.map(\.1).max() ?? 0
        let smallest = row.map(\.1).min() ?? 0
        guard smallest > 0 else { return .infinity }
        let sideSquared = side * side
        return max((sideSquared * largest) / (sum * sum), (sum * sum) / (sideSquared * smallest))
    }

    private static func layout(
        row: [(Item, Double)],
        in available: inout CGRect,
        result: inout [String: CGRect]
    ) {
        let totalArea = row.reduce(0) { $0 + $1.1 }
        if available.width >= available.height {
            let stripWidth = totalArea / Double(available.height)
            var y = Double(available.minY)
            for (index, pair) in row.enumerated() {
                let height = index == row.count - 1
                    ? Double(available.maxY) - y
                    : pair.1 / stripWidth
                result[pair.0.id] = CGRect(x: available.minX, y: y, width: stripWidth, height: height)
                y += height
            }
            available.origin.x += stripWidth
            available.size.width = max(0, available.width - stripWidth)
        } else {
            let stripHeight = totalArea / Double(available.width)
            var x = Double(available.minX)
            for (index, pair) in row.enumerated() {
                let width = index == row.count - 1
                    ? Double(available.maxX) - x
                    : pair.1 / stripHeight
                result[pair.0.id] = CGRect(x: x, y: available.minY, width: width, height: stripHeight)
                x += width
            }
            available.origin.y += stripHeight
            available.size.height = max(0, available.height - stripHeight)
        }
    }
}

struct TreemapScene: Sendable {
    struct Entry: Identifiable, Sendable {
        let node: FileNode

        var id: String { node.id }
    }

    struct Tile: Sendable {
        let entryIndex: Int
        let rect: CGRect
    }

    let entries: [Entry]
    let tiles: [Tile]
    let totalSize: Int64
    private let hitIndex: TreemapHitIndex

    static func build(nodes: [FileNode], in bounds: CGRect) -> TreemapScene {
        var stack = Array(nodes.reversed())
        var entries: [Entry] = []
        entries.reserveCapacity(nodes.reduce(0) { $0 + max(1, $1.fileCount) })

        while let node = stack.popLast() {
            if node.isDirectory {
                stack.append(contentsOf: node.children.reversed())
            } else {
                entries.append(Entry(node: node))
            }
        }
        entries.sort {
            if $0.node.size == $1.node.size { return $0.id < $1.id }
            return $0.node.size > $1.node.size
        }

        let rectangles = TreemapLayout.rectangles(
            for: entries.map { TreemapLayout.Item(id: $0.id, weight: Double($0.node.size)) },
            in: bounds
        )
        let tiles = entries.enumerated().compactMap { index, entry in
            rectangles[entry.id].map { Tile(entryIndex: index, rect: $0) }
        }
        return TreemapScene(
            entries: entries,
            tiles: tiles,
            totalSize: entries.reduce(0) { $0 + $1.node.size },
            hitIndex: TreemapHitIndex(tiles: tiles, bounds: bounds)
        )
    }

    func entry(at point: CGPoint) -> Entry? {
        guard let index = hitIndex.tileIndex(at: point, tiles: tiles) else { return nil }
        return entries[tiles[index].entryIndex]
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
