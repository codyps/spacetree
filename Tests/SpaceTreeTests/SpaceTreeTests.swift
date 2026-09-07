import Foundation
import Testing
import SpaceTreeNative
@testable import SpaceTree

@Test func compactTreeAggregatesSortsAndReconstructsPaths() throws {
    let base = URL(fileURLWithPath: "/tmp/example", isDirectory: true)
    var builder = ScanTreeBuilder(rootName: "example", rootURL: base)
    let small = builder.addNode(
        parent: builder.rootID,
        name: "small.txt",
        kind: .file,
        allocatedBytes: 100,
        logicalBytes: 80,
        modifiedAt: nil,
        identity: nil
    )
    let nested = builder.addNode(
        parent: builder.rootID,
        name: "nested",
        kind: .directory,
        allocatedBytes: 0,
        logicalBytes: 0,
        modifiedAt: nil,
        identity: nil
    )
    let large = builder.addNode(
        parent: nested,
        name: "large.dat",
        kind: .file,
        allocatedBytes: 900,
        logicalBytes: 700,
        modifiedAt: nil,
        identity: nil
    )
    let tree = try builder.finalize()
    let root = tree.metadata(for: tree.rootID)

    #expect(root.allocatedBytes == 1_000)
    #expect(root.logicalBytes == 780)
    #expect(root.fileCount == 2)
    #expect(root.directoryCount == 2)
    #expect(tree.children(of: tree.rootID).map { tree.name(of: $0) } == ["nested", "small.txt"])
    #expect(tree.url(of: large).path == "/tmp/example/nested/large.dat")
    #expect(tree.url(of: small).path == "/tmp/example/small.txt")
    try tree.validate()
}

@Test func nodeRecordMeetsMemoryBudget() {
    #expect(MemoryLayout<NodeRecord>.stride <= 96)
}

@Test func treemapUsesAvailableAreaWithoutOverlap() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
    let items = [
        TreemapLayout.Item(id: NodeID(rawValue: 0), weight: 60),
        TreemapLayout.Item(id: NodeID(rawValue: 1), weight: 30),
        TreemapLayout.Item(id: NodeID(rawValue: 2), weight: 10)
    ]
    let rectangles = TreemapLayout.rectangles(for: items, in: bounds)

    #expect(rectangles.count == items.count)
    let area = rectangles.reduce(0) { $0 + $1.width * $1.height }
    #expect(abs(area - bounds.width * bounds.height) < 0.01)
    for first in rectangles.indices {
        for second in rectangles.indices where first < second {
            #expect(rectangles[first].intersection(rectangles[second]).isEmpty)
        }
    }
}

@Test func treemapSceneContainsASeparateTileForEveryFile() throws {
    let base = URL(fileURLWithPath: "/tmp/treemap", isDirectory: true)
    var builder = ScanTreeBuilder(rootName: "treemap", rootURL: base)
    let nested = builder.addNode(parent: builder.rootID, name: "nested", kind: .directory, allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    _ = builder.addNode(parent: nested, name: "a.bin", kind: .file, allocatedBytes: 600, logicalBytes: 600, modifiedAt: nil, identity: nil)
    _ = builder.addNode(parent: nested, name: "b.bin", kind: .file, allocatedBytes: 300, logicalBytes: 300, modifiedAt: nil, identity: nil)
    let rootFile = builder.addNode(parent: builder.rootID, name: "c.bin", kind: .file, allocatedBytes: 100, logicalBytes: 100, modifiedAt: nil, identity: nil)
    let tree = try builder.finalize()
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)

    let scene = TreemapScene.build(tree: tree, nodes: [nested, rootFile], in: bounds)

    #expect(scene.entries.map { tree.name(of: $0.nodeID) } == ["a.bin", "b.bin", "c.bin"])
    #expect(scene.tiles.count == 3)
    #expect(scene.totalSize == 1_000)
    for tile in scene.tiles {
        let point = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
        #expect(scene.hit(at: point)?.entry.nodeID == scene.entries[tile.entryIndex].nodeID)
    }
}

