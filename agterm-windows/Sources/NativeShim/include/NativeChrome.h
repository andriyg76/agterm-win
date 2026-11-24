#pragma once

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>

COLORREF nt_chrome_title_bg();
COLORREF nt_chrome_title_text();
COLORREF nt_chrome_title_glyph(int active, int disabled);
COLORREF nt_chrome_title_hover(int close);
COLORREF nt_chrome_title_pressed(int close);
COLORREF nt_chrome_client_bg();
COLORREF nt_chrome_pal_bg();
COLORREF nt_chrome_pal_border();
COLORREF nt_chrome_pal_sel();
COLORREF nt_chrome_pal_text();
COLORREF nt_chrome_pal_dim();
COLORREF nt_chrome_pal_disabled();
COLORREF nt_chrome_sb_bg();
COLORREF nt_chrome_sb_text();
COLORREF nt_chrome_sb_dim();
COLORREF nt_chrome_sb_selected();
int32_t nt_chrome_is_dark();