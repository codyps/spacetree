import Foundation
import Observation

@MainActor
@Observable
final class TreemapHoverState {
    struct Details {
        let nodeID: NodeID
        let rect: CGRect
        let label: String
        let highlightRects: [CGRect]
    }

    private(set) var details: Details?
    @ObservationIgnored private var sceneID: UUID?

    // Synchronous: no debounce or queued work can leave the path behind the mouse.
    func update(at point: CGPoint, in scene: TreemapScene) {
        let hit = scene.hit(at: point)
        guard sceneID != scene.id || hit?.entry.nodeID != details?.nodeID || hit?.rect != details?.rect else { return }
        sceneID = scene.id
        guard let hit else {
            details = nil
            return
        }
        details = Details(
            nodeID: hit.entry.nodeID,
            rect: hit.rect,
            label: "\(scene.tree.displayPath(of: hit.entry.nodeID)) · \(hit.entry.allocatedBytes.formattedByteCount)" + (hit.entry.isAggregate ? " · \(hit.entry.representedFileCount.formatted()) grouped files — open folder or browse the file tree" : ""),
            highlightRects: scene.tree.breadcrumbs(to: hit.entry.nodeID).compactMap { scene.rect(for: $0) } + [hit.rect]
        )
    }

    func clear() {
        if details != nil { details = nil }
        sceneID = nil
    }
}
