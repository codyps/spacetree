import AppKit
import SwiftUI
import Foundation
import Testing
@testable import SpaceTree

private let oldBackup = BackupSnapshot(id: "2026-10-01-010000", root: "/old", device: "/dev/disk1")
private let newBackup = BackupSnapshot(id: "2026-10-02-010000", root: "/new", device: "/dev/disk1")

private func comparisonData(_ records: [[String: Any]]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: ["Changes": records, "Totals": [:]], format: .xml, options: 0)
}

@Test func backupSameSizeRewriteAndShrinkingFiles() throws {
    let data = try comparisonData([
        ["OlderItem": ["Path": "/old/db", "Size": 500], "NewerItem": ["Path": "/new/db", "Size": 500]],
        ["OlderItem": ["Path": "/old/log", "Size": 100], "NewerItem": ["Path": "/new/log", "Size": 20]]
    ])
    let result = try BackupAnalysis.parse(data, older: oldBackup, newer: newBackup, inspect: { _ in false })
    #expect(result.changes[0].delta == 0)
    #expect(BackupMetric.affected.bytes(result.changes[0]) == 500)
    #expect(BackupMetric.sizeDelta.bytes(result.changes[1]) == 80)
    #expect(result.changes[1].delta == -80)
}

@Test func backupRepeatedChangesDoNotCancelAndFolderFrequencyIsDistinct() {
    let one = BackupComparison(older: "1", newer: "2", changes: [
        BackupChange(path: "volume/folder/a", kind: "modified", oldSize: 10, newSize: 30, subtree: false),
        BackupChange(path: "volume/folder/b", kind: "added", oldSize: 0, newSize: 5, subtree: false)
    ], warnings: [])
    let two = BackupComparison(older: "2", newer: "3", changes: [
        BackupChange(path: "volume/folder/a", kind: "modified", oldSize: 30, newSize: 10, subtree: false)
    ], warnings: [])
    let rows = BackupAnalysis.rankings([one, two], metric: .sizeDelta, folder: "volume")
    #expect(rows.count == 1)
    #expect(rows[0].bytes == 45)
    #expect(rows[0].netDelta == 5)
    #expect(rows[0].intervals.count == 2)
    let leaves = BackupAnalysis.rankings([one, two], metric: .sizeDelta, folder: "volume/folder", search: "/a")
    #expect(leaves.count == 1)
    #expect(leaves[0].bytes == 40)
    #expect(!leaves[0].isFolder)
}

@Test func backupSubtreesRemovalsAndDirectoryMetadata() throws {
    let data = try comparisonData([
        ["AddedItem": ["Path": "/new/folder", "Size": 100]],
        ["RemovedItem": ["Path": "/old/deleted", "Size": 30]],
        ["OlderItem": ["Path": "/old/meta"], "NewerItem": ["Path": "/new/meta"]]
    ])
    let result = try BackupAnalysis.parse(data, older: oldBackup, newer: newBackup, inspect: { $0.hasSuffix("folder") })
    #expect(result.changes.count == 2)
    #expect(result.changes[0].subtree == true)
    #expect(BackupMetric.affected.bytes(result.changes[1]) == 0)
    #expect(BackupMetric.removed.bytes(result.changes[1]) == 30)
    #expect(result.changes[1].delta == -30)
}

@Test func backupSubtreeSummaryRemainsVisibleWhenDrilling() {
    let comparisons = [BackupComparison(older: "1", newer: "2", changes: [
        BackupChange(path: "folder", kind: "added", oldSize: 0, newSize: 100, subtree: true),
    ], warnings: []), BackupComparison(older: "2", newer: "3", changes: [
        BackupChange(path: "folder/file", kind: "modified", oldSize: 5, newSize: 10, subtree: false)
    ], warnings: [])]
    let root = BackupAnalysis.rankings(comparisons, metric: .affected)
    #expect(root[0].bytes == 110)
    #expect(root[0].isFolder)
    let nested = BackupAnalysis.rankings(comparisons, metric: .affected, folder: "folder")
    #expect(nested.reduce(0) { $0 + $1.bytes } == 110)
    #expect(nested[0].hasSubtree)
    #expect(!nested[0].isFolder)
}

