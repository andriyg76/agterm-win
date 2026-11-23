#include "NativeShim.h"

#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#include <d2d1.h>
#include <dwmapi.h>
#include <dwrite.h>
#include <dwrite_1.h>
#include <ghostty/vt.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

namespace {

template <typename T> T lesser(T a, T b) { return b < a ? b : a; }
template <typename T> T greater(T a, T b) { return a < b ? b : a; }
template <typename T> T clamped(T value, T low, T high) { return value < low ? low : high < value ? high : value; }

template <typename T> class Com {
public:
    Com() = default;
    Com(decltype(nullptr)) {}
    Com(const Com &) = delete;
    Com &operator=(const Com &) = delete;
    Com(Com &&other) : pointer(other.pointer) { other.pointer = nullptr; }
    Com &operator=(Com &&other) {
        if (this != &other) {
            Reset();
            pointer = other.pointer;
            other.pointer = nullptr;
        }
        return *this;
    }
    ~Com() { Reset(); }
    void Reset() {
        if (pointer) pointer->Release();
        pointer = nullptr;
    }
    T **put() {
        Reset();
        return &pointer;
    }
    T *Get() const { return pointer; }
    T *operator->() const { return pointer; }
    explicit operator bool() const { return pointer != nullptr; }

private:
    T *pointer = nullptr;
};

// a growable array of trivially copyable items; new items are zeroed, as std::vector value-initializes them
template <typename T> class Buffer {
public:
    Buffer() = default;
    Buffer(const Buffer &) = delete;
    Buffer &operator=(const Buffer &) = delete;
    ~Buffer() { free(items); }
    T *data() const { return items; }
    size_t size() const { return count; }
    bool empty() const { return count == 0; }
    T &operator[](size_t index) const { return items[index]; }
    void clear() { count = 0; }
    void reserve(size_t wanted) {
        if (wanted <= capacity) return;
        size_t next = greater<size_t>(wanted, capacity * 2);
        auto grown = static_cast<T *>(realloc(items, next * sizeof(T)));
        if (!grown) abort();
        items = grown;
        capacity = next;
    }
    void resize(size_t wanted) {
        reserve(wanted);
        if (wanted > count) memset(items + count, 0, (wanted - count) * sizeof(T));
        count = wanted;
    }
    void push(T item) {
        reserve(count + 1);
        items[count++] = item;
    }
    void append(const T *source, size_t length) {
        reserve(count + length);
        memcpy(items + count, source, length * sizeof(T));
        count += length;
    }
    void swap(Buffer &other) {
        T *otherItems = other.items;
        size_t otherCount = other.count, otherCapacity = other.capacity;
        other.items = items;
        other.count = count;
        other.capacity = capacity;
        items = otherItems;
        count = otherCount;
        capacity = otherCapacity;
    }

private:
    T *items = nullptr;
    size_t count = 0, capacity = 0;
};

using Text = Buffer<wchar_t>;

const wchar_t *terminated(Text &text) {
    text.reserve(text.size() + 1);
    text.data()[text.size()] = 0;
    return text.data();
}

bool same(const Text &a, const Text &b) { return a.size() == b.size() && (a.empty() || !wmemcmp(a.data(), b.data(), a.size())); }

uint32_t utf16(uint32_t codepoint, wchar_t *out) {
    if (codepoint <= 0xFFFF) {
        out[0] = static_cast<wchar_t>(codepoint);
        return 1;
    }
    codepoint -= 0x10000;
    out[0] = static_cast<wchar_t>(0xD800 + (codepoint >> 10));
    out[1] = static_cast<wchar_t>(0xDC00 + (codepoint & 0x3FF));
    return 2;
}

void appendCodepoint(Text &text, uint32_t codepoint) {
    wchar_t units[2];
    text.append(units, utf16(codepoint, units));
}

constexpr uint32_t attributeBold = 1, attributeItalic = 2, attributeUnderline = 4, attributeInverse = 8, attributeDim = 16,
                   attributeStrikethrough = 32;

// a grapheme cluster longer than this keeps only its base rune
constexpr uint32_t clusterCapacity = 32;

struct Cell {
    int32_t rune;
    uint32_t foreground, background, attributes, width;
    uint32_t foregroundKind, foregroundIndex, foregroundRGB, backgroundKind, backgroundIndex, backgroundRGB;
    uint32_t textLength;
    wchar_t text[clusterCapacity];
};

struct Info {
    uint32_t columns, rows, cursorRow, cursorColumn, cursorVisible, alternateScreen, historyCount;
    int64_t scrollGeneration;
    uint32_t mouseClick, mouseDrag, mouseMotion, mouseSGR, mouseSGRPixels, bracketedPaste;
    int32_t keyboardFlags;
    uint32_t scrollTop, scrollBottom, markCount, focusReporting, synchronizedOutput, win32InputMode, dynamicBackground;
    int32_t cursorShape;
};

D2D1_COLOR_F color(uint32_t rgb) { return D2D1::ColorF(rgb); }

uint32_t rgb(GhosttyColorRgb value) {
    return (static_cast<uint32_t>(value.r) << 16) | (static_cast<uint32_t>(value.g) << 8) | value.b;
}

uint32_t blend(uint32_t a, uint32_t b) {
    uint32_t result = 0;
    for (int shift = 0; shift <= 16; shift += 8) result |= ((((a >> shift) & 0xFF) + ((b >> shift) & 0xFF)) / 2) << shift;
    return result;
}

Com<IDWriteFontFace> face(IDWriteFontCollection *fonts, const wchar_t *family, DWRITE_FONT_WEIGHT weight,
                          DWRITE_FONT_STYLE style) {
    UINT32 index = 0;
    BOOL exists = FALSE;
    Com<IDWriteFontFamily> fontFamily;
    Com<IDWriteFont> font;
    Com<IDWriteFontFace> result;
    if (FAILED(fonts->FindFamilyName(family, &index, &exists)) || !exists || FAILED(fonts->GetFontFamily(index, fontFamily.put())) ||
        FAILED(fontFamily->GetFirstMatchingFont(weight, DWRITE_FONT_STRETCH_NORMAL, style, font.put())) ||
        FAILED(font->CreateFontFace(result.put()))) {
        return nullptr;
    }
    return result;
}

void widen(Text &text, const uint8_t *bytes, uint32_t length) {
    text.clear();
    if (!bytes) return;
    int count = MultiByteToWideChar(CP_UTF8, 0, reinterpret_cast<const char *>(bytes), static_cast<int>(length), nullptr, 0);
    text.resize(static_cast<size_t>(count));
    MultiByteToWideChar(CP_UTF8, 0, reinterpret_cast<const char *>(bytes), static_cast<int>(length), text.data(), count);
}

struct Style {
    uint32_t foreground, background, face, attributes;
};

// a buffer position: lines count from the oldest scrollback row, so a selection stays put while the view scrolls
struct Point {
    int64_t line;
    int32_t column;
    bool operator<(const Point &other) const { return line < other.line || (line == other.line && column < other.column); }
};

struct Span {
    Point first, second;
};

bool wordCharacter(int32_t rune) {
    if (rune <= ' ') return false;
    static const wchar_t *delimiters = L"()[]{}<>'\"`|,;";
    return rune > 0xFFFF || !wcschr(delimiters, static_cast<wchar_t>(rune));
}

// Process-wide crash diagnostics live with the one native implementation rather than in a rendering backend.
wchar_t crashLog[MAX_PATH];

void crashLine(const char *text) {
    HANDLE file = CreateFileW(crashLog, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr, OPEN_ALWAYS, 0, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written;
    WriteFile(file, text, static_cast<DWORD>(strlen(text)), &written, nullptr);
    CloseHandle(file);
}

LONG WINAPI unhandled(EXCEPTION_POINTERS *info) {
    char line[256];
    HMODULE module = nullptr;
    char name[MAX_PATH] = "?";
    void *address = info->ExceptionRecord->ExceptionAddress;
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           static_cast<LPCSTR>(address), &module)) {
        GetModuleFileNameA(module, name, MAX_PATH);
    }
    snprintf(line, sizeof line, "unhandled exception 0x%08lx at %p (%s+0x%llx) thread %lu\n",
                  info->ExceptionRecord->ExceptionCode, address, name,
                  static_cast<unsigned long long>(static_cast<char *>(address) - reinterpret_cast<char *>(module)),
                  GetCurrentThreadId());
    crashLine(line);
    return EXCEPTION_CONTINUE_SEARCH;
}

