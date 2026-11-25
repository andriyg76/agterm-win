import AgtermWinKit
import NativeShim
import WinSDK

private nonisolated(unsafe) var bars: [HWND: NoticeBarWindow] = [:]

/// NoticeBarWindow draws the notice bar and takes its clicks, drags and menu; the shell owns where it sits and what the
/// notices' actions do.
@MainActor
final class NoticeBarWindow {
    private(set) var window: HWND?
    var state: NoticeBar.State
    var dpi: UInt32
    var colors: (NoticeBar.Severity) -> NoticeBar.Colors = { NoticeBar.colors(ChromePalette.recompute(theme: nil), theme: nil, severity: $0) }
    /// area is the band of the parent's client the bar can be dragged in, between the title bar and the bottom edge.
    var area: () -> (top: Int32, bottom: Int32) = { (0, 0) }
    var onAction: (NoticeBar.Message, NoticeBar.Action) -> Void = { _, _ in }
    var onPosition: (NoticeBar.Position) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    private let tooltip: UnsafeMutableRawPointer?
    private var hovered: NoticeBar.Layout.Part?
    private var pressed: NoticeBar.Layout.Part?
    // where in the bar the press was, and whether the pointer has moved far enough to drag
    private var drag: (offset: Int32, moving: Bool)?

