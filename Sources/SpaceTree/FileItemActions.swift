import AppKit
import Quartz

/// Shared actions keep tree rows and map tiles consistent. Menus capture their
/// own items so a later selection change cannot redirect an action.
@MainActor
final class FileItemActions: NSObject, @preconcurrency QLPreviewPanelDataSource {
    private var previewURLs: [URL] = []
    static let shared = FileItemActions()

    func open(_ nodes: [NodeMetadata], target: ScanTarget) {
        for node in nodes {
            guard target.tree?.contains(node.handle) == true, !target.isTrashed(node.handle.nodeID) else { continue }
            if node.isDirectory { target.open(node) }
            else if !NSWorkspace.shared.open(node.url) { NSSound.beep() }
        }
    }

    func copy(_ nodes: [NodeMetadata], pathsOnly: Bool = false) {
        let urls = nodes.filter { $0.kind != .syntheticRoot }.map(\.url)
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if pathsOnly {
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        } else {
            NSPasteboard.general.writeObjects(urls as [NSURL])
        }
    }

    func preview(_ nodes: [NodeMetadata]) {
        previewURLs = nodes.filter { $0.kind != .syntheticRoot }.map(\.url)
        guard !previewURLs.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil); return }
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURLs[index] as NSURL
    }

    func menu(for nodes: [NodeMetadata], target: ScanTarget) -> NSMenu {
        let nodes = nodes.filter { !target.isTrashed($0.handle.nodeID) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = FileActionMenuItem(title: title, handler: action)
            item.isEnabled = !nodes.isEmpty
            menu.addItem(item)
        }
        add("Open") { self.open(nodes, target: target) }
        add("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(nodes.filter { $0.kind != .syntheticRoot }.map(\.url))
        }
        add("Quick Look") { self.preview(nodes) }
        menu.addItem(.separator())
        add("Copy") { self.copy(nodes) }
        add("Copy Pathname") { self.copy(nodes, pathsOnly: true) }
        menu.addItem(.separator())
        if nodes.count == 1, let node = nodes.first, canModify(node, target: target) {
            add("Rename…") { self.rename(node, target: target) }
        }
        if !nodes.isEmpty && nodes.allSatisfy({ canModify($0, target: target) }) {
            add("Move to Trash…") { self.trash(nodes, target: target) }
        }
        let up = FileActionMenuItem(title: "Enclosing Folder") { target.goUp() }
        up.isEnabled = target.canGoUp
        menu.addItem(up)
        return menu
    }

    private func canModify(_ node: NodeMetadata, target: ScanTarget) -> Bool {
        guard let tree = target.tree, tree.contains(node.handle), target.state != .scanning, !target.isTrashed(node.handle.nodeID) else { return false }
        return node.kind != .syntheticRoot && node.handle.nodeID != tree.rootID
            && !target.roots.contains(where: { $0.url.standardizedFileURL == node.url.standardizedFileURL })
    }

    func rename(_ node: NodeMetadata, target: ScanTarget) {
        guard canModify(node, target: target) else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(node.name)”"
        let field = NSTextField(string: node.name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            NSSound.beep(); return
        }
        guard name != node.name else { return }
        do {
            try FileManager.default.moveItem(at: node.url, to: node.url.deletingLastPathComponent().appendingPathComponent(name))
            target.rescan()
        } catch { NSAlert(error: error).runModal() }
    }

    func trash(_ nodes: [NodeMetadata], target: ScanTarget) {
        guard !nodes.isEmpty, nodes.allSatisfy({ canModify($0, target: target) }) else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Move \(nodes.count == 1 ? "“\(nodes[0].name)”" : "\(nodes.count) items") to the Trash?"
        alert.informativeText = "Moved items will be marked in red. Click Update to recalculate totals."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // A selected directory already includes any selected descendants.
        let paths = Set(nodes.map { $0.url.standardizedFileURL.path })
        let topLevel = nodes.filter { node in
            var parent = node.url.deletingLastPathComponent()
            while parent.path != "/" {
                if paths.contains(parent.path) { return false }
                parent.deleteLastPathComponent()
            }
            return true
        }
        do {
            try moveConfirmedItemsToTrash(topLevel, target: target) {
                try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
            }
        } catch { NSAlert(error: error).runModal() }
    }

    // Record each success immediately, even if a later item cannot be moved.
    func moveConfirmedItemsToTrash(_ nodes: [NodeMetadata], target: ScanTarget,
                                   move: (URL) throws -> Void) throws {
        for node in nodes {
            guard canModify(node, target: target) else { continue }
            try move(node.url)
            target.recordTrashed(node)
        }
    }
}

@MainActor
private final class FileActionMenuItem: NSMenuItem {
    let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performAction), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func performAction() { handler() }
}
