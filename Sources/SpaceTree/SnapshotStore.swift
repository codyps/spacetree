import CryptoKit
import Foundation

struct ScanSnapshot: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let targetID: String
    let root: FileNode
    let progress: ScanProgress
    let scannedAt: Date
    let scanDuration: TimeInterval
    let fseventID: UInt64
}

enum SnapshotStore {
    static func load(targetID: String) async -> ScanSnapshot? {
        await Task.detached(priority: .utility) {
            let url = snapshotURL(for: targetID)
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? PropertyListDecoder().decode(ScanSnapshot.self, from: data),
                  snapshot.version == ScanSnapshot.currentVersion,
                  snapshot.targetID == targetID else { return nil }
            return snapshot
        }.value
    }

    static func save(_ snapshot: ScanSnapshot) async {
        await Task.detached(priority: .utility) {
            do {
                let directory = snapshotsDirectory()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(snapshot)
                try data.write(to: snapshotURL(for: snapshot.targetID), options: .atomic)
            } catch {
                // A cache failure must never turn a successful filesystem scan into a failure.
            }
        }.value
    }

    private static func snapshotsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SpaceTree/Snapshots", isDirectory: true)
    }

    private static func snapshotURL(for targetID: String) -> URL {
        let digest = SHA256.hash(data: Data(targetID.utf8)).map { String(format: "%02x", $0) }.joined()
        return snapshotsDirectory().appendingPathComponent("\(digest).plist")
    }
}
