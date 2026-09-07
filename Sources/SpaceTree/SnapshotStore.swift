import CryptoKit
import Foundation

struct ScanSnapshot: Sendable {
    static let currentVersion = 3

    let version: Int
    let targetID: String
    let tree: ScanTree
    let progress: ScanProgress
    let scannedAt: Date
    let scanDuration: TimeInterval
    let fseventID: UInt64
    var statistics: ScanStatistics? = nil
}

enum SnapshotFormatError: Error {
    case invalidSignature
    case unsupportedVersion
    case truncated
    case invalidChecksum
    case invalidValue
    case trailingBytes
}

enum SnapshotStore {
    private static let signature = Array("SPTREE02".utf8)
    private static let checksumSize = SHA256.Digest.byteCount
    private static let maximumNodes = 100_000_000
    private static let maximumNameBytes = 2_000_000_000

    static func load(targetID: String) async -> ScanSnapshot? {
        await Task.detached(priority: .utility) {
            let url = snapshotURL(for: targetID)
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? decode(data),

                  snapshot.targetID == targetID else { return nil }
            return snapshot
        }.value
    }

    static func save(_ snapshot: ScanSnapshot) async {
        await Task.detached(priority: .utility) {
            do {
                let directory = snapshotsDirectory()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encode(snapshot).write(to: snapshotURL(for: snapshot.targetID), options: .atomic)
            } catch {
                // A cache failure must never turn a successful filesystem scan into a failure.
            }
        }.value
    }

    static func encode(_ snapshot: ScanSnapshot) throws -> Data {
        guard snapshot.version == ScanSnapshot.currentVersion else { throw SnapshotFormatError.unsupportedVersion }
        var writer = BinaryWriter()
        writer.append(bytes: signature)
        writer.append(UInt32(snapshot.version))
        try writer.append(string: snapshot.targetID)
        writer.append(snapshot.scannedAt.timeIntervalSince1970.bitPattern)
        writer.append(snapshot.scanDuration.bitPattern)
        writer.append(snapshot.fseventID)
        try writer.append(string: snapshot.progress.currentPath)
        writer.append(Int64(snapshot.progress.itemCount))
        writer.append(snapshot.progress.bytesFound)
        writer.append(Int64(snapshot.progress.unreadableCount))
        writer.append(Int64(snapshot.progress.duplicateReferenceCount))

        let tree = snapshot.tree
        try writer.append(string: tree.generation.rawValue.uuidString)
        writer.append(tree.rootID.rawValue)
        try writer.append(string: tree.displayURL.absoluteString)
        writer.append(Int64(tree.unreadableCount))
        try writer.append(count: tree.nodes.count)
        try writer.append(count: tree.nameBytes.count)
        try writer.append(count: tree.roots.count)
        try writer.append(count: tree.hardLinkGroups.count)
        try writer.append(count: tree.hardLinkMembers.count)

        for node in tree.nodes {
            writer.append(node.allocatedBytes)
            writer.append(node.logicalBytes)
            writer.append(node.modifiedNanoseconds)
            writer.append(node.parent.rawValue)
            writer.append(node.firstChild.rawValue)
            writer.append(node.nextSibling.rawValue)
            writer.append(node.nameOffset)
            writer.append(node.recursiveFileCount)
            writer.append(node.recursiveDirectoryCount)
            writer.append(node.duplicateReferenceCount)
            writer.append(node.hardLinkGroup)
            writer.append(node.nameLength)
            writer.append(node.flags.rawValue)
        }
        writer.append(bytes: tree.nameBytes)
        for root in tree.roots {
            writer.append(root.nodeID.rawValue)
            try writer.append(string: root.url.absoluteString)
        }
        for group in tree.hardLinkGroups {
            writer.append(group.deviceID)
            writer.append(group.fileID)
            writer.append(group.allocatedBytes)
            writer.append(group.logicalBytes)
            writer.append(group.canonicalMember.rawValue)
            writer.append(group.memberStart)
            writer.append(group.memberCount)
        }
        for member in tree.hardLinkMembers { writer.append(member.rawValue) }

        let statisticsData = try JSONEncoder().encode(snapshot.statistics)
        try writer.append(count: statisticsData.count)
        writer.append(bytes: Array(statisticsData))
        let checksum = SHA256.hash(data: writer.data)
        writer.data.append(contentsOf: checksum)
        return writer.data
    }

