#include "NativeShim.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <uxtheme.h>

namespace {

constexpr COLORREF background = RGB(0x25, 0x25, 0x26);
constexpr COLORREF hover = RGB(0x3D, 0x3D, 0x3E);
constexpr COLORREF pressed = RGB(0x4A, 0x4A, 0x4B);
constexpr COLORREF closeHover = RGB(0xC4, 0x2B, 0x1C);
constexpr COLORREF closePressed = RGB(0x9F, 0x22, 0x16);
constexpr COLORREF glyph = RGB(0xCC, 0xCC, 0xCC);
constexpr COLORREF title = RGB(0xE0, 0xE0, 0xE0);
constexpr COLORREF inactive = RGB(0x80, 0x80, 0x80);

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
    if (button.state == 2) return close ? closePressed : pressed;
    if (button.state == 1) return close ? closeHover : hover;
    return background;
}

}  // namespace

extern "C" void nt_title_bar_paint(void *window, uint32_t dpi, int32_t height, const uint16_t *text, int32_t title_left,
                                   int32_t title_right, const nt_title_button *buttons, int32_t count, int32_t active) {
    auto hwnd = static_cast<HWND>(window);
    PAINTSTRUCT paint;
    HDC dc = BeginPaint(hwnd, &paint);
    RECT client;
    GetClientRect(hwnd, &client);
    RECT bar{0, 0, client.right, height};
    HBRUSH backgroundBrush = CreateSolidBrush(background);

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
        for (int32_t i = 0; i < count; ++i) {
            const nt_title_button &button = buttons[i];
            RECT rect{button.left, 0, button.right, height};
            if (button.state != 0) {
                HBRUSH brush = CreateSolidBrush(fill(button));
                FillRect(memory, &rect, brush);
                DeleteObject(brush);
            }
            SelectObject(memory, button.kind == 0 ? fonts.icons : fonts.caption);
            bool lit = button.kind == 2 && button.state != 0;
            SetTextColor(memory, lit ? RGB(0xFF, 0xFF, 0xFF) : active ? glyph : inactive);
            wchar_t character = static_cast<wchar_t>(button.glyph);
            DrawTextW(memory, &character, 1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        }
        if (title_right > title_left && text) {
            RECT rect{title_left, 0, title_right, height};
            SelectObject(memory, fonts.text);
            SetTextColor(memory, active ? title : inactive);
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
