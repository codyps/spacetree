# Grid rendering profile — 2026-09-09

## Scope and method

Release build on Intel macOS, based on commit `950a1db`. Profiled the actual
`TreemapScene.build` path at 1200 × 800 points, display scale 2. A saved scan
contained 5,579,998 nodes and represented 4,321,369 files in 22,537 display
regions. Snapshot decoding was completed before scene timing began.

The opt-in saved-snapshot benchmark now reports seven runs by default, separating
layout and virtual-file indexing, bitmap rasterization, and finishing/hit-index
construction. `SPACETREE_LAYOUT_RUNS` overrides the repetition count. The previous
scene is released before building the next one.

A five-second `sample` capture during repeated baseline scene construction found
2,065 of 3,106 sampled benchmark stacks in the sibling-expansion call at
`TreemapLayout.swift`'s `stack.append(contentsOf: tree.childIDs(of: id))`.
Underlying stacks showed `AnySequence` copying, closure-based iterator creation,
allocation, and reference-count overhead. This is inclusive stack attribution,
not an exact CPU-time percentage.

## Change

- Replace closure-based `AnySequence`/`AnyIterator` sibling traversal with a concrete,
  restartable sequence and value iterator over the existing node array. This
  preserves sibling order and avoids per-directory wrapper allocations.
- Apply the 120 ms resize coalescing delay only when the same content changes size.
  Initial display, navigation, replacement scans, and display-scale changes start
  immediately. Cancellation and serialized scene construction remain in place.
- Preserve existing tile drawing, labels, region budgets, and individual-file
  hover indexing.

## Measurements

Seven-run stage medians, milliseconds:

| Stage | Baseline | Changed, first run | Changed, repeat |
| --- | ---: | ---: | ---: |
| Layout and virtual-file index | 2436.8 | 953.9 | 1176.3 |
| Bitmap rendering | 149.8 | 566.9 | 530.2 |
| Finishing | 3.5 | 10.4 | 10.3 |

Layout/index medians decreased by 52–61%. Average complete scene construction
(including benchmark reporting overhead) was 2.60 s before and 1.51–1.84 s after.
Drawing code was unchanged, but its timing and finishing timing became materially
slower across runs. These were sequential measurements on an active workstation,
not controlled interleaved trials; treat the numbers as observed ranges rather
than a precise reproducible speedup. The sampled allocation hotspot and the
layout reduction both support the iterator change.

Snapshot decode peak RSS was approximately 1.46 GiB across these processes; these
measurements do not establish a memory reduction. The removed 120 ms navigation
delay is separate from scene timings.

## Validation and limits

- Release build and all 57 tests passed.
- Saved-snapshot runs preserved represented file count, byte totals, and region
  budget; existing raster color and individual hover/deletion-rectangle tests pass.
- New tests cover restartable sibling order, independent iterators, empty folders,
  and resize versus navigation/replacement scheduling.
- `git diff --check` passed.
- No running SpaceTree application was available. SwiftUI label composition,
  window-server presentation, and visible navigation latency were not profiled.

## Reproduce

Use a writable task-specific scratch and module-cache directory:

```sh
env TMPDIR=/tmp \
  SWIFT_MODULECACHE_PATH=/tmp/spacetree-grid-module \
  CLANG_MODULE_CACHE_PATH=/tmp/spacetree-grid-clang \
  SPACETREE_LAYOUT_SNAPSHOT='/absolute/path/to/scan.spacetree' \
  SPACETREE_LAYOUT_RUNS=7 \
  swift test --disable-sandbox --scratch-path /tmp/spacetree-grid-profile \
  -c release --filter optionalSavedSnapshotLayoutBenchmark
```

For the allocation profile, run more repetitions and sample the
`swiftpm-testing-helper` process during scene construction, after snapshot decode.
