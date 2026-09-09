import Foundation

struct NodeID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    static let null = NodeID(rawValue: .max)

    let rawValue: UInt32

    static func < (lhs: NodeID, rhs: NodeID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TreeGeneration: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct NodeHandle: Hashable, Codable, Sendable, Identifiable {
    let generation: TreeGeneration
    let nodeID: NodeID

    var id: String { "\(generation.rawValue.uuidString):\(nodeID.rawValue)" }
}

enum NodeKind: UInt16, Codable, Sendable {
    case file = 0
    case directory = 1
    case symlink = 2
    case other = 3
    case syntheticRoot = 4
}

struct NodeFlags: OptionSet, Codable, Sendable {
    static let kindMask = NodeFlags(rawValue: 0x0007)
    static let unreadable = NodeFlags(rawValue: 1 << 3)
    static let duplicateReference = NodeFlags(rawValue: 1 << 4)
    static let tombstone = NodeFlags(rawValue: 1 << 5)

    let rawValue: UInt16

    init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    init(kind: NodeKind) {
        rawValue = kind.rawValue
    }

    var kind: NodeKind {
        NodeKind(rawValue: rawValue & Self.kindMask.rawValue) ?? .other
    }
}

struct NodeRecord: Codable, Equatable, Sendable {
    var allocatedBytes: UInt64
    var logicalBytes: UInt64
    var modifiedNanoseconds: Int64
    var parent: NodeID
    var firstChild: NodeID
    var nextSibling: NodeID
    var nameOffset: UInt32
    var recursiveFileCount: UInt32
    var recursiveDirectoryCount: UInt32
    var duplicateReferenceCount: UInt32
    var hardLinkGroup: UInt32
    var nameLength: UInt16
    var flags: NodeFlags

    init(
        allocatedBytes: UInt64,
        logicalBytes: UInt64,
        modifiedNanoseconds: Int64,
        parent: NodeID,
        nameOffset: UInt32,
        nameLength: UInt16,
        kind: NodeKind,
        unreadable: Bool = false
    ) {
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.modifiedNanoseconds = modifiedNanoseconds
        self.parent = parent
        firstChild = .null
        nextSibling = .null
        self.nameOffset = nameOffset
        recursiveFileCount = kind == .directory || kind == .syntheticRoot ? 0 : 1
        recursiveDirectoryCount = kind == .directory || kind == .syntheticRoot ? 1 : 0
        duplicateReferenceCount = 0
        hardLinkGroup = .max
        self.nameLength = nameLength
        flags = NodeFlags(kind: kind)
        if unreadable { flags.insert(.unreadable) }
    }
}

struct RootDescriptor: Codable, Equatable, Sendable {
    let nodeID: NodeID
    let url: URL
}

struct HardLinkGroup: Codable, Equatable, Sendable {
    let deviceID: UInt64
    let fileID: UInt64
    let allocatedBytes: UInt64
    let logicalBytes: UInt64
    let canonicalMember: NodeID
    let memberStart: UInt32
    let memberCount: UInt32
}

// Only sharing candidates occupy this side table; ordinary node records stay 60 bytes.
struct CloneMetadata: Codable, Hashable, Sendable {
    let deviceID: UInt64
    let fileID: UInt64
    let cloneID: UInt64
    let flags: UInt64
    let referenceCount: UInt32?

    // Documented names, empirically verified APFS encodings (not public SDK constants).
    var sharesAllBlocks: Bool { flags & 0x40 != 0 }
    var label: String { sharesAllBlocks ? "Full clone" : "May share blocks" }
}

struct NodeMetadata: Identifiable, Hashable, Sendable {
    let handle: NodeHandle
    let name: String
    let url: URL
    let allocatedBytes: Int64
    let intrinsicAllocatedBytes: Int64
    let logicalBytes: Int64
    let kind: NodeKind
    let modifiedAt: Date?
    let fileCount: Int
    let directoryCount: Int
    let duplicateReferenceCount: Int
    let isDuplicateReference: Bool

    var clone: CloneMetadata? = nil

    var id: String { handle.id }
    var isDirectory: Bool { kind == .directory || kind == .syntheticRoot }
    var fileExtension: String {
        isDirectory ? "Folder" : (url.pathExtension.isEmpty ? "Other" : url.pathExtension.lowercased())
    }
}

enum ScanTreeValidationError: Error, CustomStringConvertible {
    case invalidRoot(NodeID)
    case invalidLink(NodeID, String)
    case invalidName(NodeID)
    case invalidParent(child: NodeID, expected: NodeID)
    case cycle(NodeID)
    case unreachable(NodeID)
    case invalidAggregate(NodeID)
    case invalidHardLinkGroup(UInt32)
    case invalidKind(NodeID)

    var description: String {
        switch self {
        case .invalidRoot(let id): return "Invalid root node \(id.rawValue)"
        case .invalidLink(let id, let field): return "Invalid \(field) link on node \(id.rawValue)"
        case .invalidName(let id): return "Invalid name range on node \(id.rawValue)"
        case .invalidParent(let child, let expected): return "Node \(child.rawValue) has the wrong parent; expected \(expected.rawValue)"
        case .cycle(let id): return "Cycle involving node \(id.rawValue)"
        case .unreachable(let id): return "Node \(id.rawValue) is unreachable"
        case .invalidAggregate(let id): return "Node \(id.rawValue) has invalid aggregate values"
        case .invalidHardLinkGroup(let index): return "Invalid hard-link group \(index)"
        case .invalidKind(let id): return "Node \(id.rawValue) has an invalid kind or flags"
        }
    }
}

struct ScanTree: Codable, Equatable, Sendable {
    let generation: TreeGeneration
    let rootID: NodeID
    let displayURL: URL
    private(set) var nodes: [NodeRecord]
    private(set) var nameBytes: [UInt8]
    private(set) var roots: [RootDescriptor]
    private(set) var hardLinkGroups: [HardLinkGroup]
    private(set) var hardLinkMembers: [NodeID]
    let unreadableCount: Int
    private(set) var clones: [NodeID: CloneMetadata]

    init(
        generation: TreeGeneration,
        rootID: NodeID,
        displayURL: URL,
        nodes: [NodeRecord],
        nameBytes: [UInt8],
        roots: [RootDescriptor],
        hardLinkGroups: [HardLinkGroup],
        hardLinkMembers: [NodeID],
        unreadableCount: Int,
        clones: [NodeID: CloneMetadata] = [:]
    ) {
        self.generation = generation
        self.rootID = rootID
        self.displayURL = displayURL
        self.nodes = nodes
        self.nameBytes = nameBytes
        self.roots = roots
        self.hardLinkGroups = hardLinkGroups
        self.hardLinkMembers = hardLinkMembers
        self.unreadableCount = unreadableCount
        self.clones = clones
    }

    var rootHandle: NodeHandle { handle(for: rootID) }
    var nodeCount: Int { nodes.count }
    var hardLinkReferenceCount: Int { Int(nodes[index(of: rootID)].duplicateReferenceCount) }
    var estimatedStorageBytes: Int {
        nodes.capacity * MemoryLayout<NodeRecord>.stride
            + nameBytes.capacity
            + roots.capacity * MemoryLayout<RootDescriptor>.stride
            + hardLinkGroups.capacity * MemoryLayout<HardLinkGroup>.stride
            + hardLinkMembers.capacity * MemoryLayout<NodeID>.stride
            + clones.capacity * (MemoryLayout<NodeID>.stride + MemoryLayout<CloneMetadata>.stride + 1)
    }

    func handle(for nodeID: NodeID) -> NodeHandle {
        NodeHandle(generation: generation, nodeID: nodeID)
    }

    func contains(_ handle: NodeHandle) -> Bool {
        handle.generation == generation && isValid(handle.nodeID)
    }

    func metadata(for handle: NodeHandle) -> NodeMetadata? {
        guard contains(handle) else { return nil }
        return metadata(for: handle.nodeID)
    }

    func metadata(for nodeID: NodeID) -> NodeMetadata {
        let record = nodes[index(of: nodeID)]
        let duplicate = record.flags.contains(.duplicateReference)
        return NodeMetadata(
            handle: handle(for: nodeID),
            name: name(of: nodeID),
            url: url(of: nodeID),
            allocatedBytes: clampedInt64(duplicate ? 0 : record.allocatedBytes),
            intrinsicAllocatedBytes: clampedInt64(record.allocatedBytes),
            logicalBytes: clampedInt64(duplicate ? 0 : record.logicalBytes),
            kind: record.flags.kind,
            modifiedAt: record.modifiedNanoseconds == .min
                ? nil
                : Date(timeIntervalSince1970: Double(record.modifiedNanoseconds) / 1_000_000_000),
            fileCount: Int(record.recursiveFileCount),
            directoryCount: Int(record.recursiveDirectoryCount),
            duplicateReferenceCount: Int(record.duplicateReferenceCount),
            isDuplicateReference: duplicate,
            clone: clones[nodeID]
        )
    }

    func name(of nodeID: NodeID) -> String {
        let record = nodes[index(of: nodeID)]
        let start = Int(record.nameOffset)
        let end = start + Int(record.nameLength)
        return String(decoding: nameBytes[start..<end], as: UTF8.self)
    }

    func kind(of nodeID: NodeID) -> NodeKind {
        nodes[index(of: nodeID)].flags.kind
    }

    func isDuplicateReference(_ nodeID: NodeID) -> Bool {
        nodes[index(of: nodeID)].flags.contains(.duplicateReference)
    }

    func isUnreadable(_ nodeID: NodeID) -> Bool {
        nodes[index(of: nodeID)].flags.contains(.unreadable)
    }

    func allocatedBytes(of nodeID: NodeID) -> Int64 {
        let record = nodes[index(of: nodeID)]
        return clampedInt64(record.flags.contains(.duplicateReference) ? 0 : record.allocatedBytes)
    }

    func fileCount(of nodeID: NodeID) -> Int {
        Int(nodes[index(of: nodeID)].recursiveFileCount)
    }

    func fileExtension(of nodeID: NodeID) -> String {
        guard kind(of: nodeID) != .directory, kind(of: nodeID) != .syntheticRoot else { return "Folder" }
        let name = name(of: nodeID)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "Other" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    func parent(of nodeID: NodeID) -> NodeID? {
        let value = nodes[index(of: nodeID)].parent
        return value == .null ? nil : value
    }

    // Restartable sibling traversal without allocating an array for huge folders.
    func childIDs(of nodeID: NodeID) -> ChildSequence {
        ChildSequence(nodes: nodes, firstChild: nodes[index(of: nodeID)].firstChild)
    }

    // A concrete iterator avoids allocating closure/AnyIterator boxes for every
    // directory visited while preparing the grid's per-file hover index.
    struct ChildSequence: Sequence {
        fileprivate let nodes: [NodeRecord]
        fileprivate let firstChild: NodeID

        func makeIterator() -> Iterator { Iterator(nodes: nodes, nextChild: firstChild) }

        struct Iterator: IteratorProtocol {
            fileprivate let nodes: [NodeRecord]
            fileprivate var nextChild: NodeID

            mutating func next() -> NodeID? {
                guard nextChild != .null else { return nil }
                let result = nextChild
                nextChild = nodes[Int(result.rawValue)].nextSibling
                return result
            }
        }
    }

    func children(of nodeID: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var child = nodes[index(of: nodeID)].firstChild
        while child != .null {
            result.append(child)
            child = nodes[index(of: child)].nextSibling
        }
        return result
    }

    func files(inSubtree nodeIDs: [NodeID]) -> [NodeID] {
        var stack = Array(nodeIDs.reversed())
        var result: [NodeID] = []
        while let nodeID = stack.popLast() {
            let record = nodes[index(of: nodeID)]
            if record.flags.kind == .directory || record.flags.kind == .syntheticRoot {
                stack.append(contentsOf: children(of: nodeID).reversed())
            } else {
                result.append(nodeID)
            }
        }
        return result
    }

    func breadcrumbs(to nodeID: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var current: NodeID? = nodeID
        while let node = current {
            result.append(node)
            current = parent(of: node)
        }
        return result.reversed()
    }

    // Display-only path construction uses the scanned names directly. Avoid
    // constructing a Foundation URL for every ancestor during pointer movement.
    func displayPath(of nodeID: NodeID) -> String {
        if nodeID == rootID, roots.allSatisfy({ $0.nodeID != rootID }) {
            return displayURL.path
        }
        var components: [String] = []
        var current = nodeID
        while true {
            if let root = roots.first(where: { $0.nodeID == current }) {
                let prefix = root.url.path
                guard !components.isEmpty else { return prefix }
                return prefix + (prefix.hasSuffix("/") ? "" : "/") + components.reversed().joined(separator: "/")
            }
            components.append(name(of: current))
            guard let parent = parent(of: current) else { return displayURL.path }
            current = parent
        }
    }

    func url(of nodeID: NodeID) -> URL {
        if nodeID == rootID, roots.allSatisfy({ $0.nodeID != rootID }) {
            return displayURL
        }

        var components: [String] = []
        var current = nodeID
        while true {
            if let root = roots.first(where: { $0.nodeID == current }) {
                return components.reversed().reduce(root.url) { url, component in
                    url.appendingPathComponent(component)
                }
            }
            components.append(name(of: current))
            guard let parent = parent(of: current) else { return displayURL }
            current = parent
        }
    }

    func node(atPath path: String) -> NodeID? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let root = roots
            .filter({ standardized == $0.url.standardizedFileURL.path || standardized.hasPrefix($0.url.standardizedFileURL.path + "/") })
            .max(by: { $0.url.path.count < $1.url.path.count }) else { return nil }
        let rootPath = root.url.standardizedFileURL.path
        guard standardized != rootPath else { return root.nodeID }
        let suffix = standardized.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1)
        var current = root.nodeID
        for component in suffix.split(separator: "/").map(String.init) {
            guard let next = children(of: current).first(where: { name(of: $0) == component }) else { return nil }
            current = next
        }
        return current
    }

    // Resolve only on demand; exclude hard-link aliases of the selected inode.
    func clonePeers(of nodeID: NodeID) -> [NodeID] {
        guard let clone = clones[nodeID], clone.sharesAllBlocks else { return [] }
        return clones.compactMap { id, other in
            other.sharesAllBlocks && other.deviceID == clone.deviceID
                && other.cloneID == clone.cloneID && other.fileID != clone.fileID ? id : nil
        }.sorted()
    }

    func validate() throws {
        for (id, clone) in clones {
            guard isValid(id), kind(of: id) == .file, clone.cloneID != 0,
                  clone.flags & 0x41 != 0 else { throw ScanTreeValidationError.invalidKind(id) }
        }
        guard isValid(rootID) else { throw ScanTreeValidationError.invalidRoot(rootID) }
        guard nodes[index(of: rootID)].parent == .null else { throw ScanTreeValidationError.invalidRoot(rootID) }
        var describedRoots = Set<NodeID>()
        for root in roots {
            guard isValid(root.nodeID),
                  describedRoots.insert(root.nodeID).inserted,
                  root.url.isFileURL,
                  kind(of: root.nodeID) == .directory else {
                throw ScanTreeValidationError.invalidRoot(root.nodeID)
            }
        }
        var visited = Set<NodeID>()
        var active = Set<NodeID>()

        func visit(_ nodeID: NodeID) throws -> (UInt64, UInt64, UInt32, UInt32, UInt32) {
            guard isValid(nodeID) else { throw ScanTreeValidationError.invalidLink(nodeID, "node") }
            guard active.insert(nodeID).inserted else { throw ScanTreeValidationError.cycle(nodeID) }
            guard visited.insert(nodeID).inserted else { throw ScanTreeValidationError.cycle(nodeID) }
            let record = nodes[index(of: nodeID)]
            let knownFlags = NodeFlags.kindMask.rawValue
                | NodeFlags.unreadable.rawValue
                | NodeFlags.duplicateReference.rawValue
                | NodeFlags.tombstone.rawValue
            guard record.flags.rawValue & ~knownFlags == 0,
                  record.flags.rawValue & NodeFlags.kindMask.rawValue <= NodeKind.syntheticRoot.rawValue else {
                throw ScanTreeValidationError.invalidKind(nodeID)
            }
            let nameEnd = UInt64(record.nameOffset) + UInt64(record.nameLength)
            guard nameEnd <= UInt64(nameBytes.count) else { throw ScanTreeValidationError.invalidName(nodeID) }
            let isDirectory = record.flags.kind == .directory || record.flags.kind == .syntheticRoot
            guard isDirectory || record.firstChild == .null else {
                throw ScanTreeValidationError.invalidLink(nodeID, "firstChild")
            }

            var allocated = isDirectory
                ? UInt64(0)
                : (record.flags.contains(.duplicateReference) ? 0 : record.allocatedBytes)
            var logical = isDirectory
                ? UInt64(0)
                : (record.flags.contains(.duplicateReference) ? 0 : record.logicalBytes)
            var files: UInt32 = isDirectory ? 0 : 1
            var directories: UInt32 = isDirectory ? 1 : 0
            var duplicates: UInt32 = record.flags.contains(.duplicateReference) ? 1 : 0
            var siblingSeen = Set<NodeID>()
            var child = record.firstChild
            while child != .null {
                guard isValid(child) else { throw ScanTreeValidationError.invalidLink(nodeID, "child") }
                guard siblingSeen.insert(child).inserted else { throw ScanTreeValidationError.cycle(child) }
                guard nodes[index(of: child)].parent == nodeID else {
                    throw ScanTreeValidationError.invalidParent(child: child, expected: nodeID)
                }
                let values = try visit(child)
                allocated = allocated.addingReportingOverflow(values.0).overflow ? .max : allocated + values.0
                logical = logical.addingReportingOverflow(values.1).overflow ? .max : logical + values.1
                files = files.addingReportingOverflow(values.2).overflow ? .max : files + values.2
                directories = directories.addingReportingOverflow(values.3).overflow ? .max : directories + values.3
                duplicates = duplicates.addingReportingOverflow(values.4).overflow ? .max : duplicates + values.4
                child = nodes[index(of: child)].nextSibling
            }
            active.remove(nodeID)
            if isDirectory {
                guard record.allocatedBytes == allocated,
                      record.logicalBytes == logical,
                      record.recursiveFileCount == files,
                      record.recursiveDirectoryCount == directories,
                      record.duplicateReferenceCount == duplicates else {
                    throw ScanTreeValidationError.invalidAggregate(nodeID)
                }
            } else if record.recursiveFileCount != 1
                || record.recursiveDirectoryCount != 0
                || record.duplicateReferenceCount != (record.flags.contains(.duplicateReference) ? 1 : 0) {
                throw ScanTreeValidationError.invalidAggregate(nodeID)
            }
            return (allocated, logical, files, directories, duplicates)
        }

        _ = try visit(rootID)
        for raw in nodes.indices {
            let nodeID = NodeID(rawValue: UInt32(raw))
            if !nodes[raw].flags.contains(.tombstone), !visited.contains(nodeID) {
                throw ScanTreeValidationError.unreachable(nodeID)
            }
        }

        var groupedMembers = Set<NodeID>()
        for (index, group) in hardLinkGroups.enumerated() {
            let start = Int(group.memberStart)
            let end = start + Int(group.memberCount)
            guard group.memberCount >= 2,
                  end <= hardLinkMembers.count,
                  hardLinkMembers[start..<end].contains(group.canonicalMember) else {
                throw ScanTreeValidationError.invalidHardLinkGroup(UInt32(index))
            }
            for member in hardLinkMembers[start..<end] {
                guard isValid(member),
                      groupedMembers.insert(member).inserted,
                      nodes[self.index(of: member)].hardLinkGroup == UInt32(index),
                      kind(of: member) == .file,
                      nodes[self.index(of: member)].flags.contains(.duplicateReference) == (member != group.canonicalMember) else {
                    throw ScanTreeValidationError.invalidHardLinkGroup(UInt32(index))
                }
            }
        }
        guard groupedMembers.count == hardLinkMembers.count else {
            throw ScanTreeValidationError.invalidHardLinkGroup(UInt32(hardLinkGroups.count))
        }
        for (raw, node) in nodes.enumerated() where node.hardLinkGroup != .max {
            guard Int(node.hardLinkGroup) < hardLinkGroups.count,
                  groupedMembers.contains(NodeID(rawValue: UInt32(raw))) else {
                throw ScanTreeValidationError.invalidHardLinkGroup(node.hardLinkGroup)
            }
        }
    }

    private func isValid(_ nodeID: NodeID) -> Bool {
        nodeID != .null && UInt64(nodeID.rawValue) < UInt64(nodes.count)
    }

    private func index(of nodeID: NodeID) -> Int {
        precondition(isValid(nodeID), "Invalid node ID \(nodeID.rawValue)")
        return Int(nodeID.rawValue)
    }
}

