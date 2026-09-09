# Hard-link finishing optimization — 2026-09-09

The resolver previously sorted every candidate inode identity, including files
whose other links were outside the scan. Within each actual group, its sort
comparator reconstructed both complete path strings on every comparison.

The resolver now filters singleton identities before sorting, computes each
member's full path once per group, and caches up to 4,096 parent-directory paths
across groups. The cache clears when full. It retains Swift String comparison and
stable equal-key ordering, device/inode group order, canonical-member selection,
and duplicate-byte accounting. Temporary member keys are scoped to one group.

## Measurements

Release builds on Intel macOS. Each fixture contains 100,000 candidate files
beneath a common 12-directory path, with permuted filenames. The timer covers
only hard-link resolution, ending when the Preparing totals phase begins.
Baseline uses the previous resolver in a temporary checkout; changed uses the
working implementation. The final runs were sequential with compilation and
the full test suite completed:

| Links per identity | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| 1 (no in-scan duplicates) | 39.60 ms | 2.95 ms | 13.4× |
| 2 | 1,364.66 ms | 302.69 ms | 4.5× |
| 100 | 25,331.94 ms | 253.49 ms | 99.9× |

These are synthetic measurements on an active workstation, not full-disk scan
predictions. The shared parent favors directory-cache reuse; real performance
will depend on directory locality, path depth, and group size. An earlier run
while other work was finishing measured 39.36 s baseline versus 0.24 s changed
for the large-group fixture, demonstrating substantial timing variability.

## Validation

The release suite passed all 68 tests, including a new test comparing full-path
member ordering and canonical selection across devices, Unicode-equivalent names,
punctuation/prefix directory names, singleton identities, and aggregate totals.
Existing scanner hard-link and snapshot tests passed. `git diff --check` passed.
No app relaunch or full-disk scan was performed. Changes are uncommitted;
unrelated existing edits were preserved.

Run the opt-in fixture with:

```sh
env TMPDIR=/tmp \
  SWIFT_MODULECACHE_PATH=/tmp/spacetree-hardlinks-module \
  CLANG_MODULE_CACHE_PATH=/tmp/spacetree-hardlinks-clang \
  SPACETREE_HARDLINK_BENCHMARK=1 \
  swift test --disable-sandbox --scratch-path /tmp/spacetree-hardlinks-build \
  -c release --filter optionalHardLinkFinishingBenchmark
```
