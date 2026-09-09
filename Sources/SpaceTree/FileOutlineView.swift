import AppKit
import Quartz
import SwiftUI

/// AppKit supplies standard macOS range/toggle selection, type selection,
/// disclosure triangles, arrow navigation, and accessibility for the hierarchy.
struct FileOutlineView: NSViewRepresentable {
    let target: ScanTarget
    let revealRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(target: target) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FinderOutlineView()
        outline.coordinator = context.coordinator
        context.coordinator.outline = outline
        outline.delegate = context.coordinator
        outline.dataSource = context.coordinator
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsTypeSelect = true
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .inset
        outline.rowHeight = 26
        outline.autoresizingMask = [.width]
        outline.indentationPerLevel = 16
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (id, title, width) in [("name", "Name", 300.0), ("fraction", "% of parent", 130.0),
                                   ("type", "Type", 90.0), ("items", "Items", 70.0),
                                   ("size", "Allocated", 100.0), ("modified", "Modified", 130.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 160 : 60
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.openClicked)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(target: target, revealRequest: revealRequest)
    }

    @MainActor
    final class Item: NSObject {
        let id: NodeID
        init(_ id: NodeID) { self.id = id }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var target: ScanTarget
        weak var outline: FinderOutlineView?
        var tree: ScanTree?
        var roots: [NodeID] = []
        var currentID: NodeID?
        var items: [NodeID: Item] = [:]
        var childCache: [NodeID: [NodeID]] = [:]
        var syncing = false
        var lastSelection: NodeID?
        var lastReveal = -1
        var lastTrashed: Set<NodeID> = []

        init(target: ScanTarget) { self.target = target }
        func item(_ id: NodeID) -> Item {
            if let existing = items[id] { return existing }
            let value = Item(id)
            items[id] = value
            return value
        }
        func children(_ item: Any?) -> [NodeID] {
            guard let item = item as? Item, let tree else { return roots }
            if let cached = childCache[item.id] { return cached }
            let children = tree.children(of: item.id)
            childCache[item.id] = children
            return children
        }
        func update(target: ScanTarget, revealRequest: Int) {
            guard let outline else { return }
            self.target = target
            let newRoots = target.visibleChildren.map(\.handle.nodeID)
            let generationChanged = tree?.generation != target.tree?.generation
            let reload = generationChanged || roots != newRoots || currentID != target.currentID
            syncing = true
            defer { syncing = false }
            if reload {
                if generationChanged {
                    outline.collapseItem(nil, collapseChildren: true)
                    items.removeAll()
                    childCache.removeAll()
                }
                tree = target.tree
                roots = newRoots
                currentID = target.currentID
                outline.reloadData()
            }
            if lastTrashed != target.trashedNodeIDs {
                // Refresh only materialized rows, preserving expansion and scroll position.
                let visible = outline.rows(in: outline.visibleRect)
                if visible.location != NSNotFound, visible.length > 0 {
                    outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                                       columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
                }
                lastTrashed = target.trashedNodeIDs
            }
            if reload || lastSelection != target.selectedID || lastReveal != revealRequest {
                if let id = target.selectedID, let tree, tree.contains(tree.handle(for: id)),
                   let rootIndex = tree.breadcrumbs(to: id).firstIndex(where: { roots.contains($0) }) {
                    let chain = tree.breadcrumbs(to: id)
                    for ancestor in chain[rootIndex...].dropLast() { outline.expandItem(item(ancestor)) }
                    let row = outline.row(forItem: item(id))
                    if row >= 0 {
                        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        outline.scrollRowToVisible(row)
                    }
                } else {
                    outline.deselectAll(nil)
                }
            }
            lastSelection = target.selectedID
            lastReveal = revealRequest
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(item).count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            self.item(children(item)[index])
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? Item, let tree else { return false }
            return tree.metadata(for: item.id).isDirectory
        }
        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            guard let item = item as? Item else { return nil }
            return tree?.name(of: item.id)
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? Item, let tree, let column = tableColumn else { return nil }
            let node = tree.metadata(for: item.id)
            let identifier = column.identifier
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier)
            let text: String
            switch identifier.rawValue {
            case "name":
                text = node.name
                cell.imageView?.image = NSImage(systemSymbolName: node.isDirectory ? "folder.fill" : (node.isDuplicateReference ? "link" : "doc.fill"), accessibilityDescription: node.isDirectory ? "Folder" : "File")
                cell.imageView?.contentTintColor = NSColor(FilePalette.color(for: node))
            case "fraction":
                let fraction = tree.fractionOfParent(item.id)
                text = fraction.formatted(.percent.precision(.fractionLength(1)))
                if let meter = cell.subviews.first(where: { $0 is NSLevelIndicator }) as? NSLevelIndicator {
                    meter.doubleValue = fraction
                    meter.fillColor = NSColor(FilePalette.color(for: node))
                }
            case "type": text = [node.isDuplicateReference ? "Hard link" : node.fileExtension.capitalized, node.clone?.label].compactMap { $0 }.joined(separator: " · ")
            case "items": text = node.isDirectory ? node.fileCount.formatted() : "—"
            case "size": text = node.allocatedBytes.formattedByteCount
            default: text = node.modifiedAt?.formatted(date: .abbreviated, time: .omitted) ?? "—"
            }
            let trashed = target.isTrashed(item.id)
            cell.textField?.stringValue = text + (trashed && identifier.rawValue == "name" ? " — Trashed" : "")
            cell.textField?.textColor = trashed ? .systemRed : .labelColor
            cell.toolTip = node.url.path + (node.clone.map { "\n\($0.label). Allocated size may include shared blocks." } ?? "")
            return cell
        }
        private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            var leading = cell.leadingAnchor
            var offset: CGFloat = 2
            if identifier.rawValue == "name" {
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon)
                cell.imageView = icon
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)
                ])
                leading = icon.trailingAnchor
                offset = 6
            } else if identifier.rawValue == "fraction" {
                let meter = NSLevelIndicator()
                meter.levelIndicatorStyle = .continuousCapacity
                meter.minValue = 0
                meter.maxValue = 1
                meter.isEditable = false
                meter.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(meter)
                NSLayoutConstraint.activate([
                    meter.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    meter.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    meter.heightAnchor.constraint(equalToConstant: 8),
                    meter.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -5),
                    label.widthAnchor.constraint(equalToConstant: 48)
                ])
                leading = meter.trailingAnchor
                offset = 5
                label.alignment = .right
                label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            } else if ["items", "size", "modified"].contains(identifier.rawValue) {
                label.alignment = .right
                label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leading, constant: offset),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        var selectedNodes: [NodeMetadata] {
            guard let outline, let tree else { return [] }
            return outline.selectedRowIndexes.compactMap { row in
                (outline.item(atRow: row) as? Item).flatMap { target.isTrashed($0.id) ? nil : tree.metadata(for: $0.id) }
            }
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing else { return }
            // Write the lead selection before SwiftUI updates, preserving native
            // multi-selection when that update comes back through the bridge.
            let id = selectedNodes.first?.handle.nodeID
            lastSelection = id
            target.selectedID = id
        }
        @objc func openClicked() {
            guard let outline, outline.clickedRow >= 0 else { return }
            FileItemActions.shared.open(selectedNodes, target: target)
        }
    }
}

