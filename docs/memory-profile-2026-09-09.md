# Peak memory profile and reduction — 2026-09-09

## Result

For the same 446.2 MiB saved scan (5,579,998 nodes), release-process peak RSS
for loading then saving fell from **1,877.6 MiB to 940.3 MiB**, a **937.3 MiB
(49.9%) reduction**. Loading alone fell from **1,463.1 MiB to 940.3 MiB**,
a **522.8 MiB reduction**. These compare fresh test processes on the same machine
and snapshot, including the grid changes already present before this work.

| Stage | Baseline peak RSS, MiB | Changed peak RSS, MiB | Baseline live heap, MiB | Changed live heap, MiB |
| --- | ---: | ---: | ---: | ---: |
| Input opened/read | 456.8 | 10.1 | 446.7 | 0.5 |
| Decode/validation returned, input retained | 1463.1 | 940.3 | 938.3 | 484.1 |
| Input released | 1463.1 | 940.3 | 492.1 | 484.1 |
| Save prepared/completed | 1877.6 | 940.3 | 1018.1 | 502.2 |

Baseline saving measured the old complete `encode` buffer before its disk write;
changed saving includes writing and synchronizing the complete file. Thus the
baseline does not include any additional cost of its atomic disk write.
Baseline input opening reads all bytes into heap memory. Changed opening maps
when safe, so initial RSS is low; checksum verification subsequently touches all
mapped pages, and those clean file-backed pages are included in the load peak.

A separate changed process loaded the same scan and built the grid at 1200 × 800
points, scale 2. Peak RSS stayed **940.2 MiB**. Live heap rose from **484.1 MiB**
after loading to **585.2 MiB** with 22,537 grid regions. This retains individual
file hover indexing; no file information or rendering detail was removed.

A fresh read-only scan of `/Volumes/dev/p` visited **450,784 nodes**, peaking at
**98.6 MiB RSS**, with **47.8 MiB live heap** after completion and **40.6 MiB**
estimated tree storage. It completed in 2.76 s. This is a smaller representative
filesystem scan, not a repeat of the entire saved disk, and has no before/after
scan baseline; it does not establish a full-disk scanning peak reduction.

## Causes and changes

1. **Duplicate snapshot input:** decoding constructed `Data(payload)` while the
   original serialized file remained alive. Reuse the payload slice and use
   `.mappedIfSafe` for disk input. The binary reader now also handles nonzero
   `Data.startIndex` correctly without normalizing through a copy.
2. **Validation hash tables:** replace per-node visited and hard-link membership
   sets with dense bitsets. Each bitset costs about 0.67 MiB for this scan.
   A node's second visit already detects both ancestry and sibling cycles, so
   separate active/sibling sets are unnecessary. Existing validity, parent,
   aggregate, reachability, and hard-link checks remain.
3. **Whole-file output allocation:** production saves now serialize through a
   1 MiB buffer, update SHA-256 incrementally, and write to a uniquely created
   sibling temporary file. Synchronize the finished file, then atomically rename
   it over the destination. Failure cleans up only the temporary file and leaves
   the previous snapshot intact. The version-4 byte format is unchanged.
4. **Overlapping snapshot work:** synchronous operations on a dedicated actor
   serialize production snapshot loads and saves. No decode or write operation
   suspends within that actor, preventing their temporary working sets from
   overlapping across targets. Filesystem scans remain independently scheduled.

## Remaining costs and comparison limits

The saved tree's estimated retained storage is **477.1 MiB**; its populated node
records alone require approximately **340.6 MiB**, before names, hard links, and
clone metadata. The renderer adds roughly **101 MiB** of live heap on this scan.
These costs remain. Rescanning can retain the old displayed generation alongside
new builder arrays, and multiple active targets can retain multiple trees.
This change does not claim to eliminate those scan-time peaks or array slack.

DaisyDisk was running at approximately 910 MiB RSS when inspected; SpaceTree was
not running. The DaisyDisk dataset/UI state was not independently matched.
The results above therefore establish a reduction in SpaceTree's measured code
paths, not a verified end-to-end comparison with DaisyDisk. Peak RSS, live malloc
heap, and Activity Monitor's physical footprint are different metrics. SwiftUI
and window-server memory are not included in this isolated benchmark.

## Validation

Release build and all **63 tests** passed. Added tests verify streamed output
matches the in-memory encoder across multiple node/name chunks, clone/hard-link
round trips, replacement of an existing cache, cleanup and preservation on
serialization/publication failures, nonzero-index input slices, truncation,
cycles, invalid links/parents/aggregates, and duplicate hard-link members.
Existing snapshot compatibility, checksum, scanner, and grid tests also passed.
`git diff --check` passed. Changes remain uncommitted.

## Reproduce

Run each mode in a fresh process to reset peak RSS. The benchmark reports
`getrusage(RUSAGE_SELF).ru_maxrss` and `malloc_zone_statistics.size_in_use`.

```sh
env TMPDIR=/tmp \
  SWIFT_MODULECACHE_PATH=/tmp/spacetree-grid-module \
  CLANG_MODULE_CACHE_PATH=/tmp/spacetree-grid-clang \
  SPACETREE_MEMORY_SNAPSHOT='/absolute/path/to/scan.spacetree' \
  SPACETREE_SNAPSHOT_MODE=save \
  swift test --disable-sandbox --scratch-path /tmp/spacetree-grid-profile \
  -c release --filter optionalSnapshotMemoryBenchmark
```

Use `SPACETREE_SNAPSHOT_MODE=grid` for load plus grid construction or `load` for
load only. The save benchmark writes only a unique temporary file and removes it.
The existing saved scan is never overwritten.

For a fresh read-only filesystem scan, set `SPACETREE_MEMORY_SCAN` to a directory
and select `optionalScanMemoryBenchmark`. This reports finishing-stage peaks and
the returned tree's storage/heap use without saving a snapshot.
