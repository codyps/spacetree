# In-memory filesystem model plan

Status: implemented on 2026-08-15; file-backed browsing remains deferred

This document defines the intended replacement for the recursive `FileNode` model. The goal is to let SpaceTree retain and interact with multi-million-entry scans without making a heap object, full `URL`, and child array for every filesystem entry.

The design takes the useful parts of ncdu and WinDirStat: a compact arena addressed by integer IDs, parent-relative names, cached subtree totals, and a separate hard-link identity index. It remains tailored to SpaceTree's Swift scanner, treemap, snapshots, and FSEvents refresh behavior.

## Why change the current model

`FileNode` is an immutable recursive value containing a full `URL`, `String`, `[FileNode]`, counts, sizes, and other metadata for every entry. This is convenient but expensive at scale:

- Every node repeats its full path through `URL`; only the basename and parent relationship are unique.
- Every directory owns a separate Swift array allocation and sorts it while the recursive tree is built.
- `DiskScanner` first retains `[String: DirectoryBatch]`, including full URLs for entries, and then constructs the recursive `FileNode` tree. Peak memory therefore includes much of both representations.
- Incremental refresh replaces recursive values and reconstructs ancestor nodes and their child arrays.
- UI selection and navigation retain whole `FileNode` values and use path strings as identity.
- Treemap construction flattens nodes into another array and uses a dictionary keyed by full path strings for rectangles.
- The property-list snapshot repeats the same recursive, path-heavy representation on disk and during decoding.

The first objective is to remove these structural costs. Lazy, file-backed browsing can follow later if real scans still exceed the desired memory envelope.

## Goals and constraints

The new representation must:

- Preserve a tile for every file and fast directory navigation.
- Preserve allocated size, logical size, modification time, recursive file/folder counts, unreadable counts, and hard-link labels.
- Never follow symbolic links. A symlink is a terminal node, including when supplied as the selected scan root.
- Stop at filesystem boundaries exactly as the scanner does today.
- Support multiple physical roots beneath one synthetic APFS-container root.
- Permit background construction and immutable reads by SwiftUI after publication.
- Support subtree refresh without recursively copying the retained tree.
- Use stable IDs within one published tree generation and detect stale IDs across generations.
- Use checked arithmetic and reject corrupt snapshots rather than trusting offsets or counts.

It is not a goal for the first migration to memory-map snapshots, maintain a global full-path index, expose clone/shared-extent accounting that macOS does not provide, or make node IDs stable between scans.

## Chosen representation

Use a dense node arena and refer to entries with a 32-bit `NodeID`:

```swift
struct NodeID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: UInt32
}

struct TreeGeneration: Hashable, Sendable {
    let rawValue: UUID
}

struct NodeHandle: Hashable, Sendable {
    let generation: TreeGeneration
    let id: NodeID
}
```

`UInt32.max` is the null node sentinel. A 32-bit ID permits more than four billion entries and halves link storage compared with native pointers. Every public lookup validates the generation and ID before indexing.

The initial implementation should use an aligned Swift `struct` in one contiguous `[NodeRecord]`. Do not use packed or unaligned fields in Swift. Measure `MemoryLayout<NodeRecord>.stride` in a test and keep the first version at or below 80 bytes if practical, with 96 bytes as a hard ceiling.

Conceptually, a record contains:

```text
NodeRecord
  parent: NodeID
  firstChild: NodeID
  nextSibling: NodeID
  nameOffset: UInt32
  nameLength: UInt16
  flags/kind: UInt16
  allocatedBytes: UInt64
  logicalBytes: UInt64
  modifiedNanoseconds: Int64
  recursiveFileCount: UInt32
  recursiveDirectoryCount: UInt32
  duplicateReferenceCount: UInt32
  hardLinkGroup: UInt32
```

The byte fields have this invariant:

- On a regular file they are that directory entry's intrinsic sizes.
- On a directory or synthetic root they are cached totals for the subtree.
- A hard-link reference retains its intrinsic sizes, but contributes them to aggregate totals only if it is the group's canonical accounting member. UI accessors may continue showing zero accounted bytes for non-canonical references while still making the intrinsic values available for future reclaimable-space calculations.
- A symlink has zero accounted size and no children.

Names are appended once to a `[UInt8]` UTF-8 arena. A node stores only its basename slice. Root URLs and display names live in a small `[RootDescriptor]` table rather than in every node. A path or `URL` is reconstructed by walking parents to the applicable physical root. UI code may cache the handful of paths currently visible, but the tree must not retain a full-path cache for every entry.