@Test func treemapGroupsFilesInsideInvisibleDirectoryRegions() throws {
    let base = URL(fileURLWithPath: "/tmp/grouped-treemap", isDirectory: true)
    var builder = ScanTreeBuilder(rootName: "grouped-treemap", rootURL: base)
    let firstDirectory = builder.addNode(parent: builder.rootID, name: "first", kind: .directory, allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    let nestedDirectory = builder.addNode(parent: firstDirectory, name: "nested", kind: .directory, allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    let firstLarge = builder.addNode(parent: nestedDirectory, name: "first-large.bin", kind: .file, allocatedBytes: 40, logicalBytes: 40, modifiedAt: nil, identity: nil)
    let firstSmall = builder.addNode(parent: nestedDirectory, name: "first-small.bin", kind: .file, allocatedBytes: 10, logicalBytes: 10, modifiedAt: nil, identity: nil)
    let secondDirectory = builder.addNode(parent: builder.rootID, name: "second", kind: .directory, allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    let secondLarge = builder.addNode(parent: secondDirectory, name: "second-large.bin", kind: .file, allocatedBytes: 30, logicalBytes: 30, modifiedAt: nil, identity: nil)
    let secondSmall = builder.addNode(parent: secondDirectory, name: "second-small.bin", kind: .file, allocatedBytes: 20, logicalBytes: 20, modifiedAt: nil, identity: nil)
    _ = builder.addNode(parent: builder.rootID, name: "empty", kind: .directory, allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    let tree = try builder.finalize()
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)

    let scene = TreemapScene.build(tree: tree, nodes: tree.children(of: tree.rootID), in: bounds)
    let firstLargeRect = try #require(scene.rect(for: firstLarge))
    let firstSmallRect = try #require(scene.rect(for: firstSmall))
    let secondLargeRect = try #require(scene.rect(for: secondLarge))
    let secondSmallRect = try #require(scene.rect(for: secondSmall))
    let firstBounds = firstLargeRect.union(firstSmallRect)
    let secondBounds = secondLargeRect.union(secondSmallRect)

    #expect(scene.tiles.count == 4)
    #expect(!scene.entries.contains { $0.nodeID == firstDirectory || $0.nodeID == nestedDirectory || $0.nodeID == secondDirectory })
    #expect(firstBounds.intersection(secondBounds).isEmpty)
    #expect(abs(firstBounds.width * firstBounds.height - bounds.width * bounds.height / 2) < 0.01)
    #expect(abs(secondBounds.width * secondBounds.height - bounds.width * bounds.height / 2) < 0.01)
    #expect(firstBounds.union(secondBounds) == bounds)
}

@Test func scannerBuildsHierarchyAndDoesNotFollowSymlinks() async throws {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: base) }

    let nestedURL = base.appendingPathComponent("nested", isDirectory: true)
    try manager.createDirectory(at: nestedURL, withIntermediateDirectories: true)
    try Data(repeating: 7, count: 8_192).write(to: nestedURL.appendingPathComponent("sample.bin"))
    try manager.createSymbolicLink(at: base.appendingPathComponent("loop"), withDestinationURL: base)

    let tree = try await DiskScanner.scan(url: base) { _ in }
    let root = tree.metadata(for: tree.rootID)
    let children = childMetadata(tree, tree.rootID)

    #expect(root.fileCount == 2)
    #expect(children.contains(where: { $0.name == "nested" && $0.isDirectory }))
    #expect(children.first(where: { $0.name == "loop" })?.allocatedBytes == 0)
    #expect(root.allocatedBytes > 0)
    let nested = try #require(children.first(where: { $0.name == "nested" }))
    let sample = childMetadata(tree, nested.handle.nodeID).first(where: { $0.name == "sample.bin" })
    #expect(sample?.logicalBytes == 8_192)
    #expect((sample?.allocatedBytes ?? 0) > 0)
    try tree.validate()
}

@Test func scannerRejectsASymbolicLinkRoot() async throws {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let link = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: base, withIntermediateDirectories: true)
    try manager.createSymbolicLink(at: link, withDestinationURL: base)
    defer {
        try? manager.removeItem(at: link)
        try? manager.removeItem(at: base)
    }

    await #expect(throws: DiskScannerError.self) {
        try await DiskScanner.scan(url: link) { _ in }
    }
}