void invalidParameter(const wchar_t *, const wchar_t *, const wchar_t *, unsigned int, uintptr_t) {
    char line[96];
    snprintf(line, sizeof line, "UCRT invalid parameter, thread %lu\n", GetCurrentThreadId());
    crashLine(line);
    TerminateProcess(GetCurrentProcess(), 0xC000000D);
}

}  // namespace

struct nt_terminal {
    HWND window = nullptr;
    GhosttyTerminal emulator = nullptr;
    GhosttyRenderState render = nullptr;
    nt_reply_fn reply = nullptr;
    void *replyContext = nullptr;
    Com<ID2D1Factory> d2d;
    Com<IDWriteFactory> dwrite;
    Com<ID2D1HwndRenderTarget> target;
    Com<ID2D1SolidColorBrush> brush;
    Com<IDWriteFontFace> faces[4];  // regular, bold, italic, bold italic
    Com<IDWriteTextFormat> fallback[4];
    Text family;
    float points = 11;
    float dpi = 96;
    float emSize = 0, cellWidth = 0, cellHeight = 0, baseline = 0;  // DIPs, cell edges on whole pixels
    int32_t cellWidthPixels = 1, cellHeightPixels = 1, paddingPixels = 4;
    uint32_t columns = 80, rows = 24;
    int32_t scroll = 0;
    bool focused = true;
    bool attention = false;  // a bell since nt_take_attention
    bool notified = false;   // an OSC 9 or 777 notification since nt_take_notification, the last one's text below
    Text notificationTitle, notificationBody;
    bool naming = false;     // the title or the working directory changed since nt_take_naming
    uint32_t selectionColor = 0x264F78;
    bool selecting = false, hasSelection = false;
    int32_t selectionMode = 0;  // 0 cells, 1 words, 2 lines
    Point anchor{}, head{};
    Span paintSpan{};  // range() once per frame, not per row
    uint32_t foreground = 0xCCCCCC, background = 0x1E1E1E;
    uint32_t cursor = 0xCCCCCC;  // the effective cursor color, OSC 12 included
    uint32_t cursorText = UINT32_MAX;  // a theme's cursor-text; above 0xFFFFFF the background
    Buffer<Cell> grid, history;
    Text title, pwd;
    Buffer<UINT16> glyphs;
    Buffer<FLOAT> advances;

    float scale() const { return dpi / 96.f; }

    bool mode(uint16_t value) const {
        GhosttyTerminalModeConfig mode{ghostty_mode_new(value, false), false};
        return ghostty_terminal_get(emulator, GHOSTTY_TERMINAL_DATA_MODE, &mode) == GHOSTTY_SUCCESS && mode.value;
    }

