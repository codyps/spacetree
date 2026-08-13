import Foundation
import Testing
@testable import SpaceTree

@Test func directoryAggregatesAndSortsChildren() {
    let base = URL(fileURLWithPath: "/tmp/example")
    let small = FileNode.file(url: base.appendingPathComponent("small.txt"), size: 100, logicalSize: 80, modifiedAt: nil)
    let large = FileNode.file(url: base.appendingPathComponent("large.dat"), size: 900, logicalSize: 700, modifiedAt: nil)
    let root = FileNode.directory(url: base, children: [small, large])

    #expect(root.size == 1_000)
    #expect(root.logicalSize == 780)
    #expect(root.fileCount == 2)
    #expect(root.children.map(\.name) == ["large.dat", "small.txt"])
}

@Test func treemapUsesAvailableAreaWithoutOverlap() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
    let items = [
        TreemapLayout.Item(id: "a", weight: 60),
        TreemapLayout.Item(id: "b", weight: 30),
        TreemapLayout.Item(id: "c", weight: 10)
    ]
    let rectangles = TreemapLayout.rectangles(for: items, in: bounds)

    #expect(rectangles.count == items.count)
    let area = rectangles.values.reduce(0) { $0 + $1.width * $1.height }
    #expect(abs(area - bounds.width * bounds.height) < 0.01)
    for first in rectangles.keys {
        for second in rectangles.keys where first < second {
            #expect(rectangles[first]!.intersection(rectangles[second]!).isEmpty)
        }
    }
}

@Test func treemapSceneContainsASeparateTileForEveryFile() {
    let base = URL(fileURLWithPath: "/tmp/treemap")
    let nested = FileNode.directory(
        url: base.appendingPathComponent("nested"),
        children: [
            FileNode.file(url: base.appendingPathComponent("nested/a.bin"), size: 600, logicalSize: 600, modifiedAt: nil),
            FileNode.file(url: base.appendingPathComponent("nested/b.bin"), size: 300, logicalSize: 300, modifiedAt: nil)
        ]
    )
    let rootFile = FileNode.file(url: base.appendingPathComponent("c.bin"), size: 100, logicalSize: 100, modifiedAt: nil)
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)

    let scene = TreemapScene.build(nodes: [nested, rootFile], in: bounds)

    #expect(scene.entries.map(\.node.name) == ["a.bin", "b.bin", "c.bin"])
    #expect(scene.tiles.count == 3)
    #expect(scene.totalSize == 1_000)
    for tile in scene.tiles {
        let point = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
        #expect(scene.entry(at: point)?.id == scene.entries[tile.entryIndex].id)
    }
}

@Test func scannerBuildsHierarchyAndDoesNotFollowSymlinks() async throws {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: base) }

    let nested = base.appendingPathComponent("nested", isDirectory: true)
    try manager.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(repeating: 7, count: 8_192).write(to: nested.appendingPathComponent("sample.bin"))
    try manager.createSymbolicLink(at: base.appendingPathComponent("loop"), withDestinationURL: base)

    let root = try await DiskScanner.scan(url: base) { _ in }

    #expect(root.fileCount == 2)
    #expect(root.children.contains(where: { $0.name == "nested" && $0.isDirectory }))
    #expect(root.children.first(where: { $0.name == "loop" })?.size == 0)
    #expect(root.size > 0)
    let sample = root.children.first(where: { $0.name == "nested" })?.children.first(where: { $0.name == "sample.bin" })
    #expect(sample?.logicalSize == 8_192)
    #expect((sample?.size ?? 0) > 0)
}

@Test func scannerCountsHardLinkedDataOnce() async throws {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: base) }

    let original = base.appendingPathComponent("original.bin")
    let linked = base.appendingPathComponent("linked.bin")
    try Data(repeating: 42, count: 16_384).write(to: original)
    try manager.linkItem(at: original, to: linked)

    let root = try await DiskScanner.scan(url: base) { _ in }
    let files = root.children.filter { !$0.isDirectory }

    #expect(files.count == 2)
    #expect(files.filter(\.isDuplicateReference).count == 1)
    #expect(files.filter { !$0.isDuplicateReference }.count == 1)
    #expect(root.duplicateReferenceCount == 1)
    #expect(root.size == files.first(where: { !$0.isDuplicateReference })?.size)
}

