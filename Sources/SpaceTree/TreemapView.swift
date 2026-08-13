import SwiftUI

struct TreemapView: View {
    let nodes: [FileNode]
    let selectedID: FileNode.ID?
    let onSelect: (FileNode) -> Void

    @State private var scene: TreemapScene?
    @State private var hoveredEntry: TreemapScene.Entry?
    @State private var isPreparing = false

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            ZStack {
                Color.black.opacity(0.28)

                if let scene {
                    Canvas(opaque: true, colorMode: .nonLinear, rendersAsynchronously: true) { context, _ in
                        context.fill(Path(bounds), with: .color(.black.opacity(0.28)))
                        for tile in scene.tiles {
                            let entry = scene.entries[tile.entryIndex]
                            let gap: CGFloat = tile.rect.width > 2 && tile.rect.height > 2 ? 0.5 : 0
                            let rect = tile.rect.insetBy(dx: gap, dy: gap)
                            context.fill(
                                Path(rect),
                                with: .color(FilePalette.color(forExtension: entry.node.url.pathExtension.lowercased()))
                            )

                            if selectedID == entry.id || hoveredEntry?.id == entry.id {
                                context.stroke(
                                    Path(rect.insetBy(dx: 1, dy: 1)),
                                    with: .color(.white),
                                    lineWidth: selectedID == entry.id ? 3 : 2
                                )
                            }

                            if rect.width >= 78, rect.height >= 34 {
                                let label = Text(entry.node.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                context.draw(
                                    label,
                                    in: rect.insetBy(dx: 5, dy: 4)
                                )
                            }
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredEntry = scene.entry(at: location)
                        case .ended:
                            hoveredEntry = nil
                        }
                    }
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            if let entry = scene.entry(at: value.location) {
                                onSelect(entry.node)
                            }
                        }
                    )
                    .overlay(alignment: .bottomLeading) {
                        if let entry = hoveredEntry {
                            HoverCard(entry: entry, totalSize: scene.totalSize)
                                .padding(10)
                                .allowsHitTesting(false)
                        }
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
            .task(id: LayoutRequest(nodes: nodes, size: geometry.size)) {
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
        hoveredEntry = nil
        let input = nodes
        let prepared = await Task.detached(priority: .userInitiated) {
            TreemapScene.build(nodes: input, in: bounds)
        }.value
        guard !Task.isCancelled else { return }
        scene = prepared
        isPreparing = false
    }
}

private struct LayoutRequest: Equatable {
    let width: Int
    let height: Int
    let nodeIDs: [String]
    let sizes: [Int64]

    init(nodes: [FileNode], size: CGSize) {
        width = Int(size.width.rounded())
        height = Int(size.height.rounded())
        nodeIDs = nodes.map(\.id)
        sizes = nodes.map(\.size)
    }
}

private struct HoverCard: View {
    let entry: TreemapScene.Entry
    let totalSize: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.node.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text(entry.node.url.path)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(entry.node.size.formattedByteCount) · \(percentage.formatted(.percent.precision(.fractionLength(2))))")
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
        totalSize > 0 ? Double(entry.node.size) / Double(totalSize) : 0
    }
}
