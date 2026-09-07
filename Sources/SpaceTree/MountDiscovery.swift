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
    let isDiskImage: Bool
    let isTimeMachine: Bool
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

    private struct DeviceIOInfo {
        let containerUUID: String?
        let isDiskImage: Bool
        let hasBackupRole: Bool
    }

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
            let ioInfo = inspectDevice(bsdName: bsdName)
            let containerUUID = filesystemType == "apfs" ? ioInfo.containerUUID : nil
            let timeMachine = isTimeMachine(
                path: mountPath,
                device: device,
                name: name,
                hasBackupRole: ioInfo.hasBackupRole
            )
            let diskImage = ioInfo.isDiskImage || device.hasPrefix("/dev/disk_image")
            let auxiliary = isAuxiliary(path: mountPath, filesystemType: filesystemType)

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
                isDiskImage: diskImage,
                isTimeMachine: timeMachine,
                isAuxiliary: auxiliary
            ))
        }
        return results
    }

    private static func inspectDevice(bsdName: String) -> DeviceIOInfo {
        guard bsdName.hasPrefix("disk"),
              let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else {
            return DeviceIOInfo(containerUUID: nil, isDiskImage: false, hasBackupRole: false)
        }
        var current = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard current != 0 else {
            return DeviceIOInfo(containerUUID: nil, isDiskImage: false, hasBackupRole: false)
        }
        defer { IOObjectRelease(current) }

        var containerUUID: String?
        var isDiskImage = false
        var hasBackupRole = false

        while current != 0 {
            let className = IOObjectCopyClass(current).takeRetainedValue() as String
            if className == "AppleAPFSContainer", containerUUID == nil {
                if let value = IORegistryEntryCreateCFProperty(
                    current,
                    "UUID" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? String {
                    containerUUID = value
                }
            }
            if className == "AppleDiskImageDevice" || className == "AppleDiskImagesController" {
                isDiskImage = true
            }
            if !hasBackupRole {
                if let roles = IORegistryEntryCreateCFProperty(
                    current,
                    "Role" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? [String] {
                    if roles.contains("Backup") {
                        hasBackupRole = true
                    }
                }
            }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else { break }
            IOObjectRelease(current)
            current = parent
        }

        return DeviceIOInfo(containerUUID: containerUUID, isDiskImage: isDiskImage, hasBackupRole: hasBackupRole)
    }

    private static func isTimeMachine(
        path: String,
        device: String,
        name: String,
        hasBackupRole: Bool
    ) -> Bool {
        hasBackupRole
            || path.hasPrefix("/Volumes/.timemachine")
            || path.hasPrefix("/Volumes/com.apple.TimeMachine")
            || path.contains("/Backups.backupdb")
            || device.contains("com.apple.TimeMachine")
            || name == "Time Machine Backups"
            || (device.hasPrefix("//") && (path.contains(".timemachine") || device.lowercased().contains("timemachine")))
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