Children use `firstChild`/`nextSibling` links. This costs two IDs per node, avoids a separate array allocation for each directory, and permits subtree splicing during FSEvents refresh. Finalization orders each sibling chain by descending accounted allocated size and then by deterministic bytewise name order. Locale-aware display ordering, if desired, is a transient view index rather than canonical storage order.

Flags should be an `OptionSet` containing at least:

- file, directory, symlink, other, and synthetic-root kind bits;
- unreadable;
- non-canonical hard-link reference;
- tombstone, used only by mutable refresh storage.

Dates use signed nanoseconds from the Unix epoch with `Int64.min` meaning unknown. Device identifiers are interned in a small table when needed by hard-link records; they are not copied into every node.

## Tree ownership and read API

A completed `ScanTree` owns all storage:

```text
ScanTree
  generation
  nodes: [NodeRecord]
  nameBytes: [UInt8]
  roots: [RootDescriptor]
  hardLinkGroups: [HardLinkGroup]
  hardLinkMembers: [NodeID]
  unreadableCount
```

The UI stores `NodeHandle?` for root, current directory, and selection. It does not retain node values. `ScanTree` exposes narrow accessors such as:

- `name(of:)`, `path(of:)`, and `url(of:)`;
- `kind(of:)`, `allocatedBytes(of:)`, and `logicalBytes(of:)`;
- `children(of:)` and `files(inSubtree:)` as lazy sequences of IDs;
- `parent(of:)` and `breadcrumbs(to:)`;
- `metadata(for:)` for a small display projection used by rows and hover cards.

`NodeRecord` and mutable arrays remain internal so callers cannot retain unsafe indices or violate aggregation invariants. A completed tree is read-only and `Sendable`. Refresh is performed in a private mutable builder and publishes a new generation atomically, so SwiftUI never observes half-applied changes.

## Building the tree during a scan

Replace the path-keyed `DirectoryBatch` retention and recursive `buildDirectory` pass with a single coordinator-owned `ScanTreeBuilder`:

1. Validate the selected root with `lstat`; reject or represent a root symlink without opening it as a directory. Native directory opens must use `O_NOFOLLOW` to close replacement races.
2. Allocate the root node before submitting its directory work.
3. Directory workers continue returning flat metadata batches. Each work item carries its parent `NodeID` and the temporary `URL` needed to enumerate that directory.
4. The coordinator immediately interns every entry name and appends its node. It links children to the parent and queues directory children. It does not retain completed batches.
5. A transient `(device, fileID) -> hard-link group builder` performs identity accounting. This map exists only while scanning; the completed tree retains only groups that actually have multiple members.
6. After enumeration, visit nodes in reverse allocation order. Parents are always allocated before descendants, so reverse order is a valid bottom-up aggregation order. Accumulate subtree sizes, counts, duplicate counts, and descendant error state with overflow checks.
7. Sort/relink each directory's child chain by accounted size and name, freeze storage, and publish the completed `ScanTree`.

Only the bounded worker batches, pending directory work, transient identity map, and growing compact arenas should coexist. Pending work still contains temporary URLs in the first implementation. If profiling shows that queue dominating peak memory, replace those URLs with node IDs and reconstruct a path only when a worker accepts the item.

The builder is coordinator-confined rather than internally locked. Existing concurrent enumeration remains, but one task owns node allocation, name-arena writes, hard-link grouping, and link mutation. This makes deterministic output and cancellation cleanup substantially easier.

## Hard links and accounting

The displayed path hierarchy is a tree, but filesystem storage identity is a graph. Keep these concepts separate.

During scanning, key identity by the native `(device, fileID)` pair. Do not use `NSObject.hash` from `fileResourceIdentifier` as a persistent identity; the fallback path should either extract a stable byte representation for the duration of the scan or conservatively decline hard-link deduplication when it cannot establish identity.

Each retained `HardLinkGroup` records the identity, intrinsic allocated/logical sizes, canonical member, and a span in `hardLinkMembers`. Canonical ownership must be deterministic—for example, the member with the lexicographically smallest reconstructed path—not dependent on which concurrent worker completes first.

Phase one preserves the current product rule: exactly one member contributes to scan-wide and ancestor totals, and other members are labeled hard-link references. The representation deliberately retains all members and intrinsic sizes so a later phase can expose ncdu-style shared and reclaimable bytes without redesigning the tree.

