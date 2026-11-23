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
// nt_show_title puts the program's title on the terminal's top-level window.
void nt_show_title(nt_terminal *terminal);
// nt_take_attention is 1 once after the program rang the bell or posted a notification (OSC 9, 777).
int32_t nt_take_attention(nt_terminal *terminal);
void nt_select_all(nt_terminal *terminal);
// Search reads lines by buffer index, 0 the oldest scrollback line, and selects a match, scrolling it into view.
int32_t nt_line_count(nt_terminal *terminal);
int32_t nt_line_runes(nt_terminal *terminal, int32_t line, uint32_t *runes, int32_t capacity);
void nt_select_cells(nt_terminal *terminal, int32_t line, int32_t column, int32_t cells);
// nt_row_runes writes the row under a client pixel, one rune a cell (0 blank, UINT32_MAX a wide character's second
// cell), and that pixel's 0-based column; it returns the row's cell count.
int32_t nt_row_runes(nt_terminal *terminal, int32_t x, int32_t y, uint32_t *runes, int32_t capacity, int32_t *column);
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
// nt_tree_label_edit reads a WM_NOTIFY lParam for in-place renaming: 1 an edit begins (answer 1 to refuse it), 2 it
// ended with the new name in `text`, 3 it was cancelled, 0 any other notification; `tag` is the item's.
int32_t nt_tree_label_edit(intptr_t notification, int64_t *tag, uint16_t *text, int32_t capacity);
void nt_tree_edit(void *tree, void *item);
// nt_tree_set_edit_text replaces the text an in-place edit starts from (the label without its marks).
void nt_tree_set_edit_text(void *tree, const uint16_t *text);
// nt_tree_item_at is the tag of the item at a WM_CONTEXTMENU's screen point (0 off any item, a workspace row
// included); for a keyboard menu (-1, -1) it is the selected item's, and the point moves to that item's corner.
int64_t nt_tree_item_at(void *tree, int32_t *x, int32_t *y);
// nt_tree_custom_draw answers a tree's NM_CUSTOMDRAW (-1 for any other WM_NOTIFY): dark selection, and items whose
// tag's `dimmed` byte is set drawn grey.
intptr_t nt_tree_custom_draw(intptr_t notification, const uint8_t *dimmed, int64_t count);
// The find bar: an edit control posting NT_FIND_NEXT (wParam 1 with Shift) on Enter and NT_FIND_CLOSE on Escape to
// its parent; its text changes arrive as the parent's EN_CHANGE.
#define NT_FIND_NEXT 0x8014
#define NT_FIND_CLOSE 0x8015
void *nt_find_bar_create(void *parent, uint32_t dpi);
void nt_find_bar_set_dpi(void *bar, uint32_t dpi);
// nt_track_menu shows a popup menu at a screen point and returns the picked command id, 0 when dismissed.
int32_t nt_track_menu(void *menu, void *owner, int32_t x, int32_t y);

#ifdef __cplusplus
}
#endif
