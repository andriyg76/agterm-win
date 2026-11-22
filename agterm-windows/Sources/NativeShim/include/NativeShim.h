#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// One terminal drawn natively: agwinterm's emulator core (its C-ABI DLL, loaded at run time) parses the program's
// output, and Direct2D with DirectWrite draws the grid into a window. Every call is on the window's thread.
typedef struct nt_terminal nt_terminal;
typedef void (*nt_reply_fn)(void *context, const uint8_t *bytes, uint32_t length);

void nt_init_process(void);
// nt_create returns NULL with the reason in `error` when the core or the renderer cannot start.
nt_terminal *nt_create(void *window, const uint16_t *core_path, const uint16_t *font, float points, uint16_t *error,
                       int32_t error_capacity);
void nt_destroy(nt_terminal *terminal);
// nt_resize takes the client size in pixels and gives the grid that fits it.
void nt_resize(nt_terminal *terminal, int32_t width, int32_t height, int32_t *columns, int32_t *rows);
void nt_set_dpi(nt_terminal *terminal, uint32_t dpi);
// nt_feed parses program output; `reply` receives what the terminal answers back (device reports, cursor position).
void nt_feed(nt_terminal *terminal, const uint8_t *bytes, uint32_t length, nt_reply_fn reply, void *context);
void nt_paint(nt_terminal *terminal);
// nt_scroll moves the view `lines` back into the scrollback (negative toward the live screen).
void nt_scroll(nt_terminal *terminal, int32_t lines);
void nt_scroll_to_bottom(nt_terminal *terminal);
void nt_set_focus(nt_terminal *terminal, int32_t focused);
int32_t nt_bracketed_paste(nt_terminal *terminal);

#ifdef __cplusplus
}
#endif
