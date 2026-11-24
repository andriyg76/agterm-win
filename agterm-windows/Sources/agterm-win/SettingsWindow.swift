import AgtermWinKit
import Foundation
import WinSDK
import agtermCore

/// SettingsWindow is agterm-win's Settings, in tabs as macOS agterm's: General (new sessions, closing, the mouse, the
/// WSL distributions whose agterm-server starts at launch), Appearance (themes and the font) and Notifications. An appearance change previews on the
/// terminals at once; OK keeps every change, Cancel and closing put back what was there when the window opened, as the
/// macOS theme picker previews, commits and cancels.
@MainActor
final class SettingsWindow {
    struct Values: Equatable {
        var appearance: Appearance
        var points: Float
        var notifications: NotificationSettings
        var general: GeneralSettings
        /// serverAtLaunch are the distributions ticked to start their agterm-server at launch.
        var serverAtLaunch: Set<String> = []
    }

    private(set) static var current: SettingsWindow?

    private let original: Values
    private let themes: [String]
    private let fonts: [String]
    private let distributions: [String]
    private let preview: (Values) -> Void
    private let finish: (Values?) -> Void
    private var window: HWND?
    private var tabs: HWND?
    private var pages: [[HWND?]] = [[], [], []]
    private var font: HFONT?
    private var loading = true
    private var dialogBrush: HBRUSH?
    private var chromeText = COLORREF(bitPattern: 0xCCCCCC)
    private var chromeBg = COLORREF(bitPattern: 0x252526)
    private var chromeDim = COLORREF(bitPattern: 0x808080)
    private var chromeDark = true

    // UDM_SETBUDDY, UDM_SETRANGE32, UDM_SETPOS32, UDM_GETPOS32; TCM_INSERTITEMW, TCM_GETCURSEL; TCN_SELCHANGE
    private static let setBuddy = UINT(WM_USER + 105), setRange = UINT(WM_USER + 111), setPosition = UINT(WM_USER + 113),
                       getPosition = UINT(WM_USER + 114)
    private static let insertTab = UINT(0x133E), currentTab = UINT(0x130B), selectTab = UINT(0x130C)  // TCM_SETCURSEL
    fileprivate static let tabChanged = UINT(bitPattern: -551)

    private enum Control: Int32 {
        case theme = 101, follows, darkTheme, fontFamily, size, sizeArrows, banners, sound, unseenCount, flash
        case directory, customDirectory, placement, confirmClose, rightClickPastes, scrollLines, scrollArrows
    }

    // the check box for `distributions[index]` has this id plus the index
    private static let distributionBase: Int32 = 300

    private static let directories: [(AppSettings.NewSessionDirectory, String)] = [
        (.home, "Your home folder"), (.currentSession, "The selected session's folder"), (.custom, "This folder"),
    ]
    private static let placements: [(AppSettings.NewSessionPlacement, String)] = [
        (.end, "At the end of the list"), (.afterCurrent, "Right after the selected session"),
    ]

    /// show opens Settings over `owner`, or brings an open one to the front. `finish` gets the kept values, nil for a
    /// cancel.
    static func show(owner: HWND?, tab: SettingsTab = .general, values: Values, themes: [String], fonts: [String], distributions: [String],
                     chrome: ChromePalette, preview: @escaping (Values) -> Void, finish: @escaping (Values?) -> Void) {
        if let open = current, let window = open.window {
            open.select(tab)
            SetForegroundWindow(window)
            return
        }
        let settings = SettingsWindow(values: values, themes: themes, fonts: fonts, distributions: distributions, preview: preview,
                                      finish: finish)
        current = settings
        settings.applyChrome(chrome)
        settings.create(owner: owner)
        settings.select(tab)
    }

    /// select shows `tab`, as a click on it does.
    private func select(_ tab: SettingsTab) {
        let index = SettingsTab.allCases.firstIndex(of: tab) ?? 0
        SendMessageW(tabs, Self.selectTab, WPARAM(index), 0)
        showPage()
    }