    Info info() {
        Info result{};
        uint16_t columns = 0, rows = 0, cursorX = 0, cursorY = 0;
        bool cursorVisible = true;
        GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        size_t history = 0;
        ghostty_terminal_get(emulator, GHOSTTY_TERMINAL_DATA_COLS, &columns);
        ghostty_terminal_get(emulator, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
        ghostty_terminal_get(emulator, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cursorX);
        ghostty_terminal_get(emulator, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cursorY);
        ghostty_terminal_get(emulator, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &cursorVisible);
        ghostty_terminal_get(emulator, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
        ghostty_terminal_get(emulator, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &history);
        result.columns = columns;
        result.rows = rows;
        result.cursorColumn = cursorX;
        result.cursorRow = cursorY;
        result.cursorVisible = cursorVisible;
        result.alternateScreen = screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
        result.historyCount = static_cast<uint32_t>(lesser<size_t>(history, UINT32_MAX));
        result.mouseClick = mode(9) || mode(1000);
        result.mouseDrag = mode(1002);
        result.mouseMotion = mode(1003);
        result.mouseSGR = mode(1006);
        result.mouseSGRPixels = mode(1016);
        result.bracketedPaste = mode(2004);
        result.focusReporting = mode(1004);
        result.synchronizedOutput = mode(2026);
        if (render && ghostty_render_state_update(render, emulator) == GHOSTTY_SUCCESS) {
            GhosttyRenderStateCursor cursor{};
            cursor.size = sizeof(cursor);
            if (ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor) == GHOSTTY_SUCCESS) {
                result.cursorShape = cursor.visual_style == GHOSTTY_CURSOR_STYLE_UNDERLINE ? 3
                    : cursor.visual_style == GHOSTTY_CURSOR_STYLE_BAR ? 5 : 1;
            }
        }
        return result;
    }

    // loadFont takes `wanted`, else Cascadia Mono, else Consolas; false leaves the faces as they were
    bool loadFont(const wchar_t *wanted) {
        Com<IDWriteFontCollection> fonts;
        dwrite->GetSystemFontCollection(fonts.put());
        const wchar_t *families[] = {wanted && *wanted ? wanted : nullptr, L"Cascadia Mono", L"Consolas"};
        for (const wchar_t *candidate : families) {
            if (!candidate) continue;
            Com<IDWriteFontFace> regular = face(fonts.Get(), candidate, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL);
            if (!regular) continue;
            faces[0] = static_cast<Com<IDWriteFontFace> &&>(regular);
            faces[1] = face(fonts.Get(), candidate, DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_NORMAL);
            faces[2] = face(fonts.Get(), candidate, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_ITALIC);
            faces[3] = face(fonts.Get(), candidate, DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_ITALIC);
            family.clear();
            family.append(candidate, wcslen(candidate));
            return true;
        }
        return false;
    }

    void refreshColors() {
        GhosttyColorRgb fg{}, bg{};
        if (ghostty_terminal_get(emulator, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &fg) == GHOSTTY_SUCCESS) foreground = rgb(fg);
        if (ghostty_terminal_get(emulator, GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, &bg) == GHOSTTY_SUCCESS) background = rgb(bg);
        GhosttyColorRgb caret{};
        cursor = ghostty_terminal_get(emulator, GHOSTTY_TERMINAL_DATA_COLOR_CURSOR, &caret) == GHOSTTY_SUCCESS ? rgb(caret) : foreground;
    }

    void rowCells(const Info &state, int64_t line, Buffer<Cell> &out) {
        GhosttyColorRgb palette[256]{};
        ghostty_terminal_get(emulator, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, palette);
        out.clear();
        out.resize(state.columns);
        line = clamped<int64_t>(line, 0, state.historyCount + state.rows - 1);
        for (uint32_t column = 0; column < state.columns; column++) {
            GhosttyPoint point{};
            point.tag = line >= state.historyCount ? GHOSTTY_POINT_TAG_ACTIVE : GHOSTTY_POINT_TAG_SCREEN;
            point.value.coordinate = {static_cast<uint16_t>(column),
                                      static_cast<uint32_t>(line >= state.historyCount ? line - state.historyCount : line)};
            GhosttyGridRef reference{};
            if (ghostty_terminal_grid_ref(emulator, point, &reference) != GHOSTTY_SUCCESS) continue;
            GhosttyCell raw{};
            GhosttyStyle style{};
            if (ghostty_grid_ref_cell(&reference, &raw) != GHOSTTY_SUCCESS ||
                ghostty_grid_ref_style(&reference, &style) != GHOSTTY_SUCCESS) continue;
            Cell &cell = out[column];
            uint32_t codepoint = 0;
            GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint);
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
            cell.rune = static_cast<int32_t>(codepoint);
            cell.width = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : wide == GHOSTTY_CELL_WIDE_NARROW ? 1 : 0;
            uint32_t graphemes[clusterCapacity];
            size_t graphemeCount = 0;
            if (ghostty_grid_ref_graphemes(&reference, graphemes, clusterCapacity, &graphemeCount) == GHOSTTY_SUCCESS) {
                for (size_t index = 0; index < graphemeCount; index++) {
                    wchar_t units[2];
                    uint32_t length = utf16(graphemes[index], units);
                    if (cell.textLength + length > clusterCapacity) {
                        cell.textLength = 0;
                        break;
                    }
                    memcpy(cell.text + cell.textLength, units, length * sizeof(wchar_t));
                    cell.textLength += length;
                }
            }
            cell.attributes = ((style.flags & GHOSTTY_STYLE_FLAG_BOLD) ? attributeBold : 0) |
                              ((style.flags & GHOSTTY_STYLE_FLAG_ITALIC) ? attributeItalic : 0) |
                              (GHOSTTY_STYLE_UNDERLINE(style) ? attributeUnderline : 0) |
                              ((style.flags & GHOSTTY_STYLE_FLAG_INVERSE) ? attributeInverse : 0) |
                              ((style.flags & GHOSTTY_STYLE_FLAG_FAINT) ? attributeDim : 0) |
                              ((style.flags & GHOSTTY_STYLE_FLAG_STRIKETHROUGH) ? attributeStrikethrough : 0);
            auto resolve = [&](GhosttyStyleColor color, uint32_t fallback, uint32_t &value, uint32_t &kind,
                               uint32_t &index, uint32_t &direct) {
                if (color.tag == GHOSTTY_STYLE_COLOR_PALETTE) {
                    index = color.value.palette;
                    value = rgb(palette[index]);
                    kind = 1;
                } else if (color.tag == GHOSTTY_STYLE_COLOR_RGB) {
                    value = direct = rgb(color.value.rgb);
                    kind = 2;
                } else {
                    value = fallback;
                    kind = 0;
                }
            };
            resolve(style.fg_color, foreground, cell.foreground, cell.foregroundKind, cell.foregroundIndex, cell.foregroundRGB);
            resolve(style.bg_color, background, cell.background, cell.backgroundKind, cell.backgroundIndex, cell.backgroundRGB);
            GhosttyCellContentTag content = GHOSTTY_CELL_CONTENT_CODEPOINT;
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CONTENT_TAG, &content);
            if (content == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE) {
                GhosttyColorPaletteIndex index = 0;
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_PALETTE, &index);
                cell.background = rgb(palette[index]);
                cell.backgroundKind = 1;
                cell.backgroundIndex = index;
            } else if (content == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB) {
                GhosttyColorRgb direct{};
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_RGB, &direct);
                cell.background = cell.backgroundRGB = rgb(direct);
                cell.backgroundKind = 2;
            }
        }
    }

    Point point(int32_t x, int32_t y) {
        Info state = info();
        int32_t column = clamped((x - paddingPixels) / cellWidthPixels, 0, static_cast<int32_t>(state.columns) - 1);
        int32_t row = clamped((y - paddingPixels) / cellHeightPixels, 0, static_cast<int32_t>(state.rows) - 1);
        return {static_cast<int64_t>(state.historyCount) - scroll + row, column};
    }

    // range is the selection in reading order, widened to whole words or lines
    Span range() {
        Point start = lesser(anchor, head), end = greater(anchor, head);
        if (selectionMode == 2) return {{start.line, 0}, {end.line, INT32_MAX}};
        if (selectionMode == 1) {
            Info state = info();
            Buffer<Cell> cells;
            rowCells(state, start.line, cells);
            while (start.column > 0 && wordCharacter(cells[start.column - 1].rune) && wordCharacter(cells[start.column].rune)) start.column--;
            rowCells(state, end.line, cells);
            while (end.column + 1 < static_cast<int32_t>(cells.size()) && wordCharacter(cells[end.column + 1].rune) &&
                   wordCharacter(cells[end.column].rune)) {
                end.column++;
            }
        }
        return {start, end};
    }

    bool selected(const Span &span, int64_t line, uint32_t column) const {
        Point here{line, static_cast<int32_t>(column)};
        return hasSelection && !(here < span.first) && !(span.second < here);
    }

    void measure() {
        emSize = points * 96.f / 72.f;
        DWRITE_FONT_METRICS metrics;
        faces[0]->GetMetrics(&metrics);
        float units = emSize / metrics.designUnitsPerEm;
        UINT32 zero = '0';
        UINT16 glyph = 0;
        DWRITE_GLYPH_METRICS glyphMetrics{};
        faces[0]->GetGlyphIndices(&zero, 1, &glyph);
        faces[0]->GetDesignGlyphMetrics(&glyph, 1, &glyphMetrics, FALSE);
        cellWidthPixels = greater(1L, lroundf(glyphMetrics.advanceWidth * units * scale()));
        cellHeightPixels = greater(1, static_cast<int32_t>(ceilf((metrics.ascent + metrics.descent + metrics.lineGap) * units * scale())));
        paddingPixels = static_cast<int32_t>(lroundf(4 * scale()));
        cellWidth = cellWidthPixels / scale();
        cellHeight = cellHeightPixels / scale();
        baseline = roundf((metrics.lineGap / 2.f + metrics.ascent) * units * scale()) / scale();
        for (uint32_t index = 0; index < 4; index++) {
            fallback[index].Reset();
            dwrite->CreateTextFormat(terminated(family), nullptr, index & 1 ? DWRITE_FONT_WEIGHT_BOLD : DWRITE_FONT_WEIGHT_NORMAL,
                                     index & 2 ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL,
                                     DWRITE_FONT_STRETCH_NORMAL, emSize, L"", fallback[index].put());
            if (fallback[index]) fallback[index]->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        }
    }

    bool ensureTarget() {
        if (target) return true;
        RECT client;
        GetClientRect(window, &client);
        auto properties = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(), dpi, dpi);
        auto hwnd = D2D1::HwndRenderTargetProperties(window, D2D1::SizeU(client.right - client.left, client.bottom - client.top));
        if (FAILED(d2d->CreateHwndRenderTarget(properties, hwnd, target.put()))) return false;
        target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
        target->CreateSolidColorBrush(color(foreground), brush.put());
        return true;
    }

    Style style(const Cell &cell) const {
        // a default-colored cell takes this window's colors, whatever the core resolved it to
        uint32_t fg = cell.foregroundKind == 0 ? foreground : cell.foreground;
        uint32_t bg = cell.backgroundKind == 0 ? background : cell.background;
        if (cell.attributes & attributeInverse) {
            uint32_t swapped = fg;
            fg = bg;
            bg = swapped;
        }
        if (cell.attributes & attributeDim) fg = blend(fg, bg);
        uint32_t faceIndex = ((cell.attributes & attributeBold) ? 1 : 0) | ((cell.attributes & attributeItalic) ? 2 : 0);
        return {fg, bg, faces[faceIndex] ? faceIndex : 0, cell.attributes};
    }

    void fill(float left, float top, float right, float bottom, uint32_t rgb) {
        brush->SetColor(color(rgb));
        target->FillRectangle(D2D1::RectF(left, top, right, bottom), brush.Get());
    }

    void flush(IDWriteFontFace *runFace, float x, float y, uint32_t rgb) {
        if (glyphs.empty()) return;
        DWRITE_GLYPH_RUN run{runFace, emSize, static_cast<UINT32>(glyphs.size()), glyphs.data(), advances.data(), nullptr, FALSE, 0};
        brush->SetColor(color(rgb));
        target->DrawGlyphRun(D2D1::Point2F(x, y + baseline), &run, brush.Get());
        glyphs.clear();
        advances.clear();
    }

    // drawRow draws `count` cells from `x`, each glyph pinned to its cell so a run never drifts off the grid;
    // `override` is the cursor's inverted glyph color, drawn over a background already filled.
    void drawRow(const Cell *cells, uint32_t count, float x, float y, const uint32_t *override = nullptr, int64_t line = -1) {
        if (!override) {
            const auto &span = paintSpan;
            auto cellBackground = [&](uint32_t column) {
                if (column >= count) return background;
                return selected(span, line, column) ? selectionColor : style(cells[column]).background;
            };
            uint32_t start = 0;
            for (uint32_t column = 0; column <= count; column++) {
                uint32_t bg = cellBackground(column);
                uint32_t runBG = cellBackground(start);
                if (column == count || bg != runBG) {
                    if (runBG != background) fill(x + start * cellWidth, y, x + column * cellWidth, y + cellHeight, runBG);
                    start = column;
                }
            }
        }
        IDWriteFontFace *runFace = nullptr;
        uint32_t runColor = 0;
        float runX = x;
        for (uint32_t column = 0; column < count; column++) {
            const Cell &cell = cells[column];
            if (cell.width == 0) continue;
            Style s = style(cell);
            uint32_t fg = override ? *override : s.foreground;
            float left = x + column * cellWidth, span = greater<uint32_t>(cell.width, 1) * cellWidth;
            UINT32 codepoint = cell.rune > 0 ? static_cast<UINT32>(cell.rune) : ' ';
            bool cluster = cell.textLength != 0 && cell.textLength != (codepoint > 0xFFFF ? 2u : 1u);
            if (cluster) {
                flush(runFace, runX, y, runColor);
                drawFallback(cell.text, cell.textLength, left, y, span, fg, s.face);
            } else {
                UINT16 glyph = 0;
                faces[s.face]->GetGlyphIndices(&codepoint, 1, &glyph);
                if (!glyphs.empty() && (faces[s.face].Get() != runFace || fg != runColor)) flush(runFace, runX, y, runColor);
                if (glyph == 0 && codepoint != ' ') {
                    flush(runFace, runX, y, runColor);
                    wchar_t text[2];
                    drawFallback(text, utf16(codepoint, text), left, y, span, fg, s.face);
                } else {
                    if (glyphs.empty()) {
                        runFace = faces[s.face].Get();
                        runColor = fg;
                        runX = left;
                    }
                    glyphs.push(glyph);
                    advances.push(span);
                }
            }
            float line = 1 / scale();
            if (s.attributes & attributeUnderline) fill(left, y + baseline + line, left + span, y + baseline + 2 * line, fg);
            if (s.attributes & attributeStrikethrough) fill(left, y + cellHeight / 2, left + span, y + cellHeight / 2 + line, fg);
        }
        flush(runFace, runX, y, runColor);
    }

    // drawFallback shapes complete grapheme clusters and lets DirectWrite pick fonts for emoji and CJK.
    void drawFallback(const wchar_t *text, UINT32 length, float left, float y, float span, uint32_t rgb, uint32_t face) {
        if (!fallback[face]) return;
        brush->SetColor(color(rgb));
        target->DrawText(text, length, fallback[face].Get(), D2D1::RectF(left, y, left + span, y + cellHeight), brush.Get(),
                         D2D1_DRAW_TEXT_OPTIONS_CLIP | D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
    }

    void updateTitle() {
        GhosttyString value{};
        ghostty_terminal_get(emulator, GHOSTTY_TERMINAL_DATA_TITLE, &value);
        Text next;
        widen(next, value.ptr, static_cast<uint32_t>(value.len));
        if (!same(next, title)) {
            title.swap(next);
            naming = true;
            if (IsWindowVisible(window)) showTitle();
        }
        GhosttyString path{};
        ghostty_terminal_get(emulator, GHOSTTY_TERMINAL_DATA_PWD, &path);
        Text directory;
        widen(directory, path.ptr, static_cast<uint32_t>(path.len));
        if (!same(directory, pwd)) {
            pwd.swap(directory);
            naming = true;
        }
    }

    // the window's title is the shown terminal's; a hidden one keeps its title until it is shown
    void showTitle() { SetWindowTextW(GetAncestor(window, GA_ROOT), title.empty() ? L"agterm" : terminated(title)); }
};

