import AgtermWinKit
import Foundation
import NativeShim
import WinSDK
import agtermCore

private let pageOverlayFrameProcedure: WNDPROC = { window, message, wParam, lParam in
    DefWindowProcW(window, message, wParam, lParam)
}

/// PageOverlayFrame hosts a WebView2 page over a session, in the same overlay rectangle as a program overlay.
@MainActor
final class PageOverlayFrame {
    private(set) var window: HWND?
    private var page: UnsafeMutableRawPointer?

    private static func nullTerminatedUTF16(_ text: String) -> [UInt16] {
        var wide = Array(text.utf16)
        wide.append(0)
        return wide
    }

    init(parent: HWND?, dataFolder: URL) {
        let instance = GetModuleHandleW(nil)
        let className = Self.nullTerminatedUTF16("agterm-page-overlay")
        className.withUnsafeBufferPointer { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = pageOverlayFrameProcedure
            windowClass.hInstance = instance
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            windowClass.lpszClassName = name.baseAddress
            RegisterClassExW(&windowClass)
        }
        let host = CreateWindowExW(0, className, nil, DWORD(WS_CHILD) | DWORD(WS_CLIPCHILDREN) | DWORD(WS_CLIPSIBLINGS),
                                   0, 0, 1, 1, parent, nil, instance, nil)
        window = host
        if let host {
            page = Self.nullTerminatedUTF16(dataFolder.path).withUnsafeBufferPointer {
                nt_page_create(UnsafeMutableRawPointer(host), $0.baseAddress)
            }
        }
    }

    func place(_ rect: NativeOverlay.Rect, border: Int32, shown: Bool) {
        SetWindowPos(window, nil, rect.x, rect.y, rect.width, rect.height,
                     UINT(SWP_NOACTIVATE) | UINT(shown ? SWP_SHOWWINDOW : SWP_HIDEWINDOW))
        let inset = max(border, 0)
        let width = max(rect.width - 2 * inset, 1), height = max(rect.height - 2 * inset, 1)
        if let page { nt_page_move(page, inset, inset, width, height) }
    }

    var shown: Bool { IsWindowVisible(window) }

    func load(file path: String) {
        guard let page else { return }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        Self.nullTerminatedUTF16(normalized).withUnsafeBufferPointer {
            nt_page_navigate_file(page, $0.baseAddress)
        }
    }

    func load(url: URL) {
        guard let page else { return }
        Self.nullTerminatedUTF16(url.absoluteString).withUnsafeBufferPointer {
            nt_page_navigate_url(page, $0.baseAddress)
        }
    }

    func load(html: String) {
        guard let page else { return }
        Self.nullTerminatedUTF16(html).withUnsafeBufferPointer { nt_page_navigate_html(page, $0.baseAddress) }
    }

    func loadState() -> HtmlLoadState {
        guard let page else { return .failed }
        switch nt_page_state(page) {
        case 1: return .loaded
        case 0: return .loading
        default: return .failed
        }
    }

    func documentTitle() -> String? {
        guard let page, nt_page_state(page) == 1 else { return nil }
        return Self.text(page, nt_page_title)
    }

    func loadError() -> String? {
        guard let page else { return "the page view could not be created" }
        guard nt_page_state(page) == 2 else { return nil }
        return Self.text(page, nt_page_error)
    }

    private static func text(_ page: UnsafeMutableRawPointer,
                             _ read: (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt16>?, Int32) -> Int32) -> String? {
        var buffer = [UInt16](repeating: 0, count: 512)
        let length = read(page, &buffer, Int32(buffer.count))
        guard length > 0, length < buffer.count else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    func destroy() {
        if let page { nt_page_destroy(page) }
        if let window { DestroyWindow(window) }
        self.page = nil
        window = nil
    }
}