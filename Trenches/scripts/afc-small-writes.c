#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>

/* USBIP on WSL can lose the short-packet boundary on large AFC writes.
 * Waiting for an AFC acknowledgement every 4 KiB avoids the 64 KiB overflow. */
int afc_file_write(void *client, uint64_t handle, const char *data,
                   uint32_t length, uint32_t *written) {
    typedef int (*write_function)(void *, uint64_t, const char *, uint32_t, uint32_t *);
    write_function original = (write_function)dlsym(RTLD_NEXT, "afc_file_write");
    if (!written || !original) return 1;
    *written = 0;
    while (*written < length) {
        uint32_t remaining = length - *written;
        uint32_t chunk = remaining > 4096 ? 4096 : remaining;
        uint32_t count = 0;
        int error = original(client, handle, data + *written, chunk, &count);
        if (error) return error;
        if (!count || count > chunk) return 5;
        *written += count;
    }
    return 0;
}
