#include "NativeShim.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

namespace {

struct Palette {
    COLORREF chromeBg = RGB(0x25, 0x25, 0x26);
    COLORREF chromeText = RGB(0xCC, 0xCC, 0xCC);
    COLORREF chromeDim = RGB(0x80, 0x80, 0x80);
    COLORREF chromeAccent = RGB(0x26, 0x4F, 0x78);
    COLORREF chromeBorder = RGB(0x45, 0x45, 0x46);
    COLORREF sbBg = RGB(0x25, 0x25, 0x26);
    COLORREF sbActiveText = RGB(0xCC, 0xCC, 0xCC);
    COLORREF sbHeaderText = RGB(0xAA, 0xAA, 0xAA);
    COLORREF sbDim = RGB(0x80, 0x80, 0x80);
    COLORREF sbHighlight = RGB(0x3A, 0x3A, 0x3C);
    COLORREF palBg = RGB(0x2D, 0x2D, 0x30);
    COLORREF palBorder = RGB(0x45, 0x45, 0x46);
    COLORREF palSel = RGB(0x26, 0x4F, 0x78);
    COLORREF titleHover = RGB(0x3D, 0x3D, 0x3E);
    COLORREF titlePressed = RGB(0x4A, 0x4A, 0x4B);
    COLORREF closeHover = RGB(0xC4, 0x2B, 0x1C);
    COLORREF closePressed = RGB(0x9F, 0x22, 0x16);
    COLORREF titleInactive = RGB(0x80, 0x80, 0x80);
    COLORREF titleDisabled = RGB(0x6E, 0x6E, 0x6E);
    COLORREF clientBg = RGB(0x25, 0x25, 0x26);
    int isDark = 1;
} chrome;

COLORREF toColor(uint32_t rgb) { return RGB((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF); }

}  // namespace

extern "C" void nt_set_chrome_colors(const nt_chrome_palette *palette) {
    if (!palette) return;
    chrome.chromeBg = toColor(palette->chrome_bg);
    chrome.chromeText = toColor(palette->chrome_text);
    chrome.chromeDim = toColor(palette->chrome_dim);
    chrome.chromeAccent = toColor(palette->chrome_accent);
    chrome.chromeBorder = toColor(palette->chrome_border);
    chrome.sbBg = toColor(palette->sb_bg);
    chrome.sbActiveText = toColor(palette->sb_active_text);
    chrome.sbHeaderText = toColor(palette->sb_header_text);
    chrome.sbDim = toColor(palette->sb_dim);
    chrome.sbHighlight = toColor(palette->sb_highlight);
    chrome.palBg = toColor(palette->pal_bg);
    chrome.palBorder = toColor(palette->pal_border);
    chrome.palSel = toColor(palette->pal_sel);
    chrome.titleHover = toColor(palette->title_hover);
    chrome.titlePressed = toColor(palette->title_pressed);
    chrome.closeHover = toColor(palette->close_hover);
    chrome.closePressed = toColor(palette->close_pressed);
    chrome.titleInactive = toColor(palette->title_inactive);
    chrome.titleDisabled = toColor(palette->title_disabled);
    chrome.clientBg = toColor(palette->client_bg);
    chrome.isDark = palette->is_dark;
}

COLORREF nt_chrome_title_bg() { return chrome.chromeBg; }
COLORREF nt_chrome_title_text() { return chrome.chromeText; }
COLORREF nt_chrome_title_glyph(int active, int disabled) {
    if (disabled) return chrome.titleDisabled;
    return active ? chrome.chromeText : chrome.titleInactive;
}
COLORREF nt_chrome_title_hover(int close) {
    if (close == 2) return chrome.closeHover;
    return chrome.titleHover;
}
COLORREF nt_chrome_title_pressed(int close) {
    if (close == 2) return chrome.closePressed;
    return chrome.titlePressed;
}
COLORREF nt_chrome_client_bg() { return chrome.clientBg; }
COLORREF nt_chrome_pal_bg() { return chrome.palBg; }
COLORREF nt_chrome_pal_border() { return chrome.palBorder; }
COLORREF nt_chrome_pal_sel() { return chrome.palSel; }
COLORREF nt_chrome_pal_text() { return chrome.chromeText; }
COLORREF nt_chrome_pal_dim() { return chrome.chromeDim; }
COLORREF nt_chrome_pal_disabled() { return chrome.titleDisabled; }
COLORREF nt_chrome_sb_bg() { return chrome.sbBg; }
COLORREF nt_chrome_sb_text() { return chrome.sbActiveText; }
COLORREF nt_chrome_sb_dim() { return chrome.sbDim; }
COLORREF nt_chrome_sb_selected() { return chrome.chromeAccent; }
int32_t nt_chrome_is_dark() { return chrome.isDark; }