@Test func backupRejectsMalformedAndOutsidePaths() throws {
    for path in ["/newer/file", "/new/../secret", "/new"] {
        #expect(throws: (any Error).self) { try BackupAnalysis.relative(path, root: "/new") }
    }
    for size: Any in [-1, true, 0.5, "12"] {
        let data = try comparisonData([["AddedItem": ["Path": "/new/file", "Size": size]]])
        #expect(throws: (any Error).self) { try BackupAnalysis.parse(data, older: oldBackup, newer: newBackup) }
    }
    let truncated = Data("<plist><dict><key>Changes</key><array/></dict></plist>".utf8)
    #expect(throws: (any Error).self) { try BackupAnalysis.parse(truncated, older: oldBackup, newer: newBackup) }
    let mismatched = try comparisonData([["OlderItem": ["Path": "/old/a", "Size": 2], "NewerItem": ["Path": "/new/b", "Size": 2]]])
    #expect(throws: (any Error).self) { try BackupAnalysis.parse(mismatched, older: oldBackup, newer: newBackup) }
}

@Test func backupPreservesCRNamesAndReportsUnknownTypes() throws {
    let raw = Data("<plist><dict><key>Changes</key><array><dict><key>AddedItem</key><dict><key>Path</key><string>/new/Icon\r</string><key>Size</key><integer>2</integer></dict></dict></array><key>Totals</key><dict/></dict></plist>".utf8)
    let result = try BackupAnalysis.parse(raw, older: oldBackup, newer: newBackup, stderr: "Access warning", inspect: { _ in nil })
    #expect(result.changes[0].path == "Icon\r")
    #expect(result.changes[0].subtree == nil)
    #expect(result.warnings.count == 2)
}

@Test func backupCacheSeparatesDestinations() {
    let elsewhere = BackupSnapshot(id: newBackup.id, root: newBackup.root, device: "/dev/other")
    #expect(BackupAnalysis.cacheKey(older: oldBackup, newer: newBackup) != BackupAnalysis.cacheKey(older: oldBackup, newer: elsewhere))
}

@Test func backupCommandCancellationAndCacheReadback() throws {
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cache) }
    let cancelled = BackupCommand()
    cancelled.cancel()
    #expect(throws: CancellationError.self) { try cancelled.run(older: oldBackup, newer: newBackup, cacheDirectory: cache) }
    let comparison = BackupComparison(older: oldBackup.id, newer: newBackup.id, changes: [], warnings: ["cached warning"])
    let file = cache.appendingPathComponent(BackupAnalysis.cacheKey(older: oldBackup, newer: newBackup) + ".json")
    try JSONEncoder().encode(comparison).write(to: file)
    let result = try BackupCommand().run(older: oldBackup, newer: newBackup, cacheDirectory: cache)
    #expect(result.warnings == ["cached warning"])
}

@Test func backupSnapshotDiscoverySeparatesDevicesAndSkipsLiveMounts() {
    func mount(_ device: String, readOnly: Bool = true) -> MountedFilesystem {
        MountedFilesystem(url: URL(fileURLWithPath: "/Volumes/snapshot"), name: "Snapshot", format: "APFS", device: device,
                          totalCapacity: nil, availableCapacity: nil, isInternal: false, isRemovable: true, isReadOnly: readOnly,
                          apfsContainerUUID: nil, isDiskImage: false, isTimeMachine: true, isAuxiliary: false)
    }
    let found = BackupAnalysis.snapshots(mounts: [
        mount("com.apple.TimeMachine.2026-10-01-010000.backup@/dev/disk1"),
        mount("com.apple.TimeMachine.2026-10-01-010000.backup@/dev/disk2"),
        mount("com.apple.TimeMachine.2026-10-02-010000.backup@/dev/disk1", readOnly: false),
        mount("com.apple.TimeMachine.2026-10-03-010000.local@/dev/disk1"),
        mount("/dev/disk1")
    ])
    #expect(found.count == 2)
    #expect(Set(found.map(\.device)).count == 2)
    #expect(found.allSatisfy { $0.root.hasSuffix("/2026-10-01-010000.backup") })
}