    init(parent: HWND?, position: NoticeBar.Position, dpi: UInt32, tooltip: UnsafeMutableRawPointer?) {
        state = NoticeBar.State(position: position)
        self.dpi = dpi
        self.tooltip = tooltip
        let instance = GetModuleHandleW(nil)
        let className = Array("agterm-notice-bar".utf16) + [0]
        className.withUnsafeBufferPointer { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = noticeBarProcedure
            windowClass.hInstance = instance
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512)) // IDC_ARROW
            windowClass.lpszClassName = name.baseAddress
            RegisterClassExW(&windowClass)
        }
        window = CreateWindowExW(0, className, nil, DWORD(WS_CHILD) | DWORD(WS_CLIPSIBLINGS), 0, 0, 1, 1, parent, nil, instance, nil)
        if let window { bars[window] = self }
    }

    var height: Int32 { NoticeBar.height(dpi: dpi) }

    /// place shows the bar at `y` across `width` while it has a notice to show, and hides it otherwise.
    func place(y: Int32, width: Int32) {
        let text = state.shown?.text ?? ""
        SetWindowTextW(window, Array(text.utf16) + [0])
        guard state.shown != nil, drag?.moving != true else {
            if state.shown == nil { ShowWindow(window, SW_HIDE) }
            return
        }
        SetWindowPos(window, nil, 0, y, width, height, UINT(SWP_NOACTIVATE | SWP_NOZORDER | SWP_SHOWWINDOW))
        let layout = self.layout
        nt_tooltip_set(tooltip, UnsafeMutableRawPointer(window), 1, layout.text.left, 0, layout.text.right, height, Array(text.utf16) + [0])
        InvalidateRect(window, nil, false)
    }

    func invalidate() { InvalidateRect(window, nil, false) }

    private var layout: NoticeBar.Layout {
        var client = RECT()
        GetClientRect(window, &client)
        let labels = (state.shown?.actions ?? []).map { nt_notice_bar_text_width(dpi, Array($0.title.utf16) + [0]) }
        let count = NoticeBar.countText(state.waiting)
        return NoticeBar.Layout(width: client.right, dpi: dpi, labelWidths: labels,
                                countWidth: count.isEmpty ? 0 : nt_notice_bar_text_width(dpi, Array(count.utf16) + [0]))
    }

    fileprivate func paint() {
        guard let shown = state.shown else {
            var paint = PAINTSTRUCT()
            BeginPaint(window, &paint)
            EndPaint(window, &paint)
            return
        }
        let layout = self.layout
        let colors = colors(shown.severity)
        let ref = ChromePalette.colorref
        let text = Array(shown.text.utf16) + [0]
        let count = Array(NoticeBar.countText(state.waiting).utf16) + [0]
        let labels = shown.actions.prefix(layout.actions.count).map { Array($0.title.utf16) + [0] }
        func buttonState(_ part: NoticeBar.Layout.Part) -> Int32 {
            pressed == part ? (hovered == part ? 2 : 1) : (pressed == nil && hovered == part ? 1 : 0)
        }
        withLabels(labels) { pointers in
            let buttons = layout.actions.indices.map {
                nt_notice_button(left: layout.actions[$0].left, right: layout.actions[$0].right, label: pointers[$0], state: buttonState(.action($0)))
            }
            text.withUnsafeBufferPointer { text in
                count.withUnsafeBufferPointer { count in
                    buttons.withUnsafeBufferPointer { buttons in
                        var bar = nt_notice_bar(
                            text: text.baseAddress, count: count.baseAddress, glyph: shown.severity.glyph, stripe_right: layout.stripe.right,
                            grip_left: layout.grip.left, grip_right: layout.grip.right, icon_left: layout.icon.left, icon_right: layout.icon.right,
                            text_left: layout.text.left, text_right: layout.text.right, count_left: layout.count.left,
                            count_right: layout.count.right, close_left: layout.close.left, close_right: layout.close.right,
                            close_state: buttonState(.close), buttons: buttons.baseAddress, button_count: Int32(buttons.count),
                            edge_top: state.position == .bottom ? 1 : 0, edge_bottom: state.position == .top ? 1 : 0,
                            background: ref(colors.background), text_color: ref(colors.text), dim: ref(colors.dim),
                            border: ref(colors.border), accent: ref(colors.accent), button: ref(colors.button),
                            button_hover: ref(colors.buttonHover), button_pressed: ref(colors.buttonPressed))
                        nt_notice_bar_paint(UnsafeMutableRawPointer(window), dpi, &bar)
                    }
                }
            }
        }
    }

    private func withLabels(_ labels: [[UInt16]], _ body: ([UnsafePointer<UInt16>?]) -> Void) {
        var pointers: [UnsafePointer<UInt16>?] = []
        func lend(_ index: Int) {
            guard index < labels.count else { return body(pointers) }
            labels[index].withUnsafeBufferPointer { label in
                pointers.append(label.baseAddress)
                lend(index + 1)
            }
        }
        lend(0)
    }

    // MARK: mouse

    /// top is the bar's top edge in its parent's client pixels.
    private var top: Int32 {
        var rect = RECT()
        GetWindowRect(window, &rect)
        var corner = POINT(x: rect.left, y: rect.top)
        ScreenToClient(GetParent(window), &corner)
        return corner.y
    }

    fileprivate func mouseDown(x: Int32, y: Int32) {
        let part = layout.part(x: x)
        SetCapture(window)
        if part == .body {
            drag = (y, false)
        } else {
            pressed = part
            invalidate()
        }
    }

    fileprivate func mouseMoved(x: Int32, y: Int32) {
        if let current = drag {
            guard current.moving || abs(y - current.offset) >= NoticeBar.height(dpi: dpi) / 8 else { return }
            drag?.moving = true
            let area = self.area()
            let next = NoticeBar.dragTop(pointer: top + y, pressOffset: current.offset, height: height, areaTop: area.top, areaBottom: area.bottom)
            SetWindowPos(window, nil, 0, next, 0, 0, UINT(SWP_NOACTIVATE | SWP_NOSIZE))
            return
        }
        var track = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE), hwndTrack: window, dwHoverTime: 0)
        TrackMouseEvent(&track)
        let part = layout.part(x: x)
        let lit: NoticeBar.Layout.Part? = part == .body ? nil : part
        guard lit != hovered else { return }
        hovered = lit
        invalidate()
    }

    fileprivate func mouseUp(x: Int32, y: Int32) {
        if let current = drag {
            drag = nil
            ReleaseCapture()
            guard current.moving else { return }
            let area = self.area()
            onPosition(NoticeBar.snap(top: top, height: height, areaTop: area.top, areaBottom: area.bottom))
            return
        }
        let released = pressed
        pressed = nil
        ReleaseCapture()
        invalidate()
        guard let released, layout.part(x: x) == released, let shown = state.shown else { return }
        switch released {
        case .close: onDismiss()
        case .action(let index) where shown.actions.indices.contains(index): onAction(shown, shown.actions[index])
        default: break
        }
    }

    /// captureLost ends a drag Windows took the mouse from, putting the bar back where it sits.
    fileprivate func captureLost() {
        let moved = drag?.moving == true
        drag = nil
        pressed = nil
        if moved { onPosition(state.position) }
        invalidate()
    }

    fileprivate func left() {
        guard hovered != nil else { return }
        hovered = nil
        invalidate()
    }

    fileprivate func setCursor() -> Bool {
        var cursor = POINT()
        GetCursorPos(&cursor)
        ScreenToClient(window, &cursor)
        let grip = layout.grip
        guard drag?.moving == true || (cursor.x >= grip.left && cursor.x < grip.right) else { return false }
        SetCursor(LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32645))) // IDC_SIZENS
        return true
    }

    fileprivate func contextMenu(_ lParam: LPARAM) {
        var point = POINT(x: Int32(Int16(truncatingIfNeeded: lParam)), y: Int32(Int16(truncatingIfNeeded: lParam >> 16)))
        if point.x == -1, point.y == -1 {
            point = POINT(x: layout.text.left, y: height)
            ClientToScreen(window, &point)
        }
        let items = NoticeBar.menu(state)
        guard let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }
        for (index, item) in items.enumerated() {
            if item == .separator {
                AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
                continue
            }
            let current = item == .moveTo(state.position)
            AppendMenuW(menu, UINT(MF_STRING) | (current ? UINT(MF_GRAYED) | UINT(MF_CHECKED) : 0), UINT_PTR(index + 1),
                        Array(item.title.utf16) + [0])
        }
        let picked = Int(nt_track_menu(UnsafeMutableRawPointer(menu), UnsafeMutableRawPointer(window), point.x, point.y))
        guard items.indices.contains(picked - 1) else { return }
        switch items[picked - 1] {
        case .action(let action): if let shown = state.shown { onAction(shown, action) }
        case .moveTo(let position): onPosition(position)
        case .dismiss: onDismiss()
        case .separator: break
        }
    }

    fileprivate func destroyed() {
        if let window { bars[window] = nil }
        window = nil
    }
}

