import Darwin
import Foundation
import IOKit
import IOKit.storage

struct MountedFilesystem: Sendable {
    let url: URL
    let name: String
    let format: String
    let device: String
    let totalCapacity: Int64?
    let availableCapacity: Int64?
    let isInternal: Bool
    let isRemovable: Bool
    let isReadOnly: Bool
    let apfsContainerUUID: String?
    let isAuxiliary: Bool
}

enum MountDiscovery {
    private static let resourceKeys: Set<URLResourceKey> = [
        .volumeNameKey,
        .volumeLocalizedNameKey,
        .volumeLocalizedFormatDescriptionKey,
        .volumeIsInternalKey,
        .volumeIsRemovableKey,
        .volumeIsReadOnlyKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey
    ]

    static func mountedFilesystems() -> [MountedFilesystem] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }

        var results: [MountedFilesystem] = []
        for index in 0..<Int(count) {
            var entry = buffer[index]
            let mountPath = string(from: &entry.f_mntonname)
            let device = string(from: &entry.f_mntfromname)
            let filesystemType = string(from: &entry.f_fstypename)
            guard !mountPath.isEmpty else { continue }

            let url = URL(fileURLWithPath: mountPath, isDirectory: true).standardizedFileURL
            let values = try? url.resourceValues(forKeys: resourceKeys)
            let name = values?.volumeLocalizedName
                ?? values?.volumeName
                ?? (mountPath == "/" ? "Macintosh HD" : url.lastPathComponent)
            let format = values?.volumeLocalizedFormatDescription ?? filesystemType.uppercased()
            let bsdName = device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : device
            let containerUUID = filesystemType == "apfs" ? apfsContainerUUID(forBSDName: bsdName) : nil

            results.append(MountedFilesystem(
                url: url,
                name: name,
                format: format,
                device: device,
                totalCapacity: values?.volumeTotalCapacity.map(Int64.init),
                availableCapacity: values?.volumeAvailableCapacity.map(Int64.init),
                isInternal: values?.volumeIsInternal ?? false,
                isRemovable: values?.volumeIsRemovable ?? false,
                isReadOnly: values?.volumeIsReadOnly ?? ((entry.f_flags & UInt32(MNT_RDONLY)) != 0),
                apfsContainerUUID: containerUUID,
                isAuxiliary: isAuxiliary(path: mountPath, filesystemType: filesystemType)
            ))
        }
        return results
    }

    private static func apfsContainerUUID(forBSDName bsdName: String) -> String? {
        guard bsdName.hasPrefix("disk"),
              let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        var current = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard current != 0 else { return nil }
        defer { IOObjectRelease(current) }

        while current != 0 {
            let className = IOObjectCopyClass(current).takeRetainedValue() as String
            if className == "AppleAPFSContainer",
               let value = IORegistryEntryCreateCFProperty(
                   current,
                   "UUID" as CFString,
                   kCFAllocatorDefault,
                   0
               )?.takeRetainedValue() as? String {
                return value
            }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else { break }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }

    private static func isAuxiliary(path: String, filesystemType: String) -> Bool {
        path.hasPrefix("/Library/Developer/CoreSimulator/")
            || path.hasPrefix("/private/var/run/")
            || filesystemType == "autofs"
            || filesystemType == "devfs"
            || filesystemType == "fdesc"
    }

    private static func string<T>(from value: inout T) -> String {
        withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
}
