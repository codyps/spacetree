import CryptoKit
import Foundation
import Darwin

struct ScanSnapshot: Sendable {
    static let currentVersion = 4

    let version: Int
    let targetID: String
    let tree: ScanTree
    let progress: ScanProgress
    let scannedAt: Date
    let scanDuration: TimeInterval
    let fseventID: UInt64
    var statistics: ScanStatistics? = nil
    var requiresMetadataRefresh = false
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

    // These synchronous actor operations cannot interleave at an await: only one
    // snapshot's decode/validation or serialization working set is active at once.
    private actor IO {
        func load(targetID: String, progress: @Sendable (String) -> Void) -> ScanSnapshot? {
            autoreleasepool {
                guard !Task.isCancelled else { return nil }
                progress("Opening previous scan…")
                guard let data = try? Data(contentsOf: SnapshotStore.snapshotURL(for: targetID), options: .mappedIfSafe),
                      let snapshot = try? SnapshotStore.decode(data, progress: progress),
                      snapshot.targetID == targetID else { return nil }
                return snapshot
            }
        }

        func save(_ snapshot: ScanSnapshot) {
            do {
                try FileManager.default.createDirectory(at: SnapshotStore.snapshotsDirectory(), withIntermediateDirectories: true)
                try SnapshotStore.write(snapshot, to: SnapshotStore.snapshotURL(for: snapshot.targetID))
            } catch {
                // Cache failures must never turn a successful scan into a failure.
            }
        }
    }

    private static let io = IO()

    static func load(targetID: String, progress: @Sendable (String) -> Void = { _ in }) async -> ScanSnapshot? {
        await io.load(targetID: targetID, progress: progress)
    }
    static func save(_ snapshot: ScanSnapshot) async { await io.save(snapshot) }