@Test func scannerCountsHardLinkedDataOnceDeterministicallyAcrossDirectories() async throws {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let firstDirectory = base.appendingPathComponent("a", isDirectory: true)
    let secondDirectory = base.appendingPathComponent("z", isDirectory: true)
    try manager.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    try manager.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: base) }

    let canonicalURL = firstDirectory.appendingPathComponent("canonical.bin")
    let linkedURL = secondDirectory.appendingPathComponent("linked.bin")
    try Data(repeating: 42, count: 16_384).write(to: canonicalURL)
    try manager.linkItem(at: canonicalURL, to: linkedURL)

    for _ in 0..<3 {
        let tree = try await DiskScanner.scan(url: base) { _ in }
        let files = tree.files(inSubtree: [tree.rootID]).map { tree.metadata(for: $0) }
        let root = tree.metadata(for: tree.rootID)

        #expect(files.count == 2)
        #expect(files.filter(\.isDuplicateReference).count == 1)
        #expect(files.first(where: { !$0.isDuplicateReference })?.url.path == canonicalURL.path)
        #expect(root.duplicateReferenceCount == 1)
        #expect(root.allocatedBytes == files.first(where: { !$0.isDuplicateReference })?.allocatedBytes)
        try tree.validate()
    }
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

    let retainedGeneration = first.tree?.generation
    #expect(retainedGeneration != nil)
    #expect(second.tree != nil)

    second.scan()
    #expect(first.tree?.generation == retainedGeneration)
    try await waitForScan(second)
    #expect(first.tree?.generation == retainedGeneration)
}

@Test func scannerBuildsSyntheticMultipleRootTree() async throws {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let first = base.appendingPathComponent("first", isDirectory: true)
    let second = base.appendingPathComponent("second", isDirectory: true)
    try manager.createDirectory(at: first, withIntermediateDirectories: true)
    try manager.createDirectory(at: second, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: base) }
    try Data(repeating: 1, count: 1_024).write(to: first.appendingPathComponent("one.bin"))
    try Data(repeating: 2, count: 2_048).write(to: second.appendingPathComponent("two.bin"))

    let tree = try await DiskScanner.scan(
        roots: [ScanRoot(url: first, name: "First"), ScanRoot(url: second, name: "Second")],
        displayName: "Group",
        identifier: "group"
    ) { _ in }
    let roots = childMetadata(tree, tree.rootID)

    #expect(tree.kind(of: tree.rootID) == .syntheticRoot)
    #expect(roots.map(\.name) == ["Second", "First"] || roots.map(\.name) == ["First", "Second"])
    #expect(Set(tree.files(inSubtree: [tree.rootID]).map { tree.url(of: $0).path }) == Set([
        first.appendingPathComponent("one.bin").path,
        second.appendingPathComponent("two.bin").path
    ]))
    try tree.validate()
}

@Test func incrementalRefreshRebuildsOnlyChangedFilesystemSubtrees() async throws {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let changed = base.appendingPathComponent("changed", isDirectory: true)
    let stable = base.appendingPathComponent("stable", isDirectory: true)
    try manager.createDirectory(at: changed, withIntermediateDirectories: true)
    try manager.createDirectory(at: stable, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: base) }
    try Data([1]).write(to: changed.appendingPathComponent("old.bin"))
    try Data([2]).write(to: stable.appendingPathComponent("stable.bin"))

    let original = try await DiskScanner.scan(url: base) { _ in }
    try manager.removeItem(at: changed.appendingPathComponent("old.bin"))
    try Data([3, 4, 5]).write(to: changed.appendingPathComponent("new.bin"))
    let refreshed = try await DiskScanner.refresh(
        root: original,
        changedPaths: [changed.appendingPathComponent("new.bin").path],
        scanRoots: [ScanRoot(url: base, name: base.lastPathComponent)]
    ) { _ in }

    let paths = Set(refreshed.files(inSubtree: [refreshed.rootID]).map { refreshed.url(of: $0).path })
    #expect(paths.contains(changed.appendingPathComponent("new.bin").path))
    #expect(!paths.contains(changed.appendingPathComponent("old.bin").path))
    #expect(paths.contains(stable.appendingPathComponent("stable.bin").path))
    #expect(refreshed.generation != original.generation)
    try refreshed.validate()
}

@Test func snapshotsRoundTripTheCompactTree() throws {
    let url = URL(fileURLWithPath: "/tmp/snapshot", isDirectory: true)
    var builder = ScanTreeBuilder(rootName: "snapshot", rootURL: url)
    _ = builder.addNode(
        parent: builder.rootID,
        name: "file.bin",
        kind: .file,
        allocatedBytes: 4_096,
        logicalBytes: 2_048,
        modifiedAt: Date(timeIntervalSince1970: 100),
        identity: nil
    )
    let tree = try builder.finalize()
    let snapshot = ScanSnapshot(
        version: ScanSnapshot.currentVersion,
        targetID: "test",
        tree: tree,
        progress: ScanProgress(currentPath: url.path, itemCount: 2, bytesFound: 4_096, unreadableCount: 0),
        scannedAt: Date(timeIntervalSince1970: 200),
        scanDuration: 1.25,
        fseventID: 42
    )
    let encoded = try SnapshotStore.encode(snapshot)
    let decoded = try SnapshotStore.decode(encoded)

    #expect(decoded.tree == tree)
    #expect(decoded.progress == snapshot.progress)
    #expect(decoded.fseventID == 42)
    try decoded.tree.validate()
}

