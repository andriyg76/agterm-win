import AgtermWinKit
import Foundation
import NativeShim
import WinSDK

private let nativeOutputMessage = UINT(WM_APP + 11)
private let nativeExitMessage = UINT(WM_APP + 12)
// the window procedure finds its terminal here; a terminal is in it from its window's creation to its destruction
private nonisolated(unsafe) var terminals: [HWND: NativeTerminal] = [:]

/// NativeTerminal is one terminal drawn without WebView2: the program under ConPTY, agwinterm's emulator core parsing
/// its output, Direct2D with DirectWrite drawing it. It is a top-level window of its own (`--native -- <command>`) or
/// a child of NativeShell beside the sidebar.
@MainActor
final class NativeTerminal {
    static let coreFile = "agwinterm_core-abi19.dll"

    private(set) var window: HWND?
    private var terminal: OpaquePointer?
    private var console: PseudoConsole?
    private var grid = (columns: Int32(0), rows: Int32(0))
    private var highSurrogate: UInt16?
    private var points = NativeMenu.defaultPoints
    private var clicks = (count: 0, time: Int32(0), x: Int32(0), y: Int32(0))
    private var reportingButton: Int32?
    private var lastMotionCell = (column: Int32(0), row: Int32(0))
    // a generation per started program, so output or an exit still queued from the previous one is dropped
    private var generation = 0
    private var lastMatch: ScrollbackSearch.Match?
    private let pendingLock = NSLock()
    nonisolated(unsafe) private var pending = Data()
    nonisolated(unsafe) private var acceptedGeneration = 0
    private let testScreen = ProcessInfo.processInfo.environment["AGTERM_WIN_TEST_SCREEN"]
    /// onExit runs when the started program exits.
    var onExit: (() -> Void)?
    /// onWindowCommand takes the commands a terminal inside a window passes up (New and Close Session, Quit); without
    /// it those shortcuts are not taken and Quit closes the terminal's own window.
    var onWindowCommand: ((NativeMenu.Command) -> Void)?
    /// onFontSize takes a font command's new size, for a window that sizes all its terminals together.
    var onFontSize: ((Float) -> Void)?

    /// open runs `commandLine` in a top-level terminal window.
    static func open(commandLine: String, core: URL) {
        nt_init_process()
        let terminal = NativeTerminal(parent: nil, core: core)
        ShowWindow(terminal.window, SW_SHOW)
        terminal.resize()
        terminal.start(commandLine)
    }

