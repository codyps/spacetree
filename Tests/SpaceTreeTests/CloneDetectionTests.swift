import Darwin
import Foundation
import SpaceTreeNative
import Testing
@testable import SpaceTree

@Test func bulkScanDetectsFullAndDivergedClones() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let original = base.appendingPathComponent("original")
    let clone = base.appendingPathComponent("clone")
    let diverged = base.appendingPathComponent("diverged")
    let copy = base.appendingPathComponent("independent")
    let hardlink = base.appendingPathComponent("hardlink")
    let data = Data((0..<262_144).map { _ in UInt8.random(in: 0...255) })
    try data.write(to: original)
    try data.write(to: copy)
    #expect(clonefile(original.path, clone.path, 0) == 0)
    #expect(clonefile(original.path, diverged.path, 0) == 0)
    #expect(link(original.path, hardlink.path) == 0)
    let file = try FileHandle(forWritingTo: diverged)
    try file.seekToEnd()
    try file.write(contentsOf: data)
    try file.synchronize()
    try file.close()
    // Exercise directory and symlink packed records in the same bulk response.
    try FileManager.default.createDirectory(at: base.appendingPathComponent("empty"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("symlink"), withDestinationURL: original)
    let recorder = ScanStatisticsRecorder(targetID: "fixture", roots: [base.path], mode: "test")
    let tree = try await DiskScanner.scan(url: base, statistics: recorder) { _ in }
    try tree.validate()
    let nodes = Dictionary(uniqueKeysWithValues: tree.children(of: tree.rootID).map { (tree.name(of: $0), $0) })
    let a = try #require(nodes["original"])
    let b = try #require(nodes["clone"])
    let c = try #require(nodes["diverged"])
    let d = try #require(nodes["independent"])
    let h = try #require(nodes["hardlink"])
    let ac = try #require(tree.clones[a])
    let bc = try #require(tree.clones[b])
    let cc = try #require(tree.clones[c])
    #expect(ac.sharesAllBlocks && bc.sharesAllBlocks)
    #expect(ac.cloneID == bc.cloneID)
    #expect(ac.fileID != bc.fileID)
    #expect(ac.referenceCount == 2)
    #expect(cc.cloneID != ac.cloneID && !cc.sharesAllBlocks)
    #expect(tree.clones[d] == nil)
    #expect(tree.clonePeers(of: a) == [b])
    #expect(tree.clones[h]?.fileID == ac.fileID)
    #expect(tree.metadata(for: b).allocatedBytes > 0) // Clones are not zeroed as hard links.
    #expect(tree.hardLinkReferenceCount == 1)
    let stats = try #require(recorder.finish(outcome: "complete", progress: ScanProgress(currentPath: "", itemCount: 0, bytesFound: 0, unreadableCount: 0), tree: tree)?.filesystemReads)
    #expect(stats.bulkEntries == 7)
    #expect(stats.bulkCalls >= 3) // Parent data + EOF and empty-child EOF.
    #expect(stats.fallbackDirectories == 0)
    #expect(stats.cloneQueryRetries == 0)
    #expect(stats.bulkErrors.isEmpty)

    let snapshot = ScanSnapshot(version: ScanSnapshot.currentVersion, targetID: "fixture", tree: tree,
                                progress: ScanProgress(currentPath: "", itemCount: 0, bytesFound: 0, unreadableCount: 0), scannedAt: Date(), scanDuration: 1, fseventID: 0)
    let restored = try SnapshotStore.decode(SnapshotStore.encode(snapshot))
    #expect(restored.tree == tree)

    // Mutation must refresh the other members' volume-wide sharing metadata too.
    try FileManager.default.removeItem(at: clone)
    let updated = try await DiskScanner.refresh(root: tree, changedPaths: [clone.path],
        scanRoots: [ScanRoot(url: base, name: "fixture")]) { _ in }
    #expect(!updated.children(of: updated.rootID).contains { updated.name(of: $0) == "clone" })
    try updated.validate()
}

@Test func nativeBulkReadsMultipleBatches() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    for index in 0..<2500 {
        let path = base.appendingPathComponent("\(index)-" + String(repeating: "x", count: 120)).path
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        #expect(fd >= 0)
        if fd >= 0 { close(fd) }
    }
    var entries: UnsafeMutablePointer<st_directory_entry_t>?
    var count = 0
    var diagnostics = st_directory_diagnostics_t()
    let error = st_list_directory_with_diagnostics(base.path, &entries, &count, &diagnostics)
    defer { st_free_directory_entries(entries, count) }
    #expect(error == 0)
    #expect(count == 2500)
    #expect(diagnostics.bulk_entries == 2500)
    #expect(diagnostics.bulk_calls > 2)
    #expect(diagnostics.fallback_directories == 0)
    #expect(diagnostics.bulk_error == 0)
}
