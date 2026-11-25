#include "NativeShim.h"
#include "NativeChrome.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <uxtheme.h>
#include <vssym32.h>

namespace {

using InitCommonControlsExFn = BOOL(WINAPI *)(const INITCOMMONCONTROLSEX *);

constexpr UINT_PTR skinSubclass = 3;  // above the find bar's (1) and the palette's (2)

struct Brushes {
    COLORREF window = CLR_INVALID, field = CLR_INVALID;
    HBRUSH windowBrush = nullptr, fieldBrush = nullptr;
} brushes;

HBRUSH brush(COLORREF color, COLORREF &current, HBRUSH &cached) {
    if (cached && current == color) return cached;
    if (cached) DeleteObject(cached);
    current = color;
    cached = CreateSolidBrush(color);
    return cached;
}

HBRUSH windowBrush() { return brush(nt_chrome_title_bg(), brushes.window, brushes.windowBrush); }
HBRUSH fieldBrush() { return brush(nt_chrome_pal_bg(), brushes.field, brushes.fieldBrush); }

bool isClass(HWND window, const wchar_t *name) {
    wchar_t found[32];
    return GetClassNameW(window, found, 32) && lstrcmpiW(found, name) == 0;
}

bool isCheckBox(HWND button) {
    LONG type = GetWindowLongW(button, GWL_STYLE) & BS_TYPEMASK;
    return type == BS_CHECKBOX || type == BS_AUTOCHECKBOX;
}

void frame(HDC dc, const RECT &rect, COLORREF color) {
    HBRUSH line = CreateSolidBrush(color);
    FrameRect(dc, &rect, line);
    DeleteObject(line);
}

bool showsFocus(HWND window) {
    return GetFocus() == window && !(SendMessageW(window, WM_QUERYUISTATE, 0, 0) & UISF_HIDEFOCUS);
}

// Themed check boxes draw their label in the theme's text color whatever WM_CTLCOLORBTN says, black on a dark
// background, so the box comes from the theme and the label from the chrome.
void paintCheckBox(HWND button, HDC dc) {
    RECT client;
    GetClientRect(button, &client);
    FillRect(dc, &client, windowBrush());
    bool enabled = IsWindowEnabled(button);
    LRESULT state = SendMessageW(button, BM_GETSTATE, 0, 0);
    int part = !enabled ? CBS_UNCHECKEDDISABLED : (state & BST_PUSHED) ? CBS_UNCHECKEDPRESSED : (state & BST_HOT) ? CBS_UNCHECKEDHOT
                                                                                                                    : CBS_UNCHECKEDNORMAL;
    if (state & BST_CHECKED) part += CBS_CHECKEDNORMAL - CBS_UNCHECKEDNORMAL;
    SIZE box{MulDiv(13, static_cast<int>(GetDpiForWindow(button)), 96), 0};
    box.cy = box.cx;
    if (HTHEME theme = OpenThemeData(button, L"Button")) {
        GetThemePartSize(theme, dc, BP_CHECKBOX, part, nullptr, TS_DRAW, &box);
        RECT glyph{client.left, (client.bottom - box.cy) / 2, client.left + box.cx, (client.bottom - box.cy) / 2 + box.cy};
        DrawThemeBackground(theme, dc, BP_CHECKBOX, part, &glyph, nullptr);
        CloseThemeData(theme);
    }
    wchar_t text[256];
    int length = GetWindowTextW(button, text, 256);
    HGDIOBJ previous = SelectObject(dc, reinterpret_cast<HFONT>(SendMessageW(button, WM_GETFONT, 0, 0)));
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, enabled ? nt_chrome_pal_text() : nt_chrome_pal_disabled());
    RECT label{client.left + box.cx + box.cx / 2, client.top, client.right, client.bottom};
    DrawTextW(dc, text, length, &label, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    if (showsFocus(button)) {
        RECT used = label;
        DrawTextW(dc, text, length, &used, DT_LEFT | DT_SINGLELINE | DT_CALCRECT);
        OffsetRect(&used, 0, (label.bottom - label.top - (used.bottom - used.top)) / 2);
        InflateRect(&used, 2, 1);
        DrawFocusRect(dc, &used);
    }
    SelectObject(dc, previous);
}

// No visual style has a dark tab control, so the tabs are drawn whole: a row of labels over a framed page, the
// selected one lit with the palettes' selection.
void paintTabs(HWND tabs, HDC dc) {
    RECT client;
    GetClientRect(tabs, &client);
    FillRect(dc, &client, windowBrush());
    int count = TabCtrl_GetItemCount(tabs), selected = TabCtrl_GetCurSel(tabs);
    RECT item{};
    if (count > 0) TabCtrl_GetItemRect(tabs, 0, &item);
    RECT page{client.left, item.bottom, client.right, client.bottom};
    frame(dc, page, nt_chrome_pal_border());
    HGDIOBJ previous = SelectObject(dc, reinterpret_cast<HFONT>(SendMessageW(tabs, WM_GETFONT, 0, 0)));
    SetBkMode(dc, TRANSPARENT);
    for (int index = 0; index < count; ++index) {
        wchar_t text[64] = {};
        TCITEMW tab{};
        tab.mask = TCIF_TEXT;
        tab.pszText = text;
        tab.cchTextMax = 64;
        SendMessageW(tabs, TCM_GETITEMW, index, reinterpret_cast<LPARAM>(&tab));
        TabCtrl_GetItemRect(tabs, index, &item);
        bool lit = index == selected;
        if (lit) {
            HBRUSH fill = CreateSolidBrush(nt_chrome_pal_sel());
            FillRect(dc, &item, fill);
            DeleteObject(fill);
        }
        SetTextColor(dc, lit ? nt_chrome_pal_text() : nt_chrome_pal_dim());
        DrawTextW(dc, text, -1, &item, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        if (lit && showsFocus(tabs)) {
            RECT focus = item;
            InflateRect(&focus, -2, -2);
            DrawFocusRect(dc, &focus);
        }
    }
    SelectObject(dc, previous);
}

LRESULT CALLBACK paintedProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam, UINT_PTR, DWORD_PTR) {
    auto paint = [window](HDC dc) { isClass(window, WC_TABCONTROLW) ? paintTabs(window, dc) : paintCheckBox(window, dc); };
    switch (message) {
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(window, &ps);
        paint(dc);
        EndPaint(window, &ps);
        return 0;
    }
    case WM_PRINTCLIENT:
        paint(reinterpret_cast<HDC>(wParam));
        return 0;
    case WM_UPDATEUISTATE:
    case WM_ENABLE:
        InvalidateRect(window, nullptr, FALSE);
        break;
    case WM_NCDESTROY:
        RemoveWindowSubclass(window, paintedProcedure, skinSubclass);
        break;
    }
    return DefSubclassProc(window, message, wParam, lParam);
}

