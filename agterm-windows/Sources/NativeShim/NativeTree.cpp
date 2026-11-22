#include "NativeShim.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <uxtheme.h>

#pragma comment(lib, "uxtheme")

extern "C" void *nt_tree_create(void *parent, uint32_t dpi) {
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_TREEVIEW_CLASSES};
    InitCommonControlsEx(&controls);
    HWND tree = CreateWindowExW(0, WC_TREEVIEWW, L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | TVS_HASBUTTONS | TVS_LINESATROOT |
                                    TVS_SHOWSELALWAYS | TVS_FULLROWSELECT,
                                0, 0, 100, 100, static_cast<HWND>(parent), nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!tree) return nullptr;
    SetWindowTheme(tree, L"DarkMode_Explorer", nullptr);
    TreeView_SetExtendedStyle(tree, TVS_EX_DOUBLEBUFFER, TVS_EX_DOUBLEBUFFER);
    TreeView_SetBkColor(tree, RGB(0x25, 0x25, 0x26));
    TreeView_SetTextColor(tree, RGB(0xCC, 0xCC, 0xCC));
    nt_tree_set_dpi(tree, dpi);
    return tree;
}

extern "C" void nt_tree_set_dpi(void *tree, uint32_t dpi) {
    auto window = static_cast<HWND>(tree);
    HFONT font = CreateFontW(-MulDiv(10, static_cast<int>(dpi), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                             OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    auto previous = reinterpret_cast<HFONT>(SendMessageW(window, WM_GETFONT, 0, 0));
    SendMessageW(window, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
    if (previous) DeleteObject(previous);
    TreeView_SetItemHeight(window, MulDiv(24, static_cast<int>(dpi), 96));
}

extern "C" void nt_tree_clear(void *tree) { TreeView_DeleteAllItems(static_cast<HWND>(tree)); }

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
