import Foundation
import Testing
@testable import SpaceTree

@Test func hardLinkOrderingPreservesPathAndIdentitySemantics() throws {
    var builder = ScanTreeBuilder(rootName: "root", rootURL: URL(fileURLWithPath: "/tmp/root"))
    var expected: [FileIdentity: [(NodeID, String)]] = [:]
    // Prefix punctuation and Unicode exercise full Swift String ordering rather
    // than component ordering or a byte-wise replacement comparator.
    for directory in ["z", "a", "a!", "é", "e\u{301}"] {
        let parent = builder.addNode(parent: builder.rootID, name: directory, kind: .directory,
                                     allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
        for (index, name) in ["z", "a", "é", "e\u{301}"].enumerated() {
            let identity = FileIdentity(device: UInt64(index % 2), inode: UInt64(index % 3))
            let id = builder.addNode(parent: parent, name: name, kind: .file,
                                     allocatedBytes: 10, logicalBytes: 20, modifiedAt: nil, identity: identity)
            expected[identity, default: []].append((id, directory + "/" + name))
        }
    }
    _ = builder.addNode(parent: builder.rootID, name: "singleton", kind: .file,
                        allocatedBytes: 7, logicalBytes: 7, modifiedAt: nil,
                        identity: FileIdentity(device: 99, inode: 99))
    let tree = try builder.finalize()
    let identities = expected.keys.sorted { $0.device == $1.device ? $0.inode < $1.inode : $0.device < $1.device }
    #expect(tree.hardLinkGroups.count == identities.count)
    for (group, identity) in zip(tree.hardLinkGroups, identities) {
        let ordered = expected[identity]!.sorted { $0.1 < $1.1 }.map { $0.0 }
        #expect(group.deviceID == identity.device)
        #expect(group.fileID == identity.inode)
        #expect(group.canonicalMember == ordered.first)
        let start = Int(group.memberStart)
        #expect(Array(tree.hardLinkMembers[start..<(start + Int(group.memberCount))]) == ordered)
    }
    #expect(tree.metadata(for: tree.rootID).allocatedBytes == Int64(identities.count * 10 + 7))
    try tree.validate()
}

@Test func optionalHardLinkFinishingBenchmark() throws {
    guard ProcessInfo.processInfo.environment["SPACETREE_HARDLINK_BENCHMARK"] == "1" else { return }
    for groupSize in [1, 2, 100] {
        var builder = ScanTreeBuilder(rootName: "root", rootURL: URL(fileURLWithPath: "/tmp/root"))
        var parent = builder.rootID
        for depth in 0..<12 {
            parent = builder.addNode(parent: parent, name: "directory-\(depth)", kind: .directory,
                                     allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
        }
        for index in 0..<100_000 {
            _ = builder.addNode(parent: parent, name: "file-\((index * 7919) % 100_000)", kind: .file,
                                allocatedBytes: 10, logicalBytes: 10, modifiedAt: nil,
                                identity: FileIdentity(device: 1, inode: UInt64(index / groupSize)))
        }
        let start = ContinuousClock.now
        var hardLinks = Duration.zero
        let tree = try builder.finalize { update in
            if update.stage == "Preparing totals" && update.completed == 0 {
                hardLinks = start.duration(to: .now)
            }
        }
        print("HARDLINK_BENCH groupSize=\(groupSize) nodes=\(tree.nodes.count) hardLinks=\(hardLinks)")
        #expect(tree.hardLinkGroups.count == (groupSize == 1 ? 0 : 100_000 / groupSize))
    }
}