Incremental refresh of a tree containing hard links should continue to fall back to a full scan until group membership and canonical reassignment are updated correctly. Do not silently apply subtree-local deduplication; it can double-count an identity linked outside the refreshed subtree.

## Incremental refresh and compaction

Subtree refresh operates on a mutable copy of the compact storage:

1. Resolve each coalesced changed path by walking child names from its physical root. A permanent global path dictionary is not required.
2. Scan the replacement subtree into the same builder format.
3. Mark the old subtree records as tombstones and splice the replacement root into the parent's sibling chain.
4. Subtract the old cached totals and add the replacement totals through the ancestor chain.
5. Re-sort only affected sibling chains.
6. Publish a new generation and clear current selection if its old handle no longer resolves.

Appending replacements leaves dead nodes and name bytes. Compact into fresh arenas after a refresh when either tombstoned node bytes or unreachable name bytes exceed 12.5% of their arena, or before saving a snapshot. Compaction remaps IDs, therefore it always creates a new generation and the UI must remap navigation by path or return to the nearest surviving ancestor.

Until this path is implemented and tested, use full rescans rather than converting the old recursive replacement code to the new model halfway.

## Treemap and UI integration

Treemap preparation should consume IDs directly:

- Flatten file `NodeID`s below the current directory without constructing `FileNode` copies.
- Sort an `[NodeID]` by accounted allocated size.
- Make `TreemapLayout.Item.id` a `NodeID` and produce rectangles aligned with the sorted item array. Avoid a `[String: CGRect]` keyed by full paths.
- Store the node ID in each tile. Resolve its name, color extension, path, and sizes only for visible labels, selection, or hover.
- Keep the spatial hit index transient because it depends on the current bounds.

`ScanTarget` changes from `root/current/selected: FileNode?` to one retained `ScanTree?` plus node handles. `visibleChildren` becomes a lightweight ID list or lazy collection. Breadcrumbs walk parent IDs instead of searching descendants by path prefix. Finder reveal reconstructs only the selected URL.

SwiftUI identity should be `NodeHandle`, not a path string. A generation component prevents a reused numeric ID from selecting an unrelated entry after refresh or rescan.

## Snapshots

Introduce snapshot version 2 with the compact model. Version 1 snapshots are caches, so they may be ignored and regenerated rather than decoded into a second full recursive tree.

Implement persistence in two steps:

1. Encode the compact arrays and name arena with `Codable` to establish behavioral parity quickly.
2. Replace that encoding with a versioned binary container containing a header, root table, fixed-record node block, name block, hard-link blocks, lengths, and checksum. Validate every count, offset, name range, node link, and checksum before publishing a loaded tree.

The final binary reader should decode directly into final arrays with bounded temporary memory. Memory mapping and block-lazy navigation are optional follow-up work, justified only by measurements from real snapshots.

## Migration sequence

### Phase 0: baseline and invariants

- Add a deterministic synthetic-tree generator at 100 thousand and 1 million entries.
- Record wall time, peak resident memory, retained memory, snapshot size, snapshot load peak, and treemap preparation time for the existing model.
- Add explicit root-symlink and directory-replacement-race safety tests before changing scanner storage.
- Add hard-link fixtures spanning sibling directories and verify deterministic results across repeated parallel scans.

### Phase 1: compact model in isolation

- Add `NodeID`, `NodeRecord`, `ScanTree`, `ScanTreeBuilder`, name arena, root descriptors, and hard-link groups.
- Build trees from synthetic metadata and test navigation, path reconstruction, aggregation, sorting, cancellation, overflow handling, and corrupt-ID rejection.
- Add a debug-only `validate()` that checks parent/child symmetry, acyclic sibling chains, valid name ranges, aggregate totals, hard-link membership, and reachability.

### Phase 2: scanner cutover

- Integrate directory batches immediately into `ScanTreeBuilder` and delete the retained `[String: DirectoryBatch]` plus recursive `buildDirectory` pass.
- Keep native and Foundation enumeration behavior unchanged while switching their metadata output to parent-relative names and stable native identity.
- Compare complete trees from the old and new models on generated fixtures and representative real directories before deleting the old scan path.

### Phase 3: UI and treemap cutover

- Convert `ScanTarget`, breadcrumbs, filtering, rows, Finder reveal, and details to node handles/accessors.
- Convert treemap flattening and layout to numeric IDs and aligned arrays.
- Remove `FileNode` after all UI and tests use `ScanTree`.

### Phase 4: compact snapshots

