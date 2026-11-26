/// Caption controls and the application menu strip in client pixels.
public struct TitleBar: Equatable, Sendable {
    public enum Button: Int, CaseIterable, Sendable {
        case minimize, maximize, close, scratch, split, overlays, dashboard, quick

        /// trailing are the action buttons before the caption buttons, left to right.
        public static let trailing: [Button] = [.scratch, .split, .overlays, .dashboard, .quick]

        /// isCaption is whether Windows handles the button as the frame's own (HTMINBUTTON and the rest), which is
        /// what gives maximize its Snap Layouts flyout.
        public var isCaption: Bool { self == .minimize || self == .maximize || self == .close }

        /// command is what an action button runs.
        public var command: NativeMenu.Command? {
            switch self {
            case .scratch: .toggleScratch
            case .overlays: .toggleOverlay
            case .quick: .quickTerminal
            case .split: .toggleSplit
            case .dashboard: .dashboard
            default: nil
            }
        }

        /// tip is the tooltip of an action button, with the keymap's chord for its command.
        public func tip(_ shortcuts: NativeMenu.Shortcuts = [:]) -> String? {
            guard let command else { return nil }
            let chord = shortcuts[command] ?? command.shortcut
            return chord.isEmpty ? command.title : "\(command.title) (\(chord))"
        }
    }

    public enum Hit: Equatable, Sendable {
        case button(Button)
        /// appIcon is the window icon on the bar's left; a click opens the system menu.
        case appIcon
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
    public let contentTop: Int32
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
        contentTop = height + scaled(26)
        actionWidth = scaled(40)
        captionWidth = scaled(46)
    }

    /// appIcon is the strip on the bar's left edge for the application icon and system menu.
    public var appIcon: Span { Span(left: 0, right: actionWidth) }

    public func span(of button: Button) -> Span {
        if let index = Button.trailing.firstIndex(of: button) {
            let groupGap = index < 3 ? actionWidth / 4 : 0
            let right = width - 3 * captionWidth - Int32(Button.trailing.count - 1 - index) * actionWidth - groupGap
            return Span(left: right - actionWidth, right: right)
        }
        switch button {
        case .minimize: return Span(left: width - 3 * captionWidth, right: width - 2 * captionWidth)
        case .maximize: return Span(left: width - 2 * captionWidth, right: width - captionWidth)
        default: return Span(left: width - captionWidth, right: width)
        }
    }

    /// The session name starts at the terminal's leading edge, clear of the application icon.
    public var title: Span {
        let gap = actionWidth / 4
        return Span(left: max(sidebarWidth, appIcon.right) + gap, right: span(of: .scratch).left - gap)
    }

    public var menuSpans: [(index: Int, span: Span)] {
        MenuBarLayout.menuSpans(origin: actionWidth / 4, limit: width, dpi: dpi)
    }

    public func menuTab(x: Int32, y: Int32) -> Int? {
        guard height <= y, y < contentTop else { return nil }
        return menuSpans.first { x >= $0.span.left && x < $0.span.right }?.index
    }

    public func hit(x: Int32, y: Int32, topBorder: Int32) -> Hit {
        guard y >= 0, x >= 0, x < width else { return .outside }
        if let index = menuTab(x: x, y: y) { return .menuTab(index) }
        guard y < height else { return .outside }
        if y < topBorder { return .top }
        let caption: [Button] = [.close, .maximize, .minimize]
        if let button = caption.first(where: { x >= span(of: $0).left && x < span(of: $0).right }) { return .button(button) }
        if x < appIcon.right { return .appIcon }
        if let button = Button.trailing.first(where: { x >= span(of: $0).left && x < span(of: $0).right }) { return .button(button) }
        return .caption
    }
}

extension TitleBar {
    /// caption is the bar's text: the session's name, then the context an agent set for it, as a Mac's title bar shows it.
    public static func caption(name: String?, context: String?) -> String {
        guard let name else { return "agterm" }
        guard let context, !context.isEmpty else { return name }
        return "\(name) \u{2014} \(context)"
    }
}
