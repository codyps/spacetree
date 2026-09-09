# APFS clone detection during scans

Verified 2026-09-07 on macOS 26 / Darwin 25.6.0, using generated fixtures on
both the system Data volume (`/tmp`) and the APFS volume containing this repo.
The scanner now collects clone candidates in its bulk read, stores them in a
sparse per-tree side table, and displays sharing annotations. Allocated totals
are unchanged; no physical extent walk is performed. Snapshot version 4 persists
the side table and still loads versions 2 and 3 (with unknown clone state).

## What we can detect cheaply

APFS clones have separate inodes but initially share file data copy-on-write.
The scanner previously recorded device/inode identities for hard links and used
allocated sizes for ordinary files. Those fields alone cannot identify clones: each clone
can report the full allocated size despite sharing storage.

Request these attributes in the existing `getattrlistbulk` call:

| Attribute | Wire type | Purpose |
| --- | --- | --- |
| `ATTR_CMNEXT_CLONEID` | `uint64_t` | Identify a data stream shared by full clones |
| `ATTR_CMNEXT_EXT_FLAGS` | `uint64_t` | Distinguish possible sharing from sharing all blocks |
| `ATTR_CMNEXT_CLONE_REFCNT` | `uint32_t` | Full-clone reference count, across the volume |

Set `forkattr` to those bits and add `FSOPT_ATTR_CMN_EXTENDED`. Existing
`commonattr` and `fileattr` requests remain in place. File attributes and
extended common attributes occupy **separate bitmaps**; there is no need for
a second directory enumeration. A live query using the scanner's exact common
and file attribute masks, its existing options, and these additions returned
all five fixture entries successfully, with metadata scan protection enabled.

Apple documents `EF_MAY_SHARE_BLOCKS` and `EF_SHARES_ALL_BLOCKS` in
`getattrlist(2)`. The latter implies the former. Observed values were `0x1`
and `0x40`; these flag constants were not found in the public SDK headers
examined. Treat those numeric encodings as an explicitly documented
compatibility assumption if used, rather than public header definitions.

Check `VOL_CAP_FMT_CLONE_MAPPING` in the volume's valid format capabilities;
it describes clone tracking, unlike `VOL_CAP_INT_CLONE`, which describes
support for creating clones. Also check each record's returned-attribute
bitmap. Unsupported or unavailable metadata must mean **unknown**, not
“unshared”; packed zeroes alone do not establish support. Support and behavior
on other APFS volumes/OS versions still require validation.

## Live results

The probe created a 4 MiB random file, two `clonefile` copies, a hard link,
and an independent copy written using `write` (avoiding a copy utility that
might clone automatically). One clone had 1 MiB appended. All test files
were removed after the probe; no existing user files were inspected or changed.

| Entry | Inode | Clone ID | Flags | Refcount | Allocated size |
| --- | --- | --- | --- | --- | --- |
| Original | A | X | `0x41` | 2 | 4 MiB |
| Full clone | B | X | `0x41` | 2 | 4 MiB |
| Hard link to original | A | X | `0x41` | 2 | 4 MiB |
| Modified clone | C | Y | `0x1` | 1 | 5 MiB |
| Independent copy | D | Z | `0x0` | 1 | 4 MiB |

The first physical extent, queried using `F_LOG2PHYS_EXT`, was identical for
original, full clone, hard link, and modified clone; the independent copy had
a different physical address. This verifies partial sharing after divergence,
but the probe did not walk every extent or measure snapshot-held storage.

The implications are:

- A full-clone family is discoverable without opening or reading every file.
  Group within the same filesystem, using clone ID and returned metadata.
- A modified clone can receive a new clone ID while retaining shared extents.
  Clone-ID grouping alone therefore cannot detect all shared-byte overlap.
- Hard links do not add full-clone references in this fixture. Deduplicate
  inode identities before counting distinct clone members.
- Refcount includes the current data stream in this fixture and can include
  members outside the scan root. Do not display it as “N other clones” or use
  it to divide a file's allocated size.
- These attributes describe current sharing, not historical copy provenance.
  They cannot say which pathname was the source of a clone operation.

## Implemented integration

The following design is implemented for candidate annotations, snapshot storage,
and on-demand discovery of full-clone peers. Capability probing remains a future
optimization; detection currently requires returned clone ID/flags and positive
sharing flags. Unsupported extended queries retry ordinary bulk enumeration,
then fall back to metadata stat calls if necessary. No annotation means unknown
or no reported sharing, not a guarantee of exclusive storage.

## Design considerations

1. Extend `st_directory_entry_t` and the bulk parser with clone ID, 64-bit
   flags, refcount, and explicit validity information. Attribute records use
   four-byte packing; use checked offsets/`memcpy`, not native struct alignment.
2. Keep the existing metadata-only/no-follow/no-materialization scan policies.
   If clone attributes are unsupported, retain ordinary scanning. The
   `readdir`/`fstatat` fallback has no open per-file descriptor to reuse for
   `fgetattrlist`; initially report clone state as unknown there.