struct FileIdentity: Hashable, Codable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct ScanTreeBuilder {
    private(set) var nodes: [NodeRecord] = []
    private(set) var nameBytes: [UInt8] = []
    private var lastChildren: [NodeID] = []
    private var roots: [RootDescriptor] = []
    private var clones: [NodeID: CloneMetadata] = [:]
    private var identityMembers: [FileIdentity: [NodeID]] = [:]
    private var unreadableCount = 0
    let rootID: NodeID
    let displayURL: URL

    init(rootName: String, rootURL: URL, synthetic: Bool = false) {
        displayURL = rootURL
        rootID = NodeID(rawValue: 0)
        appendInitialRoot(name: rootName, kind: synthetic ? .syntheticRoot : .directory)
        if !synthetic { roots.append(RootDescriptor(nodeID: rootID, url: rootURL)) }
    }

    mutating func addPhysicalRoot(name: String, url: URL, parent: NodeID) -> NodeID {
        let nodeID = addNode(
            parent: parent,
            name: name,
            kind: .directory,
            allocatedBytes: 0,
            logicalBytes: 0,
            modifiedAt: nil,
            identity: nil
        )
        roots.append(RootDescriptor(nodeID: nodeID, url: url))
        return nodeID
    }

    @discardableResult
    mutating func addNode(
        parent: NodeID,
        name: String,
        kind: NodeKind,
        allocatedBytes: Int64,
        logicalBytes: Int64,
        modifiedAt: Date?,
        identity: FileIdentity?,
        unreadable: Bool = false,
        clone: CloneMetadata? = nil
    ) -> NodeID {
        precondition(Int(parent.rawValue) < nodes.count)
        let nameRange = appendName(name)
        let nodeID = NodeID(rawValue: UInt32(nodes.count))
        let nanoseconds = modifiedAt.map {
            let value = $0.timeIntervalSince1970 * 1_000_000_000
            if value >= Double(Int64.max) { return Int64.max }
            if value <= Double(Int64.min + 1) { return Int64.min + 1 }
            return Int64(value.rounded())
        } ?? .min
        nodes.append(NodeRecord(
            allocatedBytes: UInt64(max(0, allocatedBytes)),
            logicalBytes: UInt64(max(0, logicalBytes)),
            modifiedNanoseconds: nanoseconds,
            parent: parent,
            nameOffset: nameRange.offset,
            nameLength: nameRange.length,
            kind: kind,
            unreadable: unreadable
        ))
        lastChildren.append(.null)
        link(nodeID, to: parent)
        if unreadable { unreadableCount += 1 }
        if kind == .file, let clone { clones[nodeID] = clone }
        if kind == .file, let identity {
            identityMembers[identity, default: []].append(nodeID)
        }
        return nodeID
    }

