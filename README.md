# SpaceTree

SpaceTree is a native macOS disk space analyzer inspired by WizTree. It discovers mounted filesystems and turns each scanned location into a proportional treemap: the more allocated disk space an item consumes, the larger its tile.

![Native macOS](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)

## Features

- Native SwiftUI interface with no third-party dependencies
- Squarified, proportional treemap grouped by directory; tiny files are aggregated in the overview, with full detail available by opening folders or browsing the file tree
- Background treemap layout and asynchronous Canvas rendering keep the interface responsive
- Double-click folder drill-down with breadcrumb navigation
- File/folder detail list, search, and Finder reveal
- Allocated and logical byte accounting
- Hard-link and repeat-traversal deduplication using filesystem device/inode identity
- Live item, byte, path, and unreadable-file progress
- Estimated scan progress and time remaining using volume file/directory counts
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

## Download or build a DMG

The reusable **macOS build** GitHub Actions workflow checks pull requests,
branch pushes, and manual builds. The **Development** workflow calls it for every
push to `main`. It uses macOS 26 runners with Xcode 26.5 (Swift 6.3.2), matching
the local development toolchain. It tests on Apple Silicon and Intel, then builds a universal
`SpaceTree.app` for macOS 14 or newer. Download the **SpaceTree-universal-dmg**
artifact from a successful workflow run, unzip it, open the DMG, and drag
SpaceTree to Applications. Artifacts include a SHA-256 checksum and are retained
for 14 days. Stable installers are published separately through the release-PR
flow described below.

Build the same installer locally with Xcode's command-line tools:

```sh
scripts/build-dmg.sh
# Optional version/build overrides:
VERSION=0.1.0 BUILD_NUMBER=2 scripts/build-dmg.sh
```

The installer is written to `dist/SpaceTree-<version>-universal.dmg`, using
`version.txt` unless `VERSION` is supplied.
`SPACETREE_BUILD_ROOT` and `SPACETREE_OUTPUT_DIR` can override the build and output
directories. The script builds both architectures, packages the icon and app
metadata, signs the app ad hoc, creates a compressed DMG, and mounts it read-only
to verify the packaged signature, architectures, resources, and Applications link.

These builds are **ad-hoc signed, not Developer ID signed or notarized**. macOS
Gatekeeper may block downloaded builds on first launch. No signing credentials
are required by this workflow; trusted public distribution would need Developer ID
signing and notarization added separately. Generated installers and backup reports
remain excluded from Git.

### Development builds

