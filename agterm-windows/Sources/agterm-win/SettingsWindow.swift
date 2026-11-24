import AgtermWinKit
import Foundation
import WinSDK

/// SettingsWindow is agterm-win's Settings: its Appearance group picks the theme, the dark-mode theme that follows
/// Windows' app mode, and the font; its Notifications group what a notification does; its agterm-server group the WSL
/// distributions whose server starts as agterm opens. An appearance change previews
/// on the terminals at once; OK keeps every change, Cancel and closing put back what was there when the window
/// opened, as the macOS theme picker previews, commits and cancels.
@MainActor
final class SettingsWindow {
    struct Values: Equatable {
        var appearance: Appearance
        var points: Float
        var notifications: NotificationSettings
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
    private var font: HFONT?
    private var loading = true

    // UDM_SETBUDDY, UDM_SETRANGE32, UDM_SETPOS32, UDM_GETPOS32
    private static let setBuddy = UINT(WM_USER + 105), setRange = UINT(WM_USER + 111), setPosition = UINT(WM_USER + 113),
                       getPosition = UINT(WM_USER + 114)

    private enum Control: Int32 {
        case theme = 101, follows, darkTheme, fontFamily, size, sizeArrows, banners, sound, unseenCount, flash
    }

    // the agterm-server group's check box for `distributions[index]` has this id plus the index
    private static let distributionBase: Int32 = 300

    /// show opens Settings over `owner`, or brings an open one to the front. `finish` gets the kept values, nil for a
    /// cancel.
    static func show(owner: HWND?, values: Values, themes: [String], fonts: [String], distributions: [String],
                     preview: @escaping (Values) -> Void, finish: @escaping (Values?) -> Void) {
        if let window = current?.window {
            SetForegroundWindow(window)
            return
        }
        let settings = SettingsWindow(values: values, themes: themes, fonts: fonts, distributions: distributions, preview: preview,
                                      finish: finish)
        current = settings
        settings.create(owner: owner)
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
        // two check boxes a row, or the one line saying WSL listed none
        let serverRows = Int32(max((distributions.count + 1) / 2, 1))
        let serverGroupHeight = 56 + serverRows * 26
        let buttonsTop = 604 + serverGroupHeight + 14
        var frame = RECT(left: 0, top: 0, right: scaled(520), bottom: scaled(buttonsTop + 40))
        let style = DWORD(WS_OVERLAPPED) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)
        AdjustWindowRectExForDpi(&frame, style, false, 0, UINT(dpi))
        var ownerFrame = RECT()
        if let owner { GetWindowRect(owner, &ownerFrame) }
        let width = frame.right - frame.left, height = frame.bottom - frame.top
        let x = owner == nil ? CW_USEDEFAULT : ownerFrame.left + (ownerFrame.right - ownerFrame.left - width) / 2
        let y = owner == nil ? CW_USEDEFAULT : ownerFrame.top + (ownerFrame.bottom - ownerFrame.top - height) / 2
        guard let window = CreateWindowExW(DWORD(WS_EX_DLGMODALFRAME), className, Array("agterm Settings".utf16) + [0], style,
                                           x, y, width, height, owner, nil, instance, nil) else {
            log("settings: CreateWindowExW failed: \(GetLastError())")
            Self.current = nil
            return
        }
        self.window = window
        font = CreateFontW(-MulDiv(9, dpi, 72), 0, 0, 0, FW_NORMAL, 0, 0, 0, DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                           DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH), Array("Segoe UI".utf16) + [0])