private let noticeBarProcedure: WNDPROC = { window, message, wParam, lParam in
    MainActor.assumeIsolated {
        guard let window, let bar = bars[window] else { return DefWindowProcW(window, message, wParam, lParam) }
        let x = Int32(Int16(truncatingIfNeeded: lParam)), y = Int32(Int16(truncatingIfNeeded: lParam >> 16))
        switch message {
        case UINT(WM_PAINT):
            bar.paint()
            return 0
        case UINT(WM_ERASEBKGND):
            return 1
        case UINT(WM_LBUTTONDOWN):
            bar.mouseDown(x: x, y: y)
            return 0
        case UINT(WM_MOUSEMOVE):
            bar.mouseMoved(x: x, y: y)
            return 0
        case UINT(WM_LBUTTONUP):
            bar.mouseUp(x: x, y: y)
            return 0
        case UINT(WM_CAPTURECHANGED):
            if HWND(bitPattern: Int(lParam)) != window { bar.captureLost() }
            return 0
        case UINT(0x02A3): // WM_MOUSELEAVE
            bar.left()
            return 0
        case UINT(WM_SETCURSOR):
            return bar.setCursor() ? 1 : DefWindowProcW(window, message, wParam, lParam)
        case UINT(WM_CONTEXTMENU):
            bar.contextMenu(lParam)
            return 0
        case UINT(WM_DESTROY):
            bar.destroyed()
            return 0
        default:
            return DefWindowProcW(window, message, wParam, lParam)
        }
    }
}
