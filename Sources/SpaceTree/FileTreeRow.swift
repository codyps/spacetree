import Foundation

struct FileTreeRow: Identifiable {
    let id: NodeID
    let depth: Int

    static func visible(tree: ScanTree, roots: [NodeID], expanded: Set<NodeID>) -> [FileTreeRow] {
        var pending = roots.reversed().map { FileTreeRow(id: $0, depth: 0) }
        var rows: [FileTreeRow] = []
        while let row = pending.popLast() {
            rows.append(row)
            if expanded.contains(row.id) {
                pending.append(contentsOf: tree.children(of: row.id).reversed().map {
                    FileTreeRow(id: $0, depth: row.depth + 1)
                })
            }
        }
        return rows
    }
}

extension ScanTree {
    func fractionOfParent(_ nodeID: NodeID) -> Double {
        guard let parent = parent(of: nodeID), allocatedBytes(of: parent) > 0 else { return 0 }
        return min(1, max(0, Double(allocatedBytes(of: nodeID)) / Double(allocatedBytes(of: parent))))
    }
}