    // Write beside the destination and rename only after the complete checksummed
    // stream has reached disk. Failure leaves the previous cache intact.
    static func write(_ snapshot: ScanSnapshot, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".spacetree-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? file.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        var writer = BinaryWriter(file: file)
        try encode(snapshot, into: &writer)
        try writer.finish()
        try file.synchronize()
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func encode(_ snapshot: ScanSnapshot) throws -> Data {
        var writer = BinaryWriter()
        try encode(snapshot, into: &writer)
        try writer.finish()
        return writer.data
    }

    private static func encode(_ snapshot: ScanSnapshot, into writer: inout BinaryWriter) throws {
        guard snapshot.version == ScanSnapshot.currentVersion else { throw SnapshotFormatError.unsupportedVersion }
        try writer.append(bytes: signature)
        try writer.append(UInt32(snapshot.version))
        try writer.append(string: snapshot.targetID)
        try writer.append(snapshot.scannedAt.timeIntervalSince1970.bitPattern)
        try writer.append(snapshot.scanDuration.bitPattern)
        try writer.append(snapshot.fseventID)
        try writer.append(string: snapshot.progress.currentPath)
        try writer.append(Int64(snapshot.progress.itemCount))
        try writer.append(snapshot.progress.bytesFound)
        try writer.append(Int64(snapshot.progress.unreadableCount))
        try writer.append(Int64(snapshot.progress.duplicateReferenceCount))

        let tree = snapshot.tree
        try writer.append(string: tree.generation.rawValue.uuidString)
        try writer.append(tree.rootID.rawValue)
        try writer.append(string: tree.displayURL.absoluteString)
        try writer.append(Int64(tree.unreadableCount))
        try writer.append(count: tree.nodes.count)
        try writer.append(count: tree.nameBytes.count)
        try writer.append(count: tree.roots.count)
        try writer.append(count: tree.hardLinkGroups.count)
        try writer.append(count: tree.hardLinkMembers.count)

        for node in tree.nodes {
            try writer.append(node.allocatedBytes)
            try writer.append(node.logicalBytes)
            try writer.append(node.modifiedNanoseconds)
            try writer.append(node.parent.rawValue)
            try writer.append(node.firstChild.rawValue)
            try writer.append(node.nextSibling.rawValue)
            try writer.append(node.nameOffset)
            try writer.append(node.recursiveFileCount)
            try writer.append(node.recursiveDirectoryCount)
            try writer.append(node.duplicateReferenceCount)
            try writer.append(node.hardLinkGroup)
            try writer.append(node.nameLength)
            try writer.append(node.flags.rawValue)
        }
        try writer.append(bytes: tree.nameBytes)
        for root in tree.roots {
            try writer.append(root.nodeID.rawValue)
            try writer.append(string: root.url.absoluteString)
        }
        for group in tree.hardLinkGroups {
            try writer.append(group.deviceID)
            try writer.append(group.fileID)
            try writer.append(group.allocatedBytes)
            try writer.append(group.logicalBytes)
            try writer.append(group.canonicalMember.rawValue)
            try writer.append(group.memberStart)
            try writer.append(group.memberCount)
        }
        for member in tree.hardLinkMembers { try writer.append(member.rawValue) }

        try writer.append(count: tree.clones.count)
        for id in tree.clones.keys.sorted() {
            let clone = tree.clones[id]!
            try writer.append(id.rawValue)
            try writer.append(clone.deviceID)
            try writer.append(clone.fileID)
            try writer.append(clone.cloneID)
            try writer.append(clone.flags)
            try writer.append(clone.referenceCount ?? 0)
            try writer.append(UInt32(clone.referenceCount == nil ? 0 : 1))
        }

        let statisticsData = try JSONEncoder().encode(snapshot.statistics)
        try writer.append(count: statisticsData.count)
        try writer.append(bytes: Array(statisticsData))
    }

    static func decode(_ data: Data, progress reportProgress: @Sendable (String) -> Void = { _ in }) throws -> ScanSnapshot {
        try Task.checkCancellation()
        reportProgress("Verifying previous scan…")
        guard data.count >= signature.count + checksumSize else { throw SnapshotFormatError.truncated }
        let payloadEnd = data.count - checksumSize
        let payload = data.prefix(payloadEnd)
        let expected = data.suffix(checksumSize)
        var hash = SHA256()
        for offset in stride(from: 0, to: payload.count, by: 1_048_576) {
            try Task.checkCancellation()
            let start = payload.startIndex + offset
            hash.update(data: payload[start..<min(payload.endIndex, start + 1_048_576)])
        }
        guard Data(hash.finalize()) == expected else { throw SnapshotFormatError.invalidChecksum }
        reportProgress("Loading previous scan…")

        var reader = BinaryReader(data: payload)
        guard try reader.readBytes(count: signature.count) == signature else { throw SnapshotFormatError.invalidSignature }
        let version = Int(try reader.readUInt32())
        guard (2...ScanSnapshot.currentVersion).contains(version) else { throw SnapshotFormatError.unsupportedVersion }
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
        var clones: [NodeID: CloneMetadata] = [:]
        if version >= 4 {
            let count = try reader.readCount(maximum: nodeCount)
            guard try checkedByteCount(count, 44) <= reader.remainingCount else { throw SnapshotFormatError.truncated }
            clones.reserveCapacity(count)
            for _ in 0..<count {
                let id = NodeID(rawValue: try reader.readUInt32())
                let device = try reader.readUInt64()
                let file = try reader.readUInt64()
                let clone = try reader.readUInt64()
                let flags = try reader.readUInt64()
                let refs = try reader.readUInt32()
                let valid = try reader.readUInt32()
                guard valid <= 1, clones[id] == nil else { throw SnapshotFormatError.invalidValue }
                clones[id] = CloneMetadata(deviceID: device, fileID: file, cloneID: clone,
                                           flags: flags, referenceCount: valid == 1 ? refs : nil)
            }
        }
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
            unreadableCount: unreadableCount,
            clones: clones
        )
        try Task.checkCancellation()
        reportProgress("Validating previous scan…")
        try tree.validate()
        try Task.checkCancellation()
        return ScanSnapshot(
            version: ScanSnapshot.currentVersion,
            targetID: targetID,
            tree: tree,
            progress: progress,
            scannedAt: scannedAt,
            scanDuration: duration,
            fseventID: eventID,
            statistics: statistics,
            requiresMetadataRefresh: version < 4
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
    private static let bufferSize = 1_048_576
    var data = Data()
    private let file: FileHandle?
    private var hash = SHA256()

    init(file: FileHandle? = nil) {
        self.file = file
        if file != nil { data.reserveCapacity(Self.bufferSize) }
    }

    mutating func append<T: FixedWidthInteger>(_ value: T) throws {
        if file != nil, data.count + MemoryLayout<T>.size > Self.bufferSize { try flush() }
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        try flushIfNeeded()
    }

    mutating func append(bytes: [UInt8]) throws {
        guard file != nil else { data.append(contentsOf: bytes); return }
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + Self.bufferSize - data.count)
            data.append(contentsOf: bytes[offset..<end])
            offset = end
            try flushIfNeeded()
        }
    }

    mutating func append(string: String) throws {
        let bytes = Array(string.utf8)
        try append(count: bytes.count)
        try append(bytes: bytes)
    }

    mutating func append(count: Int) throws {
        guard count >= 0, count <= Int(UInt32.max) else { throw SnapshotFormatError.invalidValue }
        try append(UInt32(count))
    }

    private mutating func flushIfNeeded() throws {
        if file != nil, data.count >= Self.bufferSize { try flush() }
    }

    private mutating func flush() throws {
        guard let file, !data.isEmpty else { return }
        hash.update(data: data)
        try file.write(contentsOf: data)
        data.removeAll(keepingCapacity: true)
    }

    mutating func finish() throws {
        if let file {
            try flush()
            try file.write(contentsOf: Data(hash.finalize()))
        } else {
            let checksum = SHA256.hash(data: data)
            data.append(contentsOf: checksum)
        }
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
        try Task.checkCancellation()
        guard count >= 0, offset <= data.count, count <= data.count - offset else { throw SnapshotFormatError.truncated }
        let result = Array(data[(data.startIndex + offset)..<(data.startIndex + offset + count)])
        offset += count
        return result
    }

    private mutating func readInteger<T: FixedWidthInteger>() throws -> T {
        if offset & 0xffff == 0 { try Task.checkCancellation() }
        let size = MemoryLayout<T>.size
        guard offset <= data.count, size <= data.count - offset else { throw SnapshotFormatError.truncated }
        let value = data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        offset += size
        return T(littleEndian: value)
    }
}
