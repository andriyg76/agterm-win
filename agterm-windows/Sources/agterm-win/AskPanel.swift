import AgtermWinKit
import Foundation
import NativeShim
import WinSDK
import agtermCore

// the window procedure and the message loop find a panel by its window or one of its editors
private nonisolated(unsafe) var panels: [HWND: AskPanel] = [:]

/// AskPanel draws one ask over its anchor, the way upstream's `AskDialogView` does on a Mac: a title, a message, a text
/// field or a choice list, and a row of buttons, sized to its content up to 90% of the anchor and 72 cells. It paints
/// everything but the text fields itself; keys and clicks go to agtermCore's `AskDraft` and `AskNavigation` through
/// `NativeAsk`, so it answers exactly as a Mac panel does.
@MainActor
final class AskPanel {
    /// Look is what the panel is drawn with: the terminal's font and theme for a terminal ask, the palette's for a GUI one.
    struct Look: Equatable {
        var gui: Bool
        var background: UInt32
        var foreground: UInt32
        var dim: UInt32
        var border: UInt32
        var accent: UInt32
        var fontFamily: String
        var fontPoints: Float
        var dpi: UInt32
    }

    private(set) var window: HWND?
    let askID: String
    let slot: NativeAsk.Slot
    private var navigation: AskNavigation
    private var look: Look
    private var font: HFONT?
    private var boldFont: HFONT?
    private var background: HBRUSH?
    private var fieldBrush: HBRUSH?
    private var editor: HWND?
    private var other: HWND?
    private var layout = Layout()
    private var anchor = NativeOverlay.Rect(x: 0, y: 0, width: 1, height: 1)
    /// firstRow is the first choice the list shows while it is too tall for the panel.
    private var firstRow = 0
    /// onFinished runs once the ask was answered or dismissed here, for the shell to take the panel down.
    var onFinished: (() -> Void)?

    private static let destructive: UInt32 = 0xE5484D
    private static let destructiveDark: UInt32 = 0xFF6369

