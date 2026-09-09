import CryptoKit
import Foundation
import Testing
@testable import SpaceTree

private func streamingFixture(count: Int = 4) throws -> ScanSnapshot {
    var builder = ScanTreeBuilder(rootName: "snapshot", rootURL: URL(fileURLWithPath: "/tmp/snapshot"))
    for index in 0..<count {
        _ = builder.addNode(parent: builder.rootID, name: "file-\(index)-" + String(repeating: "x", count: 64),
                            kind: .file, allocatedBytes: 4096, logicalBytes: 2000, modifiedAt: nil,
                            identity: index < 2 ? FileIdentity(device: 1, inode: 2) : nil,
                            clone: index == 2 ? CloneMetadata(deviceID: 1, fileID: 3, cloneID: 4, flags: 0x40, referenceCount: 2) : nil)
    }
    return ScanSnapshot(version: ScanSnapshot.currentVersion, targetID: "stream-test", tree: try builder.finalize(),
                        progress: ScanProgress(currentPath: "", itemCount: count + 1, bytesFound: 0, unreadableCount: 0),
                        scannedAt: Date(timeIntervalSince1970: 123), scanDuration: 4, fseventID: 5)
}

@Test func streamedSnapshotMatchesEncodingAcrossChunkBoundariesAndReplacesAtomically() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snapshot")
    try Data("previous cache".utf8).write(to: url)
    let snapshot = try streamingFixture(count: 25_000) // Both nodes and names span multiple chunks.
    try SnapshotStore.write(snapshot, to: url)
    let bytes = try Data(contentsOf: url)
    #expect(bytes == (try SnapshotStore.encode(snapshot)))
    #expect(try SnapshotStore.decode(bytes).tree == snapshot.tree)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["snapshot"])
}

@Test func failedStreamPreservesExistingDestinationAndRemovesTemporaryFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snapshot")
    let previous = Data("previous cache".utf8)
    try previous.write(to: url)
    let snapshot = try streamingFixture()
    let invalid = ScanSnapshot(version: -1, targetID: snapshot.targetID, tree: snapshot.tree,
                               progress: snapshot.progress, scannedAt: snapshot.scannedAt,
                               scanDuration: snapshot.scanDuration, fseventID: snapshot.fseventID)
    #expect(throws: SnapshotFormatError.self) { try SnapshotStore.write(invalid, to: url) }
    #expect(try Data(contentsOf: url) == previous)
    // Force failure at publication, after all chunks and the checksum were written.
    let blocked = directory.appendingPathComponent("directory")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try SnapshotStore.write(snapshot, to: blocked) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["directory", "snapshot"])
}

@Test func snapshotDecoderAcceptsNonzeroIndexSliceWithoutCopyingAndRejectsTruncation() throws {
    let snapshot = try streamingFixture()
    let encoded = try SnapshotStore.encode(snapshot)
    var padded = Data(repeating: 0, count: 17)
    padded.append(encoded)
    let slice = padded.dropFirst(17)
    #expect(slice.startIndex == 17)
    #expect(try SnapshotStore.decode(slice).tree == snapshot.tree)
    #expect(throws: SnapshotFormatError.self) { try SnapshotStore.decode(slice.dropLast()) }
}

@Test func compactValidationStillRejectsCyclesBadLinksAndDuplicateHardLinkMembers() throws {
    let original = try streamingFixture(count: 130).tree
    try original.validate()
    func changed(nodes: [NodeRecord], members: [NodeID]? = nil) -> ScanTree {
        ScanTree(generation: original.generation, rootID: original.rootID, displayURL: original.displayURL,
                 nodes: nodes, nameBytes: original.nameBytes, roots: original.roots,
                 hardLinkGroups: original.hardLinkGroups, hardLinkMembers: members ?? original.hardLinkMembers,
                 unreadableCount: original.unreadableCount, clones: original.clones)
    }
    let first = Int(original.nodes[0].firstChild.rawValue)
    var nodes = original.nodes
    nodes[first].nextSibling = NodeID(rawValue: UInt32(first))
    #expect(throws: ScanTreeValidationError.self) { try changed(nodes: nodes).validate() }
    nodes = original.nodes
    nodes[0].firstChild = NodeID(rawValue: UInt32(nodes.count))
    #expect(throws: ScanTreeValidationError.self) { try changed(nodes: nodes).validate() }
    nodes = original.nodes
    nodes[first].parent = .null
    #expect(throws: ScanTreeValidationError.self) { try changed(nodes: nodes).validate() }
    nodes = original.nodes
    nodes[0].allocatedBytes += 1
    #expect(throws: ScanTreeValidationError.self) { try changed(nodes: nodes).validate() }
    var members = original.hardLinkMembers
    members[1] = members[0]
    #expect(throws: ScanTreeValidationError.self) { try changed(nodes: original.nodes, members: members).validate() }
}

@Test func snapshotPayloadBoundsExcludeChecksum() throws {
    let encoded = try SnapshotStore.encode(streamingFixture())
    func signed(_ payload: Data) -> Data {
        var result = payload
        result.append(contentsOf: SHA256.hash(data: payload))
        return result
    }
    let payload = Data(encoded.dropLast(32))
    #expect(throws: SnapshotFormatError.truncated) {
        try SnapshotStore.decode(signed(Data(payload.dropLast())))
    }
    var extra = payload
    extra.append(0)
    #expect(throws: SnapshotFormatError.trailingBytes) { try SnapshotStore.decode(signed(extra)) }
    var corrupt = encoded
    corrupt[20] ^= 1
    #expect(throws: SnapshotFormatError.invalidChecksum) { try SnapshotStore.decode(corrupt) }
}
