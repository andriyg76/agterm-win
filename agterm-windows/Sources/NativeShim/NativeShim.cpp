#include "NativeShim.h"

#define NOMINMAX
#include <windows.h>
#include <d2d1.h>
#include <dwmapi.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <cwchar>
#include <utility>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

// agwinterm-core's C ABI (native/agwinterm-core/src/lib.rs at the pinned release); a mismatch is refused at load
constexpr uint32_t coreABI = 19;
constexpr uint32_t attributeBold = 1, attributeItalic = 2, attributeUnderline = 4, attributeInverse = 8, attributeDim = 16,
                   attributeStrikethrough = 32;

struct Cell {
    int32_t rune;
    uint32_t foreground, background, attributes, width;
    uint32_t foregroundKind, foregroundIndex, foregroundRGB, backgroundKind, backgroundIndex, backgroundRGB;
};

struct Info {
    uint32_t columns, rows, cursorRow, cursorColumn, cursorVisible, alternateScreen, historyCount;
    int64_t scrollGeneration;
    uint32_t mouseClick, mouseDrag, mouseMotion, mouseSGR, mouseSGRPixels, bracketedPaste;
    int32_t keyboardFlags;
    uint32_t scrollTop, scrollBottom, markCount, focusReporting, synchronizedOutput, win32InputMode, dynamicBackground;
    int32_t cursorShape;
};

struct Core {
    uint32_t (*abiVersion)();
    void *(*create)(uint32_t, uint32_t);
    void (*free)(void *);
    bool (*feed)(void *, const uint8_t *, uint32_t);
    bool (*resize)(void *, uint32_t, uint32_t);
    uint8_t *(*takeHostActions)(void *, uint32_t *);
    bool (*info)(void *, Info *);
    bool (*setScrollback)(void *, uint32_t);
    bool (*setDefaultColors)(void *, uint32_t, uint32_t);
    bool (*copyGrid)(void *, Cell *, uint32_t);
    bool (*copyHistoryRow)(void *, uint32_t, Cell *, uint32_t);
    uint8_t *(*text)(void *, uint32_t, uint32_t *);
    void (*freeBuffer)(uint8_t *, uint32_t);
};

template <typename T> bool bind(HMODULE module, const char *name, T &function) {
    function = reinterpret_cast<T>(GetProcAddress(module, name));
    return function != nullptr;
}

bool bind(HMODULE module, Core &core) {
    return bind(module, "agwcore_abi_version", core.abiVersion) && bind(module, "agwcore_emu_new", core.create) &&
           bind(module, "agwcore_emu_free", core.free) && bind(module, "agwcore_emu_feed", core.feed) &&
           bind(module, "agwcore_emu_resize", core.resize) &&
           bind(module, "agwcore_emu_take_host_actions", core.takeHostActions) && bind(module, "agwcore_emu_info", core.info) &&
           bind(module, "agwcore_emu_set_scrollback", core.setScrollback) &&
           bind(module, "agwcore_emu_set_default_colors", core.setDefaultColors) &&
           bind(module, "agwcore_emu_copy_grid", core.copyGrid) &&
           bind(module, "agwcore_emu_copy_history_row", core.copyHistoryRow) && bind(module, "agwcore_emu_get_text", core.text) &&
           bind(module, "agwcore_free_buf", core.freeBuffer);
}

D2D1_COLOR_F color(uint32_t rgb) { return D2D1::ColorF(rgb); }

uint32_t blend(uint32_t a, uint32_t b) {
    uint32_t result = 0;
    for (int shift = 0; shift <= 16; shift += 8) result |= ((((a >> shift) & 0xFF) + ((b >> shift) & 0xFF)) / 2) << shift;
    return result;
}

ComPtr<IDWriteFontFace> face(IDWriteFontCollection *fonts, const wchar_t *family, DWRITE_FONT_WEIGHT weight,
                             DWRITE_FONT_STYLE style) {
    UINT32 index = 0;
    BOOL exists = FALSE;
    ComPtr<IDWriteFontFamily> fontFamily;
    ComPtr<IDWriteFont> font;
    ComPtr<IDWriteFontFace> result;
    if (FAILED(fonts->FindFamilyName(family, &index, &exists)) || !exists || FAILED(fonts->GetFontFamily(index, &fontFamily)) ||
        FAILED(fontFamily->GetFirstMatchingFont(weight, DWRITE_FONT_STRETCH_NORMAL, style, &font)) ||
        FAILED(font->CreateFontFace(&result))) {
        return nullptr;
    }
    return result;
}

