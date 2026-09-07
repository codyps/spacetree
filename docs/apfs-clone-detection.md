# APFS clone detection

Findings on detecting APFS cloned files during scans so their blocks are not
counted once per clone. Verified empirically on macOS 26 (Darwin 25.6.0)
against the system APFS data volume and a freshly created APFS volume image.

## Problem

APFS clones (from `clonefile(2)`, `cp -c`, or Finder duplication) are separate
inodes that share physical extents copy-on-write. Every clone reports full
`st_blocks`/allocated size through `stat`, so summing per-file sizes counts
shared blocks once per clone. Clones have `st_nlink == 1` and distinct file
IDs, so the existing hard-link dedup (`FileIdentity` from `link_count > 1` in
`DiskScanner.bulkEntries`, grouped in `ScanTreeBuilder.finalize()`) cannot see
them. Hard links to a cloned file share its clone family; the two dedups
compose.

## Detection API

`getattrlist` extended attributes, requested through the `forkattr` bitmap
with the `FSOPT_ATTR_CMN_EXTENDED` (0x20) option flag:

- `ATTR_CMNEXT_CLONEID` (0x100) — `u_int64_t` identifying the file's data
  stream. Pure clones of one another share the same ID. This is the grouping
  key.
- `ATTR_CMNEXT_EXT_FLAGS` (0x200) — `u_int32_t` of sharing flags. Names are
  documented in `getattrlist(2)` but the constants are not in the public
  header; measured values: `EF_MAY_SHARE_BLOCKS = 0x1`,
  `EF_SHARES_ALL_BLOCKS = 0x40` (which implies `EF_MAY_SHARE_BLOCKS`).
- `ATTR_CMNEXT_CLONE_REFCNT` (0x1000) — `u_int32_t`, number of full clones
  sharing this file's blocks (volume-wide, not scan-wide).
- `ATTR_CMNEXT_LINKID` (0x10) — hard-link identity; a modern replacement for
  `ATTR_FILE_LINKCOUNT` in bulk scans (see side finding below).

Without `FSOPT_ATTR_CMN_EXTENDED` the kernel rejects these bits with `EINVAL`.
`getattrlistbulk` accepts the same attributes under the same flag, so clone
data can stay in bulk-scan form.

## Verified semantics

Fixture: 4 MiB random `orig`; `clone1`, `clone2` via `cp -c`; `clone_of_clone`
cloned from `clone1`; `diverged` cloned then appended 1 MiB; `normalcopy` via
plain `cp`; `hardlink` via `ln`.

| file                | clone ID   | ext flags | refcnt | extent reality (`F_LOG2PHYS_EXT`)        |
| ------------------- | ---------- | --------- | ------ | ---------------------------------------- |
| orig                | family ID  | 0x41      | 4      | shared with all clones                   |
| clone1 / clone2     | family ID  | 0x41      | 4      | identical extent map to orig             |
| clone_of_clone      | family ID  | 0x41      | 4      | identical extent map to orig             |
| hardlink            | family ID  | 0x41      | 4      | same inode as orig                       |
| diverged            | own ID     | 0x1       | 1      | shared 4 MiB prefix + unique tail extents |
| normalcopy          | unique     | 0x0       | 0      | physically distinct                      |

Consequences:

- Grouping by clone ID finds exactly the *pure* clone families. A partially
  diverged clone gets its own ID and `EF_MAY_SHARE_BLOCKS` only; it is
  excluded from the family, so counting it normally overstates usage by its
  shared prefix but never understates. Exact partial accounting would require
  per-file extent walks via `fcntl(F_LOG2PHYS_EXT)` (verified working on
  APFS: contig device-offset runs are returned, and clones show identical
  maps). That is a possible later refinement, not needed for parity with the
  hard-link behavior.
