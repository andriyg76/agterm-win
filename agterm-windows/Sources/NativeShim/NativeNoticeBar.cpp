#include "NativeShim.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

namespace {

struct Fonts {
    uint32_t dpi = 0;
    HFONT text = nullptr, icons = nullptr, caption = nullptr;
};
Fonts fonts;

HFONT font(int pixels, uint32_t dpi, const wchar_t *face) {
    return CreateFontW(-MulDiv(pixels, static_cast<int>(dpi), 96), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                       OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, face);
}

void loadFonts(uint32_t dpi) {
    if (fonts.dpi == dpi) return;
    if (fonts.text) DeleteObject(fonts.text);
    if (fonts.icons) DeleteObject(fonts.icons);
    if (fonts.caption) DeleteObject(fonts.caption);
    fonts = {dpi, font(13, dpi, L"Segoe UI"), font(16, dpi, L"Segoe MDL2 Assets"), font(10, dpi, L"Segoe MDL2 Assets")};
}

COLORREF color(uint32_t colorref) { return static_cast<COLORREF>(colorref); }

void fill(HDC dc, const RECT &rect, uint32_t rgb) {
    HBRUSH brush = CreateSolidBrush(color(rgb));
    FillRect(dc, &rect, brush);
    DeleteObject(brush);
}

void roundRect(HDC dc, const RECT &rect, uint32_t rgb, int radius) {
    HBRUSH brush = CreateSolidBrush(color(rgb));
    HPEN pen = CreatePen(PS_SOLID, 1, color(rgb));
    HGDIOBJ oldBrush = SelectObject(dc, brush), oldPen = SelectObject(dc, pen);
    RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, radius, radius);
    SelectObject(dc, oldBrush);
    SelectObject(dc, oldPen);
    DeleteObject(brush);
    DeleteObject(pen);
}

void glyph(HDC dc, uint16_t code, RECT rect, uint32_t rgb) {
    wchar_t character = static_cast<wchar_t>(code);
    SetTextColor(dc, color(rgb));
    DrawTextW(dc, &character, 1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
}

}  // namespace

extern "C" void nt_notice_bar_paint(void *window, uint32_t dpi, const nt_notice_bar *bar) {
    auto hwnd = static_cast<HWND>(window);
    PAINTSTRUCT paint;
    HDC dc = BeginPaint(hwnd, &paint);
    RECT client;
    GetClientRect(hwnd, &client);
    if (bar && client.right > 0 && client.bottom > 0) {
        loadFonts(dpi);
        const int height = client.bottom;
        const int line = MulDiv(1, static_cast<int>(dpi), 96);
        HDC memory = CreateCompatibleDC(dc);
        HBITMAP bitmap = CreateCompatibleBitmap(dc, client.right, height);
        HGDIOBJ previousBitmap = SelectObject(memory, bitmap);
        HGDIOBJ previousFont = SelectObject(memory, fonts.text);
        SetBkMode(memory, TRANSPARENT);
        fill(memory, client, bar->background);
        fill(memory, RECT{0, 0, bar->stripe_right, height}, bar->accent);
        if (bar->edge_top) fill(memory, RECT{0, 0, client.right, line}, bar->border);
        if (bar->edge_bottom) fill(memory, RECT{0, height - line, client.right, height}, bar->border);

        SelectObject(memory, fonts.caption);
        glyph(memory, 0xE76F, RECT{bar->grip_left, 0, bar->grip_right, height}, bar->dim);
        SelectObject(memory, fonts.icons);
        glyph(memory, bar->glyph, RECT{bar->icon_left, 0, bar->icon_right, height}, bar->accent);

        SelectObject(memory, fonts.text);
        if (bar->text && bar->text_right > bar->text_left) {
            RECT rect{bar->text_left, 0, bar->text_right, height};
            SetTextColor(memory, color(bar->text_color));
            DrawTextW(memory, reinterpret_cast<const wchar_t *>(bar->text), -1, &rect,
                      DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        }
        if (bar->count && bar->count_right > bar->count_left) {
            RECT rect{bar->count_left, 0, bar->count_right, height};
            SetTextColor(memory, color(bar->dim));
            DrawTextW(memory, reinterpret_cast<const wchar_t *>(bar->count), -1, &rect,
                      DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        }
        const int inset = MulDiv(5, static_cast<int>(dpi), 96);
        const int radius = MulDiv(6, static_cast<int>(dpi), 96);
        for (int32_t i = 0; i < bar->button_count; ++i) {
            const nt_notice_button &button = bar->buttons[i];
            RECT rect{button.left, inset, button.right, height - inset};
            roundRect(memory, rect, button.state == 2 ? bar->button_pressed : button.state == 1 ? bar->button_hover : bar->button, radius);
            SetTextColor(memory, color(bar->text_color));
            if (button.label)
                DrawTextW(memory, reinterpret_cast<const wchar_t *>(button.label), -1, &rect,
                          DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        }
        RECT close{bar->close_left, 0, bar->close_right, height};
        if (bar->close_state) fill(memory, close, bar->close_state == 2 ? bar->button_pressed : bar->button_hover);
        SelectObject(memory, fonts.caption);
        glyph(memory, 0xE8BB, close, bar->close_state ? bar->text_color : bar->dim);

        BitBlt(dc, 0, 0, client.right, height, memory, 0, 0, SRCCOPY);
        SelectObject(memory, previousFont);
        SelectObject(memory, previousBitmap);
        DeleteObject(bitmap);
        DeleteDC(memory);
    }
    EndPaint(hwnd, &paint);
}

extern "C" int32_t nt_notice_bar_text_width(uint32_t dpi, const uint16_t *text) {
    if (!text || !*text) return 0;
    loadFonts(dpi);
    HDC dc = GetDC(nullptr);
    HGDIOBJ previous = SelectObject(dc, fonts.text);
    SIZE size{};
    GetTextExtentPoint32W(dc, reinterpret_cast<const wchar_t *>(text), lstrlenW(reinterpret_cast<const wchar_t *>(text)), &size);
    SelectObject(dc, previous);
    ReleaseDC(nullptr, dc);
    return size.cx;
}