    init?(parent: HWND?, slot: NativeAsk.Slot, look: Look) {
        guard let ask = slot.ask else { return nil }
        self.slot = slot
        self.look = look
        askID = ask.id
        navigation = AskNavigation(buttons: ask.buttons, defaultID: ask.defaultID, destructiveID: ask.destructiveID)
        let instance = GetModuleHandleW(nil)
        let className = Array("agterm-ask".utf16) + [0]
        className.withUnsafeBufferPointer { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = askPanelProcedure
            windowClass.hInstance = instance
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512)) // IDC_ARROW
            windowClass.lpszClassName = name.baseAddress
            RegisterClassExW(&windowClass)
        }
        window = CreateWindowExW(0, className, nil, DWORD(WS_CHILD) | DWORD(WS_CLIPCHILDREN) | DWORD(WS_CLIPSIBLINGS) | DWORD(WS_TABSTOP),
                                 0, 0, 1, 1, parent, nil, instance, nil)
        guard let window else { return nil }
        panels[window] = self
        applyLook()
        switch ask.form {
        case .input(let input):
            editor = makeEditor(multiline: input.mode == .multiline, placeholder: input.placeholder, text: slot.draft?.text ?? "")
        case .choices(let list):
            if let placeholder = list.other {
                other = makeEditor(multiline: false, placeholder: placeholder, text: slot.draft?.text ?? "")
            }
        case nil:
            break
        }
    }

    func destroy() {
        DestroyWindow(window)
    }

    /// restyle redraws the panel with `look`, after a theme, font or DPI change.
    func restyle(_ look: Look) {
        guard look != self.look else { return }
        self.look = look
        applyLook()
        place(in: anchor, shown: IsWindowVisible(window))
    }

    /// place centers the panel over `anchor`, the session, pane or terminal area it covers, above its siblings.
    func place(in anchor: NativeOverlay.Rect, shown: Bool) {
        self.anchor = anchor
        layout = measure()
        let x = anchor.x + (anchor.width - layout.size.width) / 2
        let y = anchor.y + (anchor.height - layout.size.height) / 2
        SetWindowPos(window, nil, x, y, layout.size.width, layout.size.height,
                     UINT(SWP_NOACTIVATE) | UINT(shown ? SWP_SHOWWINDOW : SWP_HIDEWINDOW))
        if look.gui {
            SetWindowRgn(window, CreateRoundRectRgn(0, 0, layout.size.width + 1, layout.size.height + 1, cornerRadius, cornerRadius), true)
        } else {
            SetWindowRgn(window, nil, true)
        }
        placeEditors()
        InvalidateRect(window, nil, false)
    }

    var shown: Bool { IsWindowVisible(window) }

    static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 { blend(a, b, amount) }

    /// focusIfActive takes the keyboard while the window is in front and no text field of the window holds it: the
    /// find bar, the palette or a sidebar rename keep it until they let go, as an active editor does on a Mac.
    func focusIfActive(_ shell: HWND) {
        guard GetForegroundWindow() == shell, !owns(GetFocus()) else { return }
        if let focused = GetFocus(), focused != shell, Self.className(of: focused) != "agterm-native" { return }
        focus()
    }

    private static func className(of window: HWND) -> String {
        var buffer = [WCHAR](repeating: 0, count: 64)
        let length = GetClassNameW(window, &buffer, Int32(buffer.count))
        return String(decoding: buffer.prefix(Int(max(length, 0))), as: UTF16.self)
    }

    /// owns is whether the keyboard is in the panel or one of its fields.
    func owns(_ focused: HWND?) -> Bool {
        guard let focused else { return false }
        return [window, editor, other].contains(focused)
    }

    /// focus gives the keyboard to the field that holds it now: the input field, the other line while the list cursor
    /// is on it, else the panel itself.
    func focus() {
        if let editor {
            SetFocus(editor)
        } else if let other, slot.draft?.cursorOnOther == true {
            SetFocus(other)
        } else {
            SetFocus(window)
        }
    }

    // MARK: keys and clicks

    /// handleKey takes a key pressed in a panel or one of its fields, before the message loop translates it.
    static func handleKey(_ message: MSG) -> Bool {
        guard message.message == UINT(WM_KEYDOWN) || message.message == UINT(WM_SYSKEYDOWN), let hwnd = message.hwnd,
              let panel = panels[hwnd] else { return false }
        let virtualKey = Int32(truncatingIfNeeded: message.wParam)
        let shift = GetKeyState(VK_SHIFT) < 0, control = GetKeyState(VK_CONTROL) < 0, alt = GetKeyState(VK_MENU) < 0
        let key: NativeAsk.Key?
        if hwnd == panel.editor, let kind = panel.editorKind {
            key = NativeAsk.editorKey(kind, virtualKey: virtualKey, shift: shift, control: control, alt: alt)
        } else if hwnd == panel.other {
            key = NativeAsk.editorKey(.other, virtualKey: virtualKey, shift: shift, control: control, alt: alt)
        } else {
            key = NativeAsk.key(virtualKey: virtualKey, shift: shift, control: control, alt: alt)
        }
        guard let key else { return hwnd == panel.window && !alt }
        panel.run(key)
        return true
    }

    private var editorKind: NativeAsk.Editor? {
        guard case .input(let input) = slot.ask?.form else { return nil }
        return .input(input.mode)
    }

    private func run(_ key: NativeAsk.Key) {
        switch NativeAsk.apply(key, to: slot, navigation: &navigation) {
        case .answer(let index): finish { slot.answer(index) }
        case .escape: finish { slot.escape() }
        case .none:
            keepCursorInView()
            if other != nil { focus() }
            InvalidateRect(window, nil, false)
        }
    }

    private func finish(_ resolve: () -> Void) {
        resolve()
        onFinished?()
    }

    fileprivate func click(x: Int32, y: Int32) {
        if let index = layout.buttons.firstIndex(where: { $0.contains(x: x, y: y) }) {
            finish { slot.answer(index) }
            return
        }
        if let row = layout.rows.first(where: { $0.frame.contains(x: x, y: y) }) {
            slot.updateDraft { $0.toggle(at: row.index) }
            InvalidateRect(window, nil, false)
        }
        focus()
    }

    fileprivate func scroll(by rows: Int) {
        guard layout.hiddenRows > 0 else { return }
        firstRow = min(max(firstRow + rows, 0), layout.hiddenRows)
        layout = measure()
        placeEditors()
        InvalidateRect(window, nil, false)
    }

    /// edited takes a field's new text into the draft, or puts the draft's back when the edit is not one a field holds.
    fileprivate func edited(_ field: HWND) {
        let text = Self.text(of: field)
        let editor: NativeAsk.Editor = field == other ? .other : editorKind ?? .input(.line)
        guard NativeAsk.acceptsEdit(text, editor: editor) else {
            Self.setText(slot.draft?.text ?? "", of: field)
            return
        }
        guard text != slot.draft?.text else { return }
        slot.updateDraft { $0.text = text }
        if field == self.editor, editorKind == .input(.multiline) {
            place(in: anchor, shown: shown)
        } else {
            InvalidateRect(window, nil, false)
        }
    }

    /// fieldFocused puts the list cursor on the other line when a click gives that line the keyboard.
    fileprivate func fieldFocused(_ field: HWND) {
        guard field == other, let cursor = slot.draft?.cursor, cursor != otherIndex else { return }
        slot.updateDraft { $0.moveCursor(by: otherIndex - cursor) }
        InvalidateRect(window, nil, false)
    }

    private func keepCursorInView() {
        guard layout.hiddenRows > 0, let cursor = slot.draft?.cursor else { return }
        if cursor < firstRow {
            firstRow = cursor
        } else if cursor >= firstRow + layout.visibleRows {
            firstRow = cursor - layout.visibleRows + 1
        }
        firstRow = min(max(firstRow, 0), layout.hiddenRows)
        layout = measure()
        placeEditors()
    }

    // MARK: layout

    fileprivate struct Frame {
        var x: Int32 = 0, y: Int32 = 0, width: Int32 = 0, height: Int32 = 0
        func contains(x px: Int32, y py: Int32) -> Bool { px >= x && px < x + width && py >= y && py < y + height }
        var rect: RECT { RECT(left: x, top: y, right: x + width, bottom: y + height) }
    }

    fileprivate struct Row {
        var index: Int
        var frame: Frame
        var label: Frame
        var subtitle: Frame?
    }

    fileprivate struct Layout {
        var size = (width: Int32(1), height: Int32(1))
        var title = Frame()
        var message: Frame?
        var field: Frame?
        var rows: [Row] = []
        var visibleRows = 0
        var hiddenRows = 0
        var buttons: [Frame] = []
    }

    private var cell: Int32 { look.gui ? scaled(8) : max(scaled(8), characterWidth) }
    private var characterWidth: Int32 { measure("0", font: font, width: nil).width }
    private var lineHeight: Int32 { measure("Ag", font: font, width: nil).height }
    private func scaled(_ value: Int32) -> Int32 { MulDiv(value, Int32(look.dpi), 96) }

    /// measure lays the panel out for `anchor`: the content's own width up to `NativeAsk.panelWidth`, an input field
    /// taking all of it, buttons in a row that fall back to a column, and a list that scrolls between the pinned title
    /// and buttons when the anchor is too short.
    private func measure() -> Layout {
        guard let ask = slot.ask else { return Layout() }
        var layout = Layout()
        let pad = cell * 2, gap = cell * 3 / 2
        let widest = NativeAsk.panelWidth(anchorWidth: anchor.width, cell: max(scaled(8), characterWidth), width: ask.width)
        let maxInner = max(widest - 2 * pad, cell)
        let buttonPad = (x: look.gui ? scaled(12) : cell / 2, y: look.gui ? scaled(6) : cell * 2 / 5)
        let labels = ask.buttons.map { NativeAsk.buttonLabel($0, destructive: !look.gui && $0.id == ask.destructiveID) }
        let natural = labels.map { measure($0, font: font, width: nil, prefix: true).width + 2 * buttonPad.x }
        let buttonWidth = natural.max() ?? 0
        let rowWidth = buttonWidth * Int32(labels.count) + cell * Int32(max(labels.count - 1, 0))
        var content = max(measure(ask.title, font: boldFont, width: nil).width, measure(ask.message ?? "", font: font, width: nil).width,
                          rowWidth)
        let marker = measure(look.gui ? "◉ " : "(•) ", font: font, width: nil).width
        if case .choices(let list) = ask.form {
            for choice in list.choices {
                content = max(content, marker + max(measure(choice.label, font: font, width: nil).width,
                                                    measure(choice.subtitle ?? "", font: font, width: nil).width))
            }
            if let placeholder = list.other { content = max(content, marker + measure(placeholder, font: font, width: nil).width + cell * 4) }
        }
        let inner: Int32
        if ask.width != nil {
            inner = maxInner
        } else if case .input = ask.form {
            inner = maxInner
        } else {
            inner = min(maxInner, max(content, cell * 10))
        }
        var y = pad
        let title = measure(ask.title, font: boldFont, width: inner)
        layout.title = Frame(x: pad, y: y, width: inner, height: title.height)
        y += title.height
        if let message = ask.message, !message.isEmpty {
            let size = measure(message, font: font, width: inner)
            y += gap / 2
            layout.message = Frame(x: pad, y: y, width: inner, height: size.height)
            y += size.height
        }
        // buttons: one shared width in a row, or a column of the panel's width when the row does not fit
        let vertical = rowWidth > inner
        let width = vertical ? min(buttonWidth, inner) : buttonWidth
        let heights = labels.map { measure($0, font: font, width: width - 2 * buttonPad.x, prefix: true).height + 2 * buttonPad.y }
        let buttonsHeight = vertical ? heights.reduce(0, +) + cell * Int32(max(heights.count - 1, 0)) : heights.max() ?? 0
        let maxHeight = max(anchor.height - 2 * cell, lineHeight * 4)
        let fixed = y + gap + buttonsHeight + pad
        var formTop = y
        switch ask.form {
        case .input(let input):
            formTop += gap
            var lines: Int32 = 1
            if input.mode == .multiline, let editor {
                lines = min(max(Int32(SendMessageW(editor, 0x00BA, 0, 0)), 5), 15) // EM_GETLINECOUNT
            }
            let fieldPad: Int32 = look.gui ? scaled(4) : cell / 2
            var height = lines * lineHeight + 2 * fieldPad
            height = min(height, max(maxHeight - fixed - gap, lineHeight + 2 * fieldPad))
            layout.field = Frame(x: pad, y: formTop, width: inner, height: height)
            y = formTop + height
        case .choices(let list):
            formTop += gap
            let count = list.choices.count + (list.other == nil ? 0 : 1)
            var heights: [Int32] = list.choices.map { choice in
                measure(choice.label, font: font, width: inner - marker).height
                    + (choice.subtitle.map { measure($0, font: font, width: inner - marker).height } ?? 0)
            }
            if list.other != nil { heights.append(lineHeight + scaled(6)) }
            let room = max(maxHeight - fixed - gap, lineHeight)
            // the rows that fit from firstRow; the list shows them and scrolls the rest into view
            var visible = 0, used: Int32 = 0
            let start = min(firstRow, max(count - 1, 0))
            for index in start..<count {
                guard used + heights[index] <= room || visible == 0 else { break }
                used += heights[index]
                visible += 1
            }
            let shownAll = start == 0 && visible == count
            layout.visibleRows = visible
            layout.hiddenRows = shownAll ? 0 : count - visible
            var rowY = formTop
            for index in start..<(start + visible) {
                let labelHeight = index < list.choices.count ? measure(list.choices[index].label, font: font, width: inner - marker).height
                    : heights[index]
                var row = Row(index: index, frame: Frame(x: pad, y: rowY, width: inner, height: heights[index]),
                              label: Frame(x: pad + marker, y: rowY, width: inner - marker, height: labelHeight))
                if index < list.choices.count, list.choices[index].subtitle != nil {
                    row.subtitle = Frame(x: pad + marker, y: rowY + labelHeight, width: inner - marker, height: heights[index] - labelHeight)
                }
                layout.rows.append(row)
                rowY += heights[index]
            }
            y = rowY
        case nil:
            break
        }
        y += gap
        let blockWidth = vertical ? width : rowWidth
        let blockX: Int32
        switch ask.align {
        case .left: blockX = pad
        case .center: blockX = pad + (inner - blockWidth) / 2
        case .right: blockX = pad + inner - blockWidth
        }
        var buttonX = blockX, buttonY = y
        for height in heights {
            layout.buttons.append(Frame(x: buttonX, y: vertical ? buttonY : y + (buttonsHeight - height) / 2, width: width, height: height))
            if vertical { buttonY += height + cell } else { buttonX += width + cell }
        }
        y += buttonsHeight + pad
        layout.size = (inner + 2 * pad, min(y, anchor.height))
        return layout
    }

    private func placeEditors() {
        if let editor, let field = layout.field {
            let inset: Int32 = look.gui ? scaled(6) : cell / 2
            MoveWindow(editor, field.x + inset, field.y + inset / 2, field.width - 2 * inset, field.height - inset, true)
        }
        if let other {
            if let row = layout.rows.first(where: { $0.index == otherIndex }) {
                MoveWindow(other, row.label.x, row.label.y + scaled(2), row.label.width, row.label.height - scaled(4), true)
                ShowWindow(other, SW_SHOW)
            } else {
                ShowWindow(other, SW_HIDE)
            }
        }
    }

    private var otherIndex: Int {
        guard case .choices(let list) = slot.ask?.form else { return -1 }
        return list.choices.count
    }

    // MARK: painting

    fileprivate func paint(_ target: HDC?) {
        guard let ask = slot.ask, let target else { return }
        var client = RECT()
        GetClientRect(window, &client)
        // drawn off screen first, so a repaint on every key never flickers
        let context = CreateCompatibleDC(target)
        let bitmap = CreateCompatibleBitmap(target, client.right, client.bottom)
        let previous = SelectObject(context, bitmap)
        defer {
            BitBlt(target, 0, 0, client.right, client.bottom, context, 0, 0, DWORD(SRCCOPY))
            SelectObject(context, previous)
            DeleteObject(bitmap)
            DeleteDC(context)
        }
        fill(context, client, look.background)
        if look.gui {
            // the window region rounds the corners, so the border follows the same curve or it is cut there
            let pen = CreatePen(PS_SOLID, 1, ChromePalette.colorref(look.border))
            let previousPen = SelectObject(context, pen), previousBrush = SelectObject(context, GetStockObject(NULL_BRUSH))
            RoundRect(context, 0, 0, client.right, client.bottom, cornerRadius, cornerRadius)
            SelectObject(context, previousBrush)
            SelectObject(context, previousPen)
            DeleteObject(pen)
        } else {
            frameRect(context, client, look.border)
        }
        SetBkMode(context, TRANSPARENT)
        draw(ask.title, in: layout.title, font: boldFont, color: look.foreground, context: context)
        if let message = ask.message, let frame = layout.message {
            draw(message, in: frame, font: font, color: look.dim, context: context)
        }
        if let field = layout.field {
            fill(context, field.rect, fieldColor)
            frameRect(context, field.rect, look.border)
        }
        if case .choices(let list) = ask.form, let draft = slot.draft {
            for row in layout.rows {
                if row.index == draft.cursor { fill(context, row.frame.rect, blend(look.foreground, look.background, 0.12)) }
                let isOther = row.index == list.choices.count
                let on = isOther ? draft.otherSelected : draft.selected.contains(list.choices[row.index].id)
                let enabled = !isOther || draft.otherEnabled
                let glyph = list.multiple ? (look.gui ? (on ? "☑" : "☐") : (on ? "[x]" : "[ ]"))
                    : (look.gui ? (on ? "◉" : "○") : (on ? "(•)" : "( )"))
                draw(glyph, in: Frame(x: row.frame.x, y: row.frame.y, width: row.label.x - row.frame.x, height: lineHeight), font: font,
                     color: enabled ? (on && look.gui ? look.accent : look.foreground) : look.dim, context: context)
                guard !isOther else { continue }
                draw(list.choices[row.index].label, in: row.label, font: font, color: look.foreground, context: context)
                if let subtitle = list.choices[row.index].subtitle, let frame = row.subtitle {
                    draw(subtitle, in: frame, font: font, color: look.dim, context: context)
                }
            }
        }
        for (index, frame) in layout.buttons.enumerated() where ask.buttons.indices.contains(index) {
            paintButton(ask.buttons[index], destructive: ask.buttons[index].id == ask.destructiveID,
                        highlighted: navigation.highlighted == index, in: frame, context: context)
        }
    }

    private func paintButton(_ button: ControlAskButton, destructive: Bool, highlighted: Bool, in frame: Frame, context: HDC?) {
        let label = NativeAsk.buttonLabel(button, destructive: !look.gui && destructive)
        let red = isDark ? Self.destructiveDark : Self.destructive
        let fillColor: UInt32, textColor: UInt32
        if look.gui {
            let tint = destructive ? red : look.accent
            fillColor = highlighted ? tint : blend(look.foreground, look.background, 0.1)
            // a theme accent can be light, so the prominent label takes whichever of black and white reads on it
            textColor = highlighted ? (luminance(tint) > 0.55 ? 0x1A1A1A : 0xFFFFFF) : destructive ? red : look.foreground
        } else {
            fillColor = highlighted ? look.foreground : blend(look.foreground, look.background, 0.12)
            textColor = highlighted ? look.background : look.foreground
        }
        var rect = frame.rect
        if look.gui {
            let brush = CreateSolidBrush(ChromePalette.colorref(fillColor))
            let pen = SelectObject(context, GetStockObject(NULL_PEN))
            let previous = SelectObject(context, brush)
            RoundRect(context, rect.left, rect.top, rect.right, rect.bottom, scaled(6), scaled(6))
            SelectObject(context, previous)
            SelectObject(context, pen)
            DeleteObject(brush)
        } else {
            fill(context, rect, fillColor)
        }
        let bold = !look.gui && destructive
        SelectObject(context, bold ? boldFont : font)
        SetTextColor(context, ChromePalette.colorref(textColor))
        let flags = UINT(DT_CENTER) | UINT(DT_WORDBREAK)
        var measured = rect
        _ = withWide(label) { DrawTextW(context, $0, -1, &measured, flags | UINT(DT_CALCRECT)) }
        let offset = (frame.height - (measured.bottom - measured.top)) / 2
        rect.top += offset
        _ = withWide(label) { DrawTextW(context, $0, -1, &rect, flags) }
    }

    private var isDark: Bool { luminance(look.background) < 0.5 }

    private var cornerRadius: Int32 { scaled(12) }

    private var fieldColor: UInt32 { look.gui ? blend(look.foreground, look.background, 0.06) : look.background }

    private func draw(_ text: String, in frame: Frame, font: HFONT?, color: UInt32, context: HDC?) {
        SelectObject(context, font)
        SetTextColor(context, ChromePalette.colorref(color))
        var rect = frame.rect
        _ = withWide(text) { DrawTextW(context, $0, -1, &rect, UINT(DT_WORDBREAK) | UINT(DT_NOPREFIX) | UINT(DT_EDITCONTROL)) }
    }

    private func fill(_ context: HDC?, _ rect: RECT, _ color: UInt32) {
        var rect = rect
        let brush = CreateSolidBrush(ChromePalette.colorref(color))
        FillRect(context, &rect, brush)
        DeleteObject(brush)
    }

    private func frameRect(_ context: HDC?, _ rect: RECT, _ color: UInt32) {
        var rect = rect
        let brush = CreateSolidBrush(ChromePalette.colorref(color))
        FrameRect(context, &rect, brush)
        DeleteObject(brush)
    }

    fileprivate func editColors(_ context: HDC?) -> LRESULT {
        SetTextColor(context, ChromePalette.colorref(look.foreground))
        SetBkColor(context, ChromePalette.colorref(fieldColor))
        return LRESULT(Int(bitPattern: fieldBrush))
    }

    // MARK: resources

    private func applyLook() {
        for object in [font, boldFont].compactMap({ $0 }) { DeleteObject(object) }
        for brush in [background, fieldBrush].compactMap({ $0 }) { DeleteObject(brush) }
        let height = -MulDiv(Int32(look.fontPoints.rounded()), Int32(look.dpi), 72)
        font = Self.font(look.fontFamily, height: height, weight: FW_NORMAL)
        boldFont = Self.font(look.fontFamily, height: height, weight: FW_BOLD)
        background = CreateSolidBrush(ChromePalette.colorref(look.background))
        fieldBrush = CreateSolidBrush(ChromePalette.colorref(fieldColor))
        for field in [editor, other].compactMap({ $0 }) {
            SendMessageW(field, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font.map { Int(bitPattern: $0) } ?? 0)), 1)
        }
    }

    private static func font(_ family: String, height: Int32, weight: Int32) -> HFONT? {
        withWide(family) {
            CreateFontW(height, 0, 0, 0, weight, 0, 0, 0, DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS),
                        DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH), $0)
        }
    }

    /// makeEditor creates a text field under the comctl32 6 activation context, whose EDIT shows a placeholder.
    private func makeEditor(multiline: Bool, placeholder: String?, text: String) -> HWND? {
        var cookie: UInt = 0
        let active = nt_common_controls_activate(&cookie)
        defer { if active { nt_common_controls_deactivate(cookie) } }
        var style = DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | DWORD(WS_TABSTOP)
        style |= multiline ? 0x0004 | 0x0040 | 0x1000 | 0x0020_0000 : 0x0080 // ES_MULTILINE|ES_AUTOVSCROLL|ES_WANTRETURN|WS_VSCROLL, ES_AUTOHSCROLL
        let field = withWide("EDIT") { name in
            CreateWindowExW(0, name, nil, style, 0, 0, 1, 1, window, nil, GetModuleHandleW(nil), nil)
        }
        guard let field else { return nil }
        panels[field] = self
        SendMessageW(field, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font.map { Int(bitPattern: $0) } ?? 0)), 1)
        if let placeholder {
            _ = withWide(placeholder) { SendMessageW(field, 0x1501, 1, LPARAM(Int(bitPattern: $0))) } // EM_SETCUEBANNER
        }
        Self.setText(text, of: field)
        return field
    }

    fileprivate func destroyed() {
        for handle in [window, editor, other].compactMap({ $0 }) { panels[handle] = nil }
        for object in [font, boldFont].compactMap({ $0 }) { DeleteObject(object) }
        for brush in [background, fieldBrush].compactMap({ $0 }) { DeleteObject(brush) }
        window = nil
        editor = nil
        other = nil
    }

    // MARK: text

    private func measure(_ text: String, font: HFONT?, width: Int32?, prefix: Bool = false) -> (width: Int32, height: Int32) {
        guard !text.isEmpty else { return (0, 0) }
        let context = GetDC(window)
        defer { ReleaseDC(window, context) }
        let previous = SelectObject(context, font)
        defer { SelectObject(context, previous) }
        var rect = RECT(left: 0, top: 0, right: width ?? 100_000, bottom: 0)
        var flags = UINT(DT_CALCRECT) | (prefix ? 0 : UINT(DT_NOPREFIX))
        flags |= width == nil ? 0 : UINT(DT_WORDBREAK) | UINT(DT_EDITCONTROL)
        _ = withWide(text) { DrawTextW(context, $0, -1, &rect, flags) }
        return (rect.right - rect.left, rect.bottom - rect.top)
    }

    private static func text(of field: HWND) -> String {
        let length = GetWindowTextLengthW(field)
        var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
        let read = GetWindowTextW(field, &buffer, Int32(buffer.count))
        return String(decoding: buffer.prefix(Int(max(read, 0))), as: UTF16.self)
    }

    private static func setText(_ text: String, of field: HWND) {
        _ = withWide(text) { SetWindowTextW(field, $0) }
        SendMessageW(field, 0x00B1, WPARAM(bitPattern: -1), -1) // EM_SETSEL to the end
    }
}

