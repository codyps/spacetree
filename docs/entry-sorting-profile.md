# Entry sorting optimization - 2026-09-22

## What the stage does

After resolving hard links and calculating directory totals, `ScanTreeBuilder`
sorts each directory's children by effective allocated size descending, then raw
UTF-8 filename bytes ascending. Duplicate hard-link references sort as zero bytes.
It rewrites the sibling links used to traverse the finished tree. This is an
in-memory operation; it does not reread file contents or sort full paths.

The latest local scan history, inspected for this change, recorded debug builds:

| Completed (UTC) | Entries | Sorting time |
| --- | ---: | ---: |
| 2026-09-23 02:06:10 | 1,481,583 | 55.38 s |
| 2026-09-23 01:38:51 | 12,306,903 | 770.06 s |

Debug mode amplifies the previous comparator's repeated node-record reads,
array-slice construction, and generic byte-by-byte collection comparisons.
Use `swift run -c release SpaceTree` for real scans. The README now defaults to
that command.

## Change

The persistent tree already uses a contiguous node array and a UTF-8 name arena.
Rather than replace that representation, sorting now gathers each child's
effective size, ID, name offset, and name length into a contiguous scratch array.
The comparator reads those keys directly and uses `memcmp` for equal-size names,
then compares lengths for prefix ties. Swift's stable sort retains insertion
order when both keys are equal. This is deterministic for a given sibling input
order; it does not impose a new tie-breaker across different scan insertion
orders. No filenames are decoded or copied for sorting.

The scratch array is reused across directories, and empty/single-child directories
skip allocation and relinking. It has 24-byte records on this machine, compared
with the previous 4-byte child IDs, so very large individual directories use more
temporary memory. Scratch capacity follows the largest directory, not the total
scan size. Persistent node layout, IDs, snapshot format, and filename ordering
are unchanged.

## Measurements

Intel macOS, separate test processes on an active workstation. Baseline uses the
sorter at `2a50d0d` in a temporary source copy; changed uses this implementation.
The same deterministic fixture inserts permuted filenames with a shared prefix
and 16 allocated-size buckets. Timings cover only the sorting stage, excluding
fixture creation and other finishing phases. Runs were sequential, without
compilation or another benchmark running alongside the measured stage.

| Build | Files | Files per directory | Before | After | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| Debug | 1,500,000 | 256 | 33.132 s | 5.208 s | 6.4× |
| Debug | 4,000,000 | 256 | 102.391 s | 13.031 s | 7.9× |
| Release | 1,500,000 | 256 | 0.195 s | 0.125 s | 1.6× |
| Release | 4,000,000 | 256 | 0.604 s | 0.444 s | 1.4× |
| Release | 500,000 | 500,000 | 0.583 s | 0.220 s | 2.6× |

Peak process RSS for the four-million-file release fixture was 910.5 MiB before
and 909.2 MiB after. For the single 500,000-file directory it was 108.8 MiB before
and 116.3 MiB after. RSS includes fixture construction and test-process overhead;
these are single-run observations, not isolated allocation measurements.

These synthetic results are not full-disk scan predictions. Directory sizes,
equal-size frequency, filename prefixes, memory pressure, and build mode all
affect performance. In particular, release mode is a much larger improvement
than the algorithm change alone. No app relaunch or full-disk rescan was performed.

## Validation and reproduction

The original 83-test release run preceded the final test edits. Correctness tests check size ordering, raw
Unicode bytes, long common prefixes, empty names and an empty name arena,
stable equal-key ordering, hard-link accounting, sibling integrity, and appending
after finalization. Existing scanner, snapshot, and treemap tests also passed.

Run the opt-in benchmark, substituting `1500000` or `4000000` for the file count.
For a wide folder, use count `500000` and fanout `500000`. Omit `-c release` for
debug measurements:

```sh
env TMPDIR=/tmp \
  SWIFT_MODULECACHE_PATH=/tmp/spacetree-swift-module-cache \
  CLANG_MODULE_CACHE_PATH=/tmp/spacetree-clang-module-cache \
  SPACETREE_SORT_BENCHMARK=4000000 SPACETREE_SORT_FANOUT=256 \
  swift test --disable-sandbox --scratch-path /tmp/spacetree-sort-build \
  -c release --filter optionalEntrySortingBenchmark
```

## Review validation - 2026-09-25

The final sorting tests passed in release mode, and the complete release suite
passed all 84 tests. Added explicit expected byte ordering (including composed
and decomposed Unicode, multibyte names, prefixes, and embedded NUL), 256
interleaved equal-key entries, repeated finalization, and direct canonical/
duplicate link and allocated-total assertions. No sorter change was necessary.
The opt-in benchmark now rejects invalid or nonpositive fanout instead of
silently falling back or trapping on division by zero.

Fresh measurements on Intel macOS with Apple Swift 6.3.2, sequential separate
release test processes using `--skip-build` after compilation:

| Files | Files per directory | Sorting | Peak process RSS |
| ---: | ---: | ---: | ---: |
| 1,500,000 | 256 | 0.134 s | 351.5 MiB |
| 4,000,000 | 256 | 0.478 s | 907.4 MiB |
| 500,000 | 500,000 | 0.232 s | 123.4 MiB |

These are single-run checks of the current implementation. The historical
baseline above was not rerun; these measurements do not establish a new speedup
ratio. No full-disk scan or app/UI validation was performed. The unrelated
README edits were preserved.