std::wstring widen(const uint8_t *bytes, uint32_t length) {
    int count = MultiByteToWideChar(CP_UTF8, 0, reinterpret_cast<const char *>(bytes), static_cast<int>(length), nullptr, 0);
    std::wstring text(count, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, reinterpret_cast<const char *>(bytes), static_cast<int>(length), text.data(), count);
    return text;
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

bool wordCharacter(int32_t rune) {
    if (rune <= ' ') return false;
    static const wchar_t *delimiters = L"()[]{}<>'\"`|,;";
    return rune > 0xFFFF || !std::wcschr(delimiters, static_cast<wchar_t>(rune));
}

}  // namespace

struct nt_terminal {
    HWND window = nullptr;
    HMODULE module = nullptr;
    Core core{};
    void *emulator = nullptr;
    ComPtr<ID2D1Factory> d2d;
    ComPtr<IDWriteFactory> dwrite;
    ComPtr<ID2D1HwndRenderTarget> target;
    ComPtr<ID2D1SolidColorBrush> brush;
    ComPtr<IDWriteFontFace> faces[4];  // regular, bold, italic, bold italic
    ComPtr<IDWriteTextFormat> fallback;
    std::wstring family;
    float points = 11;
    float dpi = 96;
    float emSize = 0, cellWidth = 0, cellHeight = 0, baseline = 0;  // DIPs, cell edges on whole pixels
    int32_t cellWidthPixels = 1, cellHeightPixels = 1, paddingPixels = 4;
    uint32_t columns = 80, rows = 24;
    int32_t scroll = 0;
    bool focused = true;
    bool applicationCursor = false;
    uint32_t selectionColor = 0x264F78;
    bool selecting = false, hasSelection = false;
    int32_t selectionMode = 0;  // 0 cells, 1 words, 2 lines
    Point anchor{}, head{};
    std::pair<Point, Point> paintSpan{};  // range() once per frame, not per row
    uint32_t foreground = 0xCCCCCC, background = 0x1E1E1E;
    std::vector<Cell> grid, history;
    std::wstring title;
    std::vector<UINT16> glyphs;
    std::vector<FLOAT> advances;

    float scale() const { return dpi / 96.f; }

    Info info() const {
        Info result{};
        core.info(emulator, &result);
        return result;
    }

    void rowCells(const Info &state, int64_t line, std::vector<Cell> &out) const {
        out.resize(state.columns);
        if (line < static_cast<int64_t>(state.historyCount)) {
            core.copyHistoryRow(emulator, static_cast<uint32_t>(line), out.data(), state.columns);
        } else {
            std::vector<Cell> all(static_cast<size_t>(state.columns) * state.rows);
            core.copyGrid(emulator, all.data(), static_cast<uint32_t>(all.size()));
            size_t row = static_cast<size_t>(std::clamp<int64_t>(line - state.historyCount, 0, state.rows - 1));
            std::copy_n(all.begin() + row * state.columns, state.columns, out.begin());
        }
    }

    Point point(int32_t x, int32_t y) const {
        Info state = info();
        int32_t column = std::clamp((x - paddingPixels) / cellWidthPixels, 0, static_cast<int32_t>(state.columns) - 1);
        int32_t row = std::clamp((y - paddingPixels) / cellHeightPixels, 0, static_cast<int32_t>(state.rows) - 1);
        return {static_cast<int64_t>(state.historyCount) - scroll + row, column};
    }

