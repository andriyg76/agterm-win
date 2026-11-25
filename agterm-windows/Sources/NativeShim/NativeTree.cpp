#include "NativeShim.h"
#include "NativeChrome.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <uxtheme.h>

#include <string.h>
#include <wchar.h>

#include <string>
#include <unordered_map>

#pragma comment(lib, "uxtheme")

namespace {

// Decoration is what an agent reported for a session row: a status glyph drawn at the row's right edge and an info
// line drawn under its title, which makes the row two lines tall.
struct Decoration {
    std::wstring glyph;
    COLORREF color = 0;
    bool blink = false;
    std::wstring info;
};

std::unordered_map<HTREEITEM, Decoration> decorations;
bool blinkDimmed = false;

// drawDecoration paints a session row's glyph and, for a row with an info line, both of its lines over the default
// label, which was drawn in the background color
void drawDecoration(const NMTVCUSTOMDRAW *draw, HTREEITEM handle, const Decoration &decoration, COLORREF text) {
    HWND window = draw->nmcd.hdr.hwndFrom;
    HDC dc = draw->nmcd.hdc;
    RECT row{}, label{};
    TreeView_GetItemRect(window, handle, &row, FALSE);
    TreeView_GetItemRect(window, handle, &label, TRUE);
    const auto oldMode = SetBkMode(dc, TRANSPARENT);
    const auto oldColor = GetTextColor(dc);
    SIZE glyphSize{};
    int margin = MulDiv(8, GetDpiForWindow(window), 96);
    if (!decoration.glyph.empty()) {
        GetTextExtentPoint32W(dc, decoration.glyph.c_str(), static_cast<int>(decoration.glyph.size()), &glyphSize);
        RECT at{row.right - margin - glyphSize.cx, row.top, row.right - margin, row.bottom};
        SetTextColor(dc, decoration.blink && blinkDimmed ? nt_chrome_sb_dim() : decoration.color);
        DrawTextW(dc, decoration.glyph.c_str(), -1, &at, DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX);
    }
    if (!decoration.info.empty()) {
        wchar_t title[512] = {};
        TVITEMW item{};
        item.mask = TVIF_TEXT;
        item.hItem = handle;
        item.pszText = title;
        item.cchTextMax = 512;
        SendMessageW(window, TVM_GETITEMW, 0, reinterpret_cast<LPARAM>(&item));
        int right = row.right - margin - (glyphSize.cx ? glyphSize.cx + margin / 2 : 0);
        int middle = (row.top + row.bottom) / 2;
        RECT top{label.left + 2, row.top, right, middle}, bottom{label.left + 2, middle, right, row.bottom};
        SetTextColor(dc, text);
        DrawTextW(dc, title, -1, &top, DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS);
        SetTextColor(dc, nt_chrome_sb_dim());
        DrawTextW(dc, decoration.info.c_str(), -1, &bottom, DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS);
    }
    SetTextColor(dc, oldColor);
    SetBkMode(dc, oldMode);
}

int64_t itemTag(HWND tree, HTREEITEM node) {
    if (!node) return 0;
    TVITEMW item{};
    item.hItem = node;
    item.mask = TVIF_PARAM;
    return SendMessageW(tree, TVM_GETITEMW, 0, reinterpret_cast<LPARAM>(&item)) ? item.lParam : 0;
}

bool launchButtonRect(HWND tree, HTREEITEM item, RECT &rect) {
    RECT client{};
    if (!GetClientRect(tree, &client) || !TreeView_GetItemRect(tree, item, &rect, FALSE)) return false;
    rect.right = client.right - MulDiv(4, GetDpiForWindow(tree), 96);
    rect.left = rect.right - (rect.bottom - rect.top);
    return rect.left >= 0;
}

int64_t launchButtonAt(HWND tree, POINT point) {
    for (auto item = TreeView_GetFirstVisible(tree); item; item = TreeView_GetNextVisible(tree, item)) {
        RECT rect{};
        if (!launchButtonRect(tree, item, rect) || point.y < rect.top) break;
        if (point.y < rect.bottom) {
            auto tag = itemTag(tree, item);
            return tag < 0 && PtInRect(&rect, point) ? tag : 0;
        }
    }
    return 0;
}

LRESULT CALLBACK treeProcedure(HWND tree, UINT message, WPARAM wParam, LPARAM lParam, UINT_PTR, DWORD_PTR) {
    if (message == WM_LBUTTONDOWN || message == WM_LBUTTONUP || message == WM_LBUTTONDBLCLK) {
        if (auto tag = launchButtonAt(tree, POINT{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)})) {
            if (message == WM_LBUTTONDOWN) SendMessageW(GetParent(tree), NT_TREE_LAUNCH, 0, static_cast<LPARAM>(tag));
            return 0;
        }
    }
    if (message == WM_NCDESTROY) RemoveWindowSubclass(tree, treeProcedure, 1);
    return DefSubclassProc(tree, message, wParam, lParam);
}

}  // namespace