@Test func snapshotsRejectCorruption() throws {
    let url = URL(fileURLWithPath: "/tmp/corrupt", isDirectory: true)
    var builder = ScanTreeBuilder(rootName: "corrupt", rootURL: url)
    _ = builder.addNode(parent: builder.rootID, name: "file", kind: .file, allocatedBytes: 1, logicalBytes: 1, modifiedAt: nil, identity: nil)
    let tree = try builder.finalize()
    let snapshot = ScanSnapshot(
        version: ScanSnapshot.currentVersion,
        targetID: "corrupt",
        tree: tree,
        progress: ScanProgress(currentPath: url.path, itemCount: 2, bytesFound: 1, unreadableCount: 0),
        scannedAt: Date(),
        scanDuration: 0.1,
        fseventID: 1
    )
    var encoded = try SnapshotStore.encode(snapshot)
    encoded[encoded.startIndex + 12] ^= 0xff

    #expect(throws: SnapshotFormatError.self) {
        try SnapshotStore.decode(encoded)
    }
}

@Test func compactTreeStoresOneHundredThousandEntriesWithinBudget() throws {
    let url = URL(fileURLWithPath: "/tmp/scale", isDirectory: true)
    var builder = ScanTreeBuilder(rootName: "scale", rootURL: url)
    for index in 0..<100_000 {
        _ = builder.addNode(
            parent: builder.rootID,
            name: "file-\(index).bin",
            kind: .file,
            allocatedBytes: 4_096,
            logicalBytes: 1_000,
            modifiedAt: nil,
            identity: nil
        )
    }
    let tree = try builder.finalize()

    #expect(tree.nodeCount == 100_001)
    #expect(tree.estimatedStorageBytes < 13 * 1_024 * 1_024)
    try tree.validate()
}

@Test func optionalMillionEntryReleaseBenchmark() throws {
    guard ProcessInfo.processInfo.environment["SPACETREE_RUN_MILLION_NODE_BENCHMARK"] == "1" else { return }
    let started = ContinuousClock.now
    let url = URL(fileURLWithPath: "/tmp/million", isDirectory: true)
    var builder = ScanTreeBuilder(rootName: "million", rootURL: url)
    for index in 0..<1_000_000 {
        _ = builder.addNode(
            parent: builder.rootID,
            name: "file-\(index).bin",
            kind: .file,
            allocatedBytes: 4_096,
            logicalBytes: 1_000,
            modifiedAt: nil,
            identity: nil
        )
    }
    let tree = try builder.finalize()
    let treeElapsed = started.duration(to: .now)
    let layoutStarted = ContinuousClock.now
    let scene = TreemapScene.build(
        tree: tree,
        nodes: tree.children(of: tree.rootID),
        in: CGRect(x: 0, y: 0, width: 800, height: 500)
    )
    let layoutElapsed = layoutStarted.duration(to: .now)
    print("SpaceTree million-entry benchmark: nodes=\(tree.nodeCount) storage=\(tree.estimatedStorageBytes) stride=\(MemoryLayout<NodeRecord>.stride) tree=\(treeElapsed) treemap=\(layoutElapsed)")

    #expect(tree.nodeCount == 1_000_001)
    #expect(tree.estimatedStorageBytes <= 128 * 1_024 * 1_024)
    #expect(scene.tiles.count == 1_000_000)
    try tree.validate()
}