    static func decode(_ data: Data) throws -> ScanSnapshot {
        guard data.count >= signature.count + checksumSize else { throw SnapshotFormatError.truncated }
        let payloadEnd = data.count - checksumSize
        let payload = data.prefix(payloadEnd)
        let expected = data.suffix(checksumSize)
        guard Data(SHA256.hash(data: payload)) == expected else { throw SnapshotFormatError.invalidChecksum }

        var reader = BinaryReader(data: Data(payload))
        guard try reader.readBytes(count: signature.count) == signature else { throw SnapshotFormatError.invalidSignature }
        let version = Int(try reader.readUInt32())
        guard version == 2 || version == ScanSnapshot.currentVersion else { throw SnapshotFormatError.unsupportedVersion }
        let targetID = try reader.readString()
        let scannedAt = Date(timeIntervalSince1970: Double(bitPattern: try reader.readUInt64()))
        let duration = Double(bitPattern: try reader.readUInt64())
        let eventID = try reader.readUInt64()
        let progress = ScanProgress(
            currentPath: try reader.readString(),
            itemCount: try checkedInt(reader.readInt64()),
            bytesFound: try reader.readInt64(),
            unreadableCount: try checkedInt(reader.readInt64()),
            duplicateReferenceCount: try checkedInt(reader.readInt64())
        )

        guard let generationUUID = UUID(uuidString: try reader.readString()) else { throw SnapshotFormatError.invalidValue }
        let rootID = NodeID(rawValue: try reader.readUInt32())
        guard let displayURL = URL(string: try reader.readString()) else { throw SnapshotFormatError.invalidValue }
        let unreadableCount = try checkedInt(reader.readInt64())
        let nodeCount = try reader.readCount(maximum: maximumNodes)
        let nameCount = try reader.readCount(maximum: maximumNameBytes)
        let rootCount = try reader.readCount(maximum: maximumNodes)
        let groupCount = try reader.readCount(maximum: maximumNodes)
        let memberCount = try reader.readCount(maximum: maximumNodes)
        let fixedBytes = try checkedByteCount(nodeCount, 60)
            + checkedByteCount(nameCount, 1)
            + checkedByteCount(rootCount, 8)
            + checkedByteCount(groupCount, 44)
            + checkedByteCount(memberCount, 4)
        guard fixedBytes <= reader.remainingCount else { throw SnapshotFormatError.truncated }

        var nodes: [NodeRecord] = []
        nodes.reserveCapacity(nodeCount)
        for _ in 0..<nodeCount {
            let allocatedBytes = try reader.readUInt64()
            let logicalBytes = try reader.readUInt64()
            let modifiedNanoseconds = try reader.readInt64()
            let parent = NodeID(rawValue: try reader.readUInt32())
            let firstChild = NodeID(rawValue: try reader.readUInt32())
            let nextSibling = NodeID(rawValue: try reader.readUInt32())
            let nameOffset = try reader.readUInt32()
            let recursiveFileCount = try reader.readUInt32()
            let recursiveDirectoryCount = try reader.readUInt32()
            let duplicateReferenceCount = try reader.readUInt32()
            let hardLinkGroup = try reader.readUInt32()
            let nameLength = try reader.readUInt16()
            let flags = NodeFlags(rawValue: try reader.readUInt16())
            var node = NodeRecord(
                allocatedBytes: allocatedBytes,
                logicalBytes: logicalBytes,
                modifiedNanoseconds: modifiedNanoseconds,
                parent: parent,
                nameOffset: nameOffset,
                nameLength: nameLength,
                kind: flags.kind
            )
            node.firstChild = firstChild
            node.nextSibling = nextSibling
            node.recursiveFileCount = recursiveFileCount
            node.recursiveDirectoryCount = recursiveDirectoryCount
            node.duplicateReferenceCount = duplicateReferenceCount
            node.hardLinkGroup = hardLinkGroup
            node.flags = flags
            nodes.append(node)
        }
        let names = try reader.readBytes(count: nameCount)
        var roots: [RootDescriptor] = []
        roots.reserveCapacity(rootCount)
        for _ in 0..<rootCount {
            let nodeID = NodeID(rawValue: try reader.readUInt32())
            guard let url = URL(string: try reader.readString()) else { throw SnapshotFormatError.invalidValue }
            roots.append(RootDescriptor(nodeID: nodeID, url: url))
        }
        var groups: [HardLinkGroup] = []
        groups.reserveCapacity(groupCount)
        for _ in 0..<groupCount {
            groups.append(HardLinkGroup(
                deviceID: try reader.readUInt64(),
                fileID: try reader.readUInt64(),
                allocatedBytes: try reader.readUInt64(),
                logicalBytes: try reader.readUInt64(),
                canonicalMember: NodeID(rawValue: try reader.readUInt32()),
                memberStart: try reader.readUInt32(),
                memberCount: try reader.readUInt32()
            ))
        }
        var members: [NodeID] = []
        members.reserveCapacity(memberCount)
        for _ in 0..<memberCount { members.append(NodeID(rawValue: try reader.readUInt32())) }
        var statistics: ScanStatistics?
        if version >= 3 {
            let count = try reader.readCount(maximum: 1_048_576)
            statistics = try JSONDecoder().decode(ScanStatistics?.self, from: Data(reader.readBytes(count: count)))
        }
        guard reader.isAtEnd else { throw SnapshotFormatError.trailingBytes }

        let tree = ScanTree(
            generation: TreeGeneration(rawValue: generationUUID),
            rootID: rootID,
            displayURL: displayURL,
            nodes: nodes,
            nameBytes: names,
            roots: roots,
            hardLinkGroups: groups,
            hardLinkMembers: members,
            unreadableCount: unreadableCount
        )
        try tree.validate()
        return ScanSnapshot(
            version: ScanSnapshot.currentVersion,
            targetID: targetID,
            tree: tree,
            progress: progress,
            scannedAt: scannedAt,
            scanDuration: duration,
            fseventID: eventID,
            statistics: statistics
        )
    }

