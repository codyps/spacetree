import SwiftUI

enum FilePalette {
    static func color(for node: FileNode) -> Color {
        if node.isDirectory { return Color(red: 0.25, green: 0.55, blue: 0.96) }
        return color(forExtension: node.url.pathExtension.lowercased())
    }

    static func color(forExtension fileExtension: String) -> Color {
        switch fileExtension {
        case "mov", "mp4", "mkv", "avi", "m4v": return Color(red: 0.65, green: 0.38, blue: 0.93)
        case "jpg", "jpeg", "png", "gif", "heic", "tiff", "raw": return Color(red: 0.92, green: 0.34, blue: 0.55)
        case "mp3", "m4a", "wav", "flac", "aac": return Color(red: 0.95, green: 0.52, blue: 0.23)
        case "zip", "7z", "rar", "gz", "dmg", "pkg", "iso": return Color(red: 0.90, green: 0.72, blue: 0.20)
        case "app", "framework", "dylib", "so", "exe": return Color(red: 0.20, green: 0.72, blue: 0.58)
        case "pdf", "doc", "docx", "pages", "txt", "md": return Color(red: 0.18, green: 0.67, blue: 0.78)
        case "swift", "rs", "js", "ts", "py", "go", "c", "cpp", "h": return Color(red: 0.42, green: 0.64, blue: 0.36)
        default: return Color(red: 0.42, green: 0.48, blue: 0.58)
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