namespace {

void writePty(GhosttyTerminal, void *userdata, const uint8_t *data, size_t length) {
    auto terminal = static_cast<nt_terminal *>(userdata);
    if (terminal->reply) terminal->reply(terminal->replyContext, data, static_cast<uint32_t>(length));
}

void bell(GhosttyTerminal, void *userdata) {
    static_cast<nt_terminal *>(userdata)->attention = true;
}

void desktopNotification(GhosttyTerminal, void *userdata, const GhosttyTerminalDesktopNotification *notification) {
    auto terminal = static_cast<nt_terminal *>(userdata);
    terminal->notified = true;
    // borrowed for the callback only
    widen(terminal->notificationTitle, notification->title.ptr, static_cast<uint32_t>(notification->title.len));
    widen(terminal->notificationBody, notification->body.ptr, static_cast<uint32_t>(notification->body.len));
}

bool terminalSize(GhosttyTerminal, void *userdata, GhosttySizeReportSize *size) {
    auto terminal = static_cast<nt_terminal *>(userdata);
    size->rows = static_cast<uint16_t>(terminal->rows);
    size->columns = static_cast<uint16_t>(terminal->columns);
    size->cell_width = terminal->cellWidthPixels;
    size->cell_height = terminal->cellHeightPixels;
    return true;
}

}  // namespace

