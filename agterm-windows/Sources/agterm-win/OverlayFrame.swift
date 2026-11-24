import AgtermWinKit
import Foundation
import WinSDK

// the window procedure finds its frame here, from the frame's creation to its destruction
private nonisolated(unsafe) var frames: [HWND: OverlayFrame] = [:]

/// OverlayFrame holds a program overlay's terminal over its session's: flush with the session's area when full, a
/// bordered panel when floating. Destroying it ends the terminal and its program with it.
@MainActor
final class OverlayFrame {
    private(set) var window: HWND?
    let terminal: NativeTerminal
    fileprivate static let borderBrush = CreateSolidBrush(0x808080)

    init(parent: HWND?, points: Float, dpi: UInt32) {
        let instance = GetModuleHandleW(nil)
        let className = Array("agterm-overlay".utf16) + [0]
        className.withUnsafeBufferPointer { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = overlayFrameProcedure
            windowClass.hInstance = instance
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512)) // IDC_ARROW
            windowClass.lpszClassName = name.baseAddress
            RegisterClassExW(&windowClass)
        }
        let window = CreateWindowExW(0, className, nil, DWORD(WS_CHILD) | DWORD(WS_CLIPCHILDREN) | DWORD(WS_CLIPSIBLINGS), 0, 0, 1, 1,
                                     parent, nil, instance, nil)
        self.window = window
        terminal = NativeTerminal(parent: window, points: points)
        terminal.setDPI(dpi)
        if let window { frames[window] = self }
    }

    /// place puts the frame at `rect` above its siblings, `border` pixels around the terminal, shown or hidden.
    func place(_ rect: NativeOverlay.Rect, border: Int32, shown: Bool) {
        SetWindowPos(window, nil, rect.x, rect.y, rect.width, rect.height,
                     UINT(SWP_NOACTIVATE) | UINT(shown ? SWP_SHOWWINDOW : SWP_HIDEWINDOW))
        terminal.move(x: border, y: border, width: max(rect.width - 2 * border, 1), height: max(rect.height - 2 * border, 1))
    }

    var shown: Bool { IsWindowVisible(window) }

    func destroy() {
        DestroyWindow(window)
    }

    fileprivate func destroyed() {
        if let window { frames[window] = nil }
        window = nil
    }
}

private let overlayFrameProcedure: WNDPROC = { window, message, wParam, lParam in
    MainActor.assumeIsolated {
        guard let window, let frame = frames[window] else { return DefWindowProcW(window, message, wParam, lParam) }
        switch message {
        case UINT(WM_ERASEBKGND):
            var client = RECT()
            GetClientRect(window, &client)
            FillRect(HDC(bitPattern: UInt(wParam)), &client, OverlayFrame.borderBrush)
            return 1
        case UINT(WM_SETFOCUS), UINT(WM_LBUTTONDOWN):
            // the border gives the keyboard to the terminal it frames
            SetFocus(frame.terminal.window)
            return 0
        case UINT(WM_DESTROY):
            frame.destroyed()
            return 0
        default:
            return DefWindowProcW(window, message, wParam, lParam)
        }
    }
}
