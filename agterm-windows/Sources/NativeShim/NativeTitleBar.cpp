#include "NativeShim.h"
#include "NativeChrome.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <uxtheme.h>

namespace {

struct Fonts {
    uint32_t dpi = 0;
    HFONT icons = nullptr, caption = nullptr, text = nullptr;
};
Fonts fonts;

HFONT font(int pixels, uint32_t dpi, const wchar_t *face) {
    return CreateFontW(-MulDiv(pixels, static_cast<int>(dpi), 96), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                       OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, face);
}

// Segoe MDL2 Assets ships with Windows 10 and 11 and holds the caption glyphs Windows' own frame draws with.
void loadFonts(uint32_t dpi) {
    if (fonts.dpi == dpi) return;
    if (fonts.icons) DeleteObject(fonts.icons);
    if (fonts.caption) DeleteObject(fonts.caption);
    if (fonts.text) DeleteObject(fonts.text);
    fonts ={dpi, font(16, dpi, L"Segoe MDL2 Assets"), font(10, dpi, L"Segoe MDL2 Assets"), font(13, dpi, L"Segoe UI")};
}

COLORREF fill(const nt_title_button &button) {
    bool close = button.kind == 2;
    if (button.state == 2) return nt_chrome_title_pressed(close);
    if (button.state == 1 || button.state == 4) return nt_chrome_title_hover(close);
    return nt_chrome_title_bg();
}

}  // namespace

extern "C" void nt_title_bar_paint(void *window, uint32_t dpi, int32_t height, int32_t menu_bottom, int32_t icon_width, int32_t icon_lit,
                                   const uint16_t *text, int32_t title_left, int32_t title_right, const nt_title_button *buttons,
                                   int32_t count, int32_t active, const nt_menu_tab *tabs, int32_t tab_count) {
    auto hwnd = static_cast<HWND>(window);
    PAINTSTRUCT paint;
    HDC dc = BeginPaint(hwnd, &paint);
    RECT client;
    GetClientRect(hwnd, &client);
    RECT bar{0, 0, client.right, menu_bottom};
    const COLORREF barBg = nt_chrome_title_bg();
    HBRUSH backgroundBrush = CreateSolidBrush(barBg);

    int saved = SaveDC(dc);
    ExcludeClipRect(dc, bar.left, bar.top, bar.right, bar.bottom);
    FillRect(dc, &paint.rcPaint, backgroundBrush);
    RestoreDC(dc, saved);

    RECT dirty;
    if (bar.right > 0 && height > 0 && IntersectRect(&dirty, &paint.rcPaint, &bar)) {
        loadFonts(dpi);
        HDC memory = CreateCompatibleDC(dc);
        HBITMAP bitmap = CreateCompatibleBitmap(dc, bar.right, bar.bottom);
        HGDIOBJ previousBitmap = SelectObject(memory, bitmap);
        HGDIOBJ previousFont = SelectObject(memory, fonts.text);
        FillRect(memory, &bar, backgroundBrush);
        SetBkMode(memory, TRANSPARENT);
        if (icon_width > 0) {
            RECT iconRect{0, 0, icon_width, height};
            if (icon_lit) {
                HBRUSH brush = CreateSolidBrush(nt_chrome_title_hover(0));
                FillRect(memory, &iconRect, brush);
                DeleteObject(brush);
            }
            HICON icon = reinterpret_cast<HICON>(GetClassLongPtrW(hwnd, GCLP_HICON));
            if (!icon) icon = reinterpret_cast<HICON>(SendMessageW(hwnd, WM_GETICON, ICON_SMALL2, 0));
            if (!icon) icon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1));
            if (icon) {
                int iconSize = MulDiv(16, static_cast<int>(dpi), 96);
                int x = icon_width > iconSize ? (icon_width - iconSize) / 2 : 0;
                int y = height > iconSize ? (height - iconSize) / 2 : 0;
                DrawIconEx(memory, x, y, icon, iconSize, iconSize, 0, nullptr, DI_NORMAL);
            }
        }
        for (int32_t i = 0; i < count; ++i) {
            const nt_title_button &button = buttons[i];
            RECT rect{button.left, 0, button.right, height};
            if (button.state == 1 || button.state == 2 || button.state == 4) {
                HBRUSH brush = CreateSolidBrush(fill(button));
                FillRect(memory, &rect, brush);
                DeleteObject(brush);
            }
            SelectObject(memory, button.kind == 0 ? fonts.icons : fonts.caption);
            bool lit = button.kind == 2 && button.state != 0;
            SetTextColor(memory, lit ? RGB(0xFF, 0xFF, 0xFF)
                                     : button.state == 3 ? nt_chrome_title_glyph(1, 1)
                                                       : nt_chrome_title_glyph(active, 0));
            wchar_t character = static_cast<wchar_t>(button.glyph);
            DrawTextW(memory, &character, 1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        }
        for (int32_t i = 0; i < tab_count; ++i) {
            const nt_menu_tab &tab = tabs[i];
            if (tab.right <= tab.left) continue;
            RECT rect{tab.left, height, tab.right, menu_bottom};
            if (tab.lit) {
                HBRUSH brush = CreateSolidBrush(nt_chrome_title_hover(0));
                FillRect(memory, &rect, brush);
                DeleteObject(brush);
            }
            SelectObject(memory, fonts.text);
            SetTextColor(memory, tab.lit ? nt_chrome_title_text() : nt_chrome_title_glyph(active, 0));
            if (tab.label)
                DrawTextW(memory, reinterpret_cast<const wchar_t *>(tab.label), -1, &rect,
                          DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
        }
        if (title_right > title_left && text) {
            RECT rect{title_left, 0, title_right, height};
            SelectObject(memory, fonts.text);
            SetTextColor(memory, active ? nt_chrome_title_text() : nt_chrome_title_glyph(0, 0));
            DrawTextW(memory, reinterpret_cast<const wchar_t *>(text), -1, &rect,
                      DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        }
        BitBlt(dc, dirty.left, dirty.top, dirty.right - dirty.left, dirty.bottom - dirty.top, memory, dirty.left, dirty.top, SRCCOPY);
        SelectObject(memory, previousFont);
        SelectObject(memory, previousBitmap);
        DeleteObject(bitmap);
        DeleteDC(memory);
    }
    DeleteObject(backgroundBrush);
    EndPaint(hwnd, &paint);
}

extern "C" void *nt_tooltip_create(void *parent) {
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_WIN95_CLASSES};
    InitCommonControlsEx(&controls);
    HWND tip = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nullptr, WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX, CW_USEDEFAULT,
                               CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, static_cast<HWND>(parent), nullptr,
                               GetModuleHandleW(nullptr), nullptr);
    if (tip) SetWindowTheme(tip, L"DarkMode_Explorer", nullptr);
    return tip;
}