extern "C" void nt_init_process(void) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    // uxtheme's unnamed SetPreferredAppMode (ordinal 135) is the only switch that makes popup menus dark; it is the
    // one Explorer and Notepad use, and a build without it just keeps light menus
    if (HMODULE theme = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32)) {
        using SetMode = int(WINAPI *)(int);
        if (auto setMode = reinterpret_cast<SetMode>(GetProcAddress(theme, MAKEINTRESOURCEA(135)))) setMode(2 /* ForceDark */);
    }
}

extern "C" void nt_install_crash_log(const uint16_t *path) {
    wcsncpy_s(crashLog, reinterpret_cast<const wchar_t *>(path), _TRUNCATE);
    SetUnhandledExceptionFilter(unhandled);
    _set_invalid_parameter_handler(invalidParameter);
}

extern "C" int32_t nt_sha256_file(const uint16_t *path, uint8_t *digest) {
    HANDLE file = CreateFileW(reinterpret_cast<const wchar_t *>(path), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                              FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (file == INVALID_HANDLE_VALUE) return static_cast<int32_t>(GetLastError());
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    NTSTATUS status = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0);
    if (BCRYPT_SUCCESS(status)) status = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0);
    unsigned char buffer[1 << 16];
    DWORD read = 0;
    int32_t failure = 0;
    while (BCRYPT_SUCCESS(status)) {
        if (!ReadFile(file, buffer, sizeof buffer, &read, nullptr)) {
            failure = static_cast<int32_t>(GetLastError());
            break;
        }
        if (read == 0) {
            status = BCryptFinishHash(hash, digest, 32, 0);
            break;
        }
        status = BCryptHashData(hash, buffer, read, 0);
    }
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    CloseHandle(file);
    return failure != 0 ? failure : BCRYPT_SUCCESS(status) ? 0 : static_cast<int32_t>(status);
}

extern "C" nt_terminal *nt_create(void *window, const uint16_t *font, float points, uint16_t *error, int32_t error_capacity) {
    auto fail = [&](const wchar_t *reason, nt_terminal *partial) -> nt_terminal * {
        if (error && error_capacity > 0) {
            size_t count = lesser<size_t>(wcslen(reason), static_cast<size_t>(error_capacity - 1));
            memcpy(error, reason, count * sizeof(wchar_t));
            error[count] = 0;
        }
        nt_destroy(partial);
        return nullptr;
    };
    auto terminal = new nt_terminal();
    terminal->window = static_cast<HWND>(window);
    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, terminal->d2d.put())) ||
        FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                   reinterpret_cast<IUnknown **>(terminal->dwrite.put())))) {
        return fail(L"Direct2D or DirectWrite did not start", terminal);
    }
    if (!terminal->loadFont(reinterpret_cast<const wchar_t *>(font))) return fail(L"no monospace font found", terminal);
    terminal->points = points;
    terminal->dpi = static_cast<float>(GetDpiForWindow(terminal->window));
    terminal->measure();
    if (ghostty_terminal_new(nullptr, &terminal->emulator, static_cast<uint16_t>(terminal->columns),
                            static_cast<uint16_t>(terminal->rows)) != GHOSTTY_SUCCESS) {
        return fail(L"libghostty-vt could not create a terminal", terminal);
    }
    if (ghostty_render_state_new(nullptr, &terminal->render) != GHOSTTY_SUCCESS) {
        return fail(L"libghostty-vt could not create render state", terminal);
    }
    GhosttyColorRgb foreground{0xCC, 0xCC, 0xCC}, background{0x1E, 0x1E, 0x1E};
    size_t scrollbackLines = 10000, scrollbackBytes = SIZE_MAX;
    bool resizePullScrollback = false;
    ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground);
    ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background);
    ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollbackLines);
    ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollbackBytes);
    ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_RESIZE_PULL_SCROLLBACK, &resizePullScrollback);
    ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_USERDATA, terminal);
    ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_WRITE_PTY, reinterpret_cast<const void *>(writePty));
    ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_BELL, reinterpret_cast<const void *>(bell));
    ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_SIZE, reinterpret_cast<const void *>(terminalSize));
    ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION,
                        reinterpret_cast<const void *>(desktopNotification));
    return terminal;
}

