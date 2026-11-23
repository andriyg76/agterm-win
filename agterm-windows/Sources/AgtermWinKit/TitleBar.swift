/// TitleBar is the window's own title bar in client pixels: ☰ and New Session at the left, the selected session's
/// name from the terminal's leading edge, then Find and the minimize, maximize and close buttons at the right.
public struct TitleBar: Equatable, Sendable {
    public enum Button: Int, CaseIterable, Sendable {
        case menu, newSession, find, minimize, maximize, close

        /// isCaption is whether Windows handles the button as the frame's own (HTMINBUTTON and the rest), which is
        /// what gives maximize its Snap Layouts flyout.
        public var isCaption: Bool { self == .minimize || self == .maximize || self == .close }

        /// command is what an action button runs; the menu button opens the ☰ menu instead.
        public var command: NativeMenu.Command? {
            switch self {
            case .newSession: .newSession
            case .find: .find
            default: nil
            }
        }

        /// tip is the tooltip of an action button, with the keymap's chord for its command.
        public func tip(_ shortcuts: NativeMenu.Shortcuts = [:]) -> String? {
            switch self {
            case .menu: return "Menu"
            case .newSession, .find:
                guard let command else { return nil }
                let chord = shortcuts[command] ?? command.shortcut
                return chord.isEmpty ? command.title : "\(command.title) (\(chord))"
            default: return nil
            }
        }
    }

    public enum Hit: Equatable, Sendable {
        case button(Button)
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

    public init(width: Int32, sidebarWidth: Int32, dpi: UInt32) {
        func scaled(_ value: Int32) -> Int32 { Int32((Int64(value) * Int64(dpi) + 48) / 96) }
        self.width = width
        self.sidebarWidth = sidebarWidth
        height = scaled(36)
        actionWidth = scaled(40)
        captionWidth = scaled(46)
    }

    public func span(of button: Button) -> Span {
        switch button {
        case .menu: Span(left: 0, right: actionWidth)
        case .newSession: Span(left: actionWidth, right: 2 * actionWidth)
        case .find: Span(left: width - 3 * captionWidth - actionWidth, right: width - 3 * captionWidth)
        case .minimize: Span(left: width - 3 * captionWidth, right: width - 2 * captionWidth)
        case .maximize: Span(left: width - 2 * captionWidth, right: width - captionWidth)
        case .close: Span(left: width - captionWidth, right: width)
        }
    }

    /// title is where the session's name goes: from the terminal's leading edge, never under a button.
    public var title: Span {
        let gap = actionWidth / 4
        return Span(left: max(span(of: .newSession).right, sidebarWidth) + gap, right: span(of: .find).left - gap)
    }

    /// hit answers WM_NCHITTEST for a client point; `topBorder` is the resize band along the top, 0 while maximized.
    /// The caption buttons win where a narrow window makes the spans overlap.
    public func hit(x: Int32, y: Int32, topBorder: Int32) -> Hit {
        guard y >= 0, y < height, x >= 0, x < width else { return .outside }
        if y < topBorder { return .top }
        let order: [Button] = [.close, .maximize, .minimize, .find, .newSession, .menu]
        if let button = order.first(where: { x >= span(of: $0).left && x < span(of: $0).right }) { return .button(button) }
        return .caption
    }
}
