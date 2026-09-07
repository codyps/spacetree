# SpaceTree

SpaceTree is a native macOS disk space analyzer inspired by WizTree. It discovers mounted filesystems and turns each scanned location into a proportional treemap: the more allocated disk space an item consumes, the larger its tile.

![Native macOS](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)

## Features

- Native SwiftUI interface with no third-party dependencies
- Squarified, proportional treemap with a separate hoverable tile for every file, spatially grouped by directory
- Background treemap layout and asynchronous Canvas rendering keep the interface responsive
- Double-click folder drill-down with breadcrumb navigation
- File/folder detail list, search, and Finder reveal
- Allocated and logical byte accounting
- Hard-link and repeat-traversal deduplication using filesystem device/inode identity
- Live item, byte, path, and unreadable-file progress
- Independent, cancellable scans that can run in parallel
- Persistent results for every scanned volume or folder
- Native mount-table and IOKit discovery of APFS containers and other filesystems
- Batched `getattrlistbulk` metadata reads with bounded directory concurrency
- Parallel scans of mounted filesystems within an APFS container
- Persistent binary snapshots and FSEvents-based incremental refreshes
- Safe handling of symbolic links (they are never followed)
- Read-only operation: SpaceTree does not delete or modify scanned files

## Run it

You need macOS 14 or newer and Xcode 16 or newer.

```sh
swift run SpaceTree
```

For an optimized build:

```sh
swift build -c release
.build/release/SpaceTree
```

The main dashboard lists APFS volumes and other mounted filesystems. Scan any item individually or use **Scan All** to run them concurrently. Scanning an entire startup disk can take a while because SpaceTree uses normal macOS filesystem APIs rather than a privileged filesystem index.

## macOS privacy permissions

macOS may prevent access to Mail, Messages, other users' data, or some system folders. SpaceTree reports those items as unreadable and continues scanning everything else.

Hard-linked files remain visible at every path, but only the first encountered `(device, inode)` pair contributes bytes to folder totals. Later references are labeled **Hard link** and show zero allocated bytes. APFS clones use distinct inodes and may share only some extents, which the normal macOS file metadata APIs do not expose; SpaceTree therefore counts clones separately.

To include protected locations, grant the terminal or packaged application **Full Disk Access** in:

**System Settings → Privacy & Security → Full Disk Access**

Then quit and reopen SpaceTree before scanning again.

## Controls

- **Add Folder** or `⌘O`: add a particular folder and immediately scan it
- **Add Home** or `⇧⌘H`: add and scan your home folder
- **Scan All** or `⇧⌘A`: scan all currently mounted items and added folders concurrently
- **Refresh Volumes**: discover newly mounted filesystems without discarding results
- **View**: open the retained treemap for a completed scan
- **Rescan**: explicitly discard and replace that item's previous result
- Hover a file tile: inspect its full path, allocated size, and share of the current view
- Single-click a file tile or row: select it
- Double-click a folder row: drill into it
- Click a breadcrumb: navigate back up
- **Reveal**: show the selected item in Finder

### Mounted filesystems

SpaceTree uses the native mount table and I/O Registry directly; it does not invoke `diskutil`. Mounted APFS filesystems that share an `AppleAPFSContainer` UUID—such as the startup System, Data, VM, Preboot, Nix, and development volumes—are combined into one scan target. External APFS containers and non-APFS filesystems remain separate. Time Machine backup volumes, mounted snapshots, disk images, and developer simulator/low-level system mounts are excluded by default from the dashboard and "Scan All", but can be enabled on demand with the dashboard's **Time Machine**, **Disk images**, and **Developer/system** checkboxes.

Container scans visit each constituent filesystem exactly once and stop at mount boundaries, preventing nested mounts from being counted twice.

### Scan performance

On supported macOS filesystems, SpaceTree retrieves names, types, file IDs, sizes, allocation sizes, and modification dates for many directory entries in each `getattrlistbulk` call. Up to eight directory reads run concurrently, while separate mounted filesystems in an APFS container scan in parallel. Filesystems that do not support bulk attributes automatically use descriptor-relative `readdir`/`fstatat` enumeration. Directory descriptors are opened with `O_NOFOLLOW`, and entry metadata is read with `AT_SYMLINK_NOFOLLOW`.

Completed trees are stored as binary snapshots in the user's Application Support directory. SpaceTree monitors their roots with FSEvents. Clicking **Check** on an unchanged result returns immediately; when changes are reported, **Update** rescans and replaces only affected directory subtrees. Dropped events, root changes, very large change sets, or trees containing hard-link references conservatively trigger a full rescan.

## Verify

```sh
swift test
```

The tests cover size aggregation, treemap geometry, real filesystem scanning, hard-link deduplication, symlink-loop avoidance, independent scans, and result retention.

### Cloud files and scan completeness

Scanning reads filesystem metadata, never regular-file contents. SpaceTree requires
macOS's no-materialization policy before scanning and applies a synchronous thread
override around directory enumeration and root metadata lookup. If protection cannot
be enabled, the operation fails. A folder whose listing requires materialization is
reported as unreadable, not as successfully scanned and empty. Cloud totals can
therefore be incomplete; logical size does not mean downloaded disk usage.

This prevents scan-triggered dataless materialization through macOS File Provider;
it does not suppress independent provider syncing or promise zero provider/network
activity. Excluding known cloud roots entirely would also hide locally downloaded
files and their disk usage. A universal provider-root exclusion is not implemented.
