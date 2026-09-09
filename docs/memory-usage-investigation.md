# Memory usage investigation — 2026-09-07

> Follow-up: the snapshot input, validation, and save-buffer fixes were implemented and measured on 2026-09-09. See [the updated profile](memory-profile-2026-09-09.md). The observations below describe the earlier code and datasets.

## Live evidence

Inspected running SpaceTree PID 34174 at approximately 15:51 EDT using `vmmap
-summary`, `heap -s`, and a three-second `sample`. The executable was launched
from `.build/x86_64-apple-macosx/debug/SpaceTree` and its sampled symbols included
the current clone-metadata code.

Physical footprint was approximately 1.5 GiB when inspected; the process's
recorded peak was 3.9 GiB. This confirms the reported spike but does not capture
the call stacks at the exact peak. Heap allocations and physical footprint are
different measures and should not be added together.

| Live allocation category | MiB allocated |
| --- | ---: |
| Three NodeRecord arrays | 746.3 |
| UInt8 arrays (principally name storage) | 277.5 |
| NodeID arrays, including hard-link members/builder bookkeeping | 58.1 |
| Two clone metadata dictionaries | 54.1 |
| FileIdentity sets | 45.7 |
| Hard-link identity-to-members dictionary | 16.0 |

The VM summary separately showed 32 MiB of CG image regions. Clone metadata and
rendering are therefore relatively small contributors in this sample. Large
reusable allocator regions also remain after temporary allocations are freed;
a high-water mark is not evidence that all peak memory is still live.

The stack sample showed two concurrent activities:

- `ScanTreeBuilder.finalize`, sorting hard-link members using `pathSortKey`.
  Each comparison constructs ancestor byte arrays and strings again.
- `SnapshotStore.save` / `encode`, sorting clone IDs for serialization of another
  completed scan while retaining that scan's tree.

`scanAll` launches available targets concurrently. Snapshot restoration and
saving use independent detached tasks without a shared memory budget. This
allows several large trees, working arrays, and serialization buffers to overlap.

## Confirmed snapshot amplification

`SnapshotStore.load` reads the entire snapshot into `Data`. In `decode`,
`BinaryReader(data: Data(payload))` makes another full-sized allocation, then
node/name/group arrays are decoded while both input buffers remain alive.
`validate()` additionally builds visited/active/sibling/group-member sets.
Saving builds a complete growable serialized `Data` alongside the live tree.

Measured in an isolated copy of the current sources, using the saved 134.1 MiB
snapshot with 1,463,920 nodes and 237,467 clone candidates. No filesystem scan
was performed. Measurements used malloc statistics and `getrusage` in a release
build; peak RSS is not identical to Activity Monitor's physical footprint.

| Stage | Baseline heap MiB | With direct payload reuse, heap MiB |
| --- | ---: | ---: |
| File read | 134.6 | 134.6 |
| Binary reader created | 268.8 | 134.6 |
| Decoded tree before validation | 421.0 | 286.8 |
| Load returned, temporary inputs released | 156.5 | 161.0 |

Load peak RSS fell from **449.9 MiB to 318.3 MiB**, approximately 29%, by changing
only `BinaryReader(data: Data(payload))` to `BinaryReader(data: payload)` in the
isolated experiment. The subsequent encode completed too; overall load-plus-save
peak fell from 505.2 MiB to 387.0 MiB. This experiment is not applied to the
working application and does not replace full compatibility tests for a fix.

The largest saved Macintosh HD snapshot is 743.7 MiB with 9,517,957 nodes.
The redundant input allocation therefore costs approximately another 743.7 MiB
when loading that snapshot. Peak reduction for a complete application session
has not been directly measured; concurrent work and page residency affect it.

## Retained tree size and allocation capacity

That saved Macintosh HD tree requires approximately 781.5 MiB for populated
node/name/hard-link array elements alone. NodeRecord is 60 serialized bytes but
has a 64-byte in-memory stride. Its node records alone require 580.9 MiB, plus
175.3 MiB of names and hard-link data.

The matching historical completed-scan statistics recorded an estimated
1,330.2 MiB of retained array capacity. The roughly 548.7 MiB difference from
populated elements reflects substantial spare capacity (plus small bookkeeping),
not additional file information. This is a previous scan's saved measurement,
not a measurement of the currently unfinished scan. The current smaller scan
similarly reported 218.9 MiB estimated retained storage; reloading its compact
snapshot measured 147.1 MiB despite containing the same nodes and clone data.

## Recommended order of work

1. Remove the confirmed full-payload copy. Preserve checksum/truncation checks.
2. Bound concurrent snapshot loads/saves and stream snapshot encoding to an
   atomic temporary file, hashing chunks rather than retaining the full output.
   Consider loading a target's full tree only when needed.
3. Reduce retained array slack and growth peaks. Reserve using previous scan
   counts where available; trim or move buffers at a controlled point, accounting
   for the temporary copy that trimming itself can require.
4. Replace validation's per-node hash-set membership with compact visitation
   state, preserving all corruption/cycle checks.
5. Reduce hard-link builder allocations and stop rebuilding complete path strings
   on every sort comparison. Release scan-only identity indexes before snapshot
   work where possible.

The strongest confirmed avoidable allocation is snapshot input duplication.
Large retained trees, spare capacity, and overlapping work explain why removing
that copy alone will not make multi-volume scans small. Nothing in this sample
establishes an unbounded leak.
