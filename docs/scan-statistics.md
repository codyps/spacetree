# Scan statistics

Each full scan or incremental refresh records a versioned `ScanStatistics` value.
`ScanTarget.scanStatistics` exposes the latest run. Completed snapshots retain
that value; old version 2 snapshots still load with no statistics.

When result persistence is enabled (the default), completed, failed, cancelled,
and superseded runs each produce a separate JSON file in
`~/Library/Application Support/SpaceTree/ScanHistory/<run UUID>.json`.
History is retained across rescans. Files can be copied for analysis now, and
`ScanStatistics.jsonData()` supports a future export action. Paths are included.
Save failures are exposed through `ScanTarget.statisticsSaveError`.

Measurements include monotonic wall time per phase, start/end timestamps,
full/incremental mode, outcome/error, enumerated directory and entry counts,
accumulated directory worker time, the 20 slowest directory reads, final item and
allocated-byte totals, unreadable and duplicate counts, estimated retained tree
storage, worker concurrency, build configuration, and OS version.

Phase durations cover scan preparation, enumeration, hard links, aggregate
preparation, directory totals, sorting, and publishing the result. Incremental
refreshes can repeat phases as subtrees are scanned, and record rebuilding.
A fallback full scan is reflected in the phase sequence and work counts.
Worker durations overlap and must not be interpreted as wall-clock durations.
They include native directory enumeration and metadata conversion, excluding
limiter wait time. Entry counts measure work and can include repeated reads in
an incremental run; completed item totals describe the resulting tree.

Cancelled/failed totals are partial. Cancellation closes the record immediately;
work still winding down cannot mutate it. Snapshot serialization, disk cache
writes, and treemap rendering occur outside the measured scan. Estimated tree
storage is not process RSS. No per-file trace or unbounded progress log is kept.
