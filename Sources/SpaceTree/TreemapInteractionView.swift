import AppKit
import Quartz
import SwiftUI

struct TreemapInteractionView: NSViewRepresentable {
    let scene: TreemapScene
    let target: ScanTarget
    let onSelect: (NodeMetadata) -> Void
    let onHover: (CGPoint?) -> Void

    func makeNSView(context: Context) -> MapInputView { MapInputView() }
    func updateNSView(_ view: MapInputView, context: Context) {
        view.scene = scene
        view.target = target
        view.onSelect = onSelect
        view.onHover = onHover
    }
}

@MainActor
final class MapInputView: NSView {
    var scene: TreemapScene?
    var target: ScanTarget?
    var onSelect: ((NodeMetadata) -> Void)?
    var onHover: ((CGPoint?) -> Void)?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // Quick Look's legacy NSObject callbacks are delivered on the UI thread.
        MainActor.assumeIsolated { panel.dataSource = FileItemActions.shared }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    private func node(at event: NSEvent) -> NodeMetadata? {
        guard let scene, let hit = scene.hit(at: convert(event.locationInWindow, from: nil)) else { return nil }
        guard target?.isTrashed(hit.entry.nodeID) != true else { return nil }
        return scene.tree.metadata(for: hit.entry.nodeID)
    }
    override func mouseMoved(with event: NSEvent) { onHover?(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        window?.makeFirstResponder(self)
        guard let node = node(at: event), let target else { return }
        onHover?(convert(event.locationInWindow, from: nil))
        onSelect?(node)
        if event.clickCount == 2 { FileItemActions.shared.open([node], target: target) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let target else { return nil }
        window?.makeFirstResponder(self)
        let node = node(at: event)
        onHover?(convert(event.locationInWindow, from: nil))
        if let node { onSelect?(node) }
        return FileItemActions.shared.menu(for: node.map { [$0] } ?? [], target: target)
    }
    override func keyDown(with event: NSEvent) {
        guard let target else { super.keyDown(with: event); return }
        let nodes = target.selected.map { [$0] } ?? []
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        if modifiers == .command && (event.keyCode == 125 || event.charactersIgnoringModifiers == "o") {
            FileItemActions.shared.open(nodes, target: target)
        } else if modifiers.isEmpty && event.keyCode == 49 {
            FileItemActions.shared.preview(nodes)
        } else if modifiers.isEmpty && event.keyCode == 36, let node = nodes.first {
            FileItemActions.shared.rename(node, target: target)
        } else if modifiers == .command && event.keyCode == 51 {
            FileItemActions.shared.trash(nodes, target: target)
        } else if (modifiers == .command || modifiers == [.command, .option]) && event.charactersIgnoringModifiers == "c" {
            FileItemActions.shared.copy(nodes, pathsOnly: modifiers.contains(.option))
        } else { super.keyDown(with: event) }
    }
    @objc func copy(_ sender: Any?) {
        if let node = target?.selected { FileItemActions.shared.copy([node]) }
    }
}
