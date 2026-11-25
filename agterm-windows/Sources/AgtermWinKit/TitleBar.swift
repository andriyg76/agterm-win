/// TitleBar is the window's own title bar in client pixels: New Session at the sidebar's trailing edge, File / View /
/// Navigate / Help menu tabs, the selected session's name from the terminal's leading edge, then Quick Terminal, Split,
/// Dashboard, Find and Settings, and the minimize, maximize and close buttons at the right.
public struct TitleBar: Equatable, Sendable {
    public enum Button: Int, CaseIterable, Sendable {
        case newSession, find, minimize, maximize, close, quick, split, dashboard, settings

        /// trailing are the action buttons before the caption buttons, left to right.
        public static let trailing: [Button] = [.quick, .split, .dashboard, .find, .settings]

        /// isCaption is whether Windows handles the button as the frame's own (HTMINBUTTON and the rest), which is
        /// what gives maximize its Snap Layouts flyout.
        public var isCaption: Bool { self == .minimize || self == .maximize || self == .close }

        /// command is what an action button runs.
        public var command: NativeMenu.Command? {
            switch self {
            case .newSession: .newSession
            case .find: .find
            case .quick: .quickTerminal
            case .split: .toggleSplit
            case .dashboard: .dashboard
            case .settings: .settings
            default: nil
            }
        }

        /// tip is the tooltip of an action button, with the keymap's chord for its command.
        public func tip(_ shortcuts: NativeMenu.Shortcuts = [:]) -> String? {
            switch self {
            case .newSession, .find, .quick, .split, .dashboard, .settings:
                guard let command else { return nil }
                let chord = shortcuts[command] ?? command.shortcut
                return chord.isEmpty ? command.title : "\(command.title) (\(chord))"
            default: return nil
            }
        }
    }

    public enum Hit: Equatable, Sendable {
        case button(Button)
        /// menuTab is a title-bar menu label; clicks stay on the client so the shell opens the popup.
        case menuTab(Int)
        /// caption drags the window and double-clicks maximize it.
        case caption
        /// top resizes the window from its top edge.
        case top
        case outside
    }

    public struct Span: Equatable, Sendable {
        public let left: Int32
        public let right: Int32

        public init(left: Int32, right: Int32) {
            self.left = left
            self.right = right
        }

        public var isEmpty: Bool { right <= left }
    }

    public let width: Int32
    public let height: Int32
    public let actionWidth: Int32
    public let captionWidth: Int32
    private let sidebarWidth: Int32
    public let dpi: UInt32

    public init(width: Int32, sidebarWidth: Int32, dpi: UInt32) {
        func scaled(_ value: Int32) -> Int32 { Int32((Int64(value) * Int64(dpi) + 48) / 96) }
        self.width = width
        self.sidebarWidth = sidebarWidth
        self.dpi = dpi
        height = scaled(40)
        actionWidth = scaled(40)
        captionWidth = scaled(46)
    }

    public func span(of button: Button) -> Span {
        if let index = Button.trailing.firstIndex(of: button) {
            let right = width - 3 * captionWidth - Int32(Button.trailing.count - 1 - index) * actionWidth
            return Span(left: right - actionWidth, right: right)
        }
        switch button {
        case .newSession: return Span(left: sidebarWidth, right: sidebarWidth + actionWidth)
        case .minimize: return Span(left: width - 3 * captionWidth, right: width - 2 * captionWidth)
        case .maximize: return Span(left: width - 2 * captionWidth, right: width - captionWidth)
        default: return Span(left: width - captionWidth, right: width)
        }
    }

    /// title is where the session's name goes: from the terminal's leading edge, never under a button.
    public var title: Span {
        let gap = actionWidth / 4
        let menuEnd = menuBarEnd(limit: span(of: Button.trailing[0]).left - gap, dpi: dpi)
        return Span(left: max(span(of: .newSession).right, menuEnd) + gap, right: span(of: Button.trailing[0]).left - gap)
    }

    /// hit answers WM_NCHITTEST for a client point; `topBorder` is the resize band along the top, 0 while maximized.
    /// The caption buttons win where a narrow window makes the spans overlap.
    public func hit(x: Int32, y: Int32, topBorder: Int32) -> Hit {
        guard y >= 0, y < height, x >= 0, x < width else { return .outside }
        if y < topBorder { return .top }
        let order: [Button] = [.close, .maximize, .minimize] + Button.trailing.reversed() + [.newSession]
        if let button = order.first(where: { x >= span(of: $0).left && x < span(of: $0).right }) { return .button(button) }
        let gap = actionWidth / 4
        let limit = span(of: Button.trailing[0]).left - gap
        if let index = menuTab(x: x, y: y, dpi: dpi, limit: limit) { return .menuTab(index) }
        return .caption
    }

    /// menuBarEnd is the right edge of the last menu tab that fits before `limit`.
    public func menuBarEnd(limit: Int32, dpi: UInt32) -> Int32 {
        let start = span(of: .newSession).right + actionWidth / 4
        return MenuBarLayout.menuSpans(origin: start, limit: limit, dpi: dpi).last?.1.right ?? start
    }

    /// menuTab is the menu label index at client x on the title row, if any.
    public func menuTab(x: Int32, y: Int32, dpi: UInt32, limit: Int32) -> Int? {
        guard y >= 0, y < height, x >= 0, x < width else { return nil }
        let start = span(of: .newSession).right + actionWidth / 4
        for (index, span) in MenuBarLayout.menuSpans(origin: start, limit: limit, dpi: dpi) where x >= span.left && x < span.right {
            return index
        }
        return nil
    }
}