extern "C" void nt_destroy(nt_terminal *terminal) {
    if (!terminal) return;
    if (terminal->render) ghostty_render_state_free(terminal->render);
    if (terminal->emulator) ghostty_terminal_free(terminal->emulator);
    terminal->brush.Reset();
    terminal->target.Reset();
    for (auto &face : terminal->faces) face.Reset();
    for (auto &format : terminal->fallback) format.Reset();
    terminal->dwrite.Reset();
    terminal->d2d.Reset();
    delete terminal;
}

extern "C" void nt_resize(nt_terminal *terminal, int32_t width, int32_t height, int32_t *columns, int32_t *rows,
                          nt_reply_fn reply, void *context) {
    if (terminal->target) terminal->target->Resize(D2D1::SizeU(greater(width, 1), greater(height, 1)));
    uint32_t nextColumns = static_cast<uint32_t>(greater(1, (width - 2 * terminal->paddingPixels) / terminal->cellWidthPixels));
    uint32_t nextRows = static_cast<uint32_t>(greater(1, (height - 2 * terminal->paddingPixels) / terminal->cellHeightPixels));
    terminal->columns = nextColumns;
    terminal->rows = nextRows;
    terminal->reply = reply;
    terminal->replyContext = context;
    ghostty_terminal_resize(terminal->emulator, static_cast<uint16_t>(nextColumns), static_cast<uint16_t>(nextRows),
                           terminal->cellWidthPixels, terminal->cellHeightPixels);
    terminal->reply = nullptr;
    terminal->replyContext = nullptr;
    *columns = static_cast<int32_t>(terminal->columns);
    *rows = static_cast<int32_t>(terminal->rows);
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" void nt_set_dpi(nt_terminal *terminal, uint32_t dpi) {
    terminal->dpi = static_cast<float>(dpi);
    terminal->measure();
    if (terminal->target) terminal->target->SetDpi(terminal->dpi, terminal->dpi);
}

extern "C" void nt_feed(nt_terminal *terminal, const uint8_t *bytes, uint32_t length, nt_reply_fn reply, void *context) {
    terminal->reply = reply;
    terminal->replyContext = context;
    ghostty_terminal_vt_write(terminal->emulator, bytes, length);
    terminal->reply = nullptr;
    terminal->replyContext = nullptr;
    terminal->updateTitle();
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" void nt_paint(nt_terminal *terminal) {
    PAINTSTRUCT paint;
    BeginPaint(terminal->window, &paint);
    EndPaint(terminal->window, &paint);
    if (!terminal->ensureTarget()) return;
    Info info = terminal->info();
    uint32_t columns = info.columns, rows = info.rows;
    terminal->grid.resize(static_cast<size_t>(columns) * rows);
    terminal->history.resize(columns);
    int32_t scroll = info.alternateScreen ? 0 : lesser(terminal->scroll, static_cast<int32_t>(info.historyCount));
    terminal->scroll = scroll;

    terminal->refreshColors();
    ID2D1HwndRenderTarget *target = terminal->target.Get();
    target->BeginDraw();
    target->Clear(color(terminal->background));
    float origin = terminal->paddingPixels / terminal->scale();
    if (terminal->hasSelection) terminal->paintSpan = terminal->range();
    for (uint32_t row = 0; row < rows; row++) {
        int64_t line = static_cast<int64_t>(info.historyCount) - scroll + row;
        terminal->rowCells(info, line, terminal->history);
        if (scroll == 0) memcpy(&terminal->grid[static_cast<size_t>(row) * columns], terminal->history.data(), columns * sizeof(Cell));
        terminal->drawRow(terminal->history.data(), columns, origin, origin + row * terminal->cellHeight, nullptr, line);
    }
    if (scroll > 0) {
        // a thumb on the right edge while the view is back in the scrollback; at the live screen it is gone
        D2D1_SIZE_F size = target->GetSize();
        float total = static_cast<float>(info.historyCount + rows), top = static_cast<float>(info.historyCount - scroll);
        float height = greater(size.height * rows / total, 24.0f);
        float y = lesser(size.height * top / total, size.height - height), width = 6, inset = 2;
        D2D1_COLOR_F thumb = color(terminal->foreground);
        thumb.a = 0.35f;
        terminal->brush->SetColor(thumb);
        target->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(size.width - width - inset, y + inset, size.width - inset, y + height - inset),
                                                       width / 2, width / 2), terminal->brush.Get());
    }
    if (scroll == 0 && info.cursorVisible && info.cursorRow < rows && columns > 0) {
        uint32_t column = lesser(info.cursorColumn, columns - 1);
        const Cell *cell = &terminal->grid[static_cast<size_t>(info.cursorRow) * columns + column];
        if (cell->width == 0 && column > 0) {
            column--;
            cell--;
        }
        float left = origin + column * terminal->cellWidth, top = origin + info.cursorRow * terminal->cellHeight;
        float right = left + greater<uint32_t>(cell->width, 1) * terminal->cellWidth, bottom = top + terminal->cellHeight;
        // DECSCUSR: 0-2 block, 3-4 underline, 5-6 bar; blinking variants draw steady
        float stroke = roundf(2 * terminal->scale()) / terminal->scale();
        if (info.cursorShape >= 3 && info.cursorShape <= 4) {
            terminal->fill(left, bottom - stroke, right, bottom, terminal->cursor);
        } else if (info.cursorShape >= 5 && info.cursorShape <= 6) {
            terminal->fill(left, top, left + stroke, bottom, terminal->cursor);
        } else if (terminal->focused) {
            terminal->fill(left, top, right, bottom, terminal->cursor);
            uint32_t text = terminal->cursorText <= 0xFFFFFF ? terminal->cursorText : terminal->background;
            terminal->drawRow(cell, 1, left, top, &text);
        } else {
            terminal->brush->SetColor(color(terminal->cursor));
            float half = 0.5f / terminal->scale();
            target->DrawRectangle(D2D1::RectF(left + half, top + half, right - half, bottom - half), terminal->brush.Get(),
                                  1 / terminal->scale());
        }
    }
    if (target->EndDraw() == D2DERR_RECREATE_TARGET) {
        terminal->brush.Reset();
        terminal->target.Reset();
        InvalidateRect(terminal->window, nullptr, FALSE);
    }
}

