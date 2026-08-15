import SwiftUI

enum FileCategory: UInt8, CaseIterable, Sendable {
    case video
    case image
    case audio
    case archive
    case application
    case document
    case sourceCode
    case other
}

enum FilePalette {
    static func color(for node: NodeMetadata) -> Color {
        if node.isDirectory { return Color(red: 0.25, green: 0.55, blue: 0.96) }
        return color(forExtension: node.url.pathExtension.lowercased())
    }

    static func color(forExtension fileExtension: String) -> Color {
        color(for: category(forExtension: fileExtension))
    }

    static func category(forExtension fileExtension: String) -> FileCategory {
        switch fileExtension {
        case "mov", "mp4", "mkv", "avi", "m4v": return .video
        case "jpg", "jpeg", "png", "gif", "heic", "tiff", "raw": return .image
        case "mp3", "m4a", "wav", "flac", "aac": return .audio
        case "zip", "7z", "rar", "gz", "dmg", "pkg", "iso": return .archive
        case "app", "framework", "dylib", "so", "exe": return .application
        case "pdf", "doc", "docx", "pages", "txt", "md": return .document
        case "swift", "rs", "js", "ts", "py", "go", "c", "cpp", "h": return .sourceCode
        default: return .other
        }
    }

    static func color(for category: FileCategory) -> Color {
        switch category {
        case .video: return Color(red: 0.65, green: 0.38, blue: 0.93)
        case .image: return Color(red: 0.92, green: 0.34, blue: 0.55)
        case .audio: return Color(red: 0.95, green: 0.52, blue: 0.23)
        case .archive: return Color(red: 0.90, green: 0.72, blue: 0.20)
        case .application: return Color(red: 0.20, green: 0.72, blue: 0.58)
        case .document: return Color(red: 0.18, green: 0.67, blue: 0.78)
        case .sourceCode: return Color(red: 0.42, green: 0.64, blue: 0.36)
        case .other: return Color(red: 0.42, green: 0.48, blue: 0.58)
        }
    }

    static let legend: [(String, Color)] = [
        ("Video", color(forExtension: "mp4")),
        ("Images", color(forExtension: "jpg")),
        ("Audio", color(forExtension: "mp3")),
        ("Archives", color(forExtension: "zip")),
        ("Apps", color(forExtension: "app")),
        ("Other", color(forExtension: ""))
    ]

}
