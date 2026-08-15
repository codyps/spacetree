import SwiftUI

struct TreemapView: View {
    let tree: ScanTree
    let nodeIDs: [NodeID]
    let selectedID: NodeID?
    let onSelect: (NodeMetadata) -> Void

    @State private var scene: TreemapScene?
    @State private var hoveredHit: TreemapScene.Hit?
    @State private var selectedRect: CGRect?
    @State private var isPreparing = false

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            ZStack {
                Color.black.opacity(0.28)

                if let scene {
                    Canvas(opaque: true, colorMode: .nonLinear, rendersAsynchronously: true) { context, _ in
                        context.fill(Path(bounds), with: .color(.black.opacity(0.28)))
                        for category in FileCategory.allCases {
                            context.fill(
                                scene.fillPaths[Int(category.rawValue)],
                                with: .color(FilePalette.color(for: category))
                            )
                        }
                        for tileIndex in scene.labeledTileIndices {
                            let tile = scene.tiles[tileIndex]
                            let entry = scene.entries[tile.entryIndex]
                            let gap: CGFloat = tile.rect.width > 2 && tile.rect.height > 2 ? 0.5 : 0
                            let rect = tile.rect.insetBy(dx: gap, dy: gap)
                            let label = Text(scene.tree.name(of: entry.nodeID))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                            context.draw(label, in: rect.insetBy(dx: 5, dy: 4))
                        }
                        if let rect = selectedRect {
                            let gap: CGFloat = rect.width > 2 && rect.height > 2 ? 0.5 : 0
                            context.stroke(
                                Path(rect.insetBy(dx: gap + 1, dy: gap + 1)),
                                with: .color(.white),
                                lineWidth: 3
                            )
                        }
                        if let hoveredHit, hoveredHit.entry.nodeID != selectedID {
                            let rect = hoveredHit.rect
                            let gap: CGFloat = rect.width > 2 && rect.height > 2 ? 0.5 : 0
                            context.stroke(
                                Path(rect.insetBy(dx: gap + 1, dy: gap + 1)),
                                with: .color(.white),
                                lineWidth: 2
                            )
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hoveredHit = scene.hit(at: location)
                        case .ended: hoveredHit = nil
                        }
                    }
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            if let hit = scene.hit(at: value.location) {
                                onSelect(scene.tree.metadata(for: hit.entry.nodeID))
                            }
                        }
                    )
                    .overlay(alignment: .bottomLeading) {
                        if let hoveredHit {
                            HoverCard(node: scene.tree.metadata(for: hoveredHit.entry.nodeID), totalSize: scene.totalSize)
                                .padding(10)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: selectedID) { _, newValue in
                        selectedRect = newValue.flatMap { scene.rect(for: $0) }
                    }
                } else if isPreparing {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Laying out every file…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: LayoutRequest(tree: tree, nodeIDs: nodeIDs, size: geometry.size)) {
                await prepareScene(in: bounds)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Disk usage treemap showing every file")
    }

    @MainActor
    private func prepareScene(in bounds: CGRect) async {
        guard bounds.width > 0, bounds.height > 0 else { return }
        isPreparing = true
        scene = nil
        hoveredHit = nil
        selectedRect = nil
        let inputTree = tree
        let inputNodes = nodeIDs
        let prepared = await Task.detached(priority: .userInitiated) {
            TreemapScene.build(tree: inputTree, nodes: inputNodes, in: bounds)
        }.value
        guard !Task.isCancelled else { return }
        scene = prepared
        selectedRect = selectedID.flatMap { prepared.rect(for: $0) }
        isPreparing = false
    }
}

private struct LayoutRequest: Equatable {
    let generation: TreeGeneration
    let width: Int
    let height: Int
    let nodeIDs: [NodeID]
    let sizes: [Int64]

    init(tree: ScanTree, nodeIDs: [NodeID], size: CGSize) {
        generation = tree.generation
        width = Int(size.width.rounded())
        height = Int(size.height.rounded())
        self.nodeIDs = nodeIDs
        sizes = nodeIDs.map { tree.allocatedBytes(of: $0) }
    }
}

private struct HoverCard: View {
    let node: NodeMetadata
    let totalSize: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(node.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text(node.url.path)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(node.allocatedBytes.formattedByteCount) · \(percentage.formatted(.percent.precision(.fractionLength(2))))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .shadow(radius: 4, y: 2)
    }

    private var percentage: Double {
        totalSize > 0 ? Double(node.allocatedBytes) / Double(totalSize) : 0
    }
}