// Opt-in, bounded integration check: point these variables at a small directory
// inside two mounted backup snapshots, not entire backup roots.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SPACETREE_TM_OLDER"] != nil && ProcessInfo.processInfo.environment["SPACETREE_TM_NEWER"] != nil))
func backupRealSnapshotComparisonAndCache() throws {
    let environment = ProcessInfo.processInfo.environment
    let older = BackupSnapshot(id: "older", root: try #require(environment["SPACETREE_TM_OLDER"]), device: "smoke-test")
    let newer = BackupSnapshot(id: "newer", root: try #require(environment["SPACETREE_TM_NEWER"]), device: "smoke-test")
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cache) }
    let result = try BackupCommand().run(older: older, newer: newer, cacheDirectory: cache)
    #expect(result.warnings.isEmpty)
    #expect(!result.changes.isEmpty)
    #expect(result.changes.allSatisfy { !$0.path.hasPrefix("/") })
    let cached = try BackupCommand().run(older: older, newer: newer, cacheDirectory: cache)
    #expect(cached.changes.count == result.changes.count)
    #expect(BackupAnalysis.rankings([result], metric: .affected).reduce(0) { $0 + $1.bytes } > 0)
}

@Test @MainActor func backupModelUpdatesMetricsAndNavigation() {
    let model = BackupChangesModel()
    #expect(model.metric == .sizeDelta)
    model.comparisons = [BackupComparison(older: "1", newer: "2", changes: [
        BackupChange(path: "folder/database", kind: "modified", oldSize: 100, newSize: 100, subtree: false),
        BackupChange(path: "folder/log", kind: "modified", oldSize: 20, newSize: 30, subtree: false)
    ], warnings: [])]
    #expect(model.rankings[0].bytes == 10)
    model.metric = .affected
    #expect(model.rankings[0].bytes == 130)
    model.folder = "folder"
    #expect(model.rankings.count == 2)
    model.metric = .sizeDelta
    #expect(model.rankings.count == 1)
    #expect(model.rankings[0].path == "folder/log")
    model.search = "database"
    #expect(model.rankings.isEmpty)
    model.metric = .affected
    #expect(model.rankings[0].bytes == 100)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SPACETREE_TM_PREVIEW"] != nil))
@MainActor func backupNativeViewRendering() throws {
    let model = BackupChangesModel()
    let data = try Data(contentsOf: URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["SPACETREE_TM_PLIST"])))
    let older = BackupSnapshot(id: "2026-09-24", root: try #require(ProcessInfo.processInfo.environment["SPACETREE_TM_OLDER"]), device: "smoke-test")
    let newer = BackupSnapshot(id: "2026-10-03", root: try #require(ProcessInfo.processInfo.environment["SPACETREE_TM_NEWER"]), device: "smoke-test")
    model.snapshots = [older, newer]
    model.device = older.device
    model.first = older.id
    model.last = newer.id
    model.comparisons = [try BackupAnalysis.parse(data, older: older, newer: newer)]
    model.requested = 1
    model.completed = 1
    model.folder = "SpaceTree"
    model.selected = "SpaceTree/DiskScanner.swift"
    model.status = "Native rendering check · real comparison of the SpaceTree Sources subtree"
    let view = NSHostingView(rootView: BackupChangesView(close: {}, model: model).frame(width: 1200, height: 800).background(Color(nsColor: .windowBackgroundColor)))
    view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["SPACETREE_TM_PREVIEW"])))
}

@Test func backupCommandFailureIncludesPathsAndAccessDiagnostics() throws {
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cache) }
    do {
        _ = try BackupCommand().run(older: oldBackup, newer: newBackup, cacheDirectory: cache)
        Issue.record("A comparison of nonexistent backup roots must fail")
    } catch {
        let message = error.localizedDescription
        #expect(message.contains("tmutil exited"))
        #expect(message.contains("/old"))
        #expect(message.contains("/new"))
        #expect(message.contains("No such file or directory"))
        #expect(!message.contains("Full Disk Access"))
    }
    let cachedFile = cache.appendingPathComponent(BackupAnalysis.cacheKey(older: oldBackup, newer: newBackup) + ".json")
    #expect(!FileManager.default.fileExists(atPath: cachedFile.path))
}

@Test func backupCarriageReturnRepairOnlyTouchesXMLStrings() throws {
    let xml = Data(" \n<plist>\r\n<dict><key>name</key><string>é\rA\r&amp;🌲</string><key>other</key><string>x</string></dict></plist>".utf8)
    let repaired = BackupAnalysis.preserveFilenameCarriageReturns(xml)
    #expect(String(decoding: repaired, as: UTF8.self).contains("<plist>\r\n"))
    let parsed = try #require(PropertyListSerialization.propertyList(from: repaired, format: nil) as? [String: String])
    #expect(parsed["name"] == "é\rA\r&🌲")
    let binary = try PropertyListSerialization.data(fromPropertyList: ["name": "a\r<string>"], format: .binary, options: 0)
    #expect(BackupAnalysis.preserveFilenameCarriageReturns(binary) == binary)
    let noRepair = Data("<plist><string>hello</string></plist>".utf8)
    #expect(BackupAnalysis.preserveFilenameCarriageReturns(noRepair) == noRepair)
}

