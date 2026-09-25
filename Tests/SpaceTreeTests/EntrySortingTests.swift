import Darwin
import Foundation
import Testing
@testable import SpaceTree

@Test func entrySortingPreservesSizeByteOrderAndLinks() throws {
    var builder = ScanTreeBuilder(rootName: "sort", rootURL: URL(fileURLWithPath: "/tmp/sort"))
    let names = ["z", "a", "a!", "é", "e\u{301}", "日本語", "", "same", "same",
                 String(repeating: "prefix", count: 100) + "z",
                 String(repeating: "prefix", count: 100) + "a"]
    var parents = [builder.rootID]
    for name in ["empty", "singleton", "many"] {
        parents.append(builder.addNode(parent: builder.rootID, name: name, kind: .directory,
                                       allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil))
    }
    for (index, name) in names.enumerated() {
        builder.addNode(parent: parents[3], name: name, kind: .file,
                        allocatedBytes: index < 3 ? 8192 : 4096, logicalBytes: 1,
                        modifiedAt: nil, identity: nil)
    }
    builder.addNode(parent: parents[2], name: "only", kind: .symlink,
                    allocatedBytes: 0, logicalBytes: 1, modifiedAt: nil, identity: nil)
    var links: [NodeID] = []
    for name in ["link-z", "link-a"] {
        links.append(builder.addNode(parent: parents[3], name: name, kind: .file,
                        allocatedBytes: 1_000_000, logicalBytes: 1_000_000, modifiedAt: nil,
                        identity: FileIdentity(device: 1, inode: 2)))
    }
    let insertionOrder = builder.nodes.indices.map { NodeID(rawValue: UInt32($0)) }
    let tree = try builder.finalize()
    #expect(tree.nodes[Int(links[0].rawValue)].flags.contains(.duplicateReference))
    #expect(!tree.nodes[Int(links[1].rawValue)].flags.contains(.duplicateReference))
    #expect(tree.children(of: parents[3]).first == links[1])
    #expect(tree.children(of: parents[3]).last == links[0])
    #expect(tree.nodes[Int(parents[3].rawValue)].allocatedBytes == 1_000_000 + 3 * 8192 + 8 * 4096)
    for parent in parents {
        let expected = insertionOrder.filter { tree.nodes[Int($0.rawValue)].parent == parent }.sorted { lhs, rhs in
            let left = tree.nodes[Int(lhs.rawValue)], right = tree.nodes[Int(rhs.rawValue)]
            let leftSize = left.flags.contains(.duplicateReference) ? 0 : left.allocatedBytes
            let rightSize = right.flags.contains(.duplicateReference) ? 0 : right.allocatedBytes
            if leftSize != rightSize { return leftSize > rightSize }
            return tree.name(of: lhs).utf8.lexicographicallyPrecedes(tree.name(of: rhs).utf8)
        }
        #expect(tree.children(of: parent) == expected)
    }
    try tree.validate()

    // Relinking must also preserve the builder's tail for subsequent appends.
    let added = builder.addNode(parent: parents[3], name: "new-largest", kind: .file,
                                allocatedBytes: 2_000_000, logicalBytes: 2_000_000, modifiedAt: nil, identity: nil)
    let extended = try builder.finalize()
    #expect(extended.children(of: parents[3]).first == added)
    #expect(extended.children(of: parents[3]).count == names.count + 3)
    try extended.validate()
}

@Test func entrySortingAcceptsAnEmptyNameBuffer() throws {
    var builder = ScanTreeBuilder(rootName: "", rootURL: URL(fileURLWithPath: "/tmp/sort"))
    let ids = (0..<3).map { _ in
        builder.addNode(parent: builder.rootID, name: "", kind: .file,
                        allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
    }
    #expect(builder.nameBytes.isEmpty)
    let tree = try builder.finalize()
    #expect(tree.children(of: tree.rootID) == ids)
    try tree.validate()
}

@Test func entrySortingHasExplicitByteOrderingAndStableTies() throws {
    var builder = ScanTreeBuilder(rootName: "sort", rootURL: URL(fileURLWithPath: "/tmp/sort"))
    // Canonically equivalent strings must remain distinct byte-sort keys. Include
    // NUL to ensure comparison uses lengths rather than C-string termination.
    let names = ["é", "日本語", "a!", "a", "", "e\u{301}", "😀", "a\0z", "a\0a"]
    let ids = names.map { name in
        builder.addNode(parent: builder.rootID, name: name, kind: .file,
                        allocatedBytes: 4096, logicalBytes: 1, modifiedAt: nil, identity: nil)
    }
    var ties: [NodeID] = []
    for index in 0..<256 {
        ties.append(builder.addNode(parent: builder.rootID, name: "same", kind: .file,
                                    allocatedBytes: 4096, logicalBytes: 1, modifiedAt: nil, identity: nil))
        builder.addNode(parent: builder.rootID, name: "large-\(index)", kind: .file,
                        allocatedBytes: 8192, logicalBytes: 1, modifiedAt: nil, identity: nil)
    }
    let expected = [4, 3, 8, 7, 2, 5].map { ids[$0] } + ties + [ids[0], ids[1], ids[6]]
    let tree = try builder.finalize()
    #expect(Array(tree.children(of: tree.rootID).dropFirst(256)) == expected)
    let repeated = try builder.finalize()
    #expect(repeated.children(of: tree.rootID) == tree.children(of: tree.rootID))
    try repeated.validate()
}

// Use the same fixture in separate debug/release processes before and after changes.
@Test func optionalEntrySortingBenchmark() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let rawCount = environment["SPACETREE_SORT_BENCHMARK"], let count = Int(rawCount), count > 0 else { return }
    let fanout = try #require(Int(environment["SPACETREE_SORT_FANOUT"] ?? "256"))
    try #require(fanout > 0, "SPACETREE_SORT_FANOUT must be positive")
    var builder = ScanTreeBuilder(rootName: "sort", rootURL: URL(fileURLWithPath: "/tmp/sort"))
    var parent = builder.rootID
    for index in 0..<count {
        if index % fanout == 0 {
            parent = builder.addNode(parent: builder.rootID, name: "directory-\(index)", kind: .directory,
                                     allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
        }
        let key = UInt64(index) &* 2_654_435_761 % UInt64(count)
        builder.addNode(parent: parent, name: "common-filename-prefix-\(key).dat", kind: .file,
                        allocatedBytes: Int64(key % 16) * 4096, logicalBytes: 1, modifiedAt: nil, identity: nil)
    }
    var start: ContinuousClock.Instant?
    var elapsed = Duration.zero
    let tree = try builder.finalize { update in
        if update.stage == "Sorting entries" {
            if update.completed == 0 && start == nil { start = .now }
            if update.completed == update.total, let start { elapsed = start.duration(to: .now) }
        }
    }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print("SORT_BENCH files=\(count) fanout=\(fanout) nodes=\(tree.nodeCount) sorting=\(elapsed) peakRSSMiB=\(Double(usage.ru_maxrss) / 1_048_576)")
    #expect(tree.nodeCount == count + (count + fanout - 1) / fanout + 1)
}
