import Foundation
import NativeShim
import WinSDK

private let nativeOutputMessage = UINT(WM_APP + 11)
private let nativeExitMessage = UINT(WM_APP + 12)
private nonisolated(unsafe) var native: NativeTerminal!

/// NativeTerminal is the `--native` spike: one program under ConPTY whose output agwinterm's emulator core parses and
/// Direct2D with DirectWrite draws, with no WebView2.
@MainActor
final class NativeTerminal {
    static let coreFile = "agwinterm_core-abi19.dll"

    private let commandLine: String
    private var window: HWND?
    private var terminal: OpaquePointer?
    private var console: PseudoConsole?
    private var grid = (columns: Int32(0), rows: Int32(0))
    private var highSurrogate: UInt16?
    // a shortcut's key also reaches TranslateMessage, whose WM_CHAR (^C, ^V) must not type
    private var swallowCharacter = false
    private var clicks = (count: 0, time: Int32(0), x: Int32(0), y: Int32(0))
    private var reportingButton: Int32?
    private var lastMotionCell = (column: Int32(0), row: Int32(0))
    private let pendingLock = NSLock()
    nonisolated(unsafe) private var pending = Data()

    private init(commandLine: String) {
        self.commandLine = commandLine
    }

    static func open(commandLine: String, core: URL) {
        nt_init_process()
        native = NativeTerminal(commandLine: commandLine)
        native.open(core: core)
    }

    private func open(core: URL) {
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
        guard let window = CreateWindowExW(0, className, Array("agterm".utf16) + [0], DWORD(WS_OVERLAPPEDWINDOW),
                                           CW_USEDEFAULT, CW_USEDEFAULT, 1100, 700, nil, nil, instance, nil) else {
            log("native: CreateWindowExW failed: \(GetLastError())")
            exit(1)
        }
        self.window = window
        var error = [UInt16](repeating: 0, count: 512)
        terminal = nt_create(UnsafeMutableRawPointer(window), Array(core.path.utf16) + [0], Array("Cascadia Mono".utf16) + [0], 11,
                             &error, Int32(error.count))
        guard terminal != nil else {
            let reason = String(decodingCString: error, as: UTF16.self)
            log("native: \(reason)")
            MessageBoxW(window, Array(reason.utf16) + [0], Array("agterm".utf16) + [0], UINT(MB_ICONERROR))
            exit(1)
        }
        ShowWindow(window, SW_SHOW)
        resize()
        do {
            console = try PseudoConsole(commandLine: commandLine, columns: Int16(clamping: grid.columns), rows: Int16(clamping: grid.rows),
                                        onOutput: { [unowned self] in enqueue($0, window: window) },
                                        onExit: { PostMessageW(window, nativeExitMessage, WPARAM($0), 0) })
            log("native: started \(commandLine) at \(grid.columns)x\(grid.rows)")
        } catch {
            log("native: start failed: \(error)")
            feed(Data("\u{1b}[31m\(error)\u{1b}[0m\r\n".utf8))
        }
    }