LRESULT CALLBACK windowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam, UINT_PTR, DWORD_PTR) {
    auto dc = reinterpret_cast<HDC>(wParam);
    auto control = reinterpret_cast<HWND>(lParam);
    switch (message) {
    case WM_ERASEBKGND: {
        RECT client;
        GetClientRect(window, &client);
        FillRect(dc, &client, windowBrush());
        return 1;
    }
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLORBTN:
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORLISTBOX: {
        // a disabled or read-only edit asks with WM_CTLCOLORSTATIC and keeps its field
        bool field = message == WM_CTLCOLOREDIT || message == WM_CTLCOLORLISTBOX || isClass(control, L"Edit");
        SetTextColor(dc, IsWindowEnabled(control) ? nt_chrome_pal_text() : nt_chrome_pal_disabled());
        SetBkColor(dc, field ? nt_chrome_pal_bg() : nt_chrome_title_bg());
        return reinterpret_cast<LRESULT>(field ? fieldBrush() : windowBrush());
    }
    case WM_NCDESTROY:
        RemoveWindowSubclass(window, windowProcedure, skinSubclass);
        break;
    }
    return DefSubclassProc(window, message, wParam, lParam);
}

BOOL CALLBACK skinChild(HWND child, LPARAM) {
    bool dark = nt_chrome_is_dark();
    const wchar_t *explorer = dark ? L"DarkMode_Explorer" : L"Explorer";
    if (isClass(child, L"ComboBox") || isClass(child, L"Edit")) {
        SetWindowTheme(child, dark ? L"DarkMode_CFD" : L"CFD", nullptr);
    } else if (isClass(child, WC_TABCONTROLW) || (isClass(child, L"Button") && isCheckBox(child))) {
        SetWindowTheme(child, explorer, nullptr);
        SetWindowSubclass(child, paintedProcedure, skinSubclass, 0);
    } else if (!isClass(child, L"Static")) {
        SetWindowTheme(child, explorer, nullptr);
    }
    return TRUE;
}

}  // namespace

extern "C" uintptr_t nt_skin_controls_begin(void) {
    HANDLE context = nt_common_controls_context();
    ULONG_PTR cookie = 0;
    if (context == INVALID_HANDLE_VALUE || !ActivateActCtx(context, &cookie)) return 0;
    // the tab and up-down classes of version 6 are registered by its own InitCommonControlsEx, not the linked one
    static bool registered = [] {
        HMODULE comctl = LoadLibraryW(L"comctl32.dll");
        auto initialize = comctl ? reinterpret_cast<InitCommonControlsExFn>(GetProcAddress(comctl, "InitCommonControlsEx")) : nullptr;
        INITCOMMONCONTROLSEX classes{sizeof(classes), ICC_STANDARD_CLASSES | ICC_TAB_CLASSES | ICC_UPDOWN_CLASS};
        return initialize && initialize(&classes);
    }();
    (void)registered;
    return cookie;
}

extern "C" void nt_skin_controls_end(uintptr_t cookie) {
    if (cookie) DeactivateActCtx(0, cookie);
}

extern "C" void nt_skin_window(void *window) {
    auto hwnd = static_cast<HWND>(window);
    if (!hwnd) return;
    BOOL dark = nt_chrome_is_dark() ? TRUE : FALSE;
    DwmSetWindowAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof(dark));
    SetWindowSubclass(hwnd, windowProcedure, skinSubclass, 0);
    EnumChildWindows(hwnd, skinChild, 0);
    RedrawWindow(hwnd, nullptr, nullptr, RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN);
}

// see NativeShim.cpp: the shim stays clear of the MSVC STL
#ifdef _YVALS_CORE_H_
#error "NativeShim must not include the MSVC STL"
#endif