@Test func backupMapShowsNestedFilesFromOverviewAndPreservesSubtreeTotals() throws {
    let comparisons = [BackupComparison(older: "1", newer: "2", changes: [
        BackupChange(path: "volume/Users/person/database", kind: "modified", oldSize: 300, newSize: 300, subtree: false),
        BackupChange(path: "volume/Users/person/log", kind: "modified", oldSize: 60, newSize: 100, subtree: false),
        BackupChange(path: "volume/cache", kind: "added", oldSize: 0, newSize: 200, subtree: true)
    ], warnings: []), BackupComparison(older: "2", newer: "3", changes: [
        BackupChange(path: "volume/cache/child", kind: "modified", oldSize: 100, newSize: 200, subtree: false)
    ], warnings: [])]
    let data = try BackupMapData.build(comparisons, metric: .affected)
    #expect(data.tree.allocatedBytes(of: data.tree.rootID) == 800)
    let scene = try TreemapScene.build(tree: data.tree, nodes: Array(data.tree.childIDs(of: data.tree.rootID)),
                                     in: CGRect(x: 0, y: 0, width: 1200, height: 800))
    let databaseID = try #require(data.ids["volume/Users/person/database"])
    let rect = try #require(scene.rect(for: databaseID))
    #expect(scene.hit(at: CGPoint(x: rect.midX, y: rect.midY))?.entry.nodeID == databaseID)
    #expect(scene.folders.contains { data.paths[$0.nodeID] == "volume/Users/person" })
    #expect(data.summaries.count == 1)
    let nested = try BackupMapData.build(comparisons, metric: .affected, folder: "volume/cache")
    #expect(nested.tree.allocatedBytes(of: nested.tree.rootID) == 400)
    #expect(nested.tree.fileCount(of: nested.tree.rootID) == 2)
    #expect(nested.summaries.count == 1)
    let filtered = try BackupMapData.build(comparisons, metric: .sizeDelta, search: "log")
    #expect(filtered.tree.allocatedBytes(of: filtered.tree.rootID) == 40)
    #expect(filtered.ids["volume/Users/person/log"] != nil)
    #expect(filtered.ids["volume/Users/person/database"] == nil)
}

@Test func backupProgressDistinguishesScanningFromParsing() {
    let scanning = BackupCommand.Progress(stage: .scanning, elapsed: 125, outputBytes: 4096)
    #expect(scanning.label.contains("2m 5s"))
    #expect(scanning.label.contains("comparison output"))
    #expect(!scanning.label.contains("100%"))
    let parsing = BackupCommand.Progress(stage: .classifying, elapsed: 126, completed: 100, total: 200)
    #expect(parsing.label.contains("100 of 200"))
    #expect(parsing.label.contains("Inspecting changes"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SPACETREE_TM_NORMALIZE_BENCHMARK"] != nil))
func backupXMLNormalizationBenchmark() throws {
    func sample(_ count: Int) -> Data {
        Data(("<?xml version=\"1.0\"?><plist><array>" + (0..<count).map { "<string>/Volumes/.timemachine/example.backup/Users/user/path/to/é-filename-\($0)\($0 % 100 == 0 ? "\r" : "")</string>" }.joined() + "</array></plist>").utf8)
    }
    let small = sample(2000)
    let startOld = Date()
    let xml = String(decoding: small, as: UTF8.self)
    let regex = try NSRegularExpression(pattern: "<string>.*?</string>", options: .dotMatchesLineSeparators)
    var preserved = xml
    for match in regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).reversed() {
        let range = try #require(Range(match.range, in: preserved))
        preserved.replaceSubrange(range, with: preserved[range].replacingOccurrences(of: "\r", with: "&#13;"))
    }
    let oldTime = Date().timeIntervalSince(startOld)
    let startNew = Date()
    let repaired = BackupAnalysis.preserveFilenameCarriageReturns(small)
    let newTime = Date().timeIntervalSince(startNew)
    #expect(Data(preserved.utf8) == repaired)
    let large = sample(100000)
    let startLarge = Date()
    _ = BackupAnalysis.preserveFilenameCarriageReturns(large)
    print("XML repair: 2,000 strings old=\(oldTime)s new=\(newTime)s; 100,000 strings new=\(Date().timeIntervalSince(startLarge))s (\(large.count) bytes)")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SPACETREE_TM_NESTED_PREVIEW"] != nil))
@MainActor func backupNestedNativeRenderingFromCachedComparisons() throws {
    let cache = try #require(ProcessInfo.processInfo.environment["SPACETREE_TM_CACHE"])
    let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: cache), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    let comparisons = try files.map { try JSONDecoder().decode(BackupComparison.self, from: Data(contentsOf: $0)) }
    #expect(!comparisons.isEmpty)
    let start = Date()
    let data = try BackupMapData.build(comparisons, metric: .affected)
    let scene = try TreemapScene.build(tree: data.tree, nodes: Array(data.tree.childIDs(of: data.tree.rootID)), in: CGRect(x: 0, y: 0, width: 1200, height: 740))
    print("Real backup map: \(comparisons.reduce(0) { $0 + $1.changes.count }) records, \(scene.tiles.count) tiles, prepared in \(Date().timeIntervalSince(start))s")
    let view = NSHostingView(rootView: VStack(alignment: .leading) {
        Text("Backup Changes · nested overview · \(comparisons.count) real cached intervals").font(.headline).padding(8)
        TreemapBaseLayer(scene: scene, bounds: scene.bounds).frame(width: 1200, height: 740)
    }.background(Color(nsColor: .windowBackgroundColor)))
    view.frame = NSRect(x: 0, y: 0, width: 1200, height: 780)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["SPACETREE_TM_NESTED_PREVIEW"])))
}