extern "C" void nt_scroll(nt_terminal *terminal, int32_t lines) {
    Info info = terminal->info();
    terminal->scroll = clamped(terminal->scroll + lines, 0, info.alternateScreen ? 0 : static_cast<int32_t>(info.historyCount));
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" void nt_scroll_to_bottom(nt_terminal *terminal) {
    if (terminal->scroll == 0) return;
    terminal->scroll = 0;
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" void nt_set_focus(nt_terminal *terminal, int32_t focused) {
    terminal->focused = focused != 0;
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" int32_t nt_application_cursor(nt_terminal *terminal) { return terminal->mode(1); }

extern "C" void nt_select_start(nt_terminal *terminal, int32_t x, int32_t y, int32_t mode) {
    terminal->anchor = terminal->head = terminal->point(x, y);
    terminal->selectionMode = mode;
    terminal->selecting = true;
    terminal->hasSelection = mode != 0;
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" void nt_select_extend(nt_terminal *terminal, int32_t x, int32_t y) {
    if (!terminal->selecting) return;
    Point next = terminal->point(x, y);
    if (next.line == terminal->head.line && next.column == terminal->head.column && terminal->hasSelection) return;
    terminal->head = next;
    terminal->hasSelection = terminal->hasSelection || terminal->anchor < next || next < terminal->anchor;
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" void nt_select_end(nt_terminal *terminal) { terminal->selecting = false; }

extern "C" void nt_select_clear(nt_terminal *terminal) {
    if (!terminal->hasSelection && !terminal->selecting) return;
    terminal->hasSelection = terminal->selecting = false;
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" int32_t nt_has_selection(nt_terminal *terminal) { return terminal->hasSelection; }

namespace {

// appendRow appends cells first...last as UTF-16, wide-character tails skipped and trailing blanks dropped
void appendRow(Text &text, const Buffer<Cell> &cells, int32_t first, int32_t last) {
    size_t start = text.size();
    for (int32_t column = first; column <= last; column++) {
        const Cell &cell = cells[column];
        if (cell.width == 0) continue;
        if (cell.textLength != 0) {
            text.append(cell.text, cell.textLength);
            continue;
        }
        uint32_t rune = cell.rune > 0 ? static_cast<uint32_t>(cell.rune) : ' ';
        appendCodepoint(text, rune);
    }
    size_t end = text.size();
    while (end > start && text[end - 1] == L' ') end--;
    text.resize(end);
}

int32_t give(const Text &text, uint16_t *out, int32_t capacity) {
    int32_t length = static_cast<int32_t>(text.size());
    if (out && capacity >= length && length > 0) memcpy(out, text.data(), text.size() * sizeof(wchar_t));
    return length;
}

}  // namespace

extern "C" int32_t nt_selection_text(nt_terminal *terminal, uint16_t *out, int32_t capacity) {
    if (!terminal->hasSelection) return 0;
    Info state = terminal->info();
    auto [start, end] = terminal->range();
    Text text;
    Buffer<Cell> cells;
    for (int64_t line = start.line; line <= end.line; line++) {
        terminal->rowCells(state, line, cells);
        int32_t first = line == start.line ? start.column : 0;
        int32_t last = lesser<int32_t>(line == end.line ? end.column : INT32_MAX, static_cast<int32_t>(cells.size()) - 1);
        appendRow(text, cells, first, last);
        if (line < end.line) text.append(L"\r\n", 2);
    }
    return give(text, out, capacity);
}

extern "C" int32_t nt_screen_text(nt_terminal *terminal, uint16_t *out, int32_t capacity) {
    Info state = terminal->info();
    Text text;
    Buffer<Cell> cells;
    for (uint32_t row = 0; row < state.historyCount + state.rows; row++) {
        terminal->rowCells(state, row, cells);
        appendRow(text, cells, 0, static_cast<int32_t>(state.columns) - 1);
        text.push(L'\n');
    }
    return give(text, out, capacity);
}

extern "C" int32_t nt_row_runes(nt_terminal *terminal, int32_t x, int32_t y, uint32_t *runes, int32_t capacity, int32_t *column) {
    Info state = terminal->info();
    Point at = terminal->point(x, y);
    Buffer<Cell> cells;
    terminal->rowCells(state, at.line, cells);
    *column = at.column;
    int32_t count = static_cast<int32_t>(cells.size());
    for (int32_t i = 0; i < lesser(count, capacity); i++) {
        runes[i] = cells[i].width == 0 ? UINT32_MAX : static_cast<uint32_t>(greater(cells[i].rune, 0));
    }
    return count;
}

extern "C" int32_t nt_line_count(nt_terminal *terminal) {
    Info state = terminal->info();
    return static_cast<int32_t>(state.historyCount + state.rows);
}

extern "C" int32_t nt_line_runes(nt_terminal *terminal, int32_t line, uint32_t *runes, int32_t capacity) {
    Info state = terminal->info();
    Buffer<Cell> cells;
    terminal->rowCells(state, line, cells);
    int32_t count = static_cast<int32_t>(cells.size());
    for (int32_t i = 0; i < lesser(count, capacity); i++) {
        runes[i] = cells[i].width == 0 ? UINT32_MAX : static_cast<uint32_t>(greater(cells[i].rune, 0));
    }
    return count;
}

extern "C" void nt_select_cells(nt_terminal *terminal, int32_t line, int32_t column, int32_t cells) {
    Info state = terminal->info();
    terminal->selectionMode = 0;
    terminal->anchor = {line, column};
    terminal->head = {line, column + greater(cells, 1) - 1};
    terminal->selecting = false;
    terminal->hasSelection = true;
    int64_t history = state.historyCount, top = history - terminal->scroll;
    if (!state.alternateScreen && (line < top || line >= top + state.rows)) {
        terminal->scroll = static_cast<int32_t>(clamped<int64_t>(history - (line - state.rows / 2), 0, history));
    }
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" void nt_select_all(nt_terminal *terminal) {
    Info state = terminal->info();
    terminal->selectionMode = 0;
    terminal->anchor = {0, 0};
    terminal->head = {static_cast<int64_t>(state.historyCount) + state.rows - 1, static_cast<int32_t>(state.columns) - 1};
    terminal->selecting = false;
    terminal->hasSelection = true;
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" void nt_clear_scrollback(nt_terminal *terminal) {
    static const uint8_t eraseSaved[] = {0x1B, '[', '3', 'J'};
    ghostty_terminal_vt_write(terminal->emulator, eraseSaved, sizeof(eraseSaved));
    terminal->scroll = 0;
    terminal->hasSelection = terminal->selecting = false;
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" void nt_set_font_size(nt_terminal *terminal, float points) {
    terminal->points = points;
    terminal->measure();
}

extern "C" void nt_reset(nt_terminal *terminal) {
    ghostty_terminal_reset(terminal->emulator);
    terminal->scroll = 0;
    terminal->hasSelection = terminal->selecting = false;
    terminal->updateTitle();
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" void nt_show_title(nt_terminal *terminal) { terminal->showTitle(); }

extern "C" int32_t nt_take_attention(nt_terminal *terminal) {
    bool attention = terminal->attention;
    terminal->attention = false;
    return attention;
}

extern "C" void nt_set_font_family(nt_terminal *terminal, const uint16_t *family) {
    if (!terminal->loadFont(reinterpret_cast<const wchar_t *>(family))) return;
    terminal->measure();
}

extern "C" void nt_set_theme(nt_terminal *terminal, uint32_t foreground, uint32_t background, uint32_t cursor, uint32_t cursorText,
                             uint32_t selection, const uint32_t *palette) {
    auto value = [](uint32_t color) { return GhosttyColorRgb{uint8_t(color >> 16), uint8_t(color >> 8), uint8_t(color)}; };
    GhosttyColorRgb fg = value(foreground <= 0xFFFFFF ? foreground : 0xCCCCCC), bg = value(background <= 0xFFFFFF ? background : 0x1E1E1E);
    ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg);
    ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg);
    GhosttyColorRgb caret = value(cursor);
    ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, cursor <= 0xFFFFFF ? &caret : nullptr);
    // the built-in palette under the theme's entries, so a theme setting sixteen colors keeps the other 240
    ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, nullptr);
    if (palette) {
        GhosttyColorRgb colors[256]{};
        ghostty_terminal_get(terminal->emulator, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, colors);
        for (int index = 0; index < 256; index++) {
            if (palette[index] <= 0xFFFFFF) colors[index] = value(palette[index]);
        }
        ghostty_terminal_set(terminal->emulator, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, colors);
    }
    terminal->cursorText = cursorText;
    terminal->selectionColor = selection <= 0xFFFFFF ? selection : 0x264F78;
    terminal->refreshColors();
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" int32_t nt_monospace_fonts(uint16_t *out, int32_t capacity) {
    Com<IDWriteFactory> dwrite;
    Com<IDWriteFontCollection> fonts;
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown **>(dwrite.put()))) ||
        FAILED(dwrite->GetSystemFontCollection(fonts.put()))) {
        return 0;
    }
    Text names;
    for (UINT32 index = 0; index < fonts->GetFontFamilyCount(); index++) {
        Com<IDWriteFontFamily> family;
        Com<IDWriteFont> font;
        Com<IDWriteFont1> described;
        Com<IDWriteLocalizedStrings> localized;
        if (FAILED(fonts->GetFontFamily(index, family.put())) ||
            FAILED(family->GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL, font.put())) ||
            FAILED(font->QueryInterface(__uuidof(IDWriteFont1), reinterpret_cast<void **>(described.put()))) ||
            !described->IsMonospacedFont() || FAILED(family->GetFamilyNames(localized.put()))) {
            continue;
        }
        UINT32 locale = 0, length = 0;
        BOOL exists = FALSE;
        if (FAILED(localized->FindLocaleName(L"en-us", &locale, &exists)) || !exists) locale = 0;
        if (FAILED(localized->GetStringLength(locale, &length))) continue;
        size_t start = names.size();
        names.resize(start + length + 1);
        if (FAILED(localized->GetString(locale, names.data() + start, length + 1))) {
            names.resize(start);
            continue;
        }
        names[start + length] = L'\n';
    }
    int32_t count = static_cast<int32_t>(names.size());
    if (out && capacity >= count && count > 0) memcpy(out, names.data(), names.size() * sizeof(wchar_t));
    return count;
}