3. Preserve relevant metadata compactly, preferably in a side table for
   sharing candidates, and group by filesystem/device identity plus clone ID.
   Keep hard-link identity and clone identity separate. Account for additional
   retained memory before adding fields to every node in a multi-million-file
   scan. Persisted clone data would require snapshot-format handling too.
4. First expose “full clone” and “may share blocks” annotations plus navigation
   to other observed members. Keep per-file allocated sizes visible. A later
   distinct-data estimate can count full-clone data once, but must distinguish
   this from per-directory allocation and bytes reclaimable by deletion.
5. Reconcile sharing groups across the complete scan generation when refreshing
   subtrees: a group's other members may live outside the refreshed directory.

Blindly reusing the hard-link duplicate flag and zeroing clone sizes would
obscure partial sharing and imply more certainty about reclaimable bytes than
these metadata provide. Clones, hard links, and snapshots can retain data after
a pathname is deleted. Stream-level clone identity also should not be treated
as proof of identical ownership of all ancillary file metadata/resource forks.

## Exact partial sharing is a separate, more expensive feature

`fcntl(F_LOG2PHYS_EXT)` maps a requested file offset to a physical offset and
contiguous run length. Walking and intersecting physical ranges can identify
shared extents among inspected files. The first-run probe worked without root
on both tested volumes, but a complete implementation must handle sparse or
unmapped ranges, short runs, compressed/dataless files, filesystem/device scope,
and files changing during inspection. It does not supply snapshot reference
counts or guarantee space recovered by deleting a selected set of files.

This requires per-file opens and potentially many extent queries. Offer it as
an explicit deeper analysis of selected sharing candidates, after benchmarking,
rather than adding it to every file in the default scan. Content hashing is
unnecessary for detecting physical sharing and would defeat metadata-only scans.

## Corrections to the previous note

The previous version incorrectly described extended flags as 32-bit, required
two directory passes because of overlapping bit values, and reported a normal
copy's refcount as zero. Current Apple source and correctly sized live parsing
support the types and single-pass query above; the ordinary copy returned one.

The previous claim that `ATTR_FILE_LINKCOUNT`/`ATTR_FILE_TOTALSIZE` always make
the bulk fast path fail with `E2BIG` was not reproduced. Both attributes,
the scanner's combined file mask `0x7`, and that mask plus clone metadata
succeeded. No replacement of the existing size/link-count attributes is
justified by the current evidence. Earlier disk-image results have not been
revalidated and should not be used to infer support on other volumes.

## Bulk-path regression found during implementation

A successful `getattrlistbulk` syscall did not prove that SpaceTree consumed its
records. The previous parser assumed file attributes were present in directory
records too. Even with `FSOPT_PACK_INVAL_ATTRS`, directories omit those fields.
A short directory record therefore failed the fixed-size check with `EIO`,
causing the entire directory to be enumerated again with `readdir`/`fstatat`.

An instrumented build of commit `00c82cf` reproduced this fallback in all six
checked directories: `/`, `/Applications`, `/System/Library`, the user home,
the repo root, and `/Volumes/dev/p`. With the corrected variable-layout parser,
all six used bulk enumeration with zero fallback/retry/error counters.

`ScanStatistics.filesystemReads` now records bulk calls, entries returned by
bulk syscalls (including discarded/retried batches), fallback directories,
extended-query retries, and bulk errors. This makes future fallback behavior
observable in the saved scan statistics rather than inferred from scan success.

Validation includes live clone/modified-clone/hard-link fixtures, directory and
symlink records, 2,500 long-name entries spanning multiple batches, snapshot
round trips, and a standalone native fault-injection test. Run that test with:

```sh
xcrun clang -Wall -Wextra -Werror -I Sources/SpaceTreeNative/include Tests/Native/BulkFallbackTests.c -o /tmp/spacetree-bulk-tests
/tmp/spacetree-bulk-tests
```

A release scan of `/Volumes/dev/p` found 447,189 nodes and 8,140 clone
candidates in 2.456 seconds. It issued 94,511 bulk calls returning 447,188
entries, with zero fallback directories, clone-query retries, or bulk errors.
This is a host/dataset-specific observation, not a cold-cache benchmark or a
measurement of the complete Macintosh HD scan.

## Primary references

- [Apple getattrlist manual](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/man/man2/getattrlist.2): attribute types, sharing semantics, capabilities.
- [Apple attribute definitions](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/sys/attr.h): separate bitmaps, attribute and capability values.
- [Apple attribute packing implementation](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/vfs/vfs_attrlist.c): 64-bit clone ID and extended flags; 32-bit clone refcount.
- [Apple fcntl manual](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/man/man2/fcntl.2): `F_LOG2PHYS_EXT` inputs and outputs.

Local verification also used the installed Xcode macOS SDK's `sys/attr.h` and
`usr/share/man/man2/{getattrlist,fcntl}.2`. Upstream `main` links may change.