        func add(_ className: String, _ text: String, _ style: Int32, _ x: Int32, _ y: Int32, _ width: Int32, _ height: Int32,
                 id: Int32 = 0, exStyle: Int32 = 0) -> HWND? {
            let child = CreateWindowExW(DWORD(exStyle), Array(className.utf16) + [0], Array(text.utf16) + [0],
                                        DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | DWORD(bitPattern: style),
                                        scaled(x), scaled(y), scaled(width), scaled(height), window, HMENU(bitPattern: Int(id)), instance, nil)
            SendMessageW(child, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: font))), 1)
            return child
        }
        let tab = Int32(WS_TABSTOP)
        _ = add("BUTTON", "Appearance", Int32(BS_GROUPBOX), 12, 8, 496, 440)
        _ = add("STATIC", "Theme", 0, 28, 32, 220, 18)
        let themeList = add("LISTBOX", "", Int32(LBS_NOTIFY) | Int32(WS_VSCROLL) | Int32(WS_BORDER) | tab, 28, 52, 220, 250, id: Control.theme.rawValue)
        _ = add("STATIC", "Dark mode theme", 0, 272, 32, 220, 18)
        let darkList = add("LISTBOX", "", Int32(LBS_NOTIFY) | Int32(WS_VSCROLL) | Int32(WS_BORDER) | tab, 272, 52, 220, 250,
                           id: Control.darkTheme.rawValue)
        let follows = add("BUTTON", "Follow Windows light and dark mode", Int32(BS_AUTOCHECKBOX) | tab, 28, 308, 464, 22,
                          id: Control.follows.rawValue)
        _ = add("STATIC", "Font", 0, 28, 344, 300, 18)
        let fontBox = add("COMBOBOX", "", Int32(CBS_DROPDOWNLIST) | Int32(WS_VSCROLL) | tab, 28, 364, 300, 300, id: Control.fontFamily.rawValue)
        _ = add("STATIC", "Size", 0, 352, 344, 140, 18)
        let size = add("EDIT", "", Int32(ES_NUMBER) | tab, 352, 364, 80, 24, id: Control.size.rawValue, exStyle: Int32(WS_EX_CLIENTEDGE))
        let arrows = add("msctls_updown32", "", Int32(UDS_SETBUDDYINT) | Int32(UDS_ALIGNRIGHT) | Int32(UDS_ARROWKEYS), 0, 0, 0, 0,
                         id: Control.sizeArrows.rawValue)
        SendMessageW(arrows, Self.setBuddy, WPARAM(UInt(bitPattern: Int(bitPattern: size))), 0)
        SendMessageW(arrows, Self.setRange, WPARAM(Int(NativeMenu.pointRange.lowerBound)), LPARAM(Int(NativeMenu.pointRange.upperBound)))
        _ = add("BUTTON", "Notifications", Int32(BS_GROUPBOX), 12, 456, 496, 140)
        let checkbox = Int32(BS_AUTOCHECKBOX) | tab
        let banners = add("BUTTON", "Show Windows notifications", checkbox, 28, 480, 230, 22, id: Control.banners.rawValue)
        let sound = add("BUTTON", "Play the notification sound", checkbox, 28, 506, 230, 22, id: Control.sound.rawValue)
        let unseen = add("BUTTON", "Count notifications beside a session's \u{25CF}", checkbox, 28, 532, 464, 22,
                         id: Control.unseenCount.rawValue)
        _ = add("STATIC", "Flash the taskbar button", 0, 272, 480, 220, 18)
        let flash = add("COMBOBOX", "", Int32(CBS_DROPDOWNLIST) | tab, 272, 500, 220, 200, id: Control.flash.rawValue)
        _ = add("BUTTON", "agterm-server", Int32(BS_GROUPBOX), 12, 604, 496, serverGroupHeight)
        _ = add("STATIC", "Start agterm-server at launch in", 0, 28, 628, 464, 18)
        var serverBoxes: [HWND?] = []
        for (index, distribution) in distributions.enumerated() {
            let column = Int32(index % 2), row = Int32(index / 2)
            serverBoxes.append(add("BUTTON", "WSL \(distribution)", checkbox, 28 + column * 244, 650 + row * 26, 220, 22,
                                   id: Self.distributionBase + Int32(index)))
        }
        if distributions.isEmpty { _ = add("STATIC", "WSL lists no distributions.", 0, 28, 650, 464, 18) }
        _ = add("BUTTON", "OK", Int32(BS_DEFPUSHBUTTON) | tab, 316, buttonsTop, 92, 28, id: Int32(IDOK))
        _ = add("BUTTON", "Cancel", Int32(BS_PUSHBUTTON) | tab, 416, buttonsTop, 92, 28, id: Int32(IDCANCEL))

        let rows = ["Default"] + themes
        for list in [themeList, darkList] { rows.forEach { addString($0, to: list, message: LB_ADDSTRING) } }
        select(original.appearance.theme, in: themeList, message: LB_SETCURSEL)
        select(original.appearance.darkTheme ?? original.appearance.theme, in: darkList, message: LB_SETCURSEL)
        SendMessageW(follows, UINT(BM_SETCHECK), WPARAM(original.appearance.followsSystem ? BST_CHECKED : BST_UNCHECKED), 0)
        EnableWindow(darkList, original.appearance.followsSystem ? true : false)
        (["Default (Cascadia Mono)"] + fonts).forEach { addString($0, to: fontBox, message: CB_ADDSTRING) }
        let fontIndex = original.appearance.fontFamily.flatMap { fonts.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        SendMessageW(fontBox, UINT(CB_SETCURSEL), WPARAM(fontIndex), 0)
        SendMessageW(arrows, Self.setPosition, 0, LPARAM(Int(original.points.rounded())))
        let notifications = original.notifications
        for (control, on) in [(banners, notifications.banners), (sound, notifications.sound), (unseen, notifications.unseenCount)] {
            SendMessageW(control, UINT(BM_SETCHECK), WPARAM(on ? BST_CHECKED : BST_UNCHECKED), 0)
        }
        EnableWindow(sound, notifications.banners ? true : false)
        TaskbarFlash.allCases.forEach { addString($0.title, to: flash, message: CB_ADDSTRING) }
        SendMessageW(flash, UINT(CB_SETCURSEL), WPARAM(TaskbarFlash.allCases.firstIndex(of: notifications.flash) ?? 0), 0)
        for (box, distribution) in zip(serverBoxes, distributions) {
            SendMessageW(box, UINT(BM_SETCHECK), WPARAM(original.serverAtLaunch.contains(distribution) ? BST_CHECKED : BST_UNCHECKED), 0)
        }
        loading = false
        ShowWindow(window, SW_SHOW)
        SetFocus(themeList)
    }

    private func addString(_ text: String, to control: HWND?, message: Int32) {
        let units = Array(text.utf16) + [0]
        units.withUnsafeBufferPointer { _ = SendMessageW(control, UINT(message), 0, LPARAM(Int(bitPattern: $0.baseAddress))) }
    }

    /// select picks `theme`'s row, Default for nil or a theme no longer installed.
    private func select(_ theme: String?, in list: HWND?, message: Int32) {
        let index = theme.flatMap { themes.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        SendMessageW(list, UINT(message), WPARAM(index), 0)
    }

    private func item(_ control: Control) -> HWND? { GetDlgItem(window, control.rawValue) }

    /// values reads the controls; a theme row past Default names `themes[row - 1]`.
    private var values: Values {
        let theme = { (row: Int) in row > 0 && row <= self.themes.count ? self.themes[row - 1] : nil }
        let themeRow = Int(SendMessageW(item(.theme), UINT(LB_GETCURSEL), 0, 0))
        let darkRow = Int(SendMessageW(item(.darkTheme), UINT(LB_GETCURSEL), 0, 0))
        let follows = SendMessageW(item(.follows), UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED)
        let fontRow = Int(SendMessageW(item(.fontFamily), UINT(CB_GETCURSEL), 0, 0))
        let points = Float(Int32(truncatingIfNeeded: SendMessageW(item(.sizeArrows), Self.getPosition, 0, 0)))
        let appearance = Appearance(theme: theme(themeRow), darkTheme: follows ? theme(darkRow) : nil, followsSystem: follows,
                                    fontFamily: fontRow > 0 && fontRow <= fonts.count ? fonts[fontRow - 1] : nil)
        let checked = { (control: Control) in SendMessageW(self.item(control), UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED) }
        let flashRow = Int(SendMessageW(item(.flash), UINT(CB_GETCURSEL), 0, 0))
        let notifications = NotificationSettings(banners: checked(.banners), sound: checked(.sound),
                                                 flash: TaskbarFlash.allCases.indices.contains(flashRow) ? TaskbarFlash.allCases[flashRow] : .untilFocused,
                                                 unseenCount: checked(.unseenCount))
        let serverAtLaunch = distributions.enumerated().filter { index, _ in
            SendMessageW(GetDlgItem(self.window, Self.distributionBase + Int32(index)), UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED)
        }.map(\.element)
        return Values(appearance: appearance, points: min(max(points, NativeMenu.pointRange.lowerBound), NativeMenu.pointRange.upperBound),
                      notifications: notifications, serverAtLaunch: Set(serverAtLaunch))
    }

    fileprivate func command(_ id: Int32, notification: Int32) {
        switch id {
        case Int32(IDOK): close(keeping: values)
        case Int32(IDCANCEL): close(keeping: nil)
        case Control.banners.rawValue where notification == BN_CLICKED:
            EnableWindow(item(.sound), SendMessageW(item(.banners), UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED) ? true : false)
        case Control.follows.rawValue where notification == BN_CLICKED:
            EnableWindow(item(.darkTheme), SendMessageW(item(.follows), UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED) ? true : false)
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
        Self.current = nil
    }
}

private let settingsWindowProcedure: WNDPROC = { window, message, wParam, lParam in
    MainActor.assumeIsolated {
        switch message {
        case UINT(WM_COMMAND):
            SettingsWindow.current?.command(Int32(wParam & 0xFFFF), notification: Int32(wParam >> 16 & 0xFFFF))
            return 0
        case UINT(WM_CLOSE):
            SettingsWindow.current?.close(keeping: nil)
            return 0
        default:
            return DefWindowProcW(window, message, wParam, lParam)
        }
    }
}