    // range is the selection in reading order, widened to whole words or lines
    std::pair<Point, Point> range() const {
        Point start = std::min(anchor, head), end = std::max(anchor, head);
        if (selectionMode == 2) return {{start.line, 0}, {end.line, INT32_MAX}};
        if (selectionMode == 1) {
            Info state = info();
            std::vector<Cell> cells;
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

    bool selected(const std::pair<Point, Point> &span, int64_t line, uint32_t column) const {
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
        cellWidthPixels = std::max(1L, std::lround(glyphMetrics.advanceWidth * units * scale()));
        cellHeightPixels = std::max(1, static_cast<int32_t>(std::ceil((metrics.ascent + metrics.descent + metrics.lineGap) * units * scale())));
        paddingPixels = static_cast<int32_t>(std::lround(4 * scale()));
        cellWidth = cellWidthPixels / scale();
        cellHeight = cellHeightPixels / scale();
        baseline = std::round((metrics.lineGap / 2.f + metrics.ascent) * units * scale()) / scale();
        fallback.Reset();
        dwrite->CreateTextFormat(family.c_str(), nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                                 DWRITE_FONT_STRETCH_NORMAL, emSize, L"", &fallback);
        if (fallback) fallback->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    }

    bool ensureTarget() {
        if (target) return true;
        RECT client;
        GetClientRect(window, &client);
        auto properties = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(), dpi, dpi);
        auto hwnd = D2D1::HwndRenderTargetProperties(window, D2D1::SizeU(client.right - client.left, client.bottom - client.top));
        if (FAILED(d2d->CreateHwndRenderTarget(properties, hwnd, &target))) return false;
        target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
        target->CreateSolidColorBrush(color(foreground), &brush);
        return true;
    }

    Style style(const Cell &cell) const {
        // a default-colored cell takes this window's colors, whatever the core resolved it to
        uint32_t fg = cell.foregroundKind == 0 ? foreground : cell.foreground;
        uint32_t bg = cell.backgroundKind == 0 ? background : cell.background;
        if (cell.attributes & attributeInverse) std::swap(fg, bg);
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
            float left = x + column * cellWidth, span = std::max<uint32_t>(cell.width, 1) * cellWidth;
            UINT32 codepoint = cell.rune > 0 ? static_cast<UINT32>(cell.rune) : ' ';
            UINT16 glyph = 0;
            faces[s.face]->GetGlyphIndices(&codepoint, 1, &glyph);
            if (!glyphs.empty() && (faces[s.face].Get() != runFace || fg != runColor)) flush(runFace, runX, y, runColor);
            if (glyph == 0 && codepoint != ' ') {
                flush(runFace, runX, y, runColor);
                drawFallback(codepoint, left, y, span, fg);
            } else {
                if (glyphs.empty()) {
                    runFace = faces[s.face].Get();
                    runColor = fg;
                    runX = left;
                }
                glyphs.push_back(glyph);
                advances.push_back(span);
            }
            float line = 1 / scale();
            if (s.attributes & attributeUnderline) fill(left, y + baseline + line, left + span, y + baseline + 2 * line, fg);
            if (s.attributes & attributeStrikethrough) fill(left, y + cellHeight / 2, left + span, y + cellHeight / 2 + line, fg);
        }
        flush(runFace, runX, y, runColor);
    }

    // drawFallback lets DirectWrite pick a font for a codepoint the terminal font lacks (emoji, most CJK)
    void drawFallback(UINT32 codepoint, float left, float y, float span, uint32_t rgb) {
        if (!fallback) return;
        wchar_t text[2];
        UINT32 length = 1;
        if (codepoint > 0xFFFF) {
            codepoint -= 0x10000;
            text[0] = static_cast<wchar_t>(0xD800 + (codepoint >> 10));
            text[1] = static_cast<wchar_t>(0xDC00 + (codepoint & 0x3FF));
            length = 2;
        } else {
            text[0] = static_cast<wchar_t>(codepoint);
        }
        brush->SetColor(color(rgb));
        target->DrawText(text, length, fallback.Get(), D2D1::RectF(left, y, left + span, y + cellHeight), brush.Get(),
                         D2D1_DRAW_TEXT_OPTIONS_CLIP | D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
    }

    void updateTitle() {
        uint32_t length = 0;
        uint8_t *bytes = core.text(emulator, 0, &length);
        std::wstring next = bytes ? widen(bytes, length) : std::wstring();
        if (bytes) core.freeBuffer(bytes, length);
        if (next == title) return;
        title = next;
        if (IsWindowVisible(window)) showTitle();
    }

    // the window's title is the shown terminal's; a hidden one keeps its title until it is shown
    void showTitle() const { SetWindowTextW(GetAncestor(window, GA_ROOT), title.empty() ? L"agterm" : title.c_str()); }
};

extern "C" void nt_init_process(void) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    // uxtheme's unnamed SetPreferredAppMode (ordinal 135) is the only switch that makes popup menus dark; it is the
    // one Explorer and Notepad use, and a build without it just keeps light menus
    if (HMODULE theme = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32)) {
        using SetMode = int(WINAPI *)(int);
        if (auto setMode = reinterpret_cast<SetMode>(GetProcAddress(theme, MAKEINTRESOURCEA(135)))) setMode(2 /* ForceDark */);
    }
}

