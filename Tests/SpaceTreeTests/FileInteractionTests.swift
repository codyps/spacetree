import AppKit
import Testing
@testable import SpaceTree

@Suite(.serialized) @MainActor
struct FileInteractionTests {
    private func fixture() throws -> (ScanTarget, NodeID, NodeID, NodeID) {
        let url = URL(fileURLWithPath: "/tmp/spacetree-interactions")
        var builder = ScanTreeBuilder(rootName: "test", rootURL: url)
        let folder = builder.addNode(parent: builder.rootID, name: "folder", kind: .directory, allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
        let file = builder.addNode(parent: folder, name: "nested.txt", kind: .file, allocatedBytes: 100, logicalBytes: 100, modifiedAt: nil, identity: nil)
        let sibling = builder.addNode(parent: builder.rootID, name: "sibling.txt", kind: .file, allocatedBytes: 10, logicalBytes: 10, modifiedAt: nil, identity: nil)
        let target = ScanTarget(id: "interaction", url: url, name: "test", kind: .folder, persistResults: false)
        target.tree = try builder.finalize()
        return (target, folder, file, sibling)
    }

    private func outline(for target: ScanTarget) -> (FinderOutlineView, FileOutlineView.Coordinator) {
        _ = NSApplication.shared
        let view = FinderOutlineView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let coordinator = FileOutlineView.Coordinator(target: target)
        coordinator.outline = view
        view.coordinator = coordinator
        view.delegate = coordinator
        view.dataSource = coordinator
        view.allowsMultipleSelection = true
        view.allowsEmptySelection = true
        let column = NSTableColumn(identifier: .init("name"))
        view.addTableColumn(column)
        view.outlineTableColumn = column
        coordinator.update(target: target, revealRequest: 0)
        return (view, coordinator)
    }

    private func click(_ view: NSView, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func mapSelectionRevealsAncestorsAndNativeMultiselectionSurvivesUpdates() throws {
        let (target, folder, file, sibling) = try fixture()
        let (view, coordinator) = outline(for: target)
        #expect(view.numberOfRows == 2)
        target.selectedID = file
        coordinator.update(target: target, revealRequest: 1)
        #expect(view.isItemExpanded(coordinator.item(folder)))
        #expect(coordinator.selectedNodes.map(\.handle.nodeID) == [file])
        let selection = IndexSet([view.row(forItem: coordinator.item(file)), view.row(forItem: coordinator.item(sibling))])
        view.selectRowIndexes(selection, byExtendingSelection: false)
        coordinator.update(target: target, revealRequest: 1)
        #expect(view.selectedRowIndexes == selection)
        #expect(coordinator.selectedNodes.count == 2)
        // A repeated click on the same map tile should reduce the selection.
        target.selectedID = file
        coordinator.update(target: target, revealRequest: 2)
        #expect(coordinator.selectedNodes.map(\.handle.nodeID) == [file])
    }

    @Test func contextClickPreservesSelectedGroupAndRetargetsUnselectedRows() throws {
        let (target, folder, _, sibling) = try fixture()
        let (view, coordinator) = outline(for: target)
        view.selectAll(nil)
        let row = view.row(forItem: coordinator.item(sibling))
        let rect = view.rect(ofRow: row)
        let event = try click(view, at: NSPoint(x: 40, y: rect.midY))
        let menu = try #require(view.menu(for: event))
        #expect(coordinator.selectedNodes.count == 2)
        #expect(menu.items.contains { $0.title == "Copy Pathname" })
        #expect(menu.items.contains { $0.title == "Move to Trash…" })
        view.selectRowIndexes(IndexSet(integer: view.row(forItem: coordinator.item(folder))), byExtendingSelection: false)
        _ = view.menu(for: event)
        #expect(coordinator.selectedNodes.map(\.handle.nodeID) == [sibling])
        let blank = try click(view, at: NSPoint(x: 40, y: 350))
        let blankMenu = try #require(view.menu(for: blank))
        #expect(coordinator.selectedNodes.isEmpty)
        #expect(blankMenu.items.first?.isEnabled == false)
    }

    @Test func navigationAndReplacementDiscardObsoleteSelection() throws {
        let (target, folder, file, _) = try fixture()
        let (view, coordinator) = outline(for: target)
        target.selectedID = file
        coordinator.update(target: target, revealRequest: 1)
        target.open(try #require(target.tree).metadata(for: folder))
        coordinator.update(target: target, revealRequest: 1)
        #expect(view.numberOfRows == 1)
        #expect(coordinator.selectedNodes.isEmpty)
        let (replacement, _, _, _) = try fixture()
        target.tree = replacement.tree
        coordinator.update(target: target, revealRequest: 1)
        #expect(view.numberOfRows == 2)
        #expect(!view.isItemExpanded(coordinator.item(folder)))
    }

    @Test func commandDownOpensDirectoryAndRootMenuOmitsMutations() throws {
        let (target, folder, _, _) = try fixture()
        let (view, coordinator) = outline(for: target)
        view.selectRowIndexes(IndexSet(integer: view.row(forItem: coordinator.item(folder))), byExtendingSelection: false)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        view.keyDown(with: event)
        #expect(target.currentID == folder)
        let tree = try #require(target.tree)
        let menu = FileItemActions.shared.menu(for: [tree.metadata(for: tree.rootID)], target: target)
        #expect(!menu.items.contains { $0.title == "Rename…" || $0.title == "Move to Trash…" })
    }
    @Test func mapContextMenuUsesClickLocationWithoutPriorHover() throws {
        let (target, _, file, sibling) = try fixture()
        let tree = try #require(target.tree)
        let scene = try TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID),
            in: CGRect(x: 0, y: 0, width: 600, height: 300), displayScale: 1)
        let view = MapInputView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.scene = scene
        view.target = target
        view.onSelect = { target.select($0) }
        target.selectedID = sibling
        let tile = try #require(scene.tiles.first { scene.entries[$0.entryIndex].nodeID == file })
        let menu = try #require(view.menu(for: click(view, at: NSPoint(x: tile.rect.midX, y: tile.rect.midY))))
        #expect(target.selectedID == file)
        #expect(menu.items.first?.title == "Open")
        #expect(menu.items.first?.isEnabled == true)
        let blankMenu = try #require(view.menu(for: click(view, at: NSPoint(x: -10, y: -10))))
        #expect(blankMenu.items.first?.isEnabled == false)
    }

    @Test func aggregateMenuTargetsTheIndividualFile() throws {
        let (target, folder, _, _) = try fixture()
        let tree = try #require(target.tree)
        // A tiny viewport forces grouping without manufacturing scene entries.
        let scene = try TreemapScene.build(tree: tree, nodes: [folder],
            in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let view = MapInputView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.scene = scene
        view.target = target
        view.onSelect = { target.select($0) }
        let menu = try #require(view.menu(for: click(view, at: NSPoint(x: 0.5, y: 0.5))))
        #expect(target.selectedID != folder)
        #expect(target.selectedID == scene.hit(at: CGPoint(x: 0.5, y: 0.5))?.entry.nodeID)
        #expect(menu.items.first?.title == "Open")
    }

    @Test func arrowKeysExpandAndCollapseTheNativeHierarchy() throws {
        let (target, folder, _, _) = try fixture()
        let (view, coordinator) = outline(for: target)
        view.selectRowIndexes(IndexSet(integer: view.row(forItem: coordinator.item(folder))), byExtendingSelection: false)
        func arrow(_ code: UInt16, _ characters: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        view.keyDown(with: try arrow(124, "\u{F703}"))
        #expect(view.isItemExpanded(coordinator.item(folder)))
        #expect(view.numberOfRows == 3)
        view.keyDown(with: try arrow(123, "\u{F702}"))
        #expect(!view.isItemExpanded(coordinator.item(folder)))
        #expect(view.numberOfRows == 2)
    }

}
