import Foundation

struct FileNode: Codable, Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let size: Int64
    let logicalSize: Int64
    let isDirectory: Bool
    let modifiedAt: Date?
    let children: [FileNode]
    let fileCount: Int
    let directoryCount: Int
    let isDuplicateReference: Bool
    let duplicateReferenceCount: Int

    var id: String { url.path }
    var fileExtension: String { isDirectory ? "Folder" : (url.pathExtension.isEmpty ? "Other" : url.pathExtension.lowercased()) }

    static func file(
        url: URL,
        size: Int64,
        logicalSize: Int64,
        modifiedAt: Date?,
        isDuplicateReference: Bool = false
    ) -> FileNode {
        FileNode(
            url: url,
            name: url.lastPathComponent,
            size: size,
            logicalSize: logicalSize,
            isDirectory: false,
            modifiedAt: modifiedAt,
            children: [],
            fileCount: 1,
            directoryCount: 0,
            isDuplicateReference: isDuplicateReference,
            duplicateReferenceCount: isDuplicateReference ? 1 : 0
        )
    }

    static func directory(
        url: URL,
        name: String? = nil,
        children: [FileNode],
        ownSize: Int64 = 0,
        modifiedAt: Date? = nil
    ) -> FileNode {
        let sorted = children.sorted { lhs, rhs in
            if lhs.size == rhs.size { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.size > rhs.size
        }
        return FileNode(
            url: url,
            name: name ?? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent),
            size: ownSize + sorted.reduce(0) { $0 + $1.size },
            logicalSize: sorted.reduce(0) { $0 + $1.logicalSize },
            isDirectory: true,
            modifiedAt: modifiedAt,
            children: sorted,
            fileCount: sorted.reduce(0) { $0 + $1.fileCount },
            directoryCount: 1 + sorted.reduce(0) { $0 + $1.directoryCount },
            isDuplicateReference: false,
            duplicateReferenceCount: sorted.reduce(0) { $0 + $1.duplicateReferenceCount }
        )
    }
}

extension Int64 {
    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