    init(parent: HWND?, core: URL, points: Float = NativeMenu.defaultPoints) {
        self.points = points
        let instance = GetModuleHandleW(nil)
        let className = Array("agterm-native".utf16) + [0]
        className.withUnsafeBufferPointer { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = nativeWindowProcedure
            windowClass.hInstance = instance
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32513)) // IDC_IBEAM
            windowClass.hIcon = LoadIconW(instance, UnsafePointer<WCHAR>(bitPattern: 1))
            windowClass.lpszClassName = name.baseAddress
            RegisterClassExW(&windowClass)
        }
        let style = parent == nil ? DWORD(WS_OVERLAPPEDWINDOW) : DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | DWORD(WS_CLIPSIBLINGS)
        guard let window = CreateWindowExW(0, className, Array("agterm".utf16) + [0], style,
                                           CW_USEDEFAULT, CW_USEDEFAULT, 1100, 700, parent, nil, instance, nil) else {
            log("native: CreateWindowExW failed: \(GetLastError())")
            exit(1)
        }
        self.window = window
        terminals[window] = self
        if parent == nil { nt_dark_title_bar(UnsafeMutableRawPointer(window)) }
        var error = [UInt16](repeating: 0, count: 512)
        terminal = nt_create(UnsafeMutableRawPointer(window), Array(core.path.utf16) + [0], Array("Cascadia Mono".utf16) + [0], points,
                             &error, Int32(error.count))
        guard terminal != nil else {
            let reason = String(decodingCString: error, as: UTF16.self)
            log("native: \(reason)")
            MessageBoxW(parent ?? window, Array(reason.utf16) + [0], Array("agterm".utf16) + [0], UINT(MB_ICONERROR))
            exit(1)
        }
    }

    /// start replaces whatever ran in the terminal with `commandLine` on a fresh screen.
    func start(_ commandLine: String, directory: String? = nil) {
        reset()
        let generation = generation, window = window
        do {
            console = try PseudoConsole(commandLine: commandLine, directory: directory, columns: Int16(clamping: grid.columns), rows: Int16(clamping: grid.rows),
                                        onOutput: { [unowned self] in enqueue($0, generation: generation, window: window) },
                                        onExit: { PostMessageW(window, nativeExitMessage, WPARAM($0), LPARAM(generation)) })
            log("native: started \(commandLine) at \(grid.columns)x\(grid.rows)")
        } catch {
            log("native: start failed: \(error)")
            feed(Data("\u{1b}[31m\(error)\u{1b}[0m\r\n".utf8))
        }
    }

    /// show replaces whatever ran in the terminal with a dimmed line and no program.
    func show(notice: String) {
        reset()
        feed(Data("\u{1b}[2m\(notice)\u{1b}[0m\r\n".utf8))
    }

    private func reset() {
        console?.close()
        console = nil
        generation += 1
        pendingLock.lock()
        pending = Data()
        acceptedGeneration = generation
        pendingLock.unlock()
        if let terminal { nt_reset(terminal) }
    }

    nonisolated private func enqueue(_ data: Data, generation: Int, window: HWND?) {
        pendingLock.lock()
        guard generation == acceptedGeneration else {
            pendingLock.unlock()
            return
        }
        let first = pending.isEmpty
        pending.append(data)
        pendingLock.unlock()
        if first { PostMessageW(window, nativeOutputMessage, 0, 0) }
    }

    fileprivate func flush() {
        pendingLock.lock()
        let data = pending
        pending = Data()
        pendingLock.unlock()
        feed(data)
    }

    private func feed(_ data: Data) {
        guard let terminal, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            nt_feed(terminal, raw.bindMemory(to: UInt8.self).baseAddress, UInt32(raw.count), { context, bytes, length in
                guard let context, let bytes else { return }
                let reply = Data(bytes: bytes, count: Int(length))
                MainActor.assumeIsolated { Unmanaged<NativeTerminal>.fromOpaque(context).takeUnretainedValue().console?.write(reply) }
            }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    fileprivate func exited(_ code: DWORD, generation: Int) {
        guard generation == self.generation else { return }
        flush()
        log("native: program exited \(code)")
        feed(Data("\r\n\u{1b}[2m[process exited with code \(code)]\u{1b}[0m\r\n".utf8))
        console?.close()
        console = nil
        onExit?()
        if let testScreen, let terminal {
            let length = nt_screen_text(terminal, nil, 0)
            var text = [UInt16](repeating: 0, count: Int(length))
            nt_screen_text(terminal, &text, length)
            try? Data(String(decoding: text, as: UTF16.self).utf8).write(to: URL(fileURLWithPath: testScreen))
            DestroyWindow(GetAncestor(window, UINT(GA_ROOT)))
        }
    }

    func move(x: Int32, y: Int32, width: Int32, height: Int32) {
        MoveWindow(window, x, y, width, height, true)
    }

    fileprivate func resize() {
        guard let terminal, let window else { return }
        var client = RECT()
        GetClientRect(window, &client)
        var columns: Int32 = 0, rows: Int32 = 0
        nt_resize(terminal, client.right - client.left, client.bottom - client.top, &columns, &rows)
        guard (columns, rows) != grid else { return }
        grid = (columns, rows)
        console?.resize(columns: Int16(clamping: columns), rows: Int16(clamping: rows))
    }

    func setDPI(_ dpi: UInt32) {
        guard let terminal else { return }
        nt_set_dpi(terminal, dpi)
        resize()
    }

    fileprivate func dpiChanged(_ dpi: UInt32, suggested: RECT) {
        SetWindowPos(window, nil, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top,
                     UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        setDPI(dpi)
    }

    fileprivate func paint() {
        if let terminal { nt_paint(terminal) }
    }

    fileprivate func focus(_ focused: Bool) {
        if let terminal { nt_set_focus(terminal, focused ? 1 : 0) }
    }

    private var modifiers: TerminalInput.Modifiers {
        var modifiers: TerminalInput.Modifiers = []
        if GetKeyState(VK_SHIFT) < 0 { modifiers.insert(.shift) }
        if GetKeyState(VK_MENU) < 0 { modifiers.insert(.alt) }
        if GetKeyState(VK_CONTROL) < 0 { modifiers.insert(.control) }
        return modifiers
    }

    var hasSelection: Bool { terminal.map { nt_has_selection($0) != 0 } ?? false }

    private var applicationCursor: Bool { terminal.map { nt_application_cursor($0) != 0 } ?? false }

    private var mouseModes: Int32 { terminal.map { nt_mouse_modes($0) } ?? 0 }

    /// reportsMouse is a program asking for the mouse; Shift keeps the mouse for selecting, as in other terminals.
    private var reportsMouse: Bool { mouseModes & 7 != 0 && GetKeyState(VK_SHIFT) >= 0 }

    /// wheel scrolls the scrollback, or reports the wheel to a program that takes the mouse, or on an alternate
    /// screen without mouse reporting (less, man) sends arrow keys.
    fileprivate func wheel(_ delta: Int16, x: Int32, y: Int32) {
        guard let terminal else { return }
        let notches = max(abs(Int32(delta)) / 120, 1)
        if reportsMouse {
            for _ in 0..<notches { report(delta > 0 ? 64 : 65, x: x, y: y, release: false) }
        } else if mouseModes & 16 != 0 {
            send(TerminalInput.wheel(up: delta > 0, notches: Int(notches), applicationCursor: applicationCursor))
        } else {
            nt_scroll(terminal, Int32(delta) / 40)
        }
    }

    /// mouseDown takes button 0 left, 1 middle, 2 right at a client pixel.
    fileprivate func mouseDown(_ button: Int32, x: Int32, y: Int32) {
        guard let terminal else { return }
        SetFocus(window)
        if button == 0, modifiers == .control, let url = link(x: x, y: y) {
            log("native: opening \(url)")
            ShellExecuteW(window, Array("open".utf16) + [0], Array(url.utf16) + [0], nil, nil, SW_SHOWNORMAL)
            return
        }
        SetCapture(window)
        if reportsMouse {
            reportingButton = button
            report(button, x: x, y: y, release: false)
            return
        }
        if button == 0 {
            let time = GetMessageTime()
            let near = abs(x - clicks.x) <= GetSystemMetrics(SM_CXDOUBLECLK) && abs(y - clicks.y) <= GetSystemMetrics(SM_CYDOUBLECLK)
            let count = near && UInt32(bitPattern: time &- clicks.time) <= GetDoubleClickTime() ? clicks.count % 3 + 1 : 1
            clicks = (count, time, x, y)
            nt_select_start(terminal, x, y, Int32(count - 1))
        }
    }

    /// find selects the next match of `needle` older than the last one (newer when not `backward`), starting over from
    /// the newest line when `restart`; false when there is none.
    func find(_ needle: String, backward: Bool, restart: Bool) -> Bool {
        guard let terminal else { return false }
        if restart { lastMatch = nil }
        let found = ScrollbackSearch.find(needle, lineCount: Int(nt_line_count(terminal)), line: { line in
            let count = nt_line_runes(terminal, Int32(line), nil, 0)
            var runes = [UInt32](repeating: 0, count: Int(count))
            nt_line_runes(terminal, Int32(line), &runes, count)
            return runes
        }, after: lastMatch, backward: backward)
        lastMatch = found
        if let found { nt_select_cells(terminal, Int32(found.line), Int32(found.column), Int32(found.cells)) } else { nt_select_clear(terminal) }
        return found != nil
    }

    /// link is the web address under a client pixel; Ctrl+click opens it, over a program that takes the mouse too.
    private func link(x: Int32, y: Int32) -> String? {
        guard let terminal else { return nil }
        var column: Int32 = 0
        let count = nt_row_runes(terminal, x, y, nil, 0, &column)
        var runes = [UInt32](repeating: 0, count: Int(count))
        nt_row_runes(terminal, x, y, &runes, count, &column)
        let row = TerminalLink.row(runes, column: Int(column))
        return TerminalLink.url(in: row.text, at: row.index)
    }

    fileprivate func mouseUp(_ button: Int32, x: Int32, y: Int32) {
        ReleaseCapture()
        if let held = reportingButton {
            reportingButton = nil
            report(held, x: x, y: y, release: true)
        } else if button == 0, let terminal {
            nt_select_end(terminal)
        } else if button == 2 {
            var point = POINT(x: x, y: y)
            ClientToScreen(window, &point)
            contextMenu(at: point)
        }
    }

    /// contextMenu is the terminal's menu; a program that takes the mouse gets right clicks, and Shift+right opens it.
    fileprivate func contextMenu(at point: POINT) {
        let entries = NativeMenu.terminal(hasSelection: terminal.map { nt_has_selection($0) != 0 } ?? false,
                                          canPaste: IsClipboardFormatAvailable(UINT(CF_UNICODETEXT)))
        if case .command(let command)? = showMenu(entries, owner: window, at: point) { perform(command) }
    }

    func perform(_ command: NativeMenu.Command) {
        guard let terminal else { return }
        switch command {
        case .copy: copySelection()
        case .paste: paste()
        case .selectAll: nt_select_all(terminal)
        case .clearScrollback: nt_clear_scrollback(terminal)
        case .fontBigger, .fontSmaller, .fontReset:
            let next = NativeMenu.points(after: command, from: points)
            if let onFontSize { onFontSize(next) } else { setFontSize(next) }
        case .newSession, .closeSession, .nextSession, .previousSession, .find, .quit:
            if let onWindowCommand { onWindowCommand(command) } else if command == .quit { DestroyWindow(window) }
        }
    }

    fileprivate func mouseMove(x: Int32, y: Int32, leftHeld: Bool) {
        guard let terminal else { return }
        let modes = mouseModes
        if reportingButton != nil ? modes & 6 != 0 : modes & 4 != 0 && GetKeyState(VK_SHIFT) >= 0 {
            var column: Int32 = 0, row: Int32 = 0
            nt_cell_at(terminal, x, y, &column, &row)
            guard (column, row) != lastMotionCell else { return }
            lastMotionCell = (column, row)
            report(reportingButton ?? 3, x: x, y: y, release: false, motion: true)
        } else if leftHeld, reportingButton == nil {
            nt_select_extend(terminal, x, y)
        }
    }

    private func report(_ button: Int32, x: Int32, y: Int32, release: Bool, motion: Bool = false) {
        guard let terminal else { return }
        var column: Int32 = 0, row: Int32 = 0
        nt_cell_at(terminal, x, y, &column, &row)
        console?.write(Data(TerminalInput.mouse(button: Int(button), column: Int(column), row: Int(row), release: release,
                                                motion: motion, modifiers: modifiers, sgr: mouseModes & 8 != 0)))
    }

    private func copySelection() {
        guard let terminal else { return }
        let length = nt_selection_text(terminal, nil, 0)
        var text = [UInt16](repeating: 0, count: Int(length) + 1)
        nt_selection_text(terminal, &text, length)
        nt_select_clear(terminal)
        guard length > 0, OpenClipboard(window) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(text.count * 2)), let pointer = GlobalLock(memory) else { return }
        text.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        GlobalUnlock(memory)
        SetClipboardData(UINT(CF_UNICODETEXT), memory)
    }

    /// shortcut is the menu command a key chord runs; Ctrl+C copies only while there is a selection.
    private func shortcut(_ key: Int32, _ modifiers: TerminalInput.Modifiers) -> NativeMenu.Command? {
        let letter = { (character: Character) in key == Int32(character.asciiValue!) }
        if modifiers == [.shift, .control] {
            if letter("C") { return .copy }
            if letter("V") { return .paste }
            if letter("A") { return .selectAll }
            if letter("K") { return .clearScrollback }
            if onWindowCommand != nil, letter("T") { return .newSession }
            if onWindowCommand != nil, letter("W") { return .closeSession }
            if onWindowCommand != nil, letter("F") { return .find }
        }
        if onWindowCommand != nil, key == VK_TAB, modifiers == .control || modifiers == [.shift, .control] {
            return modifiers.contains(.shift) ? .previousSession : .nextSession
        }
        guard modifiers == .control else { return nil }
        if letter("C"), terminal.map({ nt_has_selection($0) != 0 }) == true { return .copy }
        if key == VK_OEM_PLUS { return .fontBigger }
        if key == VK_OEM_MINUS { return .fontSmaller }
        if letter("0") { return .fontReset }
        return nil
    }

    /// key sends what a non-character key types; false leaves the key to Windows (Alt+F4, Alt+Space).
    fileprivate func key(_ key: Int32) -> Bool {
        let modifiers = modifiers
        if let command = shortcut(key, modifiers) {
            // TranslateMessage already queued the chord's WM_CHAR (^C, ^V, ^_), which must not type
            var queued = MSG()
            while PeekMessageW(&queued, window, UINT(WM_CHAR), UINT(WM_CHAR), UINT(PM_REMOVE)) {}
            perform(command)
            return true
        }
        if key == VK_APPS {
            // at the mouse when it is over the terminal, else at its corner
            var point = POINT(), origin = POINT(), client = RECT()
            GetCursorPos(&point)
            GetClientRect(window, &client)
            ClientToScreen(window, &origin)
            if !(origin.x..<origin.x + client.right).contains(point.x) || !(origin.y..<origin.y + client.bottom).contains(point.y) {
                point = origin
            }
            contextMenu(at: point)
            return true
        }
        if modifiers == .shift, key == VK_PRIOR || key == VK_NEXT, let terminal {
            nt_scroll(terminal, (key == VK_PRIOR ? 1 : -1) * max(grid.rows / 2, 1))
            return true
        }
        if modifiers.contains(.alt), key == VK_F4 { return false }
        let mapped: TerminalInput.Key? = switch key {
        case VK_UP: .up
        case VK_DOWN: .down
        case VK_RIGHT: .right
        case VK_LEFT: .left
        case VK_HOME: .home
        case VK_END: .end
        case VK_INSERT: .insert
        case VK_DELETE: .delete
        case VK_PRIOR: .pageUp
        case VK_NEXT: .pageDown
        case VK_F1...VK_F12: .function(Int(key - VK_F1) + 1)
        default: nil
        }
        guard let mapped, let sequence = TerminalInput.sequence(for: mapped, modifiers: modifiers, applicationCursor: applicationCursor)
        else { return false }
        send(sequence)
        return true
    }

    fileprivate func character(_ unit: UInt16, alt: Bool) {
        if (0xD800..<0xDC00).contains(unit) {
            highSurrogate = unit
            return
        }
        let units = highSurrogate.map { (0xDC00..<0xE000).contains(unit) ? [$0, unit] : [unit] } ?? [unit]
        highSurrogate = nil
        send(TerminalInput.character(String(decoding: units, as: UTF16.self), alt: alt))
    }

    private func paste() {
        guard let terminal, OpenClipboard(window) else { return }
        defer { CloseClipboard() }
        guard let handle = GetClipboardData(UINT(CF_UNICODETEXT)), let pointer = GlobalLock(handle) else { return }
        defer { GlobalUnlock(handle) }
        let text = String(decodingCString: pointer.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
        send(TerminalInput.paste(text, bracketed: nt_bracketed_paste(terminal) != 0))
    }

    private func send(_ text: String) {
        if let terminal {
            nt_scroll_to_bottom(terminal)
            nt_select_clear(terminal)
        }
        console?.write(Data(text.utf8))
    }

    func setFontSize(_ points: Float) {
        guard let terminal else { return }
        self.points = points
        nt_set_font_size(terminal, points)
        resize()
    }

    func setVisible(_ visible: Bool) {
        ShowWindow(window, visible ? SW_SHOW : SW_HIDE)
        if visible, let terminal { nt_show_title(terminal) }
    }

    fileprivate func destroyed() {
        console?.close()
        console = nil
        nt_destroy(terminal)
        terminal = nil
        if let window { terminals[window] = nil }
    }
}

/// showMenu opens a dark popup of `entries` at a screen point and returns what was picked, nil when dismissed.
@MainActor
func showMenu(_ entries: [NativeMenu.Entry], owner: HWND?, at point: POINT) -> NativeMenu.Pick? {
    var menus: [HMENU] = []
    defer { menus.forEach { DestroyMenu($0) } }
    func build(_ entries: [NativeMenu.Entry]) -> HMENU? {
        guard let menu = CreatePopupMenu() else { return nil }
        menus.append(menu)
        for entry in entries {
            let text = Array((entry.shortcut.isEmpty ? entry.title : "\(entry.title)\t\(entry.shortcut)").utf16) + [0]
            let state = entry.enabled ? 0 : UINT(MF_GRAYED)
            if !entry.children.isEmpty, let submenu = build(entry.children) {
                menus.removeAll { $0 == submenu } // the parent menu destroys its submenus
                AppendMenuW(menu, UINT(MF_POPUP) | state, UINT_PTR(UInt(bitPattern: Int(bitPattern: submenu))), text)
            } else if let pick = entry.pick {
                AppendMenuW(menu, UINT(MF_STRING) | state, UINT_PTR(pick.id), text)
            } else if entry.children.isEmpty, entry.title.isEmpty {
                AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
            } else {
                AppendMenuW(menu, UINT(MF_STRING) | UINT(MF_GRAYED), 0, text)
            }
        }
        return menu
    }
    guard let menu = build(entries) else { return nil }
    return NativeMenu.Pick(id: Int(nt_track_menu(UnsafeMutableRawPointer(menu), UnsafeMutableRawPointer(owner), point.x, point.y)))
}

private let nativeWindowProcedure: WNDPROC = { window, message, wParam, lParam in
    MainActor.assumeIsolated {
        guard let window, let native = terminals[window] else { return DefWindowProcW(window, message, wParam, lParam) }
        let x = Int32(Int16(truncatingIfNeeded: lParam)), y = Int32(Int16(truncatingIfNeeded: lParam >> 16))
        switch message {
        case UINT(WM_SIZE):
            native.resize()
            return 0
        case UINT(WM_PAINT):
            native.paint()
            return 0
        case UINT(WM_ERASEBKGND):
            return 1
        case UINT(WM_DPICHANGED):
            if let suggested = UnsafePointer<RECT>(bitPattern: UInt(lParam)) {
                native.dpiChanged(UInt32(wParam >> 16 & 0xFFFF), suggested: suggested.pointee)
            }
            return 0
        case UINT(WM_SETFOCUS), UINT(WM_KILLFOCUS):
            native.focus(message == UINT(WM_SETFOCUS))
            return 0
        case UINT(WM_MOUSEWHEEL):
            var point = POINT(x: x, y: y)
            ScreenToClient(window, &point)
            native.wheel(Int16(truncatingIfNeeded: wParam >> 16), x: point.x, y: point.y)
            return 0
        case UINT(WM_LBUTTONDOWN), UINT(WM_MBUTTONDOWN), UINT(WM_RBUTTONDOWN):
            native.mouseDown(message == UINT(WM_LBUTTONDOWN) ? 0 : message == UINT(WM_MBUTTONDOWN) ? 1 : 2, x: x, y: y)
            return 0
        case UINT(WM_LBUTTONUP), UINT(WM_MBUTTONUP), UINT(WM_RBUTTONUP):
            native.mouseUp(message == UINT(WM_LBUTTONUP) ? 0 : message == UINT(WM_MBUTTONUP) ? 1 : 2, x: x, y: y)
            return 0
        case UINT(WM_MOUSEMOVE):
            native.mouseMove(x: x, y: y, leftHeld: wParam & WPARAM(MK_LBUTTON) != 0)
            return 0
        case UINT(WM_KEYDOWN), UINT(WM_SYSKEYDOWN):
            return native.key(Int32(truncatingIfNeeded: wParam)) ? 0 : DefWindowProcW(window, message, wParam, lParam)
        case UINT(WM_CHAR):
            native.character(UInt16(truncatingIfNeeded: wParam), alt: false)
            return 0
        case UINT(WM_SYSCHAR):
            guard wParam != WPARAM(UInt8(ascii: " ")) else { return DefWindowProcW(window, message, wParam, lParam) }
            native.character(UInt16(truncatingIfNeeded: wParam), alt: true)
            return 0
        case nativeOutputMessage:
            native.flush()
            return 0
        case nativeExitMessage:
            native.exited(DWORD(truncatingIfNeeded: wParam), generation: Int(lParam))
            return 0
        case UINT(WM_DESTROY):
            native.destroyed()
            // a child terminal's shell owns quitting
            if GetParent(window) == nil { PostQuitMessage(0) }
            return 0
        default:
            return DefWindowProcW(window, message, wParam, lParam)
        }
    }
}
