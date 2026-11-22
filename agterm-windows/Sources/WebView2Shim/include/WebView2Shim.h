#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// One WebView2 filling one window, driven from Swift without COM: strings are NUL-terminated UTF-16.
typedef void (*wv_ready_cb)(void *ctx, int32_t hresult);
typedef void (*wv_message_cb)(void *ctx, const uint16_t *message);

void wv_init_process(void);
// crash_log_install appends unhandled exceptions and UCRT invalid-parameter aborts to `path` before the process dies.
void crash_log_install(const uint16_t *path);
// browserFolder is a fixed-version WebView2 runtime to use, or NULL for the installed one.
int32_t wv_create(void *hwnd, const uint16_t *browserFolder, const uint16_t *userDataFolder, const uint16_t *html,
                  wv_ready_cb ready, wv_message_cb message, void *ctx);
void wv_resize(int32_t width, int32_t height);
void wv_focus(void);
void wv_post_string(const uint16_t *message);
// sha256_file writes the file's SHA-256 into the 32 bytes at `digest`: 0, else the Win32 error or NTSTATUS that stopped it.
int32_t sha256_file(const uint16_t *path, uint8_t *digest);

#ifdef __cplusplus
}
#endif