@Test func optionalFilesystemScanBenchmark() async throws {
    guard let path = ProcessInfo.processInfo.environment["SPACETREE_SCAN_BENCHMARK_PATH"], !path.isEmpty else { return }
    let started = ContinuousClock.now
    let tree = try await DiskScanner.scan(url: URL(fileURLWithPath: path, isDirectory: true)) { _ in }
    let elapsed = started.duration(to: .now)
    print("SpaceTree filesystem benchmark: path=\(path) nodes=\(tree.nodeCount) elapsed=\(elapsed)")
    try tree.validate()
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
    #expect(target.currentChildren.contains(where: { $0.name == "changed.bin" }))
    #expect(!target.hasFilesystemChanges)

    try manager.createDirectory(at: base.appendingPathComponent("new-folder"), withIntermediateDirectories: false)
    let secondDeadline = ContinuousClock.now + .seconds(4)
    while !target.hasFilesystemChanges, ContinuousClock.now < secondDeadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(target.hasFilesystemChanges)
    target.rescan()
    try await waitForScan(target)
    #expect(target.currentChildren.contains(where: { $0.name == "new-folder" && $0.isDirectory }))
}

@MainActor
private func waitForScan(_ target: ScanTarget) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
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

@Test @MainActor func timeMachineAndDiskImageMountsAreHiddenByDefault() {
    let model = AppModel()

    #expect(!model.showTimeMachineMounts)
    #expect(!model.showDiskImageMounts)
    #expect(!model.showAuxiliaryMounts)

    for target in model.visibleTargets {
        #expect(!target.isTimeMachine)
        #expect(!target.isDiskImage)
        #expect(!target.isAuxiliary)
    }

    let dummyURL = URL(fileURLWithPath: "/tmp/test", isDirectory: true)
    let standard = ScanTarget(id: "standard", url: dummyURL, name: "Standard", kind: .volume(format: "APFS", isInternal: true, isRemovable: false, isReadOnly: false))
    let tmTarget = ScanTarget(id: "tm", url: dummyURL, name: "TM", kind: .volume(format: "APFS", isInternal: false, isRemovable: true, isReadOnly: false), isTimeMachine: true)
    let diTarget = ScanTarget(id: "di", url: dummyURL, name: "DI", kind: .volume(format: "HFS+", isInternal: false, isRemovable: true, isReadOnly: true), isDiskImage: true)
    let auxTarget = ScanTarget(id: "aux", url: dummyURL, name: "Aux", kind: .volume(format: "APFS", isInternal: false, isRemovable: true, isReadOnly: true), isAuxiliary: true)

    model.targets = [standard, tmTarget, diTarget, auxTarget]
    #expect(model.visibleTargets.map(\.id) == ["standard"])
    #expect(model.timeMachineTargetCount == 1)
    #expect(model.diskImageTargetCount == 1)
    #expect(model.auxiliaryTargetCount == 1)

    model.showTimeMachineMounts = true
    #expect(model.visibleTargets.map(\.id) == ["standard", "tm"])

    model.showDiskImageMounts = true
    #expect(model.visibleTargets.map(\.id) == ["standard", "tm", "di"])

    model.showAuxiliaryMounts = true
    #expect(model.visibleTargets.map(\.id) == ["standard", "tm", "di", "aux"])
}

@Test func mountDiscoveryIdentifiesKnownMountTypes() {
    let mounts = MountDiscovery.mountedFilesystems()
    for mount in mounts {
        if mount.url.path.hasPrefix("/Volumes/.timemachine")
            || mount.url.path.hasPrefix("/Volumes/com.apple.TimeMachine")
            || mount.device.contains("com.apple.TimeMachine") {
            #expect(mount.isTimeMachine)
        }
        if mount.url.path.hasPrefix("/Library/Developer/CoreSimulator/") {
            #expect(mount.isAuxiliary)
            #expect(mount.isDiskImage)
        }
    }
}

@Test func metadataScanEnablesProcessProtectionAndRestoresThreadPolicy() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try Data("local".utf8).write(to: tempDir.appendingPathComponent("local.txt"))
    let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    #expect(previous >= 0)
    defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) }
    #expect(setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_ON) == 0)

    var ptr: UnsafeMutablePointer<st_directory_entry_t>?
    var count: Int = 0
    let error = tempDir.withUnsafeFileSystemRepresentation { st_list_directory($0, &ptr, &count) }
    #expect(error == 0)
    #expect(count == 1)
    #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_ON)
    st_free_directory_entries(ptr, count)

    let policy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS)
    #expect(policy == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

    let triggerPolicy = getiopolicy_np(IOPOL_TYPE_VFS_TRIGGER_RESOLVE, IOPOL_SCOPE_PROCESS)
    #expect(triggerPolicy == IOPOL_VFS_TRIGGER_RESOLVE_OFF)
}

private func childMetadata(_ tree: ScanTree, _ nodeID: NodeID) -> [NodeMetadata] {
    tree.children(of: nodeID).map { tree.metadata(for: $0) }
}