@Test @MainActor func scanTargetsRunIndependentlyAndRetainOtherResults() async throws {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let firstURL = base.appendingPathComponent("first", isDirectory: true)
    let secondURL = base.appendingPathComponent("second", isDirectory: true)
    try manager.createDirectory(at: firstURL, withIntermediateDirectories: true)
    try manager.createDirectory(at: secondURL, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: base) }
    try Data(repeating: 1, count: 4_096).write(to: firstURL.appendingPathComponent("one.bin"))
    try Data(repeating: 2, count: 8_192).write(to: secondURL.appendingPathComponent("two.bin"))

    let first = ScanTarget(id: "first", url: firstURL, name: "First", kind: .folder, persistResults: false)
    let second = ScanTarget(id: "second", url: secondURL, name: "Second", kind: .folder, persistResults: false)
    first.scan()
    second.scan()
    try await waitForScan(first)
    try await waitForScan(second)

    let retainedFirstResult = first.root
    #expect(retainedFirstResult != nil)
    #expect(second.root != nil)

    second.scan()
    #expect(first.root == retainedFirstResult)
    try await waitForScan(second)
    #expect(first.root == retainedFirstResult)
}

@Test func snapshotsRoundTripTheCompleteTree() throws {
    let url = URL(fileURLWithPath: "/tmp/snapshot")
    let root = FileNode.directory(
        url: url,
        children: [FileNode.file(url: url.appendingPathComponent("file.bin"), size: 4_096, logicalSize: 2_048, modifiedAt: Date(timeIntervalSince1970: 100))]
    )
    let snapshot = ScanSnapshot(
        version: ScanSnapshot.currentVersion,
        targetID: "test",
        root: root,
        progress: ScanProgress(currentPath: url.path, itemCount: 2, bytesFound: 4_096, unreadableCount: 0),
        scannedAt: Date(timeIntervalSince1970: 200),
        scanDuration: 1.25,
        fseventID: 42
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let decoded = try PropertyListDecoder().decode(ScanSnapshot.self, from: encoder.encode(snapshot))

    #expect(decoded.root == root)
    #expect(decoded.progress == snapshot.progress)
    #expect(decoded.fseventID == 42)
}

@Test @MainActor func fseventsInvalidatesACompletedScan() async throws {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: base) }

    let target = ScanTarget(id: "events", url: base, name: "Events", kind: .folder, persistResults: false)
    target.scan()
    try await waitForScan(target)
    guard target.changeTrackingAvailable else { return }
    try Data([1, 2, 3]).write(to: base.appendingPathComponent("changed.bin"))

    let deadline = ContinuousClock.now + .seconds(4)
    while !target.hasFilesystemChanges, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(target.hasFilesystemChanges)

    target.rescan()
    try await waitForScan(target)
    #expect(target.root?.children.contains(where: { $0.name == "changed.bin" }) == true)
    #expect(!target.hasFilesystemChanges)

    try manager.createDirectory(at: base.appendingPathComponent("new-folder"), withIntermediateDirectories: false)
    let secondDeadline = ContinuousClock.now + .seconds(4)
    while !target.hasFilesystemChanges, ContinuousClock.now < secondDeadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(target.hasFilesystemChanges)
    target.rescan()
    try await waitForScan(target)
    #expect(target.root?.children.contains(where: { $0.name == "new-folder" && $0.isDirectory }) == true)
}

@MainActor
private func waitForScan(_ target: ScanTarget) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while target.state == .scanning, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(target.state == .complete)
}

@Test @MainActor func dashboardGroupsMountedAPFSVolumesByNativeContainer() {
    let mounts = MountDiscovery.mountedFilesystems()
    let apfsGroups = Dictionary(grouping: mounts.compactMap { mount in
        mount.apfsContainerUUID.map { ($0, mount) }
    }, by: { $0.0 })
    let model = AppModel()

    #expect(!mounts.isEmpty)
    for (containerUUID, members) in apfsGroups {
        let target = model.targets.first { $0.id == "apfs:\(containerUUID)" }
        #expect(target != nil)
        #expect(target?.roots.count == members.count)
    }
}