private func withWide<Result>(_ text: String, _ body: (UnsafePointer<WCHAR>) -> Result) -> Result {
    let wide = Array(text.utf16) + [0]
    return wide.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// blend is `a` over `b` at `amount`, in 0xRRGGBB.
private func blend(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
    func channel(_ shift: UInt32) -> UInt32 {
        let top = Double(a >> shift & 0xFF), bottom = Double(b >> shift & 0xFF)
        return UInt32((top * amount + bottom * (1 - amount)).rounded()) << shift
    }
    return channel(16) | channel(8) | channel(0)
}

private func luminance(_ rgb: UInt32) -> Double {
    (0.2126 * Double(rgb >> 16 & 0xFF) + 0.7152 * Double(rgb >> 8 & 0xFF) + 0.0722 * Double(rgb & 0xFF)) / 255
}

private let askPanelProcedure: WNDPROC = { window, message, wParam, lParam in
    MainActor.assumeIsolated {
        guard let window, let panel = panels[window] else { return DefWindowProcW(window, message, wParam, lParam) }
        switch message {
        case UINT(WM_ERASEBKGND):
            return 1
        case UINT(WM_PAINT):
            var paint = PAINTSTRUCT()
            let context = BeginPaint(window, &paint)
            panel.paint(context)
            EndPaint(window, &paint)
            return 0
        case UINT(WM_LBUTTONDOWN):
            panel.click(x: Int32(Int16(truncatingIfNeeded: lParam)), y: Int32(Int16(truncatingIfNeeded: lParam >> 16)))
            return 0
        case UINT(WM_MOUSEWHEEL):
            let delta = Int16(truncatingIfNeeded: wParam >> 16)
            panel.scroll(by: delta > 0 ? -1 : 1)
            return 0
        case UINT(WM_COMMAND) where (wParam >> 16) & 0xFFFF == 0x0300: // EN_CHANGE
            if let field = HWND(bitPattern: Int(lParam)) { panel.edited(field) }
            return 0
        case UINT(WM_COMMAND) where (wParam >> 16) & 0xFFFF == 0x0100: // EN_SETFOCUS
            if let field = HWND(bitPattern: Int(lParam)) { panel.fieldFocused(field) }
            return 0
        case UINT(WM_CTLCOLOREDIT):
            return panel.editColors(HDC(bitPattern: UInt(wParam)))
        case UINT(WM_DESTROY):
            panel.destroyed()
            return 0
        default:
            return DefWindowProcW(window, message, wParam, lParam)
        }
    }
}