extern "C" void nt_sidebar_button_paint(intptr_t notification, uint32_t dpi, uint16_t glyph, int32_t checked) {
    const auto &item = *reinterpret_cast<const DRAWITEMSTRUCT *>(notification);
    const bool disabled = (item.itemState & ODS_DISABLED) != 0;
    const bool pressed = (item.itemState & ODS_SELECTED) != 0;
    const auto color = checked ? nt_chrome_sb_selected() : pressed ? nt_chrome_sb_highlight() : nt_chrome_sb_bg();
    HBRUSH brush = CreateSolidBrush(color);
    FillRect(item.hDC, &item.rcItem, brush);
    DeleteObject(brush);

    loadFonts(dpi);
    int saved = SaveDC(item.hDC);
    SelectObject(item.hDC, fonts.icons);
    SetBkMode(item.hDC, TRANSPARENT);
    SetTextColor(item.hDC, disabled ? nt_chrome_sb_dim() : nt_chrome_sb_text());
    RECT rect = item.rcItem;
    const wchar_t character = static_cast<wchar_t>(glyph);
    DrawTextW(item.hDC, &character, 1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    if (item.itemState & ODS_FOCUS) DrawFocusRect(item.hDC, &rect);
    RestoreDC(item.hDC, saved);
}

extern "C" void nt_tooltip_for_control(void *tip, void *parent, void *control, const uint16_t *text) {
    if (!tip || !control) return;
    TTTOOLINFOW info{};
    info.cbSize = TTTOOLINFOW_V2_SIZE;
    info.hwnd = static_cast<HWND>(parent);
    info.uId = reinterpret_cast<UINT_PTR>(control);
    const auto window = static_cast<HWND>(tip);
    const auto arg = reinterpret_cast<LPARAM>(&info);
    const bool known = SendMessageW(window, TTM_GETTOOLINFOW, 0, arg) != 0;
    info.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
    info.lpszText = const_cast<wchar_t *>(reinterpret_cast<const wchar_t *>(text));
    SendMessageW(window, known ? TTM_UPDATETIPTEXTW : TTM_ADDTOOLW, 0, arg);
}

// The V2 size is what both comctl32 5 and 6 accept; the full struct's lpReserved makes version 5 refuse the tool.
extern "C" void nt_tooltip_set(void *tip, void *parent, uintptr_t id, int32_t left, int32_t top, int32_t right, int32_t bottom,
                               const uint16_t *text) {
    if (!tip) return;
    TTTOOLINFOW info{};
    info.cbSize = TTTOOLINFOW_V2_SIZE;
    info.hwnd = static_cast<HWND>(parent);
    info.uId = id;
    bool known = SendMessageW(static_cast<HWND>(tip), TTM_GETTOOLINFOW, 0, reinterpret_cast<LPARAM>(&info)) != 0;
    if (!text || !*text) {
        if (known) SendMessageW(static_cast<HWND>(tip), TTM_DELTOOLW, 0, reinterpret_cast<LPARAM>(&info));
        return;
    }
    // a known tool is moved and retitled in place: removing and adding it again re-hooks the parent, which this runs
    // under while the parent is handling a relayed mouse message
    info.uFlags = TTF_SUBCLASS;
    info.rect = {left, top, right, bottom};
    info.lpszText = const_cast<wchar_t *>(reinterpret_cast<const wchar_t *>(text));
    if (known) {
        SendMessageW(static_cast<HWND>(tip), TTM_NEWTOOLRECTW, 0, reinterpret_cast<LPARAM>(&info));
        SendMessageW(static_cast<HWND>(tip), TTM_UPDATETIPTEXTW, 0, reinterpret_cast<LPARAM>(&info));
    } else {
        SendMessageW(static_cast<HWND>(tip), TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&info));
    }
}