The rolling [Development release](https://github.com/codyps/spacetree/releases/tag/development)
contains the latest published development DMG and checksum. Every push to `main`
runs tests and builds an installer; successful builds update this single prerelease
only if their commit is still the head of `main`. Publication is serialized so an
older run cannot overwrite a newer build. Manual runs of **Development** on `main`
can retry publication. PRs, other branches, and stable release builds cannot publish
to this channel.

Development versions look like `0.2.0-dev.14+gabc123def456`: the version from
`version.txt`, the commit distance from the nearest reachable `vX.Y.Z` tag, and the
Git hash. Before the first version tag, the distance is the total commit count.
The moving `development` tag is ignored, full Git history is fetched, and builds
on an exact version tag still include the hash. Local tracked changes add `.dirty`.

The full version appears in the DMG filename and **About SpaceTree**, and is stored
as `SpaceTreeDisplayVersion` in the app's Info.plist. Apple's numeric
`CFBundleShortVersionString` and `CFBundleVersion` remain valid. Stable release
filenames continue to use plain `X.Y.Z` versions.

```sh
DISPLAY_VERSION=$(python3 scripts/build-version.py --development) scripts/build-dmg.sh
```

CI uploads the new versioned assets before updating the rolling tag and release
notes, then removes obsolete DMGs/checksums from that release. Unrelated assets
are preserved. The prerelease is never marked as the latest stable release, and
its notes link to the exact commit and CI run. Failed tests/builds leave the
previous development release available.

### Stable releases

The **Release** workflow uses [Release Please](https://github.com/googleapis/release-please)
to maintain a release PR against `main`. Its `simple` strategy updates `version.txt`,
`.release-please-manifest.json`, and `CHANGELOG.md`. Commit messages (or squash-merge
PR titles) determine the next version:

- `fix: ...` produces a patch bump.
- `feat: ...` produces a minor bump.
- `feat!: ...` or a `BREAKING CHANGE:` footer produces a major bump after 1.0;
  while the app is below 1.0, breaking changes produce a minor bump.
- Documentation and maintenance commits normally wait for the next feature/fix
  release; they do not independently trigger one.

The initial version is configured as `0.1.0`, with history bootstrapped after
`bfa675a`. Use conventional commit messages for new work; earlier free-form
commit messages are not retroactively classified.

1. Merge development changes into `main`. The bot creates or refreshes one release PR.
2. CI is explicitly dispatched for that PR's branch, because PRs created with
   `GITHUB_TOKEN` do not automatically trigger the normal PR workflow.
3. Review the proposed version/changelog and merge the release PR.
4. Release Please creates a version tag and a **draft** GitHub Release. The same
   workflow tests and builds that exact tagged commit using the reusable macOS workflow.
5. Only after the DMG passes verification are it and its checksum uploaded and the
   draft published as the latest release. No additional tag-triggered workflow is needed.

`version.txt`, the manifest version, and the release tag must match. Release builds
are pinned to the tag's resolved commit, even if `main` advances while they run.
Publication rechecks that the tag has not moved. Failed builds leave a draft;
use **Actions → Release → Run workflow** on `main` with `retry_tag` set to that
draft's tag (for example, `v0.2.0`) to retry. This rebuilds and tests the same commit;
it does not overwrite an already published release. If that commit contains a
build bug, fix it through another release PR instead of moving the old tag.

Repository setup requires **Settings → Actions → General → Workflow permissions →
Allow GitHub Actions to create and approve pull requests**. The default token can
remain read-only: write permissions are scoped to release preparation/publication
jobs. No PAT or extra secret is required, and the workflow never approves or merges
its own PR. Publishing is restricted to the `main` release flow.

The main dashboard lists APFS volumes and other mounted filesystems. Scan any item individually or use **Scan All** to run them concurrently. Scanning an entire startup disk can take a while because SpaceTree uses normal macOS filesystem APIs rather than a privileged filesystem index.

## macOS privacy permissions

macOS may prevent access to Mail, Messages, other users' data, or some system folders. SpaceTree reports those items as unreadable and continues scanning everything else.

Hard-linked files remain visible at every path, but only the first encountered `(device, inode)` pair contributes bytes to folder totals. Later references are labeled **Hard link** and show zero allocated bytes. APFS clones use distinct inodes and may share only some extents, which the normal macOS file metadata APIs do not expose; SpaceTree therefore counts clones separately.

To include protected locations, grant the terminal or packaged application **Full Disk Access** in:

**System Settings → Privacy & Security → Full Disk Access**

Then quit and reopen SpaceTree before scanning again.

## Controls

- **Add Folder** or `⇧⌘O`: add a particular folder and immediately scan it
- **Add Home** or `⇧⌘H`: add and scan your home folder
- **Scan All** or `⇧⌘A`: scan all currently mounted items and added folders concurrently
- **Refresh Volumes**: discover newly mounted filesystems without discarding results
- **View**: open the retained treemap for a completed scan
- **Rescan**: explicitly discard and replace that item's previous result
- Hover a file tile: inspect its full path, allocated size, and share of the current view
- Single-click a file tile or row: select it
- Shift-click selects a range of tree rows; Command-click toggles individual rows; `⌘A` selects all visible rows
- Arrow keys navigate the tree; Left/Right collapse and expand folders; type a name to jump to it
- Double-click a row or map tile, `⌘O`, or `⌘↓`: open a folder in SpaceTree or a file in its default app
- Space: Quick Look; Return: rename the selected item
- `⌘C`: copy selected files; `⌥⌘C`: copy their pathnames
- Right-click or Control-click either view for Open, Reveal in Finder, Quick Look, Copy, Copy Pathname, Rename, and Move to Trash
- `⌘⌫`: move selected items to Trash after confirmation. Rename updates the scan; Trash marks successful moves in red without rebuilding the view. Click Update to recalculate totals. Scan roots are protected
- Click a breadcrumb: navigate back up
- **Back** (`⌘[`) and **Forward** (`⌘]`): revisit directories within the current report
- **Up** (`⌘↑`): open the enclosing directory, stopping at the scan root
- **Reveal**: show the selected item in Finder

### Mounted filesystems

SpaceTree uses the native mount table and I/O Registry directly; it does not invoke `diskutil`. Mounted APFS filesystems that share an `AppleAPFSContainer` UUID—such as the startup System, Data, VM, Preboot, Nix, and development volumes—are combined into one scan target. External APFS containers and non-APFS filesystems remain separate. Time Machine backup volumes, mounted snapshots, disk images, and developer simulator/low-level system mounts are excluded by default from the dashboard and "Scan All", but can be enabled on demand with the dashboard's **Time Machine**, **Disk images**, and **Developer/system** checkboxes.

Container scans coalesce overlapping roots and track directory device/inode identities before scheduling enumeration. This prevents macOS firmlink aliases such as `/Users` and `/System/Volumes/Data/Users` from being traversed twice. Distinct mounted filesystems remain separate scan roots, and enumeration stops at device boundaries.

Full scans estimate progress from volume file and directory counts when available, weighting completed directory reads more heavily than discovered items. The startup estimate includes both System and Data volumes once. When volume counts are unavailable, SpaceTree uses a previous complete scan of the same roots, then allocated space as a rough fallback for volume scans. Time remaining uses smoothed scan speed, with the final 10% reserved for finishing. Counts can differ from accessible contents, so percentages and times are approximate; stalled or exceeded estimates stop showing an ETA. First-time folder scans and incremental updates remain indeterminate when no suitable total is known.

### Treemap performance

The overview generates at most 131,072 regions, sharing detail proportionally across folders so one large subtree cannot hide the rest. Internal folders stay visible unless their own projected size is tiny. Small-file groups are split into compact blocks and labeled with their directory name where there is room. A compact weighted file index resolves individual-file hover, selection, and context-menu actions inside those blocks without storing individual drawing rectangles. The file tree retains all files.

Layout jobs are cancelled and joined before their replacements start, and window resizing is coalesced for 120 ms while the previous image remains visible. Tiles draw directly into a bitmap capped at 16 megapixels; the fallback also uses the bounded tile set.

### Scan performance

On supported macOS filesystems, SpaceTree retrieves names, types, file IDs, sizes, allocation sizes, and modification dates for many directory entries in each `getattrlistbulk` call. Up to eight directory reads run concurrently, while separate mounted filesystems in an APFS container scan in parallel. Filesystems that do not support bulk attributes automatically use descriptor-relative `readdir`/`fstatat` enumeration. Directory descriptors are opened with `O_NOFOLLOW`, and entry metadata is read with `AT_SYMLINK_NOFOLLOW`.

Completed trees are stored as binary snapshots in the user's Application Support directory. SpaceTree monitors their roots with FSEvents. Clicking **Check** on an unchanged result returns immediately; when changes are reported, **Update** rescans and replaces only affected directory subtrees. Dropped events, root changes, very large change sets, trees containing hard-link references, or scans with multiple roots or rooted at `/` conservatively trigger a full rescan. These refreshes need the complete directory identity set to keep aliases deduplicated.

## Verify

### Time Machine change reports

The standalone [Time Machine change explorer](scripts/time-machine/README.md)
compares mounted backup snapshots and creates an offline interactive report of
recorded backup sizes, frequently changed files, and folder contributions:

```sh
python3 scripts/time-machine/analyze.py "/Volumes/T7 Shield" --output backup-reports/t7
open backup-reports/t7/index.html
```

### App tests

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

### Immediate Trash feedback

Moving items to Trash preserves the current map, expanded folders, and scroll position. Successfully moved rows show red “Trashed” labels; the map adds red outlines, including virtual file regions inside grouped blocks. A hidden folder can mark its containing group. Failed items stay unchanged and completed moves remain marked after a partial failure. Marked items and descendants cannot be opened or modified again through the view. Totals remain the scan snapshot until **Update** is requested; a new scan clears the marks.

### APFS clone metadata

Fresh scans annotate full APFS clones and files that may share blocks in the
outline Type column and treemap hover text. A full clone's context menu can
reveal other observed full clones in Finder. Clone metadata is saved with the
scan; older snapshots get a full metadata refresh on Check/Update before these annotations are available.
Allocated sizes remain per-file values, not an estimate of reclaimable space.

Bulk filesystem reads now distinguish directory records from file records.
Saved scan statistics include `filesystemReads` counters for bulk calls/entries,
fallback directories, extended-attribute retries, and errors. See
[the APFS detection notes](docs/apfs-clone-detection.md) for limitations and tests.
