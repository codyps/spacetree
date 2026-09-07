import Foundation
import Testing
@testable import SpaceTree

@Test @MainActor func directoryNavigationSupportsHistoryAndBranching() throws {
    let base = URL(fileURLWithPath: "/tmp/navigation")
    var builder = ScanTreeBuilder(rootName: "navigation", rootURL: base)
    let folder = builder.addNode(parent: builder.rootID, name: "folder", kind: .directory, allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    let nested = builder.addNode(parent: folder, name: "nested", kind: .directory, allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    let sibling = builder.addNode(parent: builder.rootID, name: "sibling", kind: .directory, allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    let file = builder.addNode(parent: nested, name: "file", kind: .file, allocatedBytes: 1, logicalBytes: 1, modifiedAt: nil, identity: nil)
    let tree = try builder.finalize()
    let target = ScanTarget(id: "navigation", url: base, name: "navigation", kind: .folder, persistResults: false)
    target.tree = tree

    #expect(!target.canGoBack && !target.canGoForward && !target.canGoUp)
    target.goUp()
    target.goBack()
    target.goForward()
    #expect(target.currentID == tree.rootID)

    target.open(tree.metadata(for: folder))
    target.open(tree.metadata(for: nested))
    target.open(tree.metadata(for: file))
    #expect(target.currentID == nested)
    #expect(target.selectedID == file)
    target.searchText = "no matches"
    target.goUp()
    #expect(target.currentID == folder)
    #expect(target.selectedID == nil && target.searchText.isEmpty)
    target.goBack()
    #expect(target.currentID == nested)
    target.goBack()
    #expect(target.currentID == folder)
    target.goForward()
    #expect(target.currentID == nested)

    // Clicking the current breadcrumb must preserve forward history.
    target.open(tree.metadata(for: nested))
    #expect(target.canGoForward)
    target.goForward()
    #expect(target.currentID == folder)
    #expect(!target.canGoForward)

    // Jumping to an ancestor is recorded like any other directory change.
    target.open(tree.metadata(for: tree.rootID))
    target.goBack()
    #expect(target.currentID == folder)
    target.open(tree.metadata(for: sibling))
    #expect(!target.canGoForward)
    target.goBack()
    #expect(target.currentID == folder)
}

@Test @MainActor func directoryNavigationStopsAtSyntheticRootAndResetsForNewScans() throws {
    let base = URL(fileURLWithPath: "/tmp/navigation-container")
    var builder = ScanTreeBuilder(rootName: "container", rootURL: base, synthetic: true)
    let volume = builder.addPhysicalRoot(name: "volume", url: base, parent: builder.rootID)
    let tree = try builder.finalize()
    let target = ScanTarget(id: "container", url: base, name: "container", kind: .folder, persistResults: false)
    target.tree = tree
    target.open(tree.metadata(for: volume))
    target.goUp()
    #expect(target.currentID == tree.rootID)
    #expect(!target.canGoUp)
    target.goBack()
    #expect(target.currentID == volume)
    #expect(target.canGoForward)

    var replacement = ScanTreeBuilder(rootName: "replacement", rootURL: base)
    target.tree = try replacement.finalize()
    #expect(target.currentID == target.tree?.rootID)
    #expect(!target.canGoBack && !target.canGoForward && !target.canGoUp)
    target.open(tree.metadata(for: volume))
    #expect(target.currentID == target.tree?.rootID)
    target.tree = nil
    #expect(target.currentID == nil)
    #expect(!target.canGoBack && !target.canGoForward && !target.canGoUp)
}
