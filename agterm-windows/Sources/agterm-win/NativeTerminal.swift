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

    fileprivate func wheel(_ delta: Int16) {
        if let terminal { nt_scroll(terminal, Int32(delta) / 40) }
    }

    /// key sends what a non-character key types; false leaves the key to Windows (Alt+F4, Alt+Space).
    fileprivate func key(_ key: Int32) -> Bool {
        let shift = GetKeyState(VK_SHIFT) < 0, control = GetKeyState(VK_CONTROL) < 0, alt = GetKeyState(VK_MENU) < 0
        if shift, control, key == Int32(UInt8(ascii: "V")) {
            paste()
            return true
        }
        if shift, key == VK_PRIOR || key == VK_NEXT, let terminal {
            nt_scroll(terminal, (key == VK_PRIOR ? 1 : -1) * max(grid.rows / 2, 1))
            return true
        }
        if alt, key == VK_F4 { return false }
        let modifier = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (control ? 4 : 0)
        let cursor = { (final: String) in modifier == 1 ? "\u{1b}[\(final)" : "\u{1b}[1;\(modifier)\(final)" }
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
        if let terminal { nt_scroll_to_bottom(terminal) }
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
            native.wheel(Int16(truncatingIfNeeded: wParam >> 16))
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
