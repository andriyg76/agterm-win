import AgtermWinKit
import Foundation
import NativeShim
import WinSDK
import agtermCore

private nonisolated(unsafe) var shell: NativeShell!

/// NativeShell is a remote window drawn without WebView2: the session sidebar as a Win32 tree beside one
/// NativeTerminal showing the selected session.
@MainActor
final class NativeShell {
    private let remote: RemoteWindow
    private var window: HWND?
    private var tree: UnsafeMutableRawPointer?
    private var notice: HWND?
    private var terminal: NativeTerminal!
    private var selected: Foundation.UUID?
    private var running: Foundation.UUID?
    // the tree's tags index these; 0 is a workspace row
    private var tagged: [Foundation.UUID] = []
    private var items: [Foundation.UUID: UnsafeMutableRawPointer] = [:]
    private let darkBrush = CreateSolidBrush(0x262525)
    private var dpi: UInt32 = 96

    static func open(remote: RemoteWindow, core: URL) {
        nt_init_process()
        shell = NativeShell(remote: remote)
        shell.create(core: core)
    }

    private init(remote: RemoteWindow) {
        self.remote = remote
    }

    private func create(core: URL) {
        let instance = GetModuleHandleW(nil)
        let className = Array("agterm-shell".utf16) + [0]
        className.withUnsafeBufferPointer { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = shellWindowProcedure
            windowClass.hInstance = instance
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512)) // IDC_ARROW
            windowClass.hIcon = LoadIconW(instance, UnsafePointer<WCHAR>(bitPattern: 1))
            windowClass.hbrBackground = darkBrush
            windowClass.lpszClassName = name.baseAddress
            RegisterClassExW(&windowClass)
        }
        guard let window = CreateWindowExW(0, className, Array("agterm — WSL \(remote.host.distribution)".utf16) + [0],
                                           DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN), CW_USEDEFAULT, CW_USEDEFAULT, 1300, 760,
                                           nil, nil, instance, nil) else {
            log("native shell: CreateWindowExW failed: \(GetLastError())")
            exit(1)
        }
        self.window = window
        nt_dark_title_bar(UnsafeMutableRawPointer(window))
        dpi = GetDpiForWindow(window)
        tree = nt_tree_create(UnsafeMutableRawPointer(window), dpi)
        notice = CreateWindowExW(0, Array("STATIC".utf16) + [0], nil, DWORD(WS_CHILD) | DWORD(SS_LEFT), 0, 0, 10, 10, window, nil,
                                 instance, nil)
        terminal = NativeTerminal(parent: window, core: core)
        layout()
        ShowWindow(window, SW_SHOW)
        remote.changed = { [weak self] in self?.catalogChanged() }
        catalogChanged()
        remote.start()
    }

    private var sidebarWidth: Int32 { Int32(MulDiv(240, Int32(dpi), 96)) }

    private func layout() {
        guard let window else { return }
        var client = RECT()
        GetClientRect(window, &client)
        let width = sidebarWidth, height = client.bottom
        let noticeText = remote.mirror.state.windowNotice(host: "WSL \(remote.host.distribution)")
        let noticeHeight = noticeText == nil ? 0 : Int32(MulDiv(56, Int32(dpi), 96))
        ShowWindow(notice, noticeText == nil ? SW_HIDE : SW_SHOW)
        SetWindowTextW(notice, Array((noticeText ?? "").utf16) + [0])
        MoveWindow(notice, 8, 6, width - 16, max(noticeHeight - 6, 0), true)
        MoveWindow(tree?.assumingMemoryBound(to: HWND__.self), 0, noticeHeight, width, height - noticeHeight, true)
        terminal.move(x: width, y: 0, width: max(client.right - width, 1), height: height)
    }

    private func catalogChanged() {
        let workspaces = remote.store.workspaces
        let next = SessionSidebar.selection(current: selected, in: workspaces)
        log("native shell: \(workspaces.lazy.flatMap(\.sessions).count) session(s), selecting \(next?.uuidString ?? "none")")
        rebuild(SessionSidebar.items(workspaces))
        layout()
        if let next { select(next) } else { selected = nil }
    }

    private func rebuild(_ workspaces: [SessionSidebar.Item]) {
        guard let tree else { return }
        nt_tree_clear(tree)
        tagged = []
        items = [:]
        func add(_ item: SessionSidebar.Item, under parent: UnsafeMutableRawPointer?) {
            var tag: Int64 = 0
            if !item.isWorkspace {
                tagged.append(item.id)
                tag = Int64(tagged.count)
            }
            guard let node = nt_tree_add(tree, parent, Array(item.title.utf16) + [0], tag, 1) else { return }
            if !item.isWorkspace { items[item.id] = node }
            item.children.forEach { add($0, under: node) }
        }
        workspaces.forEach { add($0, under: nil) }
    }

    fileprivate func userSelected(_ tag: Int64) {
        guard tag > 0, Int(tag) <= tagged.count else { return }
        select(tagged[Int(tag) - 1])
        SetFocus(terminal.window)
    }

    private func select(_ id: Foundation.UUID) {
        selected = id
        if let tree, let item = items[id] { nt_tree_select(tree, item) }
        guard let session = remote.session(id), id != running else { return }
        running = id
        remote.store.selectedSessionID = id
        switch SessionSidebar.launch(for: session, hostLabel: "WSL \(remote.host.distribution)") {
        case .command(let command):
            log("native shell: showing \(session.displayName) [\(id)]")
            terminal.start(command)
        case .notice(let text):
            terminal.show(notice: text)
        }
    }

    fileprivate func resized() { layout() }

    fileprivate func dpiChanged(_ dpi: UInt32, suggested: RECT) {
        self.dpi = dpi
        if let tree { nt_tree_set_dpi(tree, dpi) }
        terminal.setDPI(dpi)
        SetWindowPos(window, nil, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top,
                     UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        layout()
    }

    fileprivate func staticColors(_ context: HDC?) -> LRESULT {
        SetTextColor(context, 0x5AB4E5)
        SetBkColor(context, 0x262525)
        return LRESULT(Int(bitPattern: darkBrush))
    }

    fileprivate func focus() { SetFocus(terminal.window) }

    fileprivate func destroy() {
        terminal.destroy()
    }
}

private let shellWindowProcedure: WNDPROC = { window, message, wParam, lParam in
    MainActor.assumeIsolated {
        switch message {
        case UINT(WM_SIZE):
            shell.resized()
            return 0
        case UINT(WM_SETFOCUS):
            shell.focus()
            return 0
        case UINT(WM_NOTIFY):
            var tag: Int64 = 0
            if nt_tree_selection_changed(Int(lParam), &tag) != 0 { shell.userSelected(tag) }
            return 0
        case UINT(WM_CTLCOLORSTATIC):
            return shell.staticColors(HDC(bitPattern: UInt(wParam)))
        case UINT(WM_DPICHANGED):
            if let suggested = UnsafePointer<RECT>(bitPattern: UInt(lParam)) {
                shell.dpiChanged(UInt32(wParam >> 16 & 0xFFFF), suggested: suggested.pointee)
            }
            return 0
        case UINT(WM_DESTROY):
            shell.destroy()
            PostQuitMessage(0)
            return 0
        default:
            return DefWindowProcW(window, message, wParam, lParam)
        }
    }
}
