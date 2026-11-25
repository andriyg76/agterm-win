#include "NativeShim.h"
#include "NativeChrome.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <uxtheme.h>

#include <string.h>
#include <wchar.h>

namespace {

constexpr int visibleRows = 10;
constexpr UINT_PTR keysSubclass = 2;  // above the find bar's own, which is 1

struct Row {
    wchar_t *title, *subtitle, *detail;
    bool enabled;
};

struct Palette {
    HWND panel = nullptr, edit = nullptr, list = nullptr;
    uint32_t dpi = 96;
    HFONT font = nullptr, small = nullptr;
    HBRUSH brush = nullptr;
    Row *rows = nullptr;
    int32_t count = 0;
    int32_t left = 0, top = 0, width = 0;
};

int scaled(const Palette *palette, int value) { return MulDiv(value, static_cast<int>(palette->dpi), 96); }

Palette *of(HWND panel) { return reinterpret_cast<Palette *>(GetWindowLongPtrW(panel, GWLP_USERDATA)); }

wchar_t *copy(const uint16_t *source) {
    const wchar_t *from = source ? reinterpret_cast<const wchar_t *>(source) : L"";
    size_t length = wcslen(from);
    auto out = new wchar_t[length + 1];
    memcpy(out, from, (length + 1) * sizeof(wchar_t));
    return out;
}

void freeRows(Palette *palette) {
    for (int32_t i = 0; i < palette->count; ++i) {
        delete[] palette->rows[i].title;
        delete[] palette->rows[i].subtitle;
        delete[] palette->rows[i].detail;
    }
    delete[] palette->rows;
    palette->rows = nullptr;
    palette->count = 0;
}

void loadFonts(Palette *palette) {
    if (palette->font) DeleteObject(palette->font);
    if (palette->small) DeleteObject(palette->small);
    auto make = [palette](int points) {
        return CreateFontW(-MulDiv(points, static_cast<int>(palette->dpi), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                           OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    };
    palette->font = make(10);
    palette->small = make(9);
}

int rowHeight(const Palette *palette) { return scaled(palette, 30); }

// layout sizes the panel to its rows: the field, then up to ten rows, the list hidden while nothing matches.
void layout(Palette *palette) {
    int pad = scaled(palette, 8), field = scaled(palette, 28), gap = scaled(palette, 6);
    int shown = palette->count < visibleRows ? palette->count : visibleRows;
    int inner = palette->width - 2 * pad;
    MoveWindow(palette->edit, pad, pad, inner, field, TRUE);
    int listTop = pad + field + gap;
    MoveWindow(palette->list, pad, listTop, inner, shown * rowHeight(palette), TRUE);
    ShowWindow(palette->list, shown > 0 ? SW_SHOWNA : SW_HIDE);
    int height = shown > 0 ? listTop + shown * rowHeight(palette) + pad : pad + field + pad;
    SetWindowPos(palette->panel, HWND_TOP, palette->left, palette->top, palette->width, height, SWP_NOACTIVATE);
}

void select(Palette *palette, int32_t index) {
    if (palette->count == 0) return;
    if (index < 0) index = 0;
    if (index >= palette->count) index = palette->count - 1;
    SendMessageW(palette->list, LB_SETCURSEL, static_cast<WPARAM>(index), 0);
}

void drawRow(Palette *palette, const DRAWITEMSTRUCT *item) {
    if (item->itemID == static_cast<UINT>(-1) || static_cast<int32_t>(item->itemID) >= palette->count) return;
    const Row &row = palette->rows[item->itemID];
    HDC dc = item->hDC;
    RECT rect = item->rcItem;
    bool lit = (item->itemState & ODS_SELECTED) != 0;
    HBRUSH fill = CreateSolidBrush(lit ? nt_chrome_pal_sel() : nt_chrome_pal_bg());
    FillRect(dc, &rect, fill);
    DeleteObject(fill);
    SetBkMode(dc, TRANSPARENT);
    int pad = scaled(palette, 10), gap = scaled(palette, 12);

    HGDIOBJ previous = SelectObject(dc, palette->small);
    RECT detail = rect;
    detail.right -= pad;
    DrawTextW(dc, row.detail, -1, &detail, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
    int detailWidth = detail.right - detail.left;
    detail = rect;
    detail.left = rect.right - pad - detailWidth;
    detail.right = rect.right - pad;
    SetTextColor(dc, lit ? nt_chrome_pal_text() : nt_chrome_pal_dim());
    DrawTextW(dc, row.detail, -1, &detail, DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);

    int end = (detailWidth > 0 ? detail.left - gap : rect.right - pad);
    SelectObject(dc, palette->font);
    RECT title = rect;
    title.left += pad;
    title.right = end;
    DrawTextW(dc, row.title, -1, &title, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
    if (title.right > end) title.right = end;
    title.top = rect.top;
    title.bottom = rect.bottom;
    SetTextColor(dc, row.enabled ? nt_chrome_pal_text() : nt_chrome_pal_disabled());
    DrawTextW(dc, row.title, -1, &title, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);

    if (row.subtitle[0] && title.right + gap < end) {
        SelectObject(dc, palette->small);
        RECT subtitle{title.right + gap, rect.top, end, rect.bottom};
        SetTextColor(dc, lit ? nt_chrome_pal_text() : nt_chrome_pal_dim());
        DrawTextW(dc, row.subtitle, -1, &subtitle, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
    }
    SelectObject(dc, previous);
}

// keysProcedure gives the field the palette's keys: the arrows, Page Up/Down and Ctrl+J/K move the highlight, and
// leaving the panel closes it. Enter and Esc arrive from the find bar's own subclass as NT_FIND_NEXT/NT_FIND_CLOSE.
LRESULT CALLBACK keysProcedure(HWND edit, UINT message, WPARAM wParam, LPARAM lParam, UINT_PTR, DWORD_PTR data) {
    auto palette = reinterpret_cast<Palette *>(data);
    if (message == WM_KEYDOWN) {
        bool control = GetKeyState(VK_CONTROL) < 0;
        int delta = 0;
        if (wParam == VK_DOWN || (control && wParam == 'J')) delta = 1;
        if (wParam == VK_UP || (control && wParam == 'K')) delta = -1;
        if (wParam == VK_NEXT) delta = visibleRows;
        if (wParam == VK_PRIOR) delta = -visibleRows;
        if (delta != 0) {
            auto current = static_cast<int32_t>(SendMessageW(palette->list, LB_GETCURSEL, 0, 0));
            select(palette, (current < 0 ? 0 : current) + delta);
            return 0;
        }
    }
    // Ctrl+J and Ctrl+K type line feed and vertical tab
    if (message == WM_CHAR && (wParam == 0x0A || wParam == 0x0B)) return 0;
    if (message == WM_KILLFOCUS) PostMessageW(palette->panel, NT_FIND_CLOSE, 1, 0);
    if (message == WM_NCDESTROY) RemoveWindowSubclass(edit, keysProcedure, keysSubclass);
    return DefSubclassProc(edit, message, wParam, lParam);
}

LRESULT CALLBACK panelProcedure(HWND panel, UINT message, WPARAM wParam, LPARAM lParam) {
    Palette *palette = of(panel);
    if (!palette) return DefWindowProcW(panel, message, wParam, lParam);
    HWND owner = GetParent(panel);
    switch (message) {
    case WM_COMMAND:
        if (reinterpret_cast<HWND>(lParam) == palette->edit && HIWORD(wParam) == EN_CHANGE) {
            PostMessageW(owner, NT_PALETTE_QUERY, 0, 0);
        } else if (reinterpret_cast<HWND>(lParam) == palette->list && HIWORD(wParam) == LBN_SELCHANGE) {
            // only a click changes the list's selection itself; the keys set it through LB_SETCURSEL, which is silent
            SetFocus(palette->edit);
            PostMessageW(owner, NT_PALETTE_RUN, SendMessageW(palette->list, LB_GETCURSEL, 0, 0), 0);
        }
        return 0;
    case NT_FIND_NEXT:
        PostMessageW(owner, NT_PALETTE_RUN, SendMessageW(palette->list, LB_GETCURSEL, 0, 0), 0);
        return 0;
    case NT_FIND_CLOSE: {
        // wParam 1: the field lost focus. Where focus is now decides, not where it went then: a click on a row moves
        // it to the list and back, and a palette reopened since then holds it again.
        if (wParam == 1) {
            HWND focus = GetFocus();
            if (!IsWindowVisible(panel) || focus == palette->edit || focus == palette->list) return 0;
        }
        // Esc's close (0) gives focus back to the terminal; a click elsewhere (1) leaves it where it went
        PostMessageW(owner, NT_PALETTE_CLOSE, wParam == 1 ? 1 : 0, 0);
        return 0;
    }
    case WM_CTLCOLOREDIT:
        SetTextColor(reinterpret_cast<HDC>(wParam), nt_chrome_pal_text());
        SetBkColor(reinterpret_cast<HDC>(wParam), nt_chrome_pal_bg());
        return reinterpret_cast<LRESULT>(palette->brush);
    case WM_CTLCOLORLISTBOX:
        return reinterpret_cast<LRESULT>(palette->brush);
    case WM_MEASUREITEM:
        reinterpret_cast<MEASUREITEMSTRUCT *>(lParam)->itemHeight = static_cast<UINT>(rowHeight(palette));
        return TRUE;
    case WM_DRAWITEM:
        drawRow(palette, reinterpret_cast<const DRAWITEMSTRUCT *>(lParam));
        return TRUE;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(panel, &paint);
        RECT rect;
        GetClientRect(panel, &rect);
        FillRect(dc, &rect, palette->brush);
        HBRUSH frame = CreateSolidBrush(nt_chrome_pal_border());
        FrameRect(dc, &rect, frame);
        DeleteObject(frame);
        EndPaint(panel, &paint);
        return 0;
    }
    case WM_NCDESTROY:
        freeRows(palette);
        DeleteObject(palette->font);
        DeleteObject(palette->small);
        DeleteObject(palette->brush);
        delete palette;
        SetWindowLongPtrW(panel, GWLP_USERDATA, 0);
        return 0;
    default:
        return DefWindowProcW(panel, message, wParam, lParam);
    }
}

}  // namespace

extern "C" void *nt_palette_create(void *parent, uint32_t dpi) {
    WNDCLASSEXW windowClass{sizeof(windowClass)};
    windowClass.lpfnWndProc = panelProcedure;
    windowClass.hInstance = GetModuleHandleW(nullptr);
    windowClass.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));  // IDC_ARROW, which is narrow without UNICODE
    windowClass.lpszClassName = L"agterm-palette";
    RegisterClassExW(&windowClass);
    HWND panel = CreateWindowExW(0, L"agterm-palette", L"", WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS, 0, 0, 10, 10,
                                 static_cast<HWND>(parent), nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!panel) return nullptr;
    auto palette = new Palette;
    palette->panel = panel;
    palette->dpi = dpi;
    palette->brush = CreateSolidBrush(nt_chrome_pal_bg());
    loadFonts(palette);
    SetWindowLongPtrW(panel, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(palette));
    // the find bar's field, so the two look and type alike
    palette->edit = static_cast<HWND>(nt_find_bar_create(panel, dpi));
    if (!palette->edit) {
        DestroyWindow(panel);
        return nullptr;
    }
    ShowWindow(palette->edit, SW_SHOW);
    SetWindowSubclass(palette->edit, keysProcedure, keysSubclass, reinterpret_cast<DWORD_PTR>(palette));
    palette->list = CreateWindowExW(0, L"LISTBOX", L"", WS_CHILD | WS_VSCROLL | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | LBS_NOTIFY |
                                        LBS_NOINTEGRALHEIGHT, 0, 0, 10, 10, panel, nullptr, GetModuleHandleW(nullptr), nullptr);
    SetWindowTheme(palette->list, nt_chrome_is_dark() ? L"DarkMode_Explorer" : L"Explorer", nullptr);
    return panel;
}

extern "C" void nt_palette_set_dpi(void *panel, uint32_t dpi) {
    Palette *palette = of(static_cast<HWND>(panel));
    if (!palette) return;
    palette->dpi = dpi;
    loadFonts(palette);
    nt_find_bar_set_dpi(palette->edit, dpi);
    SendMessageW(palette->list, LB_SETITEMHEIGHT, 0, rowHeight(palette));
    layout(palette);
}

extern "C" void nt_palette_open(void *panel, const uint16_t *cue, int32_t left, int32_t top, int32_t width) {
    Palette *palette = of(static_cast<HWND>(panel));
    if (!palette) return;
    SendMessageW(palette->edit, EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(cue));
    SetWindowTextW(palette->edit, L"");
    nt_palette_place(panel, left, top, width);
    ShowWindow(palette->panel, SW_SHOW);
    SetFocus(palette->edit);
}

extern "C" void nt_palette_place(void *panel, int32_t left, int32_t top, int32_t width) {
    Palette *palette = of(static_cast<HWND>(panel));
    if (!palette) return;
    palette->left = left;
    palette->top = top;
    palette->width = width;
    layout(palette);
}

extern "C" void nt_palette_set_rows(void *panel, const nt_palette_row *rows, int32_t count, int32_t selection) {
    Palette *palette = of(static_cast<HWND>(panel));
    if (!palette) return;
    SendMessageW(palette->list, WM_SETREDRAW, FALSE, 0);
    SendMessageW(palette->list, LB_RESETCONTENT, 0, 0);
    freeRows(palette);
    palette->rows = count > 0 ? new Row[count] : nullptr;
    for (int32_t i = 0; i < count; ++i) {
        palette->rows[i] = {copy(rows[i].title), copy(rows[i].subtitle), copy(rows[i].detail), rows[i].enabled != 0};
        SendMessageW(palette->list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(palette->rows[i].title));
    }
    palette->count = count;
    select(palette, selection);
    SendMessageW(palette->list, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(palette->list, nullptr, TRUE);
    layout(palette);
}

extern "C" int32_t nt_palette_query(void *panel, uint16_t *out, int32_t capacity) {
    Palette *palette = of(static_cast<HWND>(panel));
    if (!palette || capacity <= 0) return 0;
    return GetWindowTextW(palette->edit, reinterpret_cast<wchar_t *>(out), capacity);
}

extern "C" void nt_palette_close(void *panel) { ShowWindow(static_cast<HWND>(panel), SW_HIDE); }

extern "C" int32_t nt_palette_visible(void *panel) { return IsWindowVisible(static_cast<HWND>(panel)) ? 1 : 0; }

extern "C" void nt_palette_apply_chrome(void *panel) {
    Palette *palette = of(static_cast<HWND>(panel));
    if (!palette) return;
    DeleteObject(palette->brush);
    palette->brush = CreateSolidBrush(nt_chrome_pal_bg());
    SetWindowTheme(palette->list, nt_chrome_is_dark() ? L"DarkMode_Explorer" : L"Explorer", nullptr);
    InvalidateRect(palette->panel, nullptr, TRUE);
    InvalidateRect(palette->list, nullptr, TRUE);
}

// see NativeShim.cpp: the shim stays clear of the MSVC STL
#ifdef _YVALS_CORE_H_
#error "NativeShim must not include the MSVC STL"
#endif
