// Run from the repository root:
// xcrun clang -Wall -Wextra -Werror -I Sources/SpaceTreeNative/include \
//   Tests/Native/BulkFallbackTests.c -o /tmp/spacetree-bulk-tests && /tmp/spacetree-bulk-tests
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <unistd.h>

static int mode;
static int calls;
static int injected_bulk(int fd, struct attrlist *attrs, void *buffer, size_t size, uint64_t options) {
    calls++;
    if (mode == 1 && calls == 1) { errno = ENOTSUP; return -1; }
    if (mode == 2) { errno = ENOTSUP; return -1; }
    int count = getattrlistbulk(fd, attrs, buffer, size, options);
    if (mode == 3 && count > 0) {
        uint32_t malformed_length = 2;
        memcpy(buffer, &malformed_length, sizeof(malformed_length));
    }
    return count;
}

// Fault injection is restricted to this standalone test translation unit.
#define getattrlistbulk injected_bulk
#include "../../Sources/SpaceTreeNative/SpaceTreeNative.c"
#undef getattrlistbulk

int main(void) {
    char directory[] = "/tmp/spacetree-bulk-XXXXXX";
    assert(mkdtemp(directory) != NULL);
    char file[1024], child[1024];
    snprintf(file, sizeof(file), "%s/file", directory);
    snprintf(child, sizeof(child), "%s/d", directory);
    int fd = open(file, O_CREAT | O_EXCL | O_WRONLY, 0600);
    assert(fd >= 0);
    assert(write(fd, "test", 4) == 4);
    assert(close(fd) == 0);
    assert(mkdir(child, 0700) == 0);

    for (mode = 0; mode <= 3; mode++) {
        calls = 0;
        st_directory_entry_t *entries = NULL;
        size_t count = 0;
        st_directory_diagnostics_t diagnostics;
        assert(st_list_directory_with_diagnostics(directory, &entries, &count, &diagnostics) == 0);
        assert(count == 2);
        assert(diagnostics.fallback_directories == (mode >= 2 ? 1 : 0));
        assert(diagnostics.clone_query_retries == (mode == 1 || mode == 2 ? 1 : 0));
        assert(diagnostics.bulk_error == (mode == 0 ? 0 : mode == 3 ? EIO : ENOTSUP));
        for (size_t i = 0; i < count; i++) {
            if (strcmp(entries[i].name, "file") == 0) {
                assert(entries[i].kind == ST_ENTRY_FILE);
                assert(entries[i].logical_size == 4);
                if (mode != 0) assert(entries[i].clone_valid_attrs == 0);
            } else {
                assert(strcmp(entries[i].name, "d") == 0);
                assert(entries[i].kind == ST_ENTRY_DIRECTORY);
            }
        }
        st_free_directory_entries(entries, count);
    }
    assert(unlink(file) == 0);
    assert(rmdir(child) == 0);
    assert(rmdir(directory) == 0);
    puts("Native bulk: mixed records, ordinary-bulk retry, fallback rewind, and malformed-record tests passed.");
}