    mutating func markUnreadable(_ nodeID: NodeID) {
        let index = Int(nodeID.rawValue)
        if !nodes[index].flags.contains(.unreadable) {
            nodes[index].flags.insert(.unreadable)
            unreadableCount += 1
        }
    }

    struct FinishingProgress: Codable, Equatable, Sendable {
        var stage: String
        var completed: Int
        var total: Int
    }

    mutating func finalize(
        generation: TreeGeneration = TreeGeneration(),
        progress: (FinishingProgress) -> Void = { _ in }
    ) throws -> ScanTree {
        var lastUpdate = ContinuousClock.now
        func report(_ stage: String, _ completed: Int, _ total: Int) {
            guard completed == 0 || completed == total || completed % 1_024 == 0 else { return }
            let now = ContinuousClock.now
            guard completed == 0 || completed == total || lastUpdate.duration(to: now) >= .milliseconds(120) else { return }
            lastUpdate = now
            progress(FinishingProgress(stage: stage, completed: completed, total: total))
        }
        report("Resolving hard links", 0, identityMembers.count)
        var groups: [HardLinkGroup] = []
        var members: [NodeID] = []
        // A file may have links outside the scanned roots. Those singleton
        // identities cannot form a group and need no deterministic sort.
        var hardLinkIdentities: [FileIdentity] = []
        for (identity, groupMembers) in identityMembers where groupMembers.count > 1 {
            hardLinkIdentities.append(identity)
        }
        hardLinkIdentities.sort {
            $0.device == $1.device ? $0.inode < $1.inode : $0.device < $1.device
        }
        // Reuse common directory paths across groups without retaining a path
        // string for every directory in a multi-million-node scan.
        var parentPaths: [NodeID: String] = [:]
        for (offset, identity) in hardLinkIdentities.enumerated() {
            report("Resolving hard links", offset, hardLinkIdentities.count)
            guard let groupMembers = identityMembers[identity], groupMembers.count > 1 else { continue }
            // Compute each key once, keeping Swift String comparison (including
            // Unicode equivalence) and stable ordering for equal paths intact.
            let keyed = groupMembers.map { member -> (id: NodeID, path: String) in
                let parent = nodes[Int(member.rawValue)].parent
                let name = String(decoding: nameBytes(of: member), as: UTF8.self)
                guard parent != rootID && parent != .null else { return (member, name) }
                let prefix: String
                if let cached = parentPaths[parent] {
                    prefix = cached
                } else {
                    prefix = pathSortKey(of: parent)
                    if parentPaths.count >= 4_096 { parentPaths.removeAll(keepingCapacity: true) }
                    parentPaths[parent] = prefix
                }
                return (member, prefix + "/" + name)
            }
            let ordered = keyed.sorted { $0.path < $1.path }.map { $0.id }
            let canonical = ordered[0]
            let groupIndex = UInt32(groups.count)
            let memberStart = UInt32(members.count)
            members.append(contentsOf: ordered)
            groups.append(HardLinkGroup(
                deviceID: identity.device,
                fileID: identity.inode,
                allocatedBytes: nodes[Int(canonical.rawValue)].allocatedBytes,
                logicalBytes: nodes[Int(canonical.rawValue)].logicalBytes,
                canonicalMember: canonical,
                memberStart: memberStart,
                memberCount: UInt32(ordered.count)
            ))
            for member in ordered {
                nodes[Int(member.rawValue)].hardLinkGroup = groupIndex
            }
            for duplicate in ordered.dropFirst() {
                nodes[Int(duplicate.rawValue)].flags.insert(.duplicateReference)
            }
        }

        report("Preparing totals", 0, nodes.count)
        for index in nodes.indices {
            report("Preparing totals", index, nodes.count)
            let kind = nodes[index].flags.kind
            nodes[index].recursiveFileCount = kind == .directory || kind == .syntheticRoot ? 0 : 1
            nodes[index].recursiveDirectoryCount = kind == .directory || kind == .syntheticRoot ? 1 : 0
            nodes[index].duplicateReferenceCount = nodes[index].flags.contains(.duplicateReference) ? 1 : 0
            if kind == .directory || kind == .syntheticRoot {
                nodes[index].allocatedBytes = 0
                nodes[index].logicalBytes = 0
            }
        }

        report("Calculating directory sizes", 0, nodes.count)
        if nodes.count > 1 {
            for rawIndex in stride(from: nodes.count - 1, through: 1, by: -1) {
                report("Calculating directory sizes", nodes.count - rawIndex, nodes.count)
                let child = nodes[rawIndex]
                let parentIndex = Int(child.parent.rawValue)
                nodes[parentIndex].allocatedBytes = saturatingAdd(
                    nodes[parentIndex].allocatedBytes,
                    child.flags.contains(.duplicateReference) ? 0 : child.allocatedBytes
                )
                nodes[parentIndex].logicalBytes = saturatingAdd(
                    nodes[parentIndex].logicalBytes,
                    child.flags.contains(.duplicateReference) ? 0 : child.logicalBytes
                )
                nodes[parentIndex].recursiveFileCount = saturatingAdd(nodes[parentIndex].recursiveFileCount, child.recursiveFileCount)
                nodes[parentIndex].recursiveDirectoryCount = saturatingAdd(nodes[parentIndex].recursiveDirectoryCount, child.recursiveDirectoryCount)
                nodes[parentIndex].duplicateReferenceCount = saturatingAdd(nodes[parentIndex].duplicateReferenceCount, child.duplicateReferenceCount)
            }
        }

        report("Sorting entries", 0, nodes.count)
        for rawIndex in nodes.indices {
            report("Sorting entries", rawIndex, nodes.count)
            sortChildren(of: NodeID(rawValue: UInt32(rawIndex)))
        }

        report("Sorting entries", nodes.count, nodes.count)
        roots.sort { $0.nodeID < $1.nodeID }
        let tree = ScanTree(
            generation: generation,
            rootID: rootID,
            displayURL: displayURL,
            nodes: nodes,
            nameBytes: nameBytes,
            roots: roots,
            hardLinkGroups: groups,
            hardLinkMembers: members,
            unreadableCount: unreadableCount,
            clones: clones
        )
        // The builder establishes these invariants as it appends and finalizes nodes.
        // Re-walking the entire tree here adds a second recursive O(n) pass to every
        // live scan. Tests validate constructed trees explicitly, and snapshots still
        // validate bytes read from disk before publishing them.
        return tree
    }