    private static func snapshotsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SpaceTree/Snapshots", isDirectory: true)
    }

    private static func snapshotURL(for targetID: String) -> URL {
        let digest = SHA256.hash(data: Data(targetID.utf8)).map { String(format: "%02x", $0) }.joined()
        return snapshotsDirectory().appendingPathComponent("\(digest).spacetree")
    }

    private static func checkedInt(_ value: Int64) throws -> Int {
        guard value >= 0, value <= Int64(Int.max) else { throw SnapshotFormatError.invalidValue }
        return Int(value)
    }

    private static func checkedByteCount(_ count: Int, _ stride: Int) throws -> Int {
        let result = count.multipliedReportingOverflow(by: stride)
        guard !result.overflow else { throw SnapshotFormatError.invalidValue }
        return result.partialValue
    }
}

private struct BinaryWriter {
    var data = Data()

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    mutating func append(string: String) throws {
        let bytes = Array(string.utf8)
        try append(count: bytes.count)
        append(bytes: bytes)
    }

    mutating func append(count: Int) throws {
        guard count >= 0, count <= Int(UInt32.max) else { throw SnapshotFormatError.invalidValue }
        append(UInt32(count))
    }
}

private struct BinaryReader {
    let data: Data
    var offset = 0
    var isAtEnd: Bool { offset == data.count }
    var remainingCount: Int { data.count - offset }

    mutating func readUInt16() throws -> UInt16 { try readInteger() }
    mutating func readUInt32() throws -> UInt32 { try readInteger() }
    mutating func readUInt64() throws -> UInt64 { try readInteger() }
    mutating func readInt64() throws -> Int64 { try readInteger() }

    mutating func readCount(maximum: Int) throws -> Int {
        let value = Int(try readUInt32())
        guard value <= maximum else { throw SnapshotFormatError.invalidValue }
        return value
    }

    mutating func readString() throws -> String {
        let count = try readCount(maximum: data.count)
        let bytes = try readBytes(count: count)
        guard let value = String(bytes: bytes, encoding: .utf8) else { throw SnapshotFormatError.invalidValue }
        return value
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= data.count, count <= data.count - offset else { throw SnapshotFormatError.truncated }
        let result = Array(data[offset..<(offset + count)])
        offset += count
        return result
    }

    private mutating func readInteger<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        guard offset <= data.count, size <= data.count - offset else { throw SnapshotFormatError.truncated }
        let value = data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        offset += size
        return T(littleEndian: value)
    }
}