extern "C" void *nt_tree_create(void *parent, uint32_t dpi) {
    // Settings' size arrows are an up-down control, registered with the tree's class
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_TREEVIEW_CLASSES | ICC_UPDOWN_CLASS};
    InitCommonControlsEx(&controls);
    HWND tree = CreateWindowExW(0, WC_TREEVIEWW, L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | TVS_HASBUTTONS | TVS_LINESATROOT |
                                    TVS_SHOWSELALWAYS | TVS_FULLROWSELECT | TVS_EDITLABELS,
                                0, 0, 100, 100, static_cast<HWND>(parent), nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!tree) return nullptr;
    SetWindowSubclass(tree, treeProcedure, 1, 0);
    TreeView_SetExtendedStyle(tree, TVS_EX_DOUBLEBUFFER, TVS_EX_DOUBLEBUFFER);
    nt_tree_apply_colors(tree);
    nt_tree_set_dpi(tree, dpi);
    return tree;
}

namespace {

void setFont(HWND window, uint32_t dpi) {
    HFONT font = CreateFontW(-MulDiv(10, static_cast<int>(dpi), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                             OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    auto previous = reinterpret_cast<HFONT>(SendMessageW(window, WM_GETFONT, 0, 0));
    SendMessageW(window, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
    if (previous) DeleteObject(previous);
}

}  // namespace

extern "C" void nt_tree_set_dpi(void *tree, uint32_t dpi) {
    auto window = static_cast<HWND>(tree);
    setFont(window, dpi);
    TreeView_SetItemHeight(window, MulDiv(24, static_cast<int>(dpi), 96));
}

extern "C" void nt_tree_apply_colors(void *tree) {
    auto window = static_cast<HWND>(tree);
    if (!window) return;
    TreeView_SetBkColor(window, nt_chrome_sb_bg());
    TreeView_SetTextColor(window, nt_chrome_sb_text());
    SetWindowTheme(window, nt_chrome_is_dark() ? L"DarkMode_Explorer" : L"Explorer", nullptr);
    InvalidateRect(window, nullptr, TRUE);
}

extern "C" void nt_find_bar_set_dpi(void *bar, uint32_t dpi) { setFont(static_cast<HWND>(bar), dpi); }

extern "C" void nt_tree_clear(void *tree) {
    decorations.clear();
    TreeView_DeleteAllItems(static_cast<HWND>(tree));
}

extern "C" void nt_tree_decorate(void *tree, void *item, const uint16_t *glyph, uint32_t rgb, int32_t blink, const uint16_t *info) {
    auto handle = static_cast<HTREEITEM>(item);
    Decoration decoration;
    if (glyph) decoration.glyph = reinterpret_cast<const wchar_t *>(glyph);
    decoration.color = RGB((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
    decoration.blink = blink != 0;
    if (info) decoration.info = reinterpret_cast<const wchar_t *>(info);
    if (!decoration.info.empty()) {
        TVITEMEXW change{};
        change.mask = TVIF_INTEGRAL;
        change.hItem = handle;
        change.iIntegral = 2;
        SendMessageW(static_cast<HWND>(tree), TVM_SETITEMW, 0, reinterpret_cast<LPARAM>(&change));
    }
    if (decoration.glyph.empty() && decoration.info.empty()) decorations.erase(handle);
    else decorations[handle] = decoration;
}

extern "C" int32_t nt_tree_blink(void *tree, int32_t dimmed) {
    blinkDimmed = dimmed != 0;
    bool any = false;
    for (auto &entry : decorations) any = any || entry.second.blink;
    if (any) InvalidateRect(static_cast<HWND>(tree), nullptr, FALSE);
    return any ? 1 : 0;
}

extern "C" void *nt_tree_add(void *tree, void *parent, const uint16_t *text, int64_t tag, int32_t expanded) {
    TVINSERTSTRUCTW insert{};
    insert.hParent = parent ? static_cast<HTREEITEM>(parent) : TVI_ROOT;
    insert.hInsertAfter = TVI_LAST;
    insert.item.mask = TVIF_TEXT | TVIF_PARAM | TVIF_STATE;
    insert.item.pszText = const_cast<wchar_t *>(reinterpret_cast<const wchar_t *>(text));
    insert.item.lParam = static_cast<LPARAM>(tag);
    insert.item.state = expanded ? TVIS_EXPANDED : 0;
    insert.item.stateMask = TVIS_EXPANDED;
    return reinterpret_cast<HTREEITEM>(SendMessageW(static_cast<HWND>(tree), TVM_INSERTITEMW, 0, reinterpret_cast<LPARAM>(&insert)));
}

extern "C" void nt_tree_select(void *tree, void *item) { TreeView_SelectItem(static_cast<HWND>(tree), static_cast<HTREEITEM>(item)); }

extern "C" int32_t nt_tree_selection_changed(intptr_t notification, int64_t *tag) {
    auto header = reinterpret_cast<const NMHDR *>(notification);
    if (header->code != TVN_SELCHANGEDW) return 0;
    auto change = reinterpret_cast<const NMTREEVIEWW *>(notification);
    if (change->action == TVC_UNKNOWN) return 0;  // nt_tree_select or a rebuild, not the user
    *tag = static_cast<int64_t>(change->itemNew.lParam);
    return 1;
}

extern "C" int32_t nt_track_menu(void *menu, void *owner, int32_t x, int32_t y) {
    // TPM_RETURNCMD puts the command in the BOOL result, which Swift's WinSDK import narrows to Bool
    return TrackPopupMenu(static_cast<HMENU>(menu), TPM_RETURNCMD | TPM_RIGHTBUTTON, x, y, 0, static_cast<HWND>(owner), nullptr);
}

extern "C" intptr_t nt_tree_custom_draw(intptr_t notification, const uint8_t *dimmed, int64_t count,
                                         const uint8_t *launchable, int64_t groupCount) {
    auto draw = reinterpret_cast<NMTVCUSTOMDRAW *>(notification);
    if (draw->nmcd.hdr.code != NM_CUSTOMDRAW) return -1;
    if (draw->nmcd.dwDrawStage == CDDS_PREPAINT) return CDRF_NOTIFYITEMDRAW;
    int64_t tag = static_cast<int64_t>(draw->nmcd.lItemlParam);
    const bool group = tag < 0 && tag >= -groupCount;
    if (draw->nmcd.dwDrawStage == CDDS_ITEMPOSTPAINT && group) {
        const auto tree = draw->nmcd.hdr.hwndFrom;
        const auto item = reinterpret_cast<HTREEITEM>(draw->nmcd.dwItemSpec);
        RECT rect{};
        if (launchButtonRect(tree, item, rect)) {
            const auto dc = draw->nmcd.hdc;
            const auto oldMode = SetBkMode(dc, TRANSPARENT);
            const auto oldColor = SetTextColor(dc, launchable[-tag - 1] ? nt_chrome_sb_text() : nt_chrome_sb_dim());
            const auto brush = CreateSolidBrush(TreeView_GetSelection(tree) == item ? nt_chrome_sb_selected() : nt_chrome_sb_bg());
            FillRect(dc, &rect, brush);
            DeleteObject(brush);
            DrawTextW(dc, L"+", 1, &rect, DT_SINGLELINE | DT_CENTER | DT_VCENTER);
            SetTextColor(dc, oldColor);
            SetBkMode(dc, oldMode);
        }
        return CDRF_DODEFAULT;
    }
    const auto handle = reinterpret_cast<HTREEITEM>(draw->nmcd.dwItemSpec);
    const auto found = tag > 0 ? decorations.find(handle) : decorations.end();
    bool dim = tag > 0 && tag <= count && dimmed[tag - 1];
    const COLORREF text = dim ? nt_chrome_sb_dim() : nt_chrome_sb_text();
    if (draw->nmcd.dwDrawStage == CDDS_ITEMPOSTPAINT && found != decorations.end()) {
        drawDecoration(draw, handle, found->second, text);
        return CDRF_DODEFAULT;
    }
    if (draw->nmcd.dwDrawStage != CDDS_ITEMPREPAINT) return CDRF_DODEFAULT;
    draw->clrText = text;
    draw->clrTextBk = nt_chrome_sb_bg();
    // the unthemed tree paints its selection in the light system colors unless the state is taken away
    if (draw->nmcd.uItemState & CDIS_SELECTED) {
        draw->clrTextBk = nt_chrome_sb_highlight();
        draw->nmcd.uItemState &= ~(CDIS_SELECTED | CDIS_FOCUS);
    }
    if (found != decorations.end() && !found->second.info.empty()) draw->clrText = draw->clrTextBk;
    return group || found != decorations.end() ? CDRF_NOTIFYPOSTPAINT : CDRF_DODEFAULT;
}

extern "C" int64_t nt_tree_item_at(void *tree, int32_t *x, int32_t *y) {
    auto window = static_cast<HWND>(tree);
    TVITEMW item{};
    item.mask = TVIF_PARAM;
    if (*x == -1 && *y == -1) {  // from the keyboard: at the selected item
        item.hItem = TreeView_GetSelection(window);
        RECT rect{};
        if (!item.hItem || !TreeView_GetItemRect(window, item.hItem, &rect, TRUE)) return 0;
        POINT corner{rect.left, rect.bottom};
        ClientToScreen(window, &corner);
        *x = corner.x;
        *y = corner.y;
    } else {
        TVHITTESTINFO hit{};
        hit.pt = {*x, *y};
        ScreenToClient(window, &hit.pt);
        item.hItem = TreeView_HitTest(window, &hit);
        if (!item.hItem) return launchButtonAt(window, hit.pt);
    }
    return itemTag(window, item.hItem);
}

namespace {

LRESULT CALLBACK findBarProcedure(HWND edit, UINT message, WPARAM wParam, LPARAM lParam, UINT_PTR, DWORD_PTR) {
    if (message == WM_KEYDOWN && (wParam == VK_RETURN || wParam == VK_ESCAPE)) {
        bool shift = GetKeyState(VK_SHIFT) < 0;
        PostMessageW(GetParent(edit), wParam == VK_RETURN ? NT_FIND_NEXT : NT_FIND_CLOSE, shift, 0);
        return 0;
    }
    // the edit control beeps on the WM_CHAR of Enter and Escape
    if (message == WM_CHAR && (wParam == '\r' || wParam == 27)) return 0;
    if (message == WM_NCDESTROY) RemoveWindowSubclass(edit, findBarProcedure, 1);
    return DefSubclassProc(edit, message, wParam, lParam);
}

}  // namespace

extern "C" void *nt_find_bar_create(void *parent, uint32_t dpi) {
    HWND edit = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | WS_BORDER | ES_AUTOHSCROLL, 0, 0, 100, 24, static_cast<HWND>(parent),
                                nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!edit) return nullptr;
    SetWindowSubclass(edit, findBarProcedure, 1, 0);
    SendMessageW(edit, EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(L"Find"));
    setFont(edit, dpi);
    return edit;
}

extern "C" int32_t nt_tree_label_edit(intptr_t notification, int64_t *tag, uint16_t *text, int32_t capacity) {
    auto header = reinterpret_cast<const NMHDR *>(notification);
    if (header->code != TVN_BEGINLABELEDITW && header->code != TVN_ENDLABELEDITW) return 0;
    auto edit = reinterpret_cast<const NMTVDISPINFOW *>(notification);
    *tag = static_cast<int64_t>(edit->item.lParam);
    if (header->code == TVN_BEGINLABELEDITW) return 1;
    if (!edit->item.pszText) return 3;
    if (text && capacity > 0) {
        size_t count = wcslen(edit->item.pszText);
        if (count > static_cast<size_t>(capacity - 1)) count = static_cast<size_t>(capacity - 1);
        memcpy(text, edit->item.pszText, count * sizeof(wchar_t));
        text[count] = 0;
    }
    return 2;
}

extern "C" void nt_tree_edit(void *tree, void *item) {
    SetFocus(static_cast<HWND>(tree));
    TreeView_EditLabel(static_cast<HWND>(tree), static_cast<HTREEITEM>(item));
}

extern "C" void nt_tree_set_edit_text(void *tree, const uint16_t *text) {
    if (HWND edit = TreeView_GetEditControl(static_cast<HWND>(tree))) {
        SetWindowTextW(edit, reinterpret_cast<const wchar_t *>(text));
        SendMessageW(edit, EM_SETSEL, 0, -1);
    }
}

// see NativeShim.cpp: the shim stays clear of the MSVC STL
#ifdef _YVALS_CORE_H_
#error "NativeShim must not include the MSVC STL"
#endif
