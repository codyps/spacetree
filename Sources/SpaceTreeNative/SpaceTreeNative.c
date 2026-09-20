#include "SpaceTreeNative.h"

#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>

static pthread_once_t s_dataless_policy_once = PTHREAD_ONCE_INIT;

static int s_policy_error;

static void st_init_dataless_policy(void) {
    if (setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) != 0
        || setiopolicy_np(IOPOL_TYPE_VFS_TRIGGER_RESOLVE, IOPOL_SCOPE_PROCESS, IOPOL_VFS_TRIGGER_RESOLVE_OFF) != 0) {
        s_policy_error = errno;
    }
}

int st_prepare_metadata_scan(void) {
    pthread_once(&s_dataless_policy_once, st_init_dataless_policy);
    return s_policy_error;
}

typedef struct __attribute__((packed, aligned(4))) {
    uint32_t length;
    attribute_set_t returned;
    attrreference_t name;
    dev_t device;
    fsobj_type_t object_type;
    struct timespec modified;
    uint64_t file_id;
    uint32_t link_count;
    off_t total_size;
    off_t allocated_size;
    uint64_t clone_id;
    uint64_t clone_flags;
    uint32_t clone_refcount;
} st_bulk_record_t;

static st_entry_kind_t st_kind(fsobj_type_t type) {
    switch (type) {
        case VREG: return ST_ENTRY_FILE;
        case VDIR: return ST_ENTRY_DIRECTORY;
        case VLNK: return ST_ENTRY_SYMLINK;
        default: return ST_ENTRY_OTHER;
    }
}

static int st_append(
    st_directory_entry_t **entries,
    size_t *count,
    size_t *capacity,
    const st_bulk_record_t *record,
    const char *name,
    int include_clones
) {
    if (*count == *capacity) {
        size_t new_capacity = *capacity == 0 ? 256 : *capacity * 2;
        if (new_capacity < *capacity || new_capacity > SIZE_MAX / sizeof(**entries)) return ENOMEM;
        void *new_entries = realloc(*entries, new_capacity * sizeof(**entries));
        if (new_entries == NULL) return ENOMEM;
        *entries = new_entries;
        *capacity = new_capacity;
    }

    st_directory_entry_t *entry = &(*entries)[*count];
    entry->name = strdup(name);
    if (entry->name == NULL) return ENOMEM;
    entry->device_id = (uint64_t)record->device;
    entry->file_id = record->file_id;
    entry->link_count = record->link_count;
    entry->clone_valid_attrs = include_clones ? record->returned.forkattr : 0;
    entry->clone_id = include_clones ? record->clone_id : 0;
    entry->clone_flags = include_clones ? record->clone_flags : 0;
    entry->clone_refcount = include_clones ? record->clone_refcount : 0;
    entry->logical_size = (int64_t)record->total_size;
    entry->allocated_size = (int64_t)record->allocated_size;
    entry->modified_seconds = record->modified.tv_sec;
    entry->modified_nanoseconds = record->modified.tv_nsec;
    entry->kind = st_kind(record->object_type);
    *count += 1;
    return 0;
}

static st_entry_kind_t st_kind_from_mode(mode_t mode) {
    switch (mode & S_IFMT) {
        case S_IFREG: return ST_ENTRY_FILE;
        case S_IFDIR: return ST_ENTRY_DIRECTORY;
        case S_IFLNK: return ST_ENTRY_SYMLINK;
        default: return ST_ENTRY_OTHER;
    }
}

static int st_append_stat(
    st_directory_entry_t **entries,
    size_t *count,
    size_t *capacity,
    const char *name,
    const struct stat *metadata
) {
    if (*count == *capacity) {
        size_t new_capacity = *capacity == 0 ? 256 : *capacity * 2;
        if (new_capacity < *capacity || new_capacity > SIZE_MAX / sizeof(**entries)) return ENOMEM;
        void *new_entries = realloc(*entries, new_capacity * sizeof(**entries));
        if (new_entries == NULL) return ENOMEM;
        *entries = new_entries;
        *capacity = new_capacity;
    }
    st_directory_entry_t *entry = &(*entries)[*count];
    entry->name = strdup(name);
    if (entry->name == NULL) return ENOMEM;
    entry->device_id = (uint64_t)metadata->st_dev;
    entry->file_id = (uint64_t)metadata->st_ino;
    entry->link_count = (uint32_t)metadata->st_nlink;
    entry->clone_valid_attrs = 0;
    entry->clone_id = entry->clone_flags = 0;
    entry->clone_refcount = 0;
    entry->logical_size = (int64_t)metadata->st_size;
    entry->allocated_size = (int64_t)metadata->st_blocks * 512;
    entry->modified_seconds = metadata->st_mtimespec.tv_sec;
    entry->modified_nanoseconds = metadata->st_mtimespec.tv_nsec;
    entry->kind = st_kind_from_mode(metadata->st_mode);
    *count += 1;
    return 0;
}

