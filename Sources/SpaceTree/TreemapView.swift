import SwiftUI

struct TreemapView: View {
    let tree: ScanTree
    let nodeIDs: [NodeID]
    let selectedID: NodeID?
    let target: ScanTarget
    let onSelect: (NodeMetadata) -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var scene: TreemapScene?
    @State private var hover = TreemapHoverState()
    @State private var selectedRect: CGRect?
    @State private var isPreparing = false
    @State private var activeRequest = UUID()
    @State private var buildOwner = UUID()
    @State private var previousLayoutRequest: LayoutRequest?
    @State private var buildProgress = TreemapScene.BuildProgress(stage: "Laying out tree…")

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                ZStack {
                    Color.black.opacity(0.28)

                    if let scene {
                        TreemapBaseLayer(scene: scene, bounds: bounds)
                            .equatable()
                        TreemapDeletionOverlay(scene: scene, target: target)
                            .allowsHitTesting(false)
                        TreemapHoverOverlay(hover: hover, selectedRect: selectedRect)
                            .allowsHitTesting(false)
                        TreemapInteractionView(scene: scene, target: target, onSelect: onSelect) { location in
                            if let location { hover.update(at: location, in: scene) }
                            else { hover.clear() }
                        }
                        .allowsHitTesting(!isPreparing)
                        .onChange(of: selectedID) { _, newValue in
                            selectedRect = newValue.flatMap { id in
                                scene.rect(for: id) ?? (hover.details?.nodeID == id ? hover.details?.rect : nil)
                            }
                        }
                    }
                    if isPreparing {
                        VStack(spacing: 8) {
                            ProgressView(value: buildProgress.fraction) {
                                Text(buildProgress.stage)
                            } currentValueLabel: {
                                if let total = buildProgress.total {
                                    Text("\(buildProgress.completed.formatted()) of \(total.formatted()) files")
                                        .monospacedDigit()
                                }
                            }
                            .progressViewStyle(.linear)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 280)
                            .padding(16)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .task(id: LayoutRequest(tree: tree, nodeIDs: nodeIDs, size: geometry.size, displayScale: displayScale)) {
                    await prepareScene(in: bounds)
                }
            }
            TreemapHoverPath(hover: hover, target: target)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Disk usage treemap. Grouped blocks show directory names; hover identifies individual files.")
    }

    @MainActor
    private func prepareScene(in bounds: CGRect) async {
        guard bounds.width > 0, bounds.height > 0, !Task.isCancelled else { return }
        let layoutRequest = LayoutRequest(tree: tree, nodeIDs: nodeIDs, size: bounds.size, displayScale: displayScale)
        let coalesceResize = layoutRequest.isResize(of: previousLayoutRequest)
        previousLayoutRequest = layoutRequest
        let requestID = UUID()
        activeRequest = requestID
        buildProgress = TreemapScene.BuildProgress(stage: "Laying out tree…", total: 0)
        isPreparing = true
        hover.clear()
        selectedRect = nil
        let inputTree = tree, inputNodes = nodeIDs, scale = displayScale
        let (updates, continuation) = AsyncStream<TreemapScene.BuildProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let request = Task {
            defer { continuation.finish() }
            // Coalesce live resizes, but start initial display and navigation immediately.
            if coalesceResize { try await Task.sleep(for: .milliseconds(120)) }
            return try await TreemapBuildCoordinator.shared.build(owner: buildOwner, tree: inputTree, nodes: inputNodes, bounds: bounds, scale: scale) {
                continuation.yield($0)
            }
        }
        await withTaskCancellationHandler {
            do {
                for await progress in updates {
                    try Task.checkCancellation()
                    guard activeRequest == requestID else { return }
                    buildProgress = progress
                }
                let prepared = try await request.value
                try Task.checkCancellation()
                guard activeRequest == requestID else { return }
                scene = prepared
                selectedRect = selectedID.flatMap { prepared.rect(for: $0) }
                isPreparing = false
            } catch {
                if activeRequest == requestID { isPreparing = false }
            }
        } onCancel: {
            request.cancel()
        }
    }
}

