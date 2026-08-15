#include "SpaceTreeNative.h"

#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>

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
    const st_bulk_record_t *record
) {
    if (*count == *capacity) {
        size_t new_capacity = *capacity == 0 ? 256 : *capacity * 2;
        void *new_entries = realloc(*entries, new_capacity * sizeof(**entries));
        if (new_entries == NULL) return ENOMEM;
        *entries = new_entries;
        *capacity = new_capacity;
    }

    const char *name = ((const char *)&record->name) + record->name.attr_dataoffset;
    st_directory_entry_t *entry = &(*entries)[*count];
    entry->name = strdup(name);
    if (entry->name == NULL) return ENOMEM;
    entry->device_id = (uint64_t)record->device;
    entry->file_id = record->file_id;
    entry->link_count = record->link_count;
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
        if (fstatat(descriptor, item->d_name, &metadata, AT_SYMLINK_NOFOLLOW) != 0) continue;
        error = st_append_stat(entries, count, capacity, item->d_name, &metadata);
        if (error != 0) break;
        errno = 0;
    }
    if (error == 0 && errno != 0) error = errno;
    closedir(directory);
    return error;
}

int st_list_directory(
    const char *path,
    st_directory_entry_t **entries,
    size_t *entry_count
) {
    if (path == NULL || entries == NULL || entry_count == NULL) return EINVAL;
    *entries = NULL;
    *entry_count = 0;

    int descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
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
        int batch_count = getattrlistbulk(
            descriptor,
            &attributes,
            buffer,
            buffer_size,
            FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS | FSOPT_RETURN_REALDEV
        );
        if (batch_count == 0) break;
        if (batch_count < 0) {
            error = errno;
            break;
        }

        char *cursor = buffer;
        for (int index = 0; index < batch_count; index++) {
            st_bulk_record_t *record = (st_bulk_record_t *)cursor;
            if (record->length < sizeof(st_bulk_record_t)
                || cursor + record->length > (char *)buffer + buffer_size) {
                error = EIO;
                break;
            }
            error = st_append(&result, &count, &capacity, record);
            if (error != 0) break;
            cursor += record->length;
        }
        if (error != 0) break;
    }

    free(buffer);
    if (error != 0) {
        st_free_directory_entries(result, count);
        result = NULL;
        count = 0;
        capacity = 0;
        (void)lseek(descriptor, 0, SEEK_SET);
        error = st_list_directory_fallback(descriptor, &result, &count, &capacity);
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
