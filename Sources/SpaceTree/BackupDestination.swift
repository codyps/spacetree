import Foundation

struct BackupDestination: Identifiable, Sendable {
    enum Connection: Int, Sendable { case local, unknown, network }
    let id: String
    let name: String
    let connection: Connection
    let location: String?

    var label: String {
        switch connection {
        case .local: return "\(name) · Local disk"
        case .network: return "\(location ?? name) · Network (slower)"
        case .unknown: return "\(name) · Connection unknown"
        }
    }
    var symbol: String { connection == .network ? "network" : "externaldrive" }
}

enum BackupDestinationDiscovery {
    // Disk image entities include the synthesized APFS volume device as well as
    // the physical image device. Match exact devices, never disk-number prefixes.
    static func imagePaths(_ data: Data) -> [String: String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [:] }
        var paths: [String: String] = [:]
        for image in images {
            guard let path = image["image-path"] as? String else { continue }
            for entity in image["system-entities"] as? [[String: Any]] ?? [] {
                if let device = entity["dev-entry"] as? String { paths[device] = path }
            }
        }
        return paths
    }

    static func mountedImagePaths() -> [String: String] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return [:] }
        return imagePaths(data)
    }

    static func destinations(snapshots: [BackupSnapshot], mounts: [MountedFilesystem],
                             imagePaths: [String: String]) -> [BackupDestination] {
        Set(snapshots.map(\.device)).map { device in
            let base = mounts.first { $0.device == device }
            let name = base?.name ?? device
            if let path = imagePaths[device] {
                // The longest enclosing mount wins, including nested local mounts.
                let backing = mounts.filter { path == $0.url.path || path.hasPrefix($0.url.path == "/" ? "/" : $0.url.path + "/") }
                    .max { $0.url.path.count < $1.url.path.count }
                if let backing, let location = networkLocation(backing.device) {
                    return BackupDestination(id: device, name: name, connection: .network, location: location)
                }
                if let location = networkLocation(path) {
                    return BackupDestination(id: device, name: name, connection: .network, location: location)
                }
                return BackupDestination(id: device, name: name, connection: backing == nil ? .unknown : .local, location: nil)
            }
            if let location = networkLocation(device) {
                return BackupDestination(id: device, name: name, connection: .network, location: location)
            }
            return BackupDestination(id: device, name: name,
                                     connection: base != nil && base?.isDiskImage == false ? .local : .unknown, location: nil)
        }.sorted {
            if $0.connection != $1.connection { return $0.connection.rawValue < $1.connection.rawValue }
            if $0.label != $1.label { return $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    static func networkLocation(_ source: String) -> String? {
        let candidate = source.hasPrefix("//") ? "smb:" + source : source
        if var url = URLComponents(string: candidate),
           ["smb", "afp", "nfs"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            url.user = nil
            url.password = nil
            url.query = nil
            url.fragment = nil
            return url.string
        }
        // NFS mount sources use host:/export rather than a URL.
        if !source.hasPrefix("/"), let separator = source.range(of: ":/"), !source.contains("://") {
            return "nfs://" + String(source[..<separator.lowerBound]) + "/" + String(source[separator.upperBound...])
        }
        return nil
    }
}
