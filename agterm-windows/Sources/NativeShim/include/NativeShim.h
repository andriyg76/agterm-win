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
// nt_application_cursor is DECCKM: arrows, Home and End are SS3 sequences while a program has set it.
int32_t nt_application_cursor(nt_terminal *terminal);
// Selection in client pixels: `mode` 0 selects cells, 1 words, 2 lines; a start without movement selects nothing.
void nt_select_start(nt_terminal *terminal, int32_t x, int32_t y, int32_t mode);
void nt_select_extend(nt_terminal *terminal, int32_t x, int32_t y);
void nt_select_end(nt_terminal *terminal);
void nt_select_clear(nt_terminal *terminal);
int32_t nt_has_selection(nt_terminal *terminal);
// nt_selection_text returns the selection's length in UTF-16 units and writes it when `capacity` holds it all.
int32_t nt_selection_text(nt_terminal *terminal, uint16_t *out, int32_t capacity);
// nt_cell_at is the 1-based cell under a client pixel, as mouse reports count it.
void nt_cell_at(nt_terminal *terminal, int32_t x, int32_t y, int32_t *column, int32_t *row);
// nt_mouse_modes: 1 clicks (?1000), 2 drags (?1002), 4 all motion (?1003), 8 SGR encoding (?1006), 16 alternate screen.
int32_t nt_mouse_modes(nt_terminal *terminal);
// nt_screen_text is the scrollback and the screen, one line per row, written when `capacity` holds it all.
int32_t nt_screen_text(nt_terminal *terminal, uint16_t *out, int32_t capacity);
// nt_reset starts a fresh emulator at the current grid, dropping screen, scrollback, modes and selection.
void nt_reset(nt_terminal *terminal);
void nt_dark_title_bar(void *window);
void nt_select_all(nt_terminal *terminal);
// nt_clear_scrollback drops the scrollback the way ED 3 does, leaving the screen and the program alone.
void nt_clear_scrollback(nt_terminal *terminal);
// nt_set_font_size remeasures the cell; the caller resizes to get the grid that now fits.
void nt_set_font_size(nt_terminal *terminal, float points);

// The sidebar: a dark Win32 tree whose items carry a caller's tag.
void *nt_tree_create(void *parent, uint32_t dpi);
void nt_tree_set_dpi(void *tree, uint32_t dpi);
void nt_tree_clear(void *tree);
void *nt_tree_add(void *tree, void *parent, const uint16_t *text, int64_t tag, int32_t expanded);
void nt_tree_select(void *tree, void *item);
// nt_tree_selection_changed reads a WM_NOTIFY lParam: 1 with the item's tag when the user moved the selection.
int32_t nt_tree_selection_changed(intptr_t notification, int64_t *tag);
// nt_tree_custom_draw answers a tree's NM_CUSTOMDRAW (-1 for any other WM_NOTIFY): dark selection, and items whose
// tag's `dimmed` byte is set drawn grey.
intptr_t nt_tree_custom_draw(intptr_t notification, const uint8_t *dimmed, int64_t count);
// nt_track_menu shows a popup menu at a screen point and returns the picked command id, 0 when dismissed.
int32_t nt_track_menu(void *menu, void *owner, int32_t x, int32_t y);

#ifdef __cplusplus
}
#endif