- Bump `ScanSnapshot.currentVersion` to 2 and store `ScanTree`.
- Initially discard version 1 caches; then implement the validated binary format and direct array decoding.
- Measure save/load peak memory as well as file size.

### Phase 5: refresh and hard-link refinement

- Implement tombstone-and-splice subtree refresh, ancestor deltas, and threshold compaction.
- Retain the full-rescan fallback for hard-link-bearing trees until cross-subtree group repair is correct.
- Optionally add shared/reclaimable-byte metrics using the retained hard-link groups.

### Phase 6: consider file-backed browsing

Only if a compact million-entry scan still fails the memory goals, prototype an ncdu-style indexed binary backing store with cumulative directory totals and block-lazy child loading. Do not add this complexity before the compact resident model is measured.

## Validation and acceptance criteria

Correctness gates:

- Existing aggregation, treemap geometry, real scan, multi-target, snapshot, and FSEvents tests pass against the new API.
- Child symlinks and selected-root symlinks are never traversed.
- Parent links, child links, names, and aggregate totals pass `ScanTree.validate()` for every test fixture.
- Repeated parallel scans produce identical hierarchy ordering and hard-link canonical members.
- Every non-tombstoned node is reachable exactly once from a root in the path hierarchy.
- Corrupt/truncated snapshots fail closed without out-of-bounds access or partial publication.

Performance gates, measured in a release build:

- `NodeRecord` stride is no more than 96 bytes, with 80 bytes the design target.
- A completed synthetic tree of 1 million entries consumes at most 128 MiB for node records, child links, names, roots, and retained hard-link metadata, excluding UI-derived treemap state and fixed process/runtime overhead.
- Peak scan memory is at most twice the retained compact-tree size plus a documented bounded allowance for the transient identity map.
- The new retained representation uses at least 50% less memory than the Phase 0 `FileNode` baseline on the same fixture.
- Snapshot loading does not construct a recursive intermediate tree and stays below twice the final tree's retained size.
- Numeric-ID treemap preparation uses less peak memory than the current path-keyed implementation and remains responsive at 1 million files.

If a target is missed, record the profile before changing the architecture. In particular, distinguish node storage, UTF-8 names, pending directory URLs, the hard-link hash map, snapshot decoding, and treemap-derived state; each requires a different remedy.

## Implementation status

Phases 1 through 4 are complete: `ScanTree` is the application source of truth, scanning appends directly into the compact builder, the UI and treemap retain numeric IDs, `FileNode` has been removed, and snapshots use the checksummed version 2 binary format. The scanner now rejects a symbolic-link root before enumeration and uses `O_NOFOLLOW`; its native fallback enumerates relative to the opened directory descriptor with `readdir` and `fstatat(..., AT_SYMLINK_NOFOLLOW)`.

Refresh is also implemented, with one deliberate deviation from the tombstone design above. A changed subtree is rescanned, then unchanged subtrees are copied from the old compact generation into a new compact builder. This avoids a full filesystem rescan and recursive value copying while publishing an already-compacted immutable generation. It is currently O(number of retained nodes) in memory work. Trees containing duplicate hard-link references retain the full-scan fallback until cross-subtree group repair is implemented.

The release benchmark on 2026-08-15 produced:

- 1,000,001 nodes;
- a 64-byte `NodeRecord` stride;
- 83,886,008 bytes (about 80 MiB) of estimated retained arena storage;
- 1.50 seconds to construct and finalize the tree, and 2.40 seconds including validation and test overhead.

This meets the 96-byte record and 128 MiB retained-storage gates, so Phase 6 file-backed browsing is not justified yet. The former `FileNode` implementation was removed before a comparable Phase 0 peak-RSS baseline was captured; the 50% improvement and peak-RSS gates therefore remain unverified rather than inferred. Snapshot size/load peak still need instrumentation on representative real scans.

The same opt-in release benchmark now also builds the complete million-file treemap scene. Row aspect statistics are maintained incrementally, making squarified geometry linear after sorting rather than repeatedly scanning and copying the current row. Direct children partition each directory's region recursively, but only file tiles are rendered; this keeps files from the same directory spatially grouped without adding directory chrome. The scene retains every file tile and batches its Canvas geometry into the eight existing color categories. A 2026-08-15 run prepared 1,000,000 tiles, their hit-test index, labels, categories, and cached render paths in 0.98 seconds. The benchmark is repeatable with:

```sh
SPACETREE_RUN_MILLION_NODE_BENCHMARK=1 swift test -c release --filter optionalMillionEntryReleaseBenchmark
```