struct LayoutRequest: Equatable {
    let generation: TreeGeneration
    let width: Int
    let height: Int
    let nodeIDs: [NodeID]
    let displayScale: CGFloat

    func isResize(of previous: Self?) -> Bool {
        guard let previous else { return false }
        return generation == previous.generation && nodeIDs == previous.nodeIDs
            && displayScale == previous.displayScale
            && (width != previous.width || height != previous.height)
    }

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
                // The fallback is bounded by the same visible-region budget.
                for tile in scene.tiles {
                    context.fill(Path(tile.path), with: .color(FilePalette.color(for: scene.entries[tile.entryIndex].category)))
                    if scene.entries[tile.entryIndex].isAggregate {
                        var grouped = context
                        grouped.clip(to: Path(tile.path))
                        grouped.fill(Path(tile.path), with: .color(.black.opacity(0.18)))
                        grouped.stroke(Path(TreemapScene.aggregateHatching(in: tile.rect)),
                                       with: .color(.white.opacity(0.25)), lineWidth: 1)
                    }
                }
            }
            for folder in scene.labeledFolders {
                context.stroke(Path(folder.rect.insetBy(dx: 0.5, dy: 0.5)),
                               with: .color(.white.opacity(0.3)), lineWidth: 1)
                guard let header = folder.header else { continue }
                context.fill(Path(header), with: .linearGradient(Gradient(colors: [.white.opacity(0.24), .white.opacity(0.08)]), startPoint: header.origin, endPoint: CGPoint(x: header.minX, y: header.maxY)))
                guard folder.showsName else { continue }
                var clipped = context
                clipped.clip(to: Path(header.insetBy(dx: 2, dy: 0)))
                clipped.draw(Text(scene.tree.name(of: folder.nodeID)).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white), at: CGPoint(x: header.minX + 3, y: header.midY), anchor: .leading)
            }
            for tileIndex in scene.labeledTileIndices {
                let tile = scene.tiles[tileIndex]
                let entry = scene.entries[tile.entryIndex]
                let gap: CGFloat = tile.rect.width > 2 && tile.rect.height > 2 ? 0.5 : 0
                let rect = tile.labelRect.insetBy(dx: gap, dy: gap)
                let label = Text(scene.label(for: entry))
                    .font(.system(size: entry.isAggregate ? 8 : 9, weight: .semibold))
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
    let target: ScanTarget

    var body: some View {
        let label = hover.details?.label ?? "Hover for details · click to reveal in the file tree"
        let cloneLabel = hover.details.flatMap { target.tree?.clones[$0.nodeID]?.label }
        let sharing = cloneLabel.map { " · " + $0 } ?? ""
        let trashed = hover.details.map { target.isTrashed($0.nodeID) } == true ? " · Trashed" : ""
        Text(label + sharing + trashed)
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

private struct TreemapDeletionOverlay: View {
    let scene: TreemapScene
    let target: ScanTarget
    @State private var rectangles: [CGRect] = []

    private struct Request: Equatable {
        let sceneID: UUID
        let nodes: Set<NodeID>
    }

    private var markedNodes: Set<NodeID> {
        scene.tree.generation == target.tree?.generation ? target.trashedNodeIDs : []
    }

    var body: some View {
        Canvas { context, _ in
            for rect in rectangles {
                // Subpixel files still get a visible marker centered on their region.
                let marker = CGRect(x: rect.midX - max(3, rect.width) / 2,
                                    y: rect.midY - max(3, rect.height) / 2,
                                    width: max(3, rect.width), height: max(3, rect.height))
                context.stroke(Path(marker), with: .color(.red), lineWidth: 2)
            }
        }
        .task(id: Request(sceneID: scene.id, nodes: markedNodes)) {
            let ids = markedNodes
            guard !ids.isEmpty else { rectangles = []; return }
            let worker = Task.detached(priority: .userInitiated) { try scene.deletionRects(for: ids) }
            await withTaskCancellationHandler {
                if let updated = try? await worker.value, !Task.isCancelled { rectangles = updated }
            } onCancel: { worker.cancel() }
        }
    }
}
