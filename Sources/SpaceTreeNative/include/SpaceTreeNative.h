#ifndef SPACETREE_NATIVE_H
#define SPACETREE_NATIVE_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    ST_ENTRY_OTHER = 0,
    ST_ENTRY_FILE = 1,
    ST_ENTRY_DIRECTORY = 2,
    ST_ENTRY_SYMLINK = 3
} st_entry_kind_t;

typedef struct {
    char *name;
    uint64_t device_id;
    uint64_t file_id;
    uint32_t link_count;
    uint64_t clone_id;
    uint64_t clone_flags;
    uint32_t clone_refcount;
    uint32_t clone_valid_attrs; // Returned ATTR_CMNEXT_* bits; zero means unknown.
    int64_t logical_size;
    int64_t allocated_size;
    int64_t modified_seconds;
    int64_t modified_nanoseconds;
    st_entry_kind_t kind;
} st_directory_entry_t;

typedef struct {
    uint64_t bulk_calls;
    uint64_t bulk_entries; // Entries returned by syscalls, including discarded/retried batches.
    uint64_t fallback_directories;
    uint64_t clone_query_retries;
    int bulk_error; // Original error, retained even when fallback succeeds.
} st_directory_diagnostics_t;

int st_list_directory_with_diagnostics(const char *path,
    st_directory_entry_t **entries, size_t *entry_count,
    st_directory_diagnostics_t *diagnostics);

// Enables process scan protections; returns errno on failure.
int st_prepare_metadata_scan(void);

// Returns 0 on success and an errno value on failure.
int st_list_directory(
    const char *path,
    st_directory_entry_t **entries,
    size_t *entry_count
);

void st_free_directory_entries(st_directory_entry_t *entries, size_t entry_count);

#endif