extern "C" nt_terminal *nt_create(void *window, const uint16_t *core_path, const uint16_t *font, float points, uint16_t *error,
                                  int32_t error_capacity) {
    auto fail = [&](const std::wstring &reason, nt_terminal *partial) -> nt_terminal * {
        if (error && error_capacity > 0) {
            size_t count = std::min<size_t>(reason.size(), static_cast<size_t>(error_capacity - 1));
            std::memcpy(error, reason.data(), count * sizeof(wchar_t));
            error[count] = 0;
        }
        nt_destroy(partial);
        return nullptr;
    };
    auto path = reinterpret_cast<const wchar_t *>(core_path);
    auto terminal = new nt_terminal();
    terminal->window = static_cast<HWND>(window);
    terminal->module = LoadLibraryW(path);
    if (!terminal->module) return fail(std::wstring(L"LoadLibraryW(") + path + L") failed: " + std::to_wstring(GetLastError()), terminal);
    if (!bind(terminal->module, terminal->core)) return fail(std::wstring(path) + L" lacks an agwcore export this build calls", terminal);
    if (uint32_t abi = terminal->core.abiVersion(); abi != coreABI) {
        return fail(std::wstring(path) + L" is core ABI " + std::to_wstring(abi) + L", this build needs " + std::to_wstring(coreABI), terminal);
    }
    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, terminal->d2d.GetAddressOf())) ||
        FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                   reinterpret_cast<IUnknown **>(terminal->dwrite.GetAddressOf())))) {
        return fail(L"Direct2D or DirectWrite did not start", terminal);
    }
    ComPtr<IDWriteFontCollection> fonts;
    terminal->dwrite->GetSystemFontCollection(&fonts);
    for (const wchar_t *family : {reinterpret_cast<const wchar_t *>(font), L"Cascadia Mono", L"Consolas"}) {
        if (!family || !(terminal->faces[0] = face(fonts.Get(), family, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL))) continue;
        terminal->family = family;
        terminal->faces[1] = face(fonts.Get(), family, DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_NORMAL);
        terminal->faces[2] = face(fonts.Get(), family, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_ITALIC);
        terminal->faces[3] = face(fonts.Get(), family, DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_ITALIC);
        break;
    }
    if (!terminal->faces[0]) return fail(L"no monospace font found", terminal);
    terminal->points = points;
    terminal->dpi = static_cast<float>(GetDpiForWindow(terminal->window));
    terminal->measure();
    terminal->emulator = terminal->core.create(terminal->columns, terminal->rows);
    if (!terminal->emulator) return fail(L"agwcore_emu_new failed", terminal);
    terminal->core.setDefaultColors(terminal->emulator, terminal->foreground, terminal->background);
    terminal->core.setScrollback(terminal->emulator, 10000);
    return terminal;
}

extern "C" void nt_destroy(nt_terminal *terminal) {
    if (!terminal) return;
    if (terminal->emulator) terminal->core.free(terminal->emulator);
    terminal->brush.Reset();
    terminal->target.Reset();
    for (auto &face : terminal->faces) face.Reset();
    terminal->fallback.Reset();
    terminal->dwrite.Reset();
    terminal->d2d.Reset();
    if (terminal->module) FreeLibrary(terminal->module);
    delete terminal;
}

