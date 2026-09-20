import Darwin
import Foundation
import SpaceTreeNative
import Testing
@testable import SpaceTree

@Test func startupDirectoryEntriesMatchTraversalIdentities() throws {
    // A shallow read catches startup APFS device translation, firmlinks, and
    // covered mount points without scanning the user's disk.
    var entries: UnsafeMutablePointer<st_directory_entry_t>?
    var count = 0
    var diagnostics = st_directory_diagnostics_t()
    let error = st_list_directory_with_diagnostics("/", &entries, &count, &diagnostics)
    defer { st_free_directory_entries(entries, count) }
    #expect(error == 0)
    #expect(diagnostics.fallback_directories == 0)
    let records = UnsafeBufferPointer(start: try #require(entries), count: count)
    for name in ["System", "Users", "Applications", "Library", "private", "dev"] {
        let record = try #require(records.first { String(cString: $0.name) == name })
        var metadata = stat()
        #expect(lstat("/" + name, &metadata) == 0)
        #expect(record.device_id == UInt64(metadata.st_dev), "Device mismatch for /\(name)")
        #expect(record.file_id == UInt64(metadata.st_ino), "Inode mismatch for /\(name)")
    }
}

@Test func scannerCoalescesRepeatedAndNestedRoots() async throws {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let nested = base.appendingPathComponent("nested")
    try manager.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: base) }
    try Data([1, 2, 3]).write(to: nested.appendingPathComponent("only.bin"))

    let tree = try await DiskScanner.scan(
        roots: [ScanRoot(url: nested, name: "Nested"), ScanRoot(url: base, name: "Base"),
                ScanRoot(url: base, name: "Repeated")],
        displayName: "Group", identifier: "dedup"
    ) { _ in }
    #expect(tree.kind(of: tree.rootID) == .directory)
    #expect(tree.metadata(for: tree.rootID).fileCount == 1)
    #expect(tree.metadata(for: tree.rootID).directoryCount == 2)
    #expect(tree.metadata(for: tree.rootID).logicalBytes == 3)
    try tree.validate()
}

@Test func scannerDeduplicatesMacOSDataAliasesBeforeTraversal() async throws {
    // Exercise the actual firmlink namespace with a tiny fixture, not a disk scan.
    let manager = FileManager.default
    let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let nested = base.appendingPathComponent("nested")
    try manager.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: base) }
    try Data([1, 2, 3]).write(to: nested.appendingPathComponent("only.bin"))
    let alias = URL(fileURLWithPath: "/System/Volumes/Data" + base.path)
    guard manager.fileExists(atPath: alias.path) else { return }

    // Identical roots reached under different paths collapse to a single root.
    let repeated = try await DiskScanner.scan(
        roots: [ScanRoot(url: base, name: "Base"), ScanRoot(url: alias, name: "Data")],
        displayName: "Group", identifier: "alias"
    ) { _ in }
    #expect(repeated.kind(of: repeated.rootID) == .directory)
    #expect(repeated.metadata(for: repeated.rootID).fileCount == 1)

    // A root alias to a descendant must also prevent that descendant from being
    // scheduled by its parent. Path-prefix deduplication alone cannot do this.
    let overlapping = try await DiskScanner.scan(
        roots: [ScanRoot(url: base, name: "Base"),
                ScanRoot(url: alias.appendingPathComponent("nested"), name: "Nested alias")],
        displayName: "Group", identifier: "nested-alias"
    ) { _ in }
    #expect(overlapping.metadata(for: overlapping.rootID).fileCount == 1)
    #expect(overlapping.metadata(for: overlapping.rootID).logicalBytes == 3)
    #expect(overlapping.hardLinkReferenceCount == 0)
    try overlapping.validate()

    try Data([4, 5]).write(to: nested.appendingPathComponent("new.bin"))
    let updated = try await DiskScanner.refresh(
        root: overlapping,
        changedPaths: [nested.appendingPathComponent("new.bin").path],
        scanRoots: [ScanRoot(url: base, name: "Base"),
                    ScanRoot(url: alias.appendingPathComponent("nested"), name: "Nested alias")]
    ) { _ in }
    #expect(updated.metadata(for: updated.rootID).fileCount == 2)
    #expect(updated.metadata(for: updated.rootID).logicalBytes == 5)
    try updated.validate()
}