- `CLONE_REFCNT` counts volume-wide peers, including clones outside the scan
  scope. It must not drive zeroing; it is only a UI hint ("N other clones on
  this volume").

## Volume support varies

Clone tracking is a per-volume on-disk feature (`VOL_CAP_FMT_CLONE_MAPPING`).
The system data volume reports clone IDs as described above. A freshly created
`hdiutil` APFS volume image returned no sharing information at all: every file
got a distinct sentinel-looking ID and `refcnt=0`. Non-APFS filesystems will
not implement the attributes.

Gate at scan start: issue one `getattrlist` on a probe file with
`FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED` and
`ATTR_CMN_RETURNED_ATTRS`, then check whether the `CLONEID` bit is present in
`returned.forkattr`. Unsupported volumes pack 0; skip clone grouping there.

## Integration plan

The extended flag reinterprets the entire `forkattr` bitmap as `ATTR_CMNEXT_*`
bits, and several `ATTR_FILE_*` bits alias `ATTR_CMNEXT_*` bits, so file sizes
cannot ride in the same call:

| forkattr bit | as ATTR_FILE_*        | as ATTR_CMNEXT_*   |
| ------------ | --------------------- | ------------------ |
| 0x004        | `ATTR_FILE_ALLOCSIZE` | `RELPATH`          |
| 0x100        | `ATTR_FILE_FORKLIST`  | `CLONEID`          |
| 0x200        | `ATTR_FILE_DATALENGTH`| `EXT_FLAGS`        |

Therefore `SpaceTreeNative.c` should enumerate each directory twice:

1. Size pass (existing call, with replacements from the side finding):
   `ATTR_CMN_RETURNED_ATTRS | NAME | DEVID | OBJTYPE | MODTIME | FILEID` plus
   `ATTR_FILE_DATALENGTH | ATTR_FILE_ALLOCSIZE`.
2. Identity pass: same common attributes, `forkattr =
   LINKID | CLONEID | EXT_FLAGS | CLONE_REFCNT`, options including
   `FSOPT_ATTR_CMN_EXTENDED`. Match records between passes by `ATTR_CMN_FILEID`.

`st_directory_entry_t` grows `clone_id`, `ext_flags`, and `clone_refcnt`
fields. On the Swift side, thread a clone identity
(`(realDevice, cloneID)`, skipping zero IDs) through `EntryMetadata`, and in
`ScanTreeBuilder.finalize()` run it as a second grouping dimension alongside
`FileIdentity`:

- Reuse the canonical-member and `.duplicateReference` machinery; a clone
  group marks all members after the path-ordered canonical one as duplicates.
- Only group when at least two members are visible in the scan, mirroring the
  hard-link scope rule (peers outside the scan root still occupy their own
  subtrees).
- `DiskScanner.refresh()` must fall back to a full rescan when the existing
  tree contains clone groups, exactly as it does for
  `hardLinkReferenceCount` today, because partial subtree scans cannot see
  cross-tree sharing.
- The `readdir`+`fstatat` fallback path has no clone data. It can obtain the
  same fields per file via `fgetattrlist` on the descriptor `fstatat` already
  used, or simply run without clone dedup.

Record layout notes for parsing: `attribute_set_t` is five `u_int32_t` values
(commonattr, volattr, dirattr, fileattr, forkattr — 20 bytes) after the
leading record length; returned fields are packed in attribute-list order with
4-byte alignment (`u_int64_t` fields are only 4-byte aligned, and padding
appears after 8-byte fields in single `getattrlist` records).

## Side finding: the bulk fast path is dead on this OS

On this macOS build, `getattrlistbulk` fails with `E2BIG` whenever
`ATTR_FILE_LINKCOUNT` or `ATTR_FILE_TOTALSIZE` is requested — for any buffer
size from 16 KiB to 512 KiB, with or without `FSOPT_PACK_INVAL_ATTRS` /
`FSOPT_RETURN_REALDEV`, on plain directories with no mount points and with
the dataless-materialization policy set. That is exactly the attribute set
`st_list_directory_impl` requests, so the C layer falls into the
`readdir`+`fstatat` fallback for every directory on every scan. Results stay
correct, which is why this went unnoticed, but the scan pays per-entry
`fstatat` costs throughout.

The fix falls out of the clone work: replace `ATTR_FILE_LINKCOUNT` with
`ATTR_CMNEXT_LINKID` from the identity pass, and `ATTR_FILE_TOTALSIZE` with
`ATTR_FILE_DATALENGTH` (verified working in bulk). `ATTR_FILE_ALLOCSIZE`
already works in bulk and can stay in the size pass.

## References

- `getattrlist(2)` man page (ATTR_CMNEXT_CLONEID / EXT_FLAGS / CLONE_REFCNT,
  FSOPT_ATTR_CMN_EXTENDED, VOL_CAP_FMT_CLONE_MAPPING)
- `xnu` `bsd/sys/attr.h` (attribute bit values, capability bits)
- `fcntl(F_LOG2PHYS_EXT)` for physical extent maps