@Test func backupDestinationsResolveNetworkImagesAndPreferLocalDisks() throws {
    func mount(_ device: String, _ path: String, _ name: String, image: Bool = false) -> MountedFilesystem {
        MountedFilesystem(url: URL(fileURLWithPath: path), name: name, format: "APFS", device: device,
                          totalCapacity: nil, availableCapacity: nil, isInternal: false, isRemovable: false,
                          isReadOnly: false, apfsContainerUUID: nil, isDiskImage: image,
                          isTimeMachine: true, isAuxiliary: false)
    }
    let mounts = [mount("/dev/disk9s1", "/Volumes/USB", "USB Backup"),
                  mount("/dev/disk2s1", "/Volumes/Network", "Backup Image", image: true),
                  mount("//user:secret@nas.example/Backups", "/Volumes/Share", "Share"),
                  mount("/dev/disk20s1", "/Volumes/Unknown", "Unknown Image", image: true)]
    let data = try PropertyListSerialization.data(fromPropertyList: ["images": [
        ["image-path": "/Volumes/Share/My Mac.sparsebundle", "system-entities": [["dev-entry": "/dev/disk2s1"]]]
    ]], format: .xml, options: 0)
    let images = BackupDestinationDiscovery.imagePaths(data)
    let snapshots = ["/dev/disk2s1", "/dev/disk9s1", "/dev/disk20s1"].map {
        BackupSnapshot(id: "2026-10-01", root: "/snapshot", device: $0)
    }
    let destinations = BackupDestinationDiscovery.destinations(snapshots: snapshots, mounts: mounts, imagePaths: images)
    #expect(destinations.map(\.connection) == [.local, .unknown, .network])
    #expect(destinations.first?.id == "/dev/disk9s1")
    #expect(destinations.last?.location == "smb://nas.example/Backups")
    #expect(destinations.last?.label == "smb://nas.example/Backups · Network (slower)")
    #expect(BackupDestinationDiscovery.networkLocation("server:/export/backups") == "nfs://server/export/backups")
    #expect(BackupDestinationDiscovery.imagePaths(Data()).isEmpty)
    let localImage = BackupDestinationDiscovery.destinations(snapshots: [snapshots[0]], mounts: mounts,
        imagePaths: ["/dev/disk2s1": "/Volumes/USB/Local.sparsebundle"])
    #expect(localImage.first?.connection == .local)
    let prefixMismatch = BackupDestinationDiscovery.destinations(snapshots: [snapshots[0]], mounts: mounts,
        imagePaths: ["/dev/disk2s1": "/Volumes/Share-other/My Mac.sparsebundle"])
    #expect(prefixMismatch.first?.connection == .unknown)
}