    private init(values: Values, themes: [String], fonts: [String], distributions: [String], preview: @escaping (Values) -> Void,
                 finish: @escaping (Values?) -> Void) {
        original = values
        self.themes = themes
        self.fonts = fonts
        self.distributions = distributions
        self.preview = preview
        self.finish = finish
    }

    var handle: HWND? { window }

    private func applyChrome(_ palette: ChromePalette) {
        if let dialogBrush { DeleteObject(dialogBrush) }
        chromeDark = palette.isDark
        chromeBg = COLORREF(bitPattern: Int32(palette.clientBg & 0xFFFFFF))
        chromeText = COLORREF(bitPattern: Int32(palette.chromeText & 0xFFFFFF))
        chromeDim = COLORREF(bitPattern: Int32(palette.chromeDim & 0xFFFFFF))
        dialogBrush = CreateSolidBrush(COLORREF(bitPattern: Int32(palette.palBg & 0xFFFFFF)))
    }

    private func tintCommCtrls(_ window: HWND?) {
        guard let window else { return }
        let theme = Array((chromeDark ? "DarkMode_Explorer" : "Explorer").utf16) + [0]
        theme.withUnsafeBufferPointer { name in
            SetWindowTheme(window, name.baseAddress, nil)
            var child = GetWindow(window, GW_CHILD)
            while let current = child {
                SetWindowTheme(current, name.baseAddress, nil)
                child = GetWindow(current, GW_HWNDNEXT)
            }
        }
    }

    fileprivate func controlColors(_ context: HDC?) -> LRESULT {
        guard let context, let dialogBrush else { return 0 }
        SetTextColor(context, chromeText)
        SetBkColor(context, chromeBg)
        return LRESULT(Int(bitPattern: dialogBrush))
    }