static int st_list_directory_fallback(
    int descriptor,
    st_directory_entry_t **entries,
    size_t *count,
    size_t *capacity
) {
    int duplicate = dup(descriptor);
    if (duplicate < 0) return errno;
    DIR *directory = fdopendir(duplicate);
    if (directory == NULL) {
        int error = errno;
        close(duplicate);
        return error;
    }

    int error = 0;
    errno = 0;
    for (struct dirent *item = readdir(directory); item != NULL; item = readdir(directory)) {
        if (strcmp(item->d_name, ".") == 0 || strcmp(item->d_name, "..") == 0) continue;
        struct stat metadata;
        if (fstatat(descriptor, item->d_name, &metadata, AT_SYMLINK_NOFOLLOW) != 0) {
            error = errno;
            break;
        }
        error = st_append_stat(entries, count, capacity, item->d_name, &metadata);
        if (error != 0) break;
        errno = 0;
    }
    if (error == 0 && errno != 0) error = errno;
    closedir(directory);
    return error;
}

static int st_list_directory_impl(
    const char *path,
    st_directory_entry_t **entries,
    size_t *entry_count,
    st_directory_diagnostics_t *diagnostics
) {
    if (path == NULL || entries == NULL || entry_count == NULL) return EINVAL;
    *entries = NULL;
    *entry_count = 0;

    int descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (descriptor < 0) return errno;
    struct stat directory_metadata;
    if (fstat(descriptor, &directory_metadata) != 0 || !S_ISDIR(directory_metadata.st_mode)) {
        int error = errno == 0 ? ENOTDIR : errno;
        close(descriptor);
        return error;
    }

    struct attrlist attributes;
    memset(&attributes, 0, sizeof(attributes));
    attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.commonattr = ATTR_CMN_RETURNED_ATTRS
        | ATTR_CMN_NAME
        | ATTR_CMN_DEVID
        | ATTR_CMN_OBJTYPE
        | ATTR_CMN_MODTIME
        | ATTR_CMN_FILEID;
    attributes.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;

    attributes.forkattr = ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS | ATTR_CMNEXT_CLONE_REFCNT;
    int include_clones = 1;

    const size_t buffer_size = 256 * 1024;
    void *buffer = malloc(buffer_size);
    if (buffer == NULL) {
        close(descriptor);
        return ENOMEM;
    }

    st_directory_entry_t *result = NULL;
    size_t count = 0;
    size_t capacity = 0;
    int error = 0;
    for (;;) {
        diagnostics->bulk_calls++;
        int batch_count = getattrlistbulk(
            descriptor,
            &attributes,
            buffer,
            buffer_size,
            // Match lstat/fstatat's unified device IDs on the startup volume.
            FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS
                | (include_clones ? FSOPT_ATTR_CMN_EXTENDED : 0)
        );
        if (batch_count == 0) break;
        if (batch_count < 0) {
            error = errno;
            diagnostics->bulk_error = error;
            // Unsupported extended attributes must not disable the ordinary bulk path.
            if (include_clones && (error == EINVAL || error == ENOTSUP || error == E2BIG)) {
                st_free_directory_entries(result, count);
                result = NULL; count = 0; capacity = 0;
                if (lseek(descriptor, 0, SEEK_SET) < 0) break;
                include_clones = 0;
                attributes.forkattr = 0;
                diagnostics->clone_query_retries++;
                error = 0;
                continue;
            }
            break;
        }
        diagnostics->bulk_entries += batch_count;

        char *cursor = buffer;
        for (int index = 0; index < batch_count; index++) {
            size_t remaining = (char *)buffer + buffer_size - cursor;
            const size_t common_size = offsetof(st_bulk_record_t, link_count);
            const size_t file_size = offsetof(st_bulk_record_t, clone_id) - common_size;
            const size_t clone_size = sizeof(st_bulk_record_t) - offsetof(st_bulk_record_t, clone_id);
            st_bulk_record_t record = {0};
            if (remaining < common_size) { error = EIO; break; }
            memcpy(&record, cursor, common_size);
            if (!(record.returned.commonattr & ATTR_CMN_OBJTYPE)) { error = EIO; break; }
            // PACK_INVAL_ATTRS packs unsupported fields, but file attributes are
            // omitted entirely for directories. Extended common fields follow
            // whichever file fields were actually requested for this vnode type.
            size_t fixed_size = common_size + (record.object_type == VDIR ? 0 : file_size)
                + (include_clones ? clone_size : 0);
            if (remaining < fixed_size || record.length < fixed_size) { error = EIO; break; }
            size_t offset = common_size;
            if (record.object_type != VDIR) {
                memcpy((char *)&record + common_size, cursor + offset, file_size);
                offset += file_size;
            }
            if (include_clones) memcpy(&record.clone_id, cursor + offset, clone_size);
            int64_t name_offset = (int64_t)offsetof(st_bulk_record_t, name) + record.name.attr_dataoffset;
            if (record.length < fixed_size || record.length > remaining
                || !(record.returned.commonattr & ATTR_CMN_NAME)
                || name_offset < (int64_t)fixed_size || name_offset >= record.length
                || record.name.attr_length == 0
                || record.name.attr_length > record.length - name_offset
                || memchr(cursor + name_offset, 0, record.name.attr_length) == NULL) {
                error = EIO;
                break;
            }
            // Bulk enumeration can describe the covered directory rather than
            // the mounted filesystem or firmlink reached through this name.
            // Resolve directory identities before Swift filters devices and
            // deduplicates traversal, without following symbolic links.
            struct stat child_metadata;
            if (record.object_type == VDIR
                && fstatat(descriptor, cursor + name_offset, &child_metadata, AT_SYMLINK_NOFOLLOW) == 0) {
                error = st_append_stat(&result, &count, &capacity, cursor + name_offset, &child_metadata);
            } else {
                error = st_append(&result, &count, &capacity, &record, cursor + name_offset, include_clones);
            }
            if (error != 0) break;
            cursor += record.length;
        }
        if (error != 0) break;
    }

    free(buffer);
    if (error != 0 && error != EDEADLK) {
        diagnostics->fallback_directories++;
        diagnostics->bulk_error = error;
        st_free_directory_entries(result, count);
        result = NULL;
        count = 0;
        capacity = 0;
        if (lseek(descriptor, 0, SEEK_SET) < 0) error = errno;
        else error = st_list_directory_fallback(descriptor, &result, &count, &capacity);
    }
    close(descriptor);
    if (error != 0) {
        st_free_directory_entries(result, count);
        return error;
    }
    *entries = result;
    *entry_count = count;
    return 0;
}

