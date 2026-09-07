# Treemap memory and CPU investigation

Investigated 2026-09-07. The baseline below includes the layout progress change; the implemented results are recorded at the end.

## Observed dataset and limits of diagnosis

The saved `Macintosh HD APFS Container` snapshot contains 9,501,401 nodes: 7,716,381 files and 1,785,020 directories. It covers six mounted roots, including the startup filesystem, `/Volumes/dev`, and `/nix`. Its serialized size is about 742 MiB. Nodes at their 64-byte in-memory stride plus name bytes account for about 755 MiB before capacity slack, hard-link indexes, and other application state.

SpaceTree was not running during inspection. The reported 22 GiB process footprint was therefore not captured or reproduced. System swap usage was about 15 GiB at inspection; this is system-wide and cannot identify SpaceTree as its sole cause. RSS benchmark figures below are process high-water marks, not Activity Monitor's compressed-memory accounting.

## Controlled evidence

Release build, x86_64 macOS test target, synthetic metadata only:

- Existing flat-million benchmark: scene construction 1.48 seconds, compact tree allocation 80 MiB.
- New nested benchmark: 1,000,000 files in 100,000 directories, 1200 × 800 points at 2× display scale. Tree allocation 144 MiB. Process peak RSS: tree ready 233 MiB; geometry complete 387 MiB; paths prepared 565 MiB; raster complete 580 MiB; scene complete 659 MiB. Scene construction approximately 3.44 seconds.
- Skewed benchmark: one dominant file plus 1,000,000 small files in 100,000 directories. All one million small tiles were narrower or shorter than a physical pixel, yet peak RSS still reached 662 MiB and scene construction took approximately 1.61 seconds. The renderer paid nearly the same memory cost for invisible detail.
- These runs establish allocation amplification; they do not justify a precise linear prediction for the full disk or reproduce its workload.

## Baseline source issues

1. **Obsolete builds run to completion.** `TreemapView.prepareScene` creates a detached worker. SwiftUI changes the task ID on rounded size, node set, tree generation, or display-scale changes. Cancellation stops consuming progress or publishing the result, but never cancels the worker. `TreemapScene.build` has no cancellation checks. Repeated resize/navigation requests can therefore retain several whole trees/scenes in active builds. The immutable tree may be shared for the same generation, but each build allocates its own scene geometry. This is a plausible multiplier behind the reported spike, not a measured explanation of that incident.
2. **Duplicated per-file geometry.** Each file has a 24-byte entry and a 40-byte tile. Every node also gets a rectangle dictionary entry. Every file rectangle is copied into category arrays and category paths; paths are retained even after a raster image is available. Folders take 80 bytes each, including those too small to label. The hit grid adds further tile-index storage. Temporary arrangements also contain node IDs, weights, and rectangles.
3. **No screen-resolution limit on work.** Every reachable file is sorted/laid out, assigned a category, converted to paths, drawn, and indexed, even when its rectangle is subpixel. With 7.72 million files, a 1200 × 800 point Retina view has fewer physical pixels than files before folder headers consume any area.
4. **Hit-grid work can concentrate.** The index caps at roughly 4096 buckets and linearly searches a bucket. Skewed sizes can place many tiny tiles in the same bucket. Large tiles are inserted into multiple buckets. This affects interaction and index size, independently of the progress UI.
5. **The bitmap cap does not bound scene memory.** The 64-megapixel cap only limits the optional bitmap. All preceding geometry still exists, and the fallback uses the large paths.

## Implementation approach

### 1. Bound concurrent builds

Use a retained worker/coordinator that cancels the old job and waits for it to exit before starting its successor; retain only the latest pending request. Propagate cancellation and check it during traversal, child arrangement, tile preparation, raster batches, and indexing. Cancellation during one large sort also needs consideration. Coalesce resize requests with a short debounce, and scale the last completed raster during live resizing.

Acceptance: rapid resize/navigation leaves at most one active scene build; superseded builds exit promptly and release their temporary storage; stale progress and scenes never publish. This preserves existing per-file behavior.

### 2. Remove redundant representations

Draw directly from tiles into a bounded bitmap, using bounded category batches if useful. Do not construct category paths speculatively for successful raster builds. Keep any fallback bounded too. Store selectable geometry once, with a compact lookup from NodeID to tile/region index. Retain only necessary folder geometry; compute byte totals from subtree aggregates.