@MainActor
final class FinderOutlineView: NSOutlineView {
    weak var coordinator: FileOutlineView.Coordinator?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // Quick Look's legacy NSObject callbacks are delivered on the UI thread.
        MainActor.assumeIsolated { panel.dataSource = FileItemActions.shared }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator else { return nil }
        window?.makeFirstResponder(self)
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 {
            if !isRowSelected(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        } else { deselectAll(nil) }
        return FileItemActions.shared.menu(for: coordinator.selectedNodes, target: coordinator.target)
    }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let nodes = coordinator.selectedNodes
        if modifiers == .command && (event.keyCode == 125 || event.charactersIgnoringModifiers == "o") {
            FileItemActions.shared.open(nodes, target: coordinator.target)
        } else if modifiers == .command && event.keyCode == 126 {
            coordinator.target.goUp()
        } else if modifiers == .command && event.charactersIgnoringModifiers == "a" {
            selectAll(nil)
        } else if (modifiers == .command || modifiers == [.command, .option]) && event.charactersIgnoringModifiers == "c" {
            FileItemActions.shared.copy(nodes, pathsOnly: modifiers.contains(.option))
        } else if modifiers.isEmpty && event.keyCode == 49 {
            FileItemActions.shared.preview(nodes)
        } else if modifiers.isEmpty && event.keyCode == 36 && nodes.count == 1 {
            FileItemActions.shared.rename(nodes[0], target: coordinator.target)
        } else if modifiers == .command && event.keyCode == 51 {
            FileItemActions.shared.trash(nodes, target: coordinator.target)
        } else { super.keyDown(with: event) }
    }

    @objc func copy(_ sender: Any?) {
        if let coordinator { FileItemActions.shared.copy(coordinator.selectedNodes) }
    }
}
