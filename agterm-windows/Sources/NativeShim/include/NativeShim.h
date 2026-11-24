#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// One terminal drawn natively: libghostty-vt parses the program's output, and Direct2D with DirectWrite draws the
// grid into a window. Every call is on the window's thread.
typedef struct nt_terminal nt_terminal;
typedef void (*nt_reply_fn)(void *context, const uint8_t *bytes, uint32_t length);

void nt_init_process(void);
// Appends unhandled exceptions and UCRT invalid-parameter aborts to `path` before the process dies.
void nt_install_crash_log(const uint16_t *path);
// Writes the file's SHA-256 into the 32 bytes at `digest`: 0, else the Win32 error or NTSTATUS that stopped it.
int32_t nt_sha256_file(const uint16_t *path, uint8_t *digest);
// nt_create returns NULL with the reason in `error` when the core or the renderer cannot start.
nt_terminal *nt_create(void *window, const uint16_t *font, float points, uint16_t *error, int32_t error_capacity);
void nt_destroy(nt_terminal *terminal);
// nt_resize takes the client size in pixels and gives the grid that fits it.
void nt_resize(nt_terminal *terminal, int32_t width, int32_t height, int32_t *columns, int32_t *rows,
               nt_reply_fn reply, void *context);
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
// nt_take_attention is 1 once after the program rang the bell.
int32_t nt_take_attention(nt_terminal *terminal);
// nt_take_notification is 1 while an OSC 9 or 777 notification waits, the last one's title and body lengths in the
// length outputs; buffers that hold both take it, and the next call is 0 until another arrives.
int32_t nt_take_notification(nt_terminal *terminal, uint16_t *title, int32_t title_capacity, int32_t *title_length,
                             uint16_t *body, int32_t body_capacity, int32_t *body_length);
// nt_take_naming is 1 once after the program's title (OSC 0/2) or working directory (OSC 7, 9;9, 1337) changed;
// nt_title and nt_pwd return their length in UTF-16 units and write them when `capacity` holds them.
int32_t nt_take_naming(nt_terminal *terminal);
int32_t nt_title(nt_terminal *terminal, uint16_t *out, int32_t capacity);
int32_t nt_pwd(nt_terminal *terminal, uint16_t *out, int32_t capacity);
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
// nt_set_font_family switches to `family`, else Cascadia Mono, else Consolas, and remeasures like nt_set_font_size.
void nt_set_font_family(nt_terminal *terminal, const uint16_t *family);
// nt_set_theme sets the default colors as 0xRRGGBB; a value above 0xFFFFFF keeps that one's built-in default.
// `palette` is 256 such values, or NULL for the built-in palette.
void nt_set_theme(nt_terminal *terminal, uint32_t foreground, uint32_t background, uint32_t cursor, uint32_t cursor_text,
                  uint32_t selection, const uint32_t *palette);
// nt_monospace_fonts writes the installed monospaced families, each ended by a newline, when `capacity` holds them all;
// it returns their length in UTF-16 units.
int32_t nt_monospace_fonts(uint16_t *out, int32_t capacity);

// Windows toasts. nt_is_packaged is 1 in an MSIX, whose identity they use; otherwise nt_toast_init registers `app_id`
// under HKCU with `display_name` and the `icon` PNG and takes it as the process's AppUserModelID. A clicked toast posts
// `message` to `window` with its group in lParam, a heap string freed with nt_toast_free.
int32_t nt_is_packaged(void);
int32_t nt_toast_init(void *window, uint32_t message, const uint16_t *app_id, const uint16_t *display_name, const uint16_t *icon);
// nt_toast_show shows toast XML; a later toast with the same tag and group replaces it.
int32_t nt_toast_show(const uint16_t *xml, const uint16_t *tag, const uint16_t *group);
void nt_toast_remove_group(const uint16_t *group);
void nt_toast_free(void *text);

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
// The shim's messages sit at WM_APP + 0x100 and up; the Swift side numbers its own WM_APP + n below that.
#define NT_FIND_NEXT 0x8100
#define NT_FIND_CLOSE 0x8101
void *nt_find_bar_create(void *parent, uint32_t dpi);
void nt_find_bar_set_dpi(void *bar, uint32_t dpi);
// nt_track_menu shows a popup menu at a screen point and returns the picked command id, 0 when dismissed.
int32_t nt_track_menu(void *menu, void *owner, int32_t x, int32_t y);

// The palettes: the find bar's field over a list, posting NT_PALETTE_QUERY to its parent when the query changes,
// NT_PALETTE_RUN with the highlighted row (-1 none) on Enter or a click, and NT_PALETTE_CLOSE on Esc (wParam 0) or when
// focus leaves it (1). The arrows, Page Up/Down and Ctrl+J/K move the highlight without the parent.
#define NT_PALETTE_QUERY 0x8102
#define NT_PALETTE_RUN 0x8103
#define NT_PALETTE_CLOSE 0x8104
typedef struct {
    const uint16_t *title, *subtitle, *detail;
    int32_t enabled;
} nt_palette_row;
void *nt_palette_create(void *parent, uint32_t dpi);
void nt_palette_set_dpi(void *palette, uint32_t dpi);
// nt_palette_open clears the field, shows the panel at `left`, `top` (parent client pixels) and focuses it.
void nt_palette_open(void *palette, const uint16_t *cue, int32_t left, int32_t top, int32_t width);
void nt_palette_place(void *palette, int32_t left, int32_t top, int32_t width);
// nt_palette_set_rows replaces the list, highlighting `selection`; the panel's height follows, up to ten rows.
void nt_palette_set_rows(void *palette, const nt_palette_row *rows, int32_t count, int32_t selection);
int32_t nt_palette_query(void *palette, uint16_t *out, int32_t capacity);
void nt_palette_close(void *palette);
int32_t nt_palette_visible(void *palette);

// The window's own title bar. A button's `kind` is 0 an action icon, 1 a caption button, 2 close; `state` is 0 at
// rest, 1 hovered, 2 pressed; `glyph` is a Segoe MDL2 Assets code point.
typedef struct {
    int32_t left, right;
    uint16_t glyph;
    int32_t kind, state;
} nt_title_button;
// nt_title_bar_paint answers the window's WM_PAINT: the bar across the top `height` pixels, the background below it.
void nt_title_bar_paint(void *window, uint32_t dpi, int32_t height, const uint16_t *title, int32_t title_left,
                        int32_t title_right, const nt_title_button *buttons, int32_t count, int32_t active);
// A tooltip over rectangles of `parent`'s client; nt_tooltip_set with an empty text removes the tool `id`.
void *nt_tooltip_create(void *parent);
void nt_tooltip_set(void *tip, void *parent, uintptr_t id, int32_t left, int32_t top, int32_t right, int32_t bottom,
                    const uint16_t *text);

#ifdef __cplusplus
}
#endif
