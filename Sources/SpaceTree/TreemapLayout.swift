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

    // Split only the aggregate's geometry, retaining one logical entry. The small
    // leading piece joins the final visible row; the rest occupies the remainder.
    static func regions(weights: [Double], groupedTail: Bool, in bounds: CGRect) -> [[CGRect]] {
        let weights = weights.map { max(1, $0) }
        guard groupedTail, weights.count > 1, let tail = weights.last,
              tail - weights[weights.count - 2] >= 1 else {
            return rectangles(for: weights, in: bounds, weight: { $0 }).map { [$0] }
        }
        let leading = max(1, weights[weights.count - 2])
        let expanded = Array(weights.dropLast()) + [leading, tail - leading]
        let rects = rectangles(for: expanded, in: bounds, weight: { $0 })
        guard rects.count == expanded.count else { return [] }
        return rects.dropLast(2).map { [$0] } + [Array(rects.suffix(2))]
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
            let stripWidth = min(Double(available.width), totalArea / Double(available.height))
            var y = Double(available.minY)
            for (index, pair) in row.enumerated() {
                let height = index == row.count - 1 ? Double(available.maxY) - y : pair.1 / stripWidth
                result[pair.0] = CGRect(x: available.minX, y: y, width: stripWidth, height: height)
                y += height
            }
            available.origin.x += stripWidth
            available.size.width = max(0, available.width - stripWidth)
        } else {
            let stripHeight = min(Double(available.height), totalArea / Double(available.width))
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
    static let maximumRegions = 131_072
    let id = UUID()

    struct Entry: Identifiable, Sendable {
        let nodeID: NodeID
        let allocatedBytes: Int64
        let category: FileCategory
        var representedFileCount: Int = 1
        // Drawing labels name the directory; virtualRange resolves individual hits.
        var isAggregate = false
        var virtualRange: Range<Int>? = nil
        var id: NodeID { nodeID }
    }
    struct Tile: Sendable {
        let entryIndex: Int
        let rect: CGRect
        var pieces: [CGRect] = []
        var shape: [CGRect] { pieces.isEmpty ? [rect] : pieces }
        var labelRect: CGRect { shape.max { $0.width * $0.height < $1.width * $1.height } ?? rect }
        var path: CGPath {
            let path = CGMutablePath()
            for piece in shape { path.addRect(piece) }
            return path
        }
        func contains(_ point: CGPoint) -> Bool { shape.contains { $0.contains(point) } }
    }
    struct Hit: Sendable {
        let entry: Entry
        let rect: CGRect
    }
    struct Folder: Sendable {
        let nodeID: NodeID
        let rect: CGRect
        let header: CGRect?
        var showsName: Bool { (header?.height ?? 0) >= 14 }
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
    // Only 12 bytes per hidden file: ID plus cumulative weight, no CGRect/Path.
    private let virtualNodes: [NodeID]
    private let virtualWeights: [Double]

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
        var virtualNodes: [NodeID] = []
        var virtualWeights: [Double] = []
        var tileLookup: [NodeID: Int] = [:]
        var folderLookup: [NodeID: Int] = [:]
        let totalFiles = nodes.reduce(0) { $0 + tree.fileCount(of: $1) }
        var completed = 0
        onProgress(BuildProgress(stage: "Laying out tree…", total: totalFiles))
        let owner = nodes.first.flatMap { tree.parent(of: $0) } ?? tree.rootID
        var pending = Array(try arrangedNodes(tree: tree, nodes: nodes, owner: owner,
                                              in: bounds, scale: scale, limit: maximumRegions).reversed())
        while let region = pending.popLast() {
            try Task.checkCancellation()
            let kind = tree.kind(of: region.entry.nodeID)
            let isDirectory = kind == .directory || kind == .syntheticRoot
            if !region.entry.isAggregate, isDirectory,
               region.rect.width * scale >= 4, region.rect.height * scale >= 4,
               region.budget > 1 {
                let headerHeight: CGFloat = region.rect.width >= 32 && region.rect.height >= 28
                    ? 14 : min(2, region.rect.height / 4)
                let header = CGRect(x: region.rect.minX, y: region.rect.minY,
                                    width: region.rect.width, height: headerHeight)
                // Retain ancestors for highlighting, but never a second rectangle dictionary.
                folderLookup[region.entry.nodeID] = folders.count
                folders.append(Folder(nodeID: region.entry.nodeID, rect: region.rect, header: header))
                let content = CGRect(x: region.rect.minX, y: region.rect.minY + headerHeight,
                                     width: region.rect.width, height: region.rect.height - headerHeight)
                let children = try arrangedNodes(tree: tree, nodes: tree.childIDs(of: region.entry.nodeID),
                                                 owner: region.entry.nodeID, in: content, scale: scale,
                                                 limit: region.budget - 1)
                pending.append(contentsOf: children.reversed())
                continue
            }
            var entry = region.entry
            if isDirectory { entry.isAggregate = true }
            if entry.isAggregate {
                let start = virtualNodes.count
                var sum = 0.0
                var visited = 0
                var stack = Array((region.members ?? [entry.nodeID]).reversed())
                while let id = stack.popLast() {
                    if visited.isMultiple(of: 1_024) { try Task.checkCancellation() }
                    visited += 1
                    let kind = tree.kind(of: id)
                    if kind == .directory || kind == .syntheticRoot {
                        stack.append(contentsOf: tree.childIDs(of: id))
                    } else {
                        sum += max(1, Double(tree.allocatedBytes(of: id)))
                        virtualNodes.append(id)
                        virtualWeights.append(sum)
                    }
                }
                entry.virtualRange = start..<virtualNodes.count
            }
            if !entry.isAggregate { entry = Entry(nodeID: entry.nodeID, allocatedBytes: entry.allocatedBytes,
                                                  category: FilePalette.category(forExtension: tree.fileExtension(of: entry.nodeID))) }
            tileLookup[entry.nodeID] = tiles.count
            entries.append(entry)
            tiles.append(Tile(entryIndex: entries.count - 1, rect: region.rect, pieces: region.pieces))
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
                            labeledTileIndices: tiles.indices.filter {
                                let rect = tiles[$0].labelRect
                                return entries[tiles[$0].entryIndex].isAggregate
                                    ? rect.width >= 36 && rect.height >= 24
                                    : rect.width >= 78 && rect.height >= 34
                            },
                            totalSize: entries.reduce(0) { saturatingSceneAdd($0, $1.allocatedBytes) },
                            representedFileCount: completed, tileLookup: tileLookup, folderLookup: folderLookup, hitIndex: hitIndex, virtualNodes: virtualNodes, virtualWeights: virtualWeights)
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
            if tile.pieces.isEmpty {
                context.fill(tile.rect)
            } else {
                context.addPath(tile.path)
                context.fillPath()
            }
            if entries[tile.entryIndex].isAggregate {
                context.saveGState()
                context.addPath(tile.path)
                context.clip()
                context.setFillColor(CGColor(gray: 0, alpha: 0.18))
                context.addPath(tile.path)
                context.fillPath()
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
                context.setLineWidth(1)
                context.addPath(aggregateHatching(in: tile.rect))
                context.strokePath()
                context.restoreGState()
            }
        }
        context.setShouldAntialias(true)
        context.setLineWidth(1)
        for (index, tile) in tiles.enumerated() where !entries[tile.entryIndex].isAggregate && tile.rect.width >= 3 && tile.rect.height >= 3 {
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

    // Shared geometry keeps the raster and Canvas fallback visually identical.
    static func aggregateHatching(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 7
        }
        return path
    }

    private struct NodeRegion {
        var entry: Entry
        let rect: CGRect
        var pieces: [CGRect] = []
        var budget: Int = 1
        var members: [NodeID]? = nil
    }
    private struct WeightedEntry {
        let entry: Entry
        let weight: Double
        var members: [NodeID]? = nil
    }

    private static func arrangedNodes<IDs: Sequence>(
        tree: ScanTree, nodes: IDs, owner: NodeID, in bounds: CGRect,
        scale: CGFloat, limit: Int
    ) throws -> [NodeRegion] where IDs.Element == NodeID {
        guard bounds.width > 0, bounds.height > 0, limit > 0 else { return [] }
        // Linear sibling passes, with sorting limited to the visible-region budget.
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
        var small: [NodeID] = []
        var smallWeight = 0.0
        // Prefer directories. Their own projected size, not descendant file count,
        // decides whether their structure remains visible.
        var visibleDirectories = Set<NodeID>()
        for (index, id) in nodes.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let kind = tree.kind(of: id)
            if kind == .directory || kind == .syntheticRoot,
               tree.fileCount(of: id) > 0, weight(id) * pixels / total >= 16,
               items.count < limit - 1 {
                visibleDirectories.insert(id)
                items.append(WeightedEntry(entry: Entry(nodeID: id, allocatedBytes: tree.allocatedBytes(of: id), category: .other,
                                                         representedFileCount: tree.fileCount(of: id)), weight: weight(id)))
            }
        }
        for (index, id) in nodes.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let count = tree.fileCount(of: id)
            guard count > 0, !visibleDirectories.contains(id) else { continue }
            let kind = tree.kind(of: id)
            let bytes = tree.allocatedBytes(of: id), value = weight(id)
            if kind != .directory && kind != .syntheticRoot,
               value >= cutoff, items.count < limit - 1 {
                items.append(WeightedEntry(entry: Entry(nodeID: id, allocatedBytes: bytes, category: .other), weight: value))
            } else {
                small.append(id)
                smallWeight += value
            }
        }
        // One tail region per folder. Its combined area never promotes it ahead
        // of individually visible children in the descending display order.
        if !small.isEmpty {
            var bytes: Int64 = 0
            var files = 0
            for (index, id) in small.enumerated() {
                if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
                bytes = saturatingSceneAdd(bytes, tree.allocatedBytes(of: id))
                files += tree.fileCount(of: id)
            }
            let destination: NodeID
            if small.count == 1, let id = small.first,
               tree.kind(of: id) == .directory || tree.kind(of: id) == .syntheticRoot {
                destination = id
            } else { destination = owner }
            items.append(WeightedEntry(entry: Entry(nodeID: destination, allocatedBytes: bytes, category: .other,
                                                     representedFileCount: files, isAggregate: true),
                                       weight: smallWeight, members: small))
        }
        try Task.checkCancellation()
        items.sort {
            if $0.entry.isAggregate != $1.entry.isAggregate { return !$0.entry.isAggregate }
            return $0.weight == $1.weight ? $0.entry.nodeID < $1.entry.nodeID : $0.weight > $1.weight
        }
        let rectangles = TreemapLayout.regions(weights: items.map(\.weight),
                                               groupedTail: items.last?.entry.isAggregate == true, in: bounds)
        try Task.checkCancellation()
        let spare = max(0, limit - items.count)
        return zip(items, rectangles).map {
            NodeRegion(entry: $0.entry, rect: $1.reduce(CGRect.null) { $0.union($1) }, pieces: $1.count > 1 ? $1 : [],
                       budget: 1 + Int((Double(spare) * $0.weight / total).rounded(.down)), members: $0.members)
        }
    }

    func hit(at point: CGPoint) -> Hit? {
        if let folder = folders.first(where: { $0.header?.contains(point) == true }) {
            return Hit(entry: Entry(nodeID: folder.nodeID, allocatedBytes: tree.allocatedBytes(of: folder.nodeID), category: .other), rect: folder.rect)
        }
        guard let index = hitIndex.tileIndex(at: point, tiles: tiles) else { return nil }
        let tile = tiles[index]
        let entry = entries[tile.entryIndex]
        if let range = entry.virtualRange, !range.isEmpty {
            return virtualHit(at: point, range: range, in: tile.shape)
        }
        return Hit(entry: entry, rect: tile.rect)
    }
    // A weighted binary partition provides stable per-file hit rectangles without
    // storing or drawing them. Each pointer lookup takes logarithmic time.
    // Partition actual occupied area, including a bend in the grouped tail.
    // At most two rectangles are carried through each binary search step.
    private func virtualRects(range: Range<Int>, in bounds: [CGRect], point: CGPoint, index: Int? = nil) -> (Int, [CGRect]) {
        var lower = range.lowerBound, upper = range.upperBound
        var pieces = bounds
        func prefix(_ index: Int) -> Double { index == range.lowerBound ? 0 : virtualWeights[index - 1] }
        while upper - lower > 1 {
            let middle = lower + (upper - lower) / 2
            let total = prefix(upper) - prefix(lower)
            let fraction = total > 0 ? (prefix(middle) - prefix(lower)) / total : 0.5
            let box = pieces.reduce(CGRect.null) { $0.union($1) }
            let horizontal = box.width >= box.height
            let edges = Set(pieces.flatMap { horizontal ? [$0.minX, $0.maxX] : [$0.minY, $0.maxY] }).sorted()
            var remaining = pieces.reduce(0.0) { $0 + $1.width * $1.height } * fraction
            var split = edges[0]
            for (start, end) in zip(edges, edges.dropFirst()) {
                let cross = pieces.reduce(0.0) { sum, rect in
                    let covers = horizontal ? rect.minX <= start && rect.maxX >= end : rect.minY <= start && rect.maxY >= end
                    return sum + (covers ? (horizontal ? rect.height : rect.width) : 0)
                }
                if cross > 0 && remaining <= (end - start) * cross {
                    split = start + remaining / cross
                    break
                }
                remaining -= (end - start) * cross
            }
            let first = index.map { $0 < middle } ?? (horizontal ? point.x < split : point.y < split)
            pieces = pieces.compactMap { rect in
                let clipped: CGRect
                if horizontal {
                    let start = first ? rect.minX : max(rect.minX, split)
                    let end = first ? min(rect.maxX, split) : rect.maxX
                    clipped = CGRect(x: start, y: rect.minY, width: max(0, end - start), height: rect.height)
                } else {
                    let start = first ? rect.minY : max(rect.minY, split)
                    let end = first ? min(rect.maxY, split) : rect.maxY
                    clipped = CGRect(x: rect.minX, y: start, width: rect.width, height: max(0, end - start))
                }
                return clipped.width > 0 && clipped.height > 0 ? clipped : nil
            }
            if first { upper = middle } else { lower = middle }
        }
        return (lower, pieces)
    }

    private func virtualHit(at point: CGPoint, range: Range<Int>, in bounds: [CGRect]) -> Hit {
        let (index, pieces) = virtualRects(range: range, in: bounds, point: point)
        let id = virtualNodes[index]
        return Hit(entry: Entry(nodeID: id, allocatedBytes: tree.allocatedBytes(of: id),
                                category: FilePalette.category(forExtension: tree.fileExtension(of: id))),
                   rect: pieces.first { $0.contains(point) } ?? pieces[0])
    }

    func deletionRects(for ids: Set<NodeID>) throws -> [CGRect] {
        var result: [CGRect] = []
        var hidden: [NodeID: Bool] = [:]
        for id in ids {
            try Task.checkCancellation()
            if let rect = rect(for: id) { result.append(rect); continue }
            var leaf = id
            let isFolder = tree.kind(of: id) == .directory || tree.kind(of: id) == .syntheticRoot
            while tree.kind(of: leaf) == .directory || tree.kind(of: leaf) == .syntheticRoot {
                guard let child = tree.childIDs(of: leaf).first(where: { tree.fileCount(of: $0) > 0 }) else { break }
                leaf = child
            }
            hidden[leaf] = isFolder
        }
        guard !hidden.isEmpty else { return result }
        // One pass over compact IDs on a worker; never rebuild the layout or paths.
        for tile in tiles {
            guard let range = entries[tile.entryIndex].virtualRange else { continue }
            for index in range {
                if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
                if let isFolder = hidden.removeValue(forKey: virtualNodes[index]) {
                    result.append(contentsOf: isFolder ? tile.shape : virtualRects(range: range, in: tile.shape, point: .zero, index: index).1)
                    if hidden.isEmpty { return result }
                }
            }
        }
        return result
    }

    func label(for entry: Entry) -> String {
        let name = tree.name(of: entry.nodeID)
        return entry.isAggregate ? "\(name) · \(entry.representedFileCount.formatted()) files" : name
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
        return buckets[row * columns + column].first { tiles[$0].contains(point) }
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