extern "C" void nt_resize(nt_terminal *terminal, int32_t width, int32_t height, int32_t *columns, int32_t *rows) {
    if (terminal->target) terminal->target->Resize(D2D1::SizeU(std::max(width, 1), std::max(height, 1)));
    uint32_t nextColumns = static_cast<uint32_t>(std::max(1, (width - 2 * terminal->paddingPixels) / terminal->cellWidthPixels));
    uint32_t nextRows = static_cast<uint32_t>(std::max(1, (height - 2 * terminal->paddingPixels) / terminal->cellHeightPixels));
    if (nextColumns != terminal->columns || nextRows != terminal->rows) {
        terminal->columns = nextColumns;
        terminal->rows = nextRows;
        terminal->core.resize(terminal->emulator, nextColumns, nextRows);
    }
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
    terminal->core.feed(terminal->emulator, bytes, length);
    uint32_t size = 0;
    if (uint8_t *actions = terminal->core.takeHostActions(terminal->emulator, &size)) {
        // u32 count, then records of u8 kind + payload; str = u32 length + UTF-8 (lib.rs, agwcore_emu_take_host_actions)
        uint32_t at = 0;
        auto u32 = [&]() -> uint32_t {
            uint32_t value = 0;
            if (at + 4 <= size) std::memcpy(&value, actions + at, 4);
            at += 4;
            return value;
        };
        auto string = [&]() -> std::string {
            uint32_t length = u32();
            std::string text = at + length <= size ? std::string(reinterpret_cast<const char *>(actions + at), length) : std::string();
            at += length;
            return text;
        };
        auto skipString = [&]() { at += u32(); };
        uint32_t count = u32();
        for (uint32_t index = 0; index < count && at < size; index++) {
            uint8_t kind = actions[at++];
            if (kind == 1) {
                skipString();
                skipString();
            } else if (kind == 5) {
                // the core leaves DECCKM (?1) to the host, which owns key encoding
                std::string what = string(), detail = string();
                if (what == "MODE" && (detail == "?1 h" || detail == "?1 l")) terminal->applicationCursor = detail.back() == 'h';
            } else if (kind == 2) {
                at += 8;
            } else if (kind == 3) {
                skipString();
            } else if (kind == 4) {
                uint32_t replyLength = u32();
                if (at + replyLength <= size && reply) reply(context, actions + at, replyLength);
                at += replyLength;
            } else if (kind != 6) {
                break;
            }
        }
        terminal->core.freeBuffer(actions, size);
    }
    terminal->updateTitle();
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" void nt_paint(nt_terminal *terminal) {
    PAINTSTRUCT paint;
    BeginPaint(terminal->window, &paint);
    EndPaint(terminal->window, &paint);
    if (!terminal->ensureTarget()) return;
    Info info{};
    terminal->core.info(terminal->emulator, &info);
    uint32_t columns = info.columns, rows = info.rows;
    terminal->grid.resize(static_cast<size_t>(columns) * rows);
    terminal->history.resize(columns);
    terminal->core.copyGrid(terminal->emulator, terminal->grid.data(), static_cast<uint32_t>(terminal->grid.size()));
    int32_t scroll = info.alternateScreen ? 0 : std::min(terminal->scroll, static_cast<int32_t>(info.historyCount));
    terminal->scroll = scroll;

    auto target = terminal->target;
    target->BeginDraw();
    target->Clear(color(terminal->background));
    float origin = terminal->paddingPixels / terminal->scale();
    if (terminal->hasSelection) terminal->paintSpan = terminal->range();
    for (uint32_t row = 0; row < rows; row++) {
        int64_t line = static_cast<int64_t>(info.historyCount) - scroll + row;
        const Cell *cells = nullptr;
        if (line < static_cast<int64_t>(info.historyCount)) {
            terminal->core.copyHistoryRow(terminal->emulator, static_cast<uint32_t>(line), terminal->history.data(), columns);
            cells = terminal->history.data();
        } else {
            cells = &terminal->grid[static_cast<size_t>(line - info.historyCount) * columns];
        }
        terminal->drawRow(cells, columns, origin, origin + row * terminal->cellHeight, nullptr, line);
    }
    if (scroll == 0 && info.cursorVisible && info.cursorRow < rows && columns > 0) {
        uint32_t column = std::min(info.cursorColumn, columns - 1);
        const Cell *cell = &terminal->grid[static_cast<size_t>(info.cursorRow) * columns + column];
        if (cell->width == 0 && column > 0) {
            column--;
            cell--;
        }
        float left = origin + column * terminal->cellWidth, top = origin + info.cursorRow * terminal->cellHeight;
        float right = left + std::max<uint32_t>(cell->width, 1) * terminal->cellWidth, bottom = top + terminal->cellHeight;
        if (terminal->focused) {
            terminal->fill(left, top, right, bottom, terminal->foreground);
            terminal->drawRow(cell, 1, left, top, &terminal->background);
        } else {
            terminal->brush->SetColor(color(terminal->foreground));
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
    Info info{};
    terminal->core.info(terminal->emulator, &info);
    terminal->scroll = std::clamp(terminal->scroll + lines, 0, info.alternateScreen ? 0 : static_cast<int32_t>(info.historyCount));
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

extern "C" int32_t nt_application_cursor(nt_terminal *terminal) { return terminal->applicationCursor; }

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

// rowText is cells first...last as UTF-16, wide-character tails skipped and trailing blanks dropped
std::wstring rowText(const std::vector<Cell> &cells, int32_t first, int32_t last) {
    std::wstring row;
    for (int32_t column = first; column <= last; column++) {
        const Cell &cell = cells[column];
        if (cell.width == 0) continue;
        uint32_t rune = cell.rune > 0 ? static_cast<uint32_t>(cell.rune) : ' ';
        if (rune > 0xFFFF) {
            rune -= 0x10000;
            row += static_cast<wchar_t>(0xD800 + (rune >> 10));
            row += static_cast<wchar_t>(0xDC00 + (rune & 0x3FF));
        } else {
            row += static_cast<wchar_t>(rune);
        }
    }
    size_t end = row.find_last_not_of(L' ');
    row.erase(end == std::wstring::npos ? 0 : end + 1);
    return row;
}

int32_t give(const std::wstring &text, uint16_t *out, int32_t capacity) {
    int32_t length = static_cast<int32_t>(text.size());
    if (out && capacity >= length) std::memcpy(out, text.data(), text.size() * sizeof(wchar_t));
    return length;
}

}  // namespace

extern "C" int32_t nt_selection_text(nt_terminal *terminal, uint16_t *out, int32_t capacity) {
    if (!terminal->hasSelection) return 0;
    Info state = terminal->info();
    auto [start, end] = terminal->range();
    std::wstring text;
    std::vector<Cell> cells;
    for (int64_t line = start.line; line <= end.line; line++) {
        terminal->rowCells(state, line, cells);
        int32_t first = line == start.line ? start.column : 0;
        int32_t last = std::min<int32_t>(line == end.line ? end.column : INT32_MAX, static_cast<int32_t>(cells.size()) - 1);
        text += rowText(cells, first, last);
        if (line < end.line) text += L"\r\n";
    }
    return give(text, out, capacity);
}

extern "C" int32_t nt_screen_text(nt_terminal *terminal, uint16_t *out, int32_t capacity) {
    Info state = terminal->info();
    std::wstring text;
    std::vector<Cell> cells(state.columns);
    for (uint32_t line = 0; line < state.historyCount; line++) {
        terminal->core.copyHistoryRow(terminal->emulator, line, cells.data(), state.columns);
        text += rowText(cells, 0, static_cast<int32_t>(state.columns) - 1) + L"\n";
    }
    std::vector<Cell> grid(static_cast<size_t>(state.columns) * state.rows);
    terminal->core.copyGrid(terminal->emulator, grid.data(), static_cast<uint32_t>(grid.size()));
    for (uint32_t row = 0; row < state.rows; row++) {
        std::copy_n(grid.begin() + static_cast<size_t>(row) * state.columns, state.columns, cells.begin());
        text += rowText(cells, 0, static_cast<int32_t>(state.columns) - 1) + L"\n";
    }
    return give(text, out, capacity);
}

extern "C" int32_t nt_row_runes(nt_terminal *terminal, int32_t x, int32_t y, uint32_t *runes, int32_t capacity, int32_t *column) {
    Info state = terminal->info();
    Point at = terminal->point(x, y);
    std::vector<Cell> cells;
    terminal->rowCells(state, at.line, cells);
    *column = at.column;
    int32_t count = static_cast<int32_t>(cells.size());
    for (int32_t i = 0; i < std::min(count, capacity); i++) {
        runes[i] = cells[i].width == 0 ? UINT32_MAX : static_cast<uint32_t>(std::max(cells[i].rune, 0));
    }
    return count;
}

extern "C" int32_t nt_line_count(nt_terminal *terminal) {
    Info state = terminal->info();
    return static_cast<int32_t>(state.historyCount + state.rows);
}

extern "C" int32_t nt_line_runes(nt_terminal *terminal, int32_t line, uint32_t *runes, int32_t capacity) {
    Info state = terminal->info();
    std::vector<Cell> cells;
    terminal->rowCells(state, line, cells);
    int32_t count = static_cast<int32_t>(cells.size());
    for (int32_t i = 0; i < std::min(count, capacity); i++) {
        runes[i] = cells[i].width == 0 ? UINT32_MAX : static_cast<uint32_t>(std::max(cells[i].rune, 0));
    }
    return count;
}

extern "C" void nt_select_cells(nt_terminal *terminal, int32_t line, int32_t column, int32_t cells) {
    Info state = terminal->info();
    terminal->selectionMode = 0;
    terminal->anchor = {line, column};
    terminal->head = {line, column + std::max(cells, 1) - 1};
    terminal->selecting = false;
    terminal->hasSelection = true;
    int64_t history = state.historyCount, top = history - terminal->scroll;
    if (!state.alternateScreen && (line < top || line >= top + state.rows)) {
        terminal->scroll = static_cast<int32_t>(std::clamp<int64_t>(history - (line - state.rows / 2), 0, history));
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
    terminal->core.feed(terminal->emulator, eraseSaved, sizeof(eraseSaved));
    terminal->scroll = 0;
    terminal->hasSelection = terminal->selecting = false;
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" void nt_set_font_size(nt_terminal *terminal, float points) {
    terminal->points = points;
    terminal->measure();
}

extern "C" void nt_reset(nt_terminal *terminal) {
    void *fresh = terminal->core.create(terminal->columns, terminal->rows);
    if (!fresh) return;
    terminal->core.free(terminal->emulator);
    terminal->emulator = fresh;
    terminal->core.setDefaultColors(fresh, terminal->foreground, terminal->background);
    terminal->core.setScrollback(fresh, 10000);
    terminal->scroll = 0;
    terminal->applicationCursor = false;
    terminal->hasSelection = terminal->selecting = false;
    InvalidateRect(terminal->window, nullptr, FALSE);
}

extern "C" void nt_show_title(nt_terminal *terminal) { terminal->showTitle(); }

extern "C" void nt_dark_title_bar(void *window) {
    BOOL dark = TRUE;
    DwmSetWindowAttribute(static_cast<HWND>(window), 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof(dark));
}

extern "C" void nt_cell_at(nt_terminal *terminal, int32_t x, int32_t y, int32_t *column, int32_t *row) {
    Info state = terminal->info();
    *column = std::clamp((x - terminal->paddingPixels) / terminal->cellWidthPixels, 0, static_cast<int32_t>(state.columns) - 1) + 1;
    *row = std::clamp((y - terminal->paddingPixels) / terminal->cellHeightPixels, 0, static_cast<int32_t>(state.rows) - 1) + 1;
}

extern "C" int32_t nt_mouse_modes(nt_terminal *terminal) {
    Info state = terminal->info();
    return (state.mouseClick ? 1 : 0) | (state.mouseDrag ? 2 : 0) | (state.mouseMotion ? 4 : 0) | (state.mouseSGR ? 8 : 0) |
           (state.alternateScreen ? 16 : 0);
}

extern "C" int32_t nt_bracketed_paste(nt_terminal *terminal) {
    Info info{};
    terminal->core.info(terminal->emulator, &info);
    return info.bracketedPaste != 0;
}