    nonisolated private func enqueue(_ data: Data, window: HWND?) {
        pendingLock.lock()
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
            nt_feed(terminal, raw.bindMemory(to: UInt8.self).baseAddress, UInt32(raw.count), { _, bytes, length in
                guard let bytes else { return }
                let reply = Data(bytes: bytes, count: Int(length))
                MainActor.assumeIsolated { native.console?.write(reply) }
            }, nil)
        }
    }

    fileprivate func exited(_ code: DWORD) {
        log("native: program exited \(code)")
        feed(Data("\r\n\u{1b}[2m[process exited \(code)]\u{1b}[0m\r\n".utf8))
        console?.close()
        console = nil
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

    fileprivate func dpiChanged(_ dpi: UInt32, suggested: RECT) {
        guard let terminal else { return }
        nt_set_dpi(terminal, dpi)
        SetWindowPos(window, nil, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top,
                     UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        resize()
    }

    fileprivate func paint() {
        if let terminal { nt_paint(terminal) }
    }

    fileprivate func focus(_ focused: Bool) {
        if let terminal { nt_set_focus(terminal, focused ? 1 : 0) }
    }

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
            send(String(repeating: cursorKey(delta > 0 ? "A" : "B", modifier: 1), count: Int(notches) * 3))
        } else {
            nt_scroll(terminal, Int32(delta) / 40)
        }
    }

    /// mouseDown takes button 0 left, 1 middle, 2 right at a client pixel.
    fileprivate func mouseDown(_ button: Int32, x: Int32, y: Int32) {
        guard let terminal else { return }
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
        } else if button == 2 {
            if nt_has_selection(terminal) != 0 { copySelection() } else { paste() }
        }
    }

    fileprivate func mouseUp(_ button: Int32, x: Int32, y: Int32) {
        ReleaseCapture()
        if let held = reportingButton {
            reportingButton = nil
            report(held, x: x, y: y, release: true)
        } else if button == 0, let terminal {
            nt_select_end(terminal)
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

    /// report encodes a mouse event for the program: SGR when it asked for ?1006, the X10 bytes otherwise.
    private func report(_ button: Int32, x: Int32, y: Int32, release: Bool, motion: Bool = false) {
        guard let terminal else { return }
        var column: Int32 = 0, row: Int32 = 0
        nt_cell_at(terminal, x, y, &column, &row)
        var code = button + (motion ? 32 : 0)
        if GetKeyState(VK_SHIFT) < 0 { code += 4 }
        if GetKeyState(VK_MENU) < 0 { code += 8 }
        if GetKeyState(VK_CONTROL) < 0 { code += 16 }
        if mouseModes & 8 != 0 {
            console?.write(Data("\u{1b}[<\(code);\(column);\(row)\(release ? "m" : "M")".utf8))
        } else {
            if release { code = (code & ~3) | 3 }
            let clamp = { (value: Int32) in UInt8(clamping: min(value + 32, 255)) }
            console?.write(Data([0x1B, 0x5B, 0x4D, clamp(code), clamp(column), clamp(row)]))
        }
    }

    private func cursorKey(_ final: String, modifier: Int) -> String {
        let application = terminal.map { nt_application_cursor($0) != 0 } ?? false
        return modifier > 1 ? "\u{1b}[1;\(modifier)\(final)" : application ? "\u{1b}O\(final)" : "\u{1b}[\(final)"
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

    /// key sends what a non-character key types; false leaves the key to Windows (Alt+F4, Alt+Space).
    fileprivate func key(_ key: Int32) -> Bool {
        let shift = GetKeyState(VK_SHIFT) < 0, control = GetKeyState(VK_CONTROL) < 0, alt = GetKeyState(VK_MENU) < 0
        if shift, control, key == Int32(UInt8(ascii: "V")) {
            swallowCharacter = true
            paste()
            return true
        }
        if control, key == Int32(UInt8(ascii: "C")), shift || terminal.map({ nt_has_selection($0) != 0 }) == true {
            swallowCharacter = true
            copySelection()
            return true
        }
        if shift, key == VK_PRIOR || key == VK_NEXT, let terminal {
            nt_scroll(terminal, (key == VK_PRIOR ? 1 : -1) * max(grid.rows / 2, 1))
            return true
        }
        if alt, key == VK_F4 { return false }
        let modifier = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (control ? 4 : 0)
        let cursor = { (final: String) in self.cursorKey(final, modifier: modifier) }
        let tilde = { (code: Int) in modifier == 1 ? "\u{1b}[\(code)~" : "\u{1b}[\(code);\(modifier)~" }
        let function = { (final: String) in modifier == 1 ? "\u{1b}O\(final)" : "\u{1b}[1;\(modifier)\(final)" }
        let sequence: String? = switch key {
        case VK_UP: cursor("A")
        case VK_DOWN: cursor("B")
        case VK_RIGHT: cursor("C")
        case VK_LEFT: cursor("D")
        case VK_HOME: cursor("H")
        case VK_END: cursor("F")
        case VK_INSERT: tilde(2)
        case VK_DELETE: tilde(3)
        case VK_PRIOR: tilde(5)
        case VK_NEXT: tilde(6)
        case VK_F1: function("P")
        case VK_F2: function("Q")
        case VK_F3: function("R")
        case VK_F4: function("S")
        case VK_F5: tilde(15)
        case VK_F6: tilde(17)
        case VK_F7: tilde(18)
        case VK_F8: tilde(19)
        case VK_F9: tilde(20)
        case VK_F10: tilde(21)
        case VK_F11: tilde(23)
        case VK_F12: tilde(24)
        default: nil
        }
        guard let sequence else { return false }
        send(sequence)
        return true
    }

    fileprivate func character(_ unit: UInt16, alt: Bool) {
        if swallowCharacter {
            swallowCharacter = false
            return
        }
        if (0xD800..<0xDC00).contains(unit) {
            highSurrogate = unit
            return
        }
        let units = highSurrogate.map { (0xDC00..<0xE000).contains(unit) ? [$0, unit] : [unit] } ?? [unit]
        highSurrogate = nil
        let text = unit == 0x08 ? "\u{7f}" : String(decoding: units, as: UTF16.self)
        send((alt ? "\u{1b}" : "") + text)
    }

    private func paste() {
        guard let terminal, OpenClipboard(window) else { return }
        defer { CloseClipboard() }
        guard let handle = GetClipboardData(UINT(CF_UNICODETEXT)), let pointer = GlobalLock(handle) else { return }
        defer { GlobalUnlock(handle) }
        let text = String(decodingCString: pointer.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
            .replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        send(nt_bracketed_paste(terminal) != 0 ? "\u{1b}[200~\(text)\u{1b}[201~" : text)
    }

    private func send(_ text: String) {
        if let terminal {
            nt_scroll_to_bottom(terminal)
            nt_select_clear(terminal)
        }
        console?.write(Data(text.utf8))
    }

    fileprivate func destroy() {
        console?.close()
        console = nil
        nt_destroy(terminal)
        terminal = nil
    }
}

private let nativeWindowProcedure: WNDPROC = { window, message, wParam, lParam in
    MainActor.assumeIsolated {
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
            var point = POINT(x: Int32(Int16(truncatingIfNeeded: lParam)), y: Int32(Int16(truncatingIfNeeded: lParam >> 16)))
            ScreenToClient(window, &point)
            native.wheel(Int16(truncatingIfNeeded: wParam >> 16), x: point.x, y: point.y)
            return 0
        case UINT(WM_LBUTTONDOWN), UINT(WM_MBUTTONDOWN), UINT(WM_RBUTTONDOWN):
            let button: Int32 = message == UINT(WM_LBUTTONDOWN) ? 0 : message == UINT(WM_MBUTTONDOWN) ? 1 : 2
            native.mouseDown(button, x: Int32(Int16(truncatingIfNeeded: lParam)), y: Int32(Int16(truncatingIfNeeded: lParam >> 16)))
            return 0
        case UINT(WM_LBUTTONUP), UINT(WM_MBUTTONUP), UINT(WM_RBUTTONUP):
            let button: Int32 = message == UINT(WM_LBUTTONUP) ? 0 : message == UINT(WM_MBUTTONUP) ? 1 : 2
            native.mouseUp(button, x: Int32(Int16(truncatingIfNeeded: lParam)), y: Int32(Int16(truncatingIfNeeded: lParam >> 16)))
            return 0
        case UINT(WM_MOUSEMOVE):
            native.mouseMove(x: Int32(Int16(truncatingIfNeeded: lParam)), y: Int32(Int16(truncatingIfNeeded: lParam >> 16)),
                             leftHeld: wParam & WPARAM(MK_LBUTTON) != 0)
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
            native.exited(DWORD(truncatingIfNeeded: wParam))
            return 0
        case UINT(WM_DESTROY):
            native.destroy()
            PostQuitMessage(0)
            return 0
        default:
            return DefWindowProcW(window, message, wParam, lParam)
        }
    }
}
