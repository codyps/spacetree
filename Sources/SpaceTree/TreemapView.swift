import SwiftUI

struct TreemapView: View {
    let tree: ScanTree
    let nodeIDs: [NodeID]
    let selectedID: NodeID?
    let onSelect: (NodeMetadata) -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var scene: TreemapScene?
    @State private var hover = TreemapHoverState()
    @State private var selectedRect: CGRect?
    @State private var isPreparing = false

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                ZStack {
                    Color.black.opacity(0.28)

                    if let scene {
                        TreemapBaseLayer(scene: scene, bounds: bounds)
                            .equatable()
                        TreemapHoverOverlay(hover: hover, selectedRect: selectedRect)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): hover.update(at: location, in: scene)
                            case .ended: hover.clear()
                            }
                        }
                        .gesture(
                            SpatialTapGesture().onEnded { value in
                                if let hit = scene.hit(at: value.location) {
                                    onSelect(scene.tree.metadata(for: hit.entry.nodeID))
                                }
                            }
                        )
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
                .task(id: LayoutRequest(tree: tree, nodeIDs: nodeIDs, size: geometry.size, displayScale: displayScale)) {
                    await prepareScene(in: bounds)
                }
            }
            TreemapHoverPath(hover: hover)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Disk usage treemap showing every file")
    }

    @MainActor
    private func prepareScene(in bounds: CGRect) async {
        guard bounds.width > 0, bounds.height > 0 else { return }
        isPreparing = true
        scene = nil
        hover.clear()
        selectedRect = nil
        let inputTree = tree
        let inputNodes = nodeIDs
        let scale = displayScale
        let prepared = await Task.detached(priority: .userInitiated) {
            TreemapScene.build(tree: inputTree, nodes: inputNodes, in: bounds, displayScale: scale)
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
    let displayScale: CGFloat

    init(tree: ScanTree, nodeIDs: [NodeID], size: CGSize, displayScale: CGFloat) {
        self.displayScale = displayScale
        generation = tree.generation
        width = Int(size.width.rounded())
        height = Int(size.height.rounded())
        self.nodeIDs = nodeIDs
    }
}

// Keep the expensive drawing independent of selection and pointer state.
private struct TreemapBaseLayer: View, Equatable {
    let scene: TreemapScene
    let bounds: CGRect

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scene.id == rhs.scene.id && lhs.bounds == rhs.bounds
    }

    var body: some View {
        Canvas(opaque: true, colorMode: .nonLinear, rendersAsynchronously: true) { context, _ in
            context.fill(Path(bounds), with: .color(.black.opacity(0.28)))
            if let raster = scene.raster {
                context.draw(Image(decorative: raster, scale: 1), in: bounds)
            } else {
                for category in FileCategory.allCases {
                    context.fill(
                        scene.fillPaths[Int(category.rawValue)],
                        with: .color(FilePalette.color(for: category))
                    )
                }
                context.stroke(scene.lightEdges, with: .color(.white.opacity(0.30)), lineWidth: 1)
                context.stroke(scene.darkEdges, with: .color(.black.opacity(0.18)), lineWidth: 1)
            }
            for folder in scene.labeledFolders {
                guard let header = folder.header else { continue }
                context.fill(Path(header), with: .linearGradient(Gradient(colors: [.white.opacity(0.24), .white.opacity(0.08)]), startPoint: header.origin, endPoint: CGPoint(x: header.minX, y: header.maxY)))
                var clipped = context
                clipped.clip(to: Path(header.insetBy(dx: 4, dy: 0)))
                clipped.draw(Text(scene.tree.name(of: folder.nodeID)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white), at: CGPoint(x: header.minX + 5, y: header.midY), anchor: .leading)
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
        }
        .allowsHitTesting(false)
    }
}

// Only these small views observe mouse movement. The parent layout request and
// the static map layer do not depend on hover details.
private struct TreemapHoverPath: View {
    let hover: TreemapHoverState

    var body: some View {
        Text(hover.details?.label ?? "Hover for details · click to reveal in the file tree")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 22)
            .transaction { $0.animation = nil }
    }
}

private struct TreemapHoverOverlay: View {
    let hover: TreemapHoverState
    let selectedRect: CGRect?

    var body: some View {
        let highlightRects = hover.details?.highlightRects ?? []
        Canvas { context, _ in
            if let rect = selectedRect {
                let gap: CGFloat = rect.width > 2 && rect.height > 2 ? 0.5 : 0
                context.stroke(Path(rect.insetBy(dx: gap + 1, dy: gap + 1)), with: .color(.white), lineWidth: 3)
            }
            for rect in highlightRects {
                context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(.white.opacity(0.9)), lineWidth: 2)
            }
        }
        .transaction { $0.animation = nil }
    }
}
