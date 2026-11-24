import AgtermWinKit
import Foundation
import NativeShim
import WinSDK

// the window procedure finds the panel here while it exists
private nonisolated(unsafe) var panel: QuickWindow?

/// QuickWindow is the quick terminal: one throwaway shell for the whole app in a borderless topmost panel on the monitor
/// under the pointer. Losing the keyboard hides a panel a person summoned; one `quick show` pinned stays. Hiding keeps
/// the shell; its exit drops it, and the next show starts a fresh one.
@MainActor
final class QuickWindow {
    private(set) var window: HWND?
    private(set) var terminal: NativeTerminal?
    private var pinned = false
    /// resignedAt is when losing the keyboard last hid the panel: a click on a button that toggles it lands right after.
    private(set) var resignedAt = Date.distantPast
    private let points: () -> Float
    /// configure wires a new terminal as the window's are, and start runs its shell.
    private let configure: (NativeTerminal) -> Void
    private let start: (NativeTerminal) -> Void
    var onVisibility: (() -> Void)?

    init(points: @escaping () -> Float, configure: @escaping (NativeTerminal) -> Void, start: @escaping (NativeTerminal) -> Void) {
        self.points = points
        self.configure = configure
        self.start = start
        let instance = GetModuleHandleW(nil)
        let className = Array("agterm-quick".utf16) + [0]
        className.withUnsafeBufferPointer { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = quickWindowProcedure
            windowClass.hInstance = instance
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512)) // IDC_ARROW
            windowClass.hbrBackground = CreateSolidBrush(0x808080)
            windowClass.lpszClassName = name.baseAddress
            RegisterClassExW(&windowClass)
        }
        window = CreateWindowExW(DWORD(WS_EX_TOOLWINDOW) | DWORD(WS_EX_TOPMOST), className, Array("Quick Terminal".utf16) + [0],
                                 DWORD(WS_POPUP) | DWORD(WS_CLIPCHILDREN), 0, 0, 800, 500, nil, nil, instance, nil)
        panel = self
        if let window { nt_dark_title_bar(UnsafeMutableRawPointer(window)) }
    }

    var shown: Bool { window.map { IsWindowVisible($0) } ?? false }

    /// show puts the panel on the pointer's monitor and gives it the keyboard; `pinned` keeps it there when it loses it.
    func show(pinned: Bool) {
        guard let window else { return }
        self.pinned = pinned
        var pointer = POINT()
        GetCursorPos(&pointer)
        var monitor = MONITORINFO()
        monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        GetMonitorInfoW(MonitorFromPoint(pointer, DWORD(MONITOR_DEFAULTTONEAREST)), &monitor)
        let work = monitor.rcWork
        let frame = QuickPanel.frame(work: .init(x: work.left, y: work.top, width: work.right - work.left, height: work.bottom - work.top),
                                     dpi: GetDpiForWindow(window))
        let wasShown = shown
        SetWindowPos(window, HWND(bitPattern: -1), frame.x, frame.y, frame.width, frame.height, UINT(SWP_SHOWWINDOW)) // HWND_TOPMOST
        if terminal == nil {
            let made = NativeTerminal(parent: window, points: points())
            made.setDPI(GetDpiForWindow(window))
            configure(made)
            made.onExit = { [unowned self] _ in shellExited() }
            terminal = made
            layout()
            start(made)
        } else {
            layout()
        }
        SetForegroundWindow(window)
        SetFocus(terminal?.window)
        if !wasShown { onVisibility?() }
    }

    func hide() {
        guard shown else { return }
        pinned = false
        ShowWindow(window, SW_HIDE)
        onVisibility?()
    }

    fileprivate func layout() {
        var client = RECT()
        GetClientRect(window, &client)
        // a one-pixel edge in the class's grey marks the panel off whatever is behind it
        terminal?.move(x: 1, y: 1, width: max(client.right - 2, 1), height: max(client.bottom - 2, 1))
    }

    fileprivate func deactivated() {
        guard shown, !pinned else { return }
        resignedAt = Date()
        hide()
    }

    fileprivate func focus() { SetFocus(terminal?.window) }

    private func shellExited() {
        let ended = terminal
        terminal = nil
        hide()
        // after the exit message that reported it has returned
        DispatchQueue.main.async { if let window = ended?.window { DestroyWindow(window) } }
    }
}

private let quickWindowProcedure: WNDPROC = { window, message, wParam, lParam in
    MainActor.assumeIsolated {
        guard let panel, panel.window == window else { return DefWindowProcW(window, message, wParam, lParam) }
        switch message {
        case UINT(WM_SIZE):
            panel.layout()
            return 0
        case UINT(WM_ACTIVATE):
            if wParam & 0xFFFF == WPARAM(WA_INACTIVE) { panel.deactivated() }
            return DefWindowProcW(window, message, wParam, lParam)
        case UINT(WM_SETFOCUS):
            panel.focus()
            return 0
        case UINT(WM_CLOSE):
            panel.hide()
            return 0
        default:
            return DefWindowProcW(window, message, wParam, lParam)
        }
    }
}
