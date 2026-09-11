# Time Machine change explorer

A read-only analyzer for mounted APFS Time Machine backup snapshots. It produces a
self-contained, offline HTML report with a backup timeline, file/subtree rankings,
folder drill-down, path search, and change frequency across inspected intervals.
Python 3.9+ and macOS's `tmutil` are required. No Python packages, server, or network
requests are needed. This is a standalone companion to SpaceTree.

```sh
# Expose completed snapshots if they are not already mounted.
tmutil listbackups -d "/Volumes/T7 Shield" -m

# Compare the latest three mounted intervals.
python3 scripts/time-machine/analyze.py "/Volumes/T7 Shield" \
  --output backup-reports/t7
open backup-reports/t7/index.html
```

If macOS denies access, run from a terminal with Full Disk Access. `tmutil` may also
require administrator privileges to list/mount snapshots. The analyzer itself
never requests elevated privileges, mounts volumes, or changes backup settings.

Use `--last 0` for a quick manifest-only timeline, or `--last 10` for more history.
Select specific intervals with repeatable pairs:

```sh
python3 scripts/time-machine/analyze.py "/Volumes/T7 Shield" \
  --output backup-reports/t7 \
  --pair 2026-09-07-161633 2026-09-08-185544 \
  --pair 2026-09-10-183137 2026-09-10-203327
```

Comparison progress prints every 15 seconds. Large backups with millions of files
can take many minutes per interval. Ctrl-C terminates the active comparison and
retains finished results. Repeating the command reuses complete cached comparisons.
An HTML report is written before scanning and updated after each interval; reload
it to see progress. Each invocation reports its selected intervals, while raw
comparisons from previous invocations remain in the cache.

`report.json` contains the report data. `cache/` retains the raw XML plist,
command, stderr, and duration for each completed comparison. Generated reports
contain private filenames and stay under the git-ignored `backup-reports/` directory
by default. No file contents are embedded in reports.

## What the numbers mean

- **History bars** use `stats.changed.logicalSize` from the destination's
  `backup_manifest.plist`. Physical size and item count are also shown exactly as
  recorded. This observed manifest schema is validated; it is not a public Apple API.
  Manifest dates are UTC and are converted to the machine's local timezone.
- **Affected size** sums full newer sizes of added/modified files and subtree
  records from `tmutil compare -s -t -E -X`. A 500 MB database modified without
  growing contributes 500 MB to this ranking. It does not imply 500 MB of new
  uniquely allocated APFS blocks. No content hashing, xattr or ACL comparison occurs.
- **Removed size** is separate. Deletion from a later snapshot does not imply that
  historical storage has been reclaimed.
- **Subtree** labels identify added/removed directory summaries emitted by tmutil.
  Descendants are not separately enumerated, so records are not file counts. Folder
  metadata-only changes have no payload and are omitted from the rankings.
- **Intervals** counts distinct selected comparison pairs in which the path or
  folder changed. It is not a count across uninspected backups. Folder depth includes
  the backup volume name as the first component. Click a folder to drill deeper.

Only read-only snapshot mounts on the destination's exact device are discovered.
The live `.previous` and `.inprogress` trees are excluded. Missing snapshots can
make a comparison span multiple backup runs, so comparison totals and individual
manifest entries need not match. Mount discovery expects standard macOS mount output;
legacy HFS+ and network sparsebundle discovery are outside this tool's scope.

Errors and `tmutil` stderr appear in the report's coverage section. A failed interval
is never shown as a successful empty comparison. The tool does not prove that a
successful `tmutil` scan accessed every protected file. Symlink metadata is inspected
with `lstat`; targets are not resolved by the report parser.

```sh
python3 -m unittest discover -s scripts/time-machine -p 'test_*.py'
```