    private mutating func appendInitialRoot(name: String, kind: NodeKind) {
        let range = appendName(name)
        nodes.append(NodeRecord(
            allocatedBytes: 0,
            logicalBytes: 0,
            modifiedNanoseconds: .min,
            parent: .null,
            nameOffset: range.offset,
            nameLength: range.length,
            kind: kind
        ))
        lastChildren.append(.null)
    }

    private mutating func appendName(_ name: String) -> (offset: UInt32, length: UInt16) {
        let bytes = Array(name.utf8)
        precondition(nameBytes.count <= Int(UInt32.max))
        precondition(bytes.count <= Int(UInt16.max))
        let result = (UInt32(nameBytes.count), UInt16(bytes.count))
        nameBytes.append(contentsOf: bytes)
        return result
    }

    private mutating func link(_ child: NodeID, to parent: NodeID) {
        let parentIndex = Int(parent.rawValue)
        if nodes[parentIndex].firstChild == .null {
            nodes[parentIndex].firstChild = child
        } else {
            nodes[Int(lastChildren[parentIndex].rawValue)].nextSibling = child
        }
        lastChildren[parentIndex] = child
    }

    private mutating func sortChildren(of parent: NodeID) {
        let parentIndex = Int(parent.rawValue)
        guard nodes[parentIndex].firstChild != .null else { return }
        var children: [NodeID] = []
        var child = nodes[parentIndex].firstChild
        while child != .null {
            children.append(child)
            child = nodes[Int(child.rawValue)].nextSibling
        }
        children.sort { lhs, rhs in
            let left = nodes[Int(lhs.rawValue)]
            let right = nodes[Int(rhs.rawValue)]
            let leftSize = left.flags.contains(.duplicateReference) ? 0 : left.allocatedBytes
            let rightSize = right.flags.contains(.duplicateReference) ? 0 : right.allocatedBytes
            if leftSize != rightSize { return leftSize > rightSize }
            return nameBytes(of: lhs).lexicographicallyPrecedes(nameBytes(of: rhs))
        }
        nodes[parentIndex].firstChild = children[0]
        for index in children.indices {
            nodes[Int(children[index].rawValue)].nextSibling = index + 1 < children.count ? children[index + 1] : .null
        }
        lastChildren[parentIndex] = children.last ?? .null
    }

    private func pathComponents(of nodeID: NodeID) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var current = nodeID
        while current != rootID {
            result.append(Array(nameBytes(of: current)))
            let parent = nodes[Int(current.rawValue)].parent
            if parent == .null { break }
            current = parent
        }
        return result.reversed()
    }

    private func pathSortKey(of nodeID: NodeID) -> String {
        pathComponents(of: nodeID)
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "/")
    }

    private func nameBytes(of nodeID: NodeID) -> ArraySlice<UInt8> {
        let record = nodes[Int(nodeID.rawValue)]
        let start = Int(record.nameOffset)
        return nameBytes[start..<(start + Int(record.nameLength))]
    }
}

private func saturatingAdd<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? .max : result.partialValue
}

private func clampedInt64(_ value: UInt64) -> Int64 {
    value > UInt64(Int64.max) ? .max : Int64(value)
}

extension Int64 {
    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