Acceptance: same file hit results and colors at ordinary sizes, substantially lower peak RSS, no giant-path fallback if bitmap allocation fails. This can precede a change to overview semantics.

### 3. Render a screen-sized overview

Stop descending when a region cannot show useful detail at the current physical pixel scale. Render the region as a folder/aggregate; account for every descendant's bytes without generating its individual tile. Aggregate tiny siblings into a selectable "small files" region instead of dropping their area. Bound the visible-region count as well as applying a pixel threshold, since a single enormous directory still needs an efficient bounded selection/aggregation pass.

Opening a folder rebuilds its map with more detail; the outline continues to expose every file. Labels and accessibility text must explain aggregates. The existing tests asserting one tile per file must be replaced with coverage/accounting and drill-down tests, rather than silently changing their meaning.

Acceptance: fixed-size overview geometry stays within its explicit budget as scan size grows; all bytes remain represented; small files remain reachable; no false per-file hit targets for aggregates.

### Verification after changes

Run flat, nested, and strongly skewed distributions. Record current footprint plus high-water RSS, elapsed time per phase, visible versus represented file counts, and maximum simultaneous jobs. Then validate the saved Macintosh HD dataset in a release app with resize/navigation stress. Attribute the original 22 GiB incident only if a live sample/allocation trace supports it.

## Reproduction

The opt-in `optionalTreemapMemoryBenchmark` is bounded to one million generated small files, plus one large file for `clustered`. It does not scan disk or read regular-file contents.

```sh
SPACETREE_MEMORY_BENCHMARK=nested swift test -c release --filter optionalTreemapMemoryBenchmark
SPACETREE_MEMORY_BENCHMARK=clustered swift test -c release --filter optionalTreemapMemoryBenchmark
```

On this managed environment, tests used `--disable-sandbox --scratch-path /tmp/spacetree-layout-progress-build` and temporary Swift/Clang module caches because the default build/cache paths were not writable.

## Implemented results

The renderer now caps generated regions (including folders and pending work) at 16,384. A two-pass sibling traversal computes aggregate weights/counts without allocating a full child array or sorting more than the budget. Groups represent small siblings or an unexpanded directory, with a four-physical-pixel area threshold and a depth cap of 64. All represented bytes and file counts are retained. A single grouped directory opens directly; a mixed sibling group targets the containing folder and individual files remain accessible in the outline. Group menus and keyboard handling do not treat an aggregate as a mutable file selection.

`TreemapBuildCoordinator` cancels and joins superseded jobs from the same map, serializes jobs across windows, and checks cancellation throughout scene construction. Resize requests debounce for 120 ms. The previous image stays visible while preparing its replacement, with interaction disabled until current geometry is ready.

Category paths and rectangle arrays have been removed. The rasterizer fills bounded tiles directly, and NodeID lookups store indexes rather than duplicate rectangles. The bitmap cap is 16 megapixels (about 61 MiB of RGBA pixels); fallback drawing uses the same bounded tiles.

Release measurements at 1200 × 800 points, 2× scale:

| Dataset | Baseline scene time | New scene time | Baseline peak RSS | New peak RSS |
| --- | ---: | ---: | ---: | ---: |
| 1 million files, 100k equal folders | 3.44 s | 0.045 s | 659 MiB | 247 MiB |
| 1 million small files plus one dominant file | 1.61 s | 0.038 s | 662 MiB | 247 MiB |
| Saved Macintosh HD, 9.50 million nodes | Not reproduced | 0.112 s | Reported 22 GiB incident, unverified | 2416 MiB |

The equal-folder synthetic overview collapses to one aggregate; this is a deliberate loss of overview detail, with original files retained in the outline. The real Macintosh HD overview uses all 16,384 available regions and represents all 7,716,381 files. Its allocated-byte total exactly matches the saved tree. Its RSS high-water mark was already 2416 MiB after snapshot loading and did not increase during rendering. Snapshot loading/validation plus rendering took 16.25 seconds; this is distinct from the 0.112-second scene construction measurement.

47 tests passed, including byte/count preservation, grouping and folder detail, cancellation, serialized worker replacement, raster colors, hover/selection, and aggregate context menus. Tests and benchmarks ran locally; interactive app resize behavior has not been visually verified. No app was installed or launched, and changes remain uncommitted.