    private func create(owner: HWND?) {
        let instance = GetModuleHandleW(nil)
        let className = Array("agterm-settings".utf16) + [0]
        className.withUnsafeBufferPointer { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = settingsWindowProcedure
            windowClass.hInstance = instance
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512)) // IDC_ARROW
            windowClass.hIcon = LoadIconW(instance, UnsafePointer<WCHAR>(bitPattern: 1))
            windowClass.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1))
            windowClass.lpszClassName = name.baseAddress
            RegisterClassExW(&windowClass)
        }
        let dpi = owner.map { Int32(GetDpiForWindow($0)) } ?? 96
        let scaled = { (value: Int32) in MulDiv(value, dpi, 96) }
        var frame = RECT(left: 0, top: 0, right: scaled(520), bottom: scaled(560))
        let style = DWORD(WS_OVERLAPPED) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)
        AdjustWindowRectExForDpi(&frame, style, false, 0, UINT(dpi))
        var ownerFrame = RECT()
        if let owner { GetWindowRect(owner, &ownerFrame) }
        let width = frame.right - frame.left, height = frame.bottom - frame.top
        let x = owner == nil ? CW_USEDEFAULT : ownerFrame.left + (ownerFrame.right - ownerFrame.left - width) / 2
        let y = owner == nil ? CW_USEDEFAULT : ownerFrame.top + (ownerFrame.bottom - ownerFrame.top - height) / 2
        guard let window = CreateWindowExW(DWORD(WS_EX_DLGMODALFRAME) | DWORD(WS_EX_CONTROLPARENT), className,
                                           Array("agterm Settings".utf16) + [0], style, x, y, width, height, owner, nil, instance, nil) else {
            log("settings: CreateWindowExW failed: \(GetLastError())")
            Self.current = nil
            return
        }
        self.window = window
        font = CreateFontW(-MulDiv(9, dpi, 72), 0, 0, 0, FW_NORMAL, 0, 0, 0, DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                           DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH), Array("Segoe UI".utf16) + [0])

        var page = -1
        func add(_ className: String, _ text: String, _ style: Int32, _ x: Int32, _ y: Int32, _ width: Int32, _ height: Int32,
                 id: Int32 = 0, exStyle: Int32 = 0) -> HWND? {
            let visible = page <= 0 ? DWORD(WS_VISIBLE) : 0
            let child = CreateWindowExW(DWORD(exStyle), Array(className.utf16) + [0], Array(text.utf16) + [0],
                                        DWORD(WS_CHILD) | visible | DWORD(bitPattern: style),
                                        scaled(x), scaled(y), scaled(width), scaled(height), window, HMENU(bitPattern: Int(id)), instance, nil)
            SendMessageW(child, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: font))), 1)
            if page >= 0 { pages[page].append(child) }
            return child
        }
        let tab = Int32(WS_TABSTOP), checkbox = Int32(BS_AUTOCHECKBOX) | Int32(WS_TABSTOP)
        let list = Int32(CBS_DROPDOWNLIST) | Int32(WS_VSCROLL) | tab
        tabs = add("SysTabControl32", "", Int32(WS_CLIPSIBLINGS) | tab, 12, 8, 496, 500)
        for (index, tab) in SettingsTab.allCases.enumerated() { addTab(tab.rawValue.capitalized, at: index) }

        page = 0
        _ = add("STATIC", "New sessions open in", 0, 28, 48, 300, 18)
        let directory = add("COMBOBOX", "", list, 28, 68, 300, 200, id: Control.directory.rawValue)
        let custom = add("EDIT", original.general.newSessionCustomDirectory ?? "", Int32(ES_AUTOHSCROLL) | tab, 28, 100, 464, 24,
                         id: Control.customDirectory.rawValue, exStyle: Int32(WS_EX_CLIENTEDGE))
        _ = add("STATIC", "New sessions go", 0, 28, 136, 300, 18)
        let placement = add("COMBOBOX", "", list, 28, 156, 300, 200, id: Control.placement.rawValue)
        let confirmClose = add("BUTTON", "Ask before closing a session", checkbox, 28, 196, 464, 22, id: Control.confirmClose.rawValue)
        let rightClick = add("BUTTON", "Right-click pastes (Shift+right-click opens the menu)", checkbox, 28, 222, 464, 22,
                             id: Control.rightClickPastes.rawValue)
        _ = add("STATIC", "A mouse wheel notch scrolls this many lines", 0, 28, 258, 400, 18)
        let lines = add("EDIT", "", Int32(ES_NUMBER) | tab, 28, 278, 60, 24, id: Control.scrollLines.rawValue, exStyle: Int32(WS_EX_CLIENTEDGE))
        let lineArrows = add("msctls_updown32", "", Int32(UDS_SETBUDDYINT) | Int32(UDS_ALIGNRIGHT) | Int32(UDS_ARROWKEYS), 0, 0, 0, 0,
                             id: Control.scrollArrows.rawValue)
        _ = add("STATIC", "Start agterm-server at launch in", 0, 28, 318, 464, 18)
        // two a row, as many as the page holds; the menu starts any of them
        let serverBoxes = distributions.prefix(12).enumerated().map { index, distribution in
            add("BUTTON", "WSL \(distribution)", checkbox, 28 + Int32(index % 2) * 244, 340 + Int32(index / 2) * 26, 220, 22,
                id: Self.distributionBase + Int32(index))
        }
        if distributions.isEmpty { _ = add("STATIC", "WSL lists no distributions.", 0, 28, 340, 464, 18) }

        page = 1
        _ = add("STATIC", "Theme", 0, 28, 48, 220, 18)
        let themeList = add("LISTBOX", "", Int32(LBS_NOTIFY) | Int32(WS_VSCROLL) | Int32(WS_BORDER) | tab, 28, 68, 220, 230,
                            id: Control.theme.rawValue)
        _ = add("STATIC", "Dark mode theme", 0, 272, 48, 220, 18)
        let darkList = add("LISTBOX", "", Int32(LBS_NOTIFY) | Int32(WS_VSCROLL) | Int32(WS_BORDER) | tab, 272, 68, 220, 230,
                           id: Control.darkTheme.rawValue)
        let follows = add("BUTTON", "Follow Windows light and dark mode", checkbox, 28, 304, 464, 22, id: Control.follows.rawValue)
        _ = add("STATIC", "Font", 0, 28, 338, 300, 18)
        let fontBox = add("COMBOBOX", "", list, 28, 358, 300, 300, id: Control.fontFamily.rawValue)
        _ = add("STATIC", "Size", 0, 352, 338, 140, 18)
        let size = add("EDIT", "", Int32(ES_NUMBER) | tab, 352, 358, 80, 24, id: Control.size.rawValue, exStyle: Int32(WS_EX_CLIENTEDGE))
        let arrows = add("msctls_updown32", "", Int32(UDS_SETBUDDYINT) | Int32(UDS_ALIGNRIGHT) | Int32(UDS_ARROWKEYS), 0, 0, 0, 0,
                         id: Control.sizeArrows.rawValue)

        page = 2
        let banners = add("BUTTON", "Show Windows notifications", checkbox, 28, 48, 230, 22, id: Control.banners.rawValue)
        let sound = add("BUTTON", "Play the notification sound", checkbox, 28, 74, 230, 22, id: Control.sound.rawValue)
        let unseen = add("BUTTON", "Count notifications beside a session's \u{25CF}", checkbox, 28, 100, 464, 22,
                         id: Control.unseenCount.rawValue)
        _ = add("STATIC", "Flash the taskbar button", 0, 272, 48, 220, 18)
        let flash = add("COMBOBOX", "", list, 272, 68, 220, 200, id: Control.flash.rawValue)

        page = -1
        _ = add("BUTTON", "OK", Int32(BS_DEFPUSHBUTTON) | tab, 316, 520, 92, 28, id: Int32(IDOK))
        _ = add("BUTTON", "Cancel", Int32(BS_PUSHBUTTON) | tab, 416, 520, 92, 28, id: Int32(IDCANCEL))

        let general = original.general
        Self.directories.forEach { addString($0.1, to: directory, message: CB_ADDSTRING) }
        SendMessageW(directory, UINT(CB_SETCURSEL), WPARAM(Self.directories.firstIndex { $0.0 == general.directory } ?? 0), 0)
        EnableWindow(custom, general.directory == .custom ? true : false)
        Self.placements.forEach { addString($0.1, to: placement, message: CB_ADDSTRING) }
        SendMessageW(placement, UINT(CB_SETCURSEL), WPARAM(Self.placements.firstIndex { $0.0 == general.placement } ?? 0), 0)
        check(confirmClose, general.confirmCloseSession)
        check(rightClick, general.rightClickPastes)
        buddy(lineArrows, lines, range: GeneralSettings.scrollLineRange.lowerBound...GeneralSettings.scrollLineRange.upperBound,
              value: general.scrollLines)
        for (box, distribution) in zip(serverBoxes, distributions) { check(box, original.serverAtLaunch.contains(distribution)) }

        let rows = ["Default"] + themes
        for box in [themeList, darkList] { rows.forEach { addString($0, to: box, message: LB_ADDSTRING) } }
        select(original.appearance.theme, in: themeList)
        select(original.appearance.darkTheme ?? original.appearance.theme, in: darkList)
        check(follows, original.appearance.followsSystem)
        EnableWindow(darkList, original.appearance.followsSystem ? true : false)
        (["Default (Cascadia Mono)"] + fonts).forEach { addString($0, to: fontBox, message: CB_ADDSTRING) }
        let fontIndex = original.appearance.fontFamily.flatMap { fonts.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        SendMessageW(fontBox, UINT(CB_SETCURSEL), WPARAM(fontIndex), 0)
        buddy(arrows, size, range: Int(NativeMenu.pointRange.lowerBound)...Int(NativeMenu.pointRange.upperBound),
              value: Int(original.points.rounded()))

        let notifications = original.notifications
        check(banners, notifications.banners)
        check(sound, notifications.sound)
        check(unseen, notifications.unseenCount)
        EnableWindow(sound, notifications.banners ? true : false)
        TaskbarFlash.allCases.forEach { addString($0.title, to: flash, message: CB_ADDSTRING) }
        SendMessageW(flash, UINT(CB_SETCURSEL), WPARAM(TaskbarFlash.allCases.firstIndex(of: notifications.flash) ?? 0), 0)
        if let dialogBrush { SetClassLongPtr(window, GCLP_HBRBACKGROUND, dialogBrush) }
        tintCommCtrls(window)
        loading = false
        ShowWindow(window, SW_SHOW)
        SetFocus(tabs)
    }

    private func addTab(_ title: String, at index: Int) {
        var text = Array(title.utf16) + [0]
        text.withUnsafeMutableBufferPointer { buffer in
            var item = TCITEMW()
            item.mask = UINT(TCIF_TEXT)
            item.pszText = buffer.baseAddress
            withUnsafeMutablePointer(to: &item) { _ = SendMessageW(tabs, Self.insertTab, WPARAM(index), LPARAM(Int(bitPattern: $0))) }
        }
    }

    /// showPage shows the selected tab's controls and hides the others'.
    fileprivate func showPage() {
        let selected = Int(SendMessageW(tabs, Self.currentTab, 0, 0))
        for (index, controls) in pages.enumerated() {
            for control in controls { ShowWindow(control, index == selected ? SW_SHOW : SW_HIDE) }
        }
    }

    private func addString(_ text: String, to control: HWND?, message: Int32) {
        let units = Array(text.utf16) + [0]
        units.withUnsafeBufferPointer { _ = SendMessageW(control, UINT(message), 0, LPARAM(Int(bitPattern: $0.baseAddress))) }
    }

    private func check(_ control: HWND?, _ on: Bool) {
        SendMessageW(control, UINT(BM_SETCHECK), WPARAM(on ? BST_CHECKED : BST_UNCHECKED), 0)
    }

    private func buddy(_ arrows: HWND?, _ edit: HWND?, range: ClosedRange<Int>, value: Int) {
        SendMessageW(arrows, Self.setBuddy, WPARAM(UInt(bitPattern: Int(bitPattern: edit))), 0)
        SendMessageW(arrows, Self.setRange, WPARAM(range.lowerBound), LPARAM(range.upperBound))
        SendMessageW(arrows, Self.setPosition, 0, LPARAM(value))
    }

    /// select picks `theme`'s row, Default for nil or a theme no longer installed.
    private func select(_ theme: String?, in list: HWND?) {
        let index = theme.flatMap { themes.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        SendMessageW(list, UINT(LB_SETCURSEL), WPARAM(index), 0)
    }

    private func item(_ control: Control) -> HWND? { GetDlgItem(window, control.rawValue) }

    private func checked(_ control: Control) -> Bool { SendMessageW(item(control), UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED) }

    private func row(_ control: Control, list: Bool = false) -> Int {
        Int(SendMessageW(item(control), UINT(list ? LB_GETCURSEL : CB_GETCURSEL), 0, 0))
    }

    private func text(_ control: Control) -> String {
        var units = [UInt16](repeating: 0, count: 1024)
        let count = GetWindowTextW(item(control), &units, Int32(units.count))
        return String(decoding: units.prefix(Int(count)), as: UTF16.self)
    }

    /// values reads the controls; a theme row past Default names `themes[row - 1]`.
    private var values: Values {
        let theme = { (row: Int) in row > 0 && row <= self.themes.count ? self.themes[row - 1] : nil }
        let follows = checked(.follows)
        let fontRow = row(.fontFamily)
        let points = Float(Int32(truncatingIfNeeded: SendMessageW(item(.sizeArrows), Self.getPosition, 0, 0)))
        let appearance = Appearance(theme: theme(row(.theme, list: true)), darkTheme: follows ? theme(row(.darkTheme, list: true)) : nil,
                                    followsSystem: follows, fontFamily: fontRow > 0 && fontRow <= fonts.count ? fonts[fontRow - 1] : nil)
        let flashRow = row(.flash)
        let notifications = NotificationSettings(banners: checked(.banners), sound: checked(.sound),
                                                 flash: TaskbarFlash.allCases.indices.contains(flashRow) ? TaskbarFlash.allCases[flashRow] : .untilFocused,
                                                 unseenCount: checked(.unseenCount))
        var general = original.general
        let directoryRow = row(.directory), placementRow = row(.placement)
        general.newSessionDirectory = Self.directories.indices.contains(directoryRow) ? Self.directories[directoryRow].0.rawValue : nil
        let custom = text(.customDirectory).trimmingCharacters(in: .whitespaces)
        general.newSessionCustomDirectory = custom.isEmpty ? nil : custom
        general.newSessionPlacement = Self.placements.indices.contains(placementRow) ? Self.placements[placementRow].0.rawValue : nil
        general.confirmCloseSession = checked(.confirmClose)
        general.rightClickPastes = checked(.rightClickPastes)
        let lines = Int(Int32(truncatingIfNeeded: SendMessageW(item(.scrollArrows), Self.getPosition, 0, 0)))
        general.scrollLines = min(max(lines, GeneralSettings.scrollLineRange.lowerBound), GeneralSettings.scrollLineRange.upperBound)
        let serverAtLaunch = distributions.prefix(12).enumerated().filter { index, _ in
            SendMessageW(GetDlgItem(self.window, Self.distributionBase + Int32(index)), UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED)
        }.map(\.element)
        return Values(appearance: appearance, points: min(max(points, NativeMenu.pointRange.lowerBound), NativeMenu.pointRange.upperBound),
                      notifications: notifications, general: general, serverAtLaunch: Set(serverAtLaunch))
    }

    fileprivate func command(_ id: Int32, notification: Int32) {
        switch id {
        case Int32(IDOK): close(keeping: values)
        case Int32(IDCANCEL): close(keeping: nil)
        case Control.banners.rawValue where notification == BN_CLICKED:
            EnableWindow(item(.sound), checked(.banners) ? true : false)
        case Control.directory.rawValue where notification == CBN_SELCHANGE:
            EnableWindow(item(.customDirectory), Self.directories.indices.contains(row(.directory))
                && Self.directories[row(.directory)].0 == .custom ? true : false)
        case Control.follows.rawValue where notification == BN_CLICKED:
            EnableWindow(item(.darkTheme), checked(.follows) ? true : false)
            changed()
        case Control.theme.rawValue where notification == LBN_SELCHANGE, Control.darkTheme.rawValue where notification == LBN_SELCHANGE,
             Control.fontFamily.rawValue where notification == CBN_SELCHANGE, Control.size.rawValue where notification == EN_CHANGE:
            changed()
        default: break
        }
    }

    private func changed() {
        guard !loading else { return }
        preview(values)
    }

    /// close keeps `kept`, or puts the opening values back for nil.
    fileprivate func close(keeping kept: Values?) {
        guard let window else { return }
        if kept == nil { preview(original) }
        finish(kept)
        self.window = nil
        DestroyWindow(window)
        if let font { DeleteObject(font) }
        if let dialogBrush { DeleteObject(dialogBrush) }
        Self.current = nil
    }
}

private let settingsWindowProcedure: WNDPROC = { window, message, wParam, lParam in
    MainActor.assumeIsolated {
        switch message {
        case UINT(WM_COMMAND):
            SettingsWindow.current?.command(Int32(wParam & 0xFFFF), notification: Int32(wParam >> 16 & 0xFFFF))
            return 0
        case UINT(WM_NOTIFY):
            if let header = UnsafePointer<NMHDR>(bitPattern: Int(lParam)), header.pointee.code == SettingsWindow.tabChanged {
                SettingsWindow.current?.showPage()
            }
            return 0
        case UINT(WM_CLOSE):
            SettingsWindow.current?.close(keeping: nil)
            return 0
        case UINT(WM_CTLCOLORSTATIC), UINT(WM_CTLCOLOREDIT), UINT(WM_CTLCOLORLISTBOX), UINT(WM_CTLCOLORBTN):
            if let colors = SettingsWindow.current?.controlColors(HDC(bitPattern: UInt(wParam))), colors != 0 { return colors }
            return DefWindowProcW(window, message, wParam, lParam)
        default:
            return DefWindowProcW(window, message, wParam, lParam)
        }
    }
}