void st_free_directory_entries(st_directory_entry_t *entries, size_t entry_count) {
    if (entries == NULL) return;
    for (size_t index = 0; index < entry_count; index++) free(entries[index].name);
    free(entries);
}

// Keep the thread override inside synchronous C: Swift tasks can change threads
// at suspension points. A process policy alone can be overridden by a thread.
int st_list_directory_with_diagnostics(const char *path, st_directory_entry_t **entries, size_t *entry_count,
                                       st_directory_diagnostics_t *diagnostics) {
    st_directory_diagnostics_t unused = {0};
    if (diagnostics == NULL) diagnostics = &unused;
    memset(diagnostics, 0, sizeof(*diagnostics));
    if (path == NULL || entries == NULL || entry_count == NULL) return EINVAL;
    *entries = NULL;
    *entry_count = 0;
    int error = st_prepare_metadata_scan();
    if (error != 0) return error;
    int previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD);
    if (previous < 0) return errno;
    if (setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) != 0) return errno;
    error = st_list_directory_impl(path, entries, entry_count, diagnostics);
    int restore = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous);
    if (restore != 0 && error == 0) {
        error = errno;
        st_free_directory_entries(*entries, *entry_count);
        *entries = NULL;
        *entry_count = 0;
    }
    return error;
}

int st_list_directory(const char *path, st_directory_entry_t **entries, size_t *entry_count) {
    return st_list_directory_with_diagnostics(path, entries, entry_count, NULL);
}