extern "C" int32_t nt_take_notification(nt_terminal *terminal, uint16_t *title, int32_t title_capacity, int32_t *title_length,
                                        uint16_t *body, int32_t body_capacity, int32_t *body_length) {
    *title_length = give(terminal->notificationTitle, title, title_capacity);
    *body_length = give(terminal->notificationBody, body, body_capacity);
    if (!title || !body || title_capacity < *title_length || body_capacity < *body_length) return terminal->notified;
    bool notified = terminal->notified;
    terminal->notified = false;
    return notified;
}

extern "C" int32_t nt_take_naming(nt_terminal *terminal) {
    bool naming = terminal->naming;
    terminal->naming = false;
    return naming;
}

extern "C" int32_t nt_title(nt_terminal *terminal, uint16_t *out, int32_t capacity) { return give(terminal->title, out, capacity); }

extern "C" int32_t nt_pwd(nt_terminal *terminal, uint16_t *out, int32_t capacity) { return give(terminal->pwd, out, capacity); }

extern "C" void nt_dark_title_bar(void *window) {
    BOOL dark = TRUE;
    DwmSetWindowAttribute(static_cast<HWND>(window), 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof(dark));
}

extern "C" void nt_cell_at(nt_terminal *terminal, int32_t x, int32_t y, int32_t *column, int32_t *row) {
    Info state = terminal->info();
    *column = clamped((x - terminal->paddingPixels) / terminal->cellWidthPixels, 0, static_cast<int32_t>(state.columns) - 1) + 1;
    *row = clamped((y - terminal->paddingPixels) / terminal->cellHeightPixels, 0, static_cast<int32_t>(state.rows) - 1) + 1;
}

extern "C" int32_t nt_mouse_modes(nt_terminal *terminal) {
    Info state = terminal->info();
    return (state.mouseClick ? 1 : 0) | (state.mouseDrag ? 2 : 0) | (state.mouseMotion ? 4 : 0) | (state.mouseSGR ? 8 : 0) |
           (state.alternateScreen ? 16 : 0);
}

extern "C" int32_t nt_bracketed_paste(nt_terminal *terminal) {
    Info info = terminal->info();
    return info.bracketedPaste != 0;
}

// Swift's Clang and the MSVC STL accept only each other's matching versions, so the shim stays clear of the STL
#ifdef _YVALS_CORE_H_
#error "NativeShim must not include the MSVC STL"
#endif
