import Foundation
import agtermCore

/// NoticeBar is the window's notice bar: a full-width strip under the title bar or along the bottom edge that shows
/// the most important of the window's notices, with its actions and a close.
public enum NoticeBar {
    public enum Position: String, Codable, Sendable, CaseIterable {
        case top, bottom
    }

    public enum Severity: String, Sendable {
        case info, progress, error

        var rank: Int {
            switch self {
            case .info: 0
            case .progress: 1
            case .error: 2
            }
        }

        /// glyph is the Segoe MDL2 Assets icon the bar draws for the severity.
        public var glyph: UInt16 {
            switch self {
            case .info: 0xE946
            case .progress: 0xE895
            case .error: 0xE783
            }
        }
    }

    public enum Action: String, Sendable, CaseIterable {
        case retry, install, openLog

        public var title: String {
            switch self {
            case .retry: "Retry"
            case .install: "Install"
            case .openLog: "Open Log"
            }
        }
    }

    /// Message is one notice; `source` names what produced it (a WSL distribution), which its actions act on.
    public struct Message: Hashable, Sendable {
        public let source: String
        public let text: String
        public let severity: Severity
        public let actions: [Action]

        public init(source: String, text: String, severity: Severity, actions: [Action] = []) {
            self.source = source
            self.text = text
            self.severity = severity
            self.actions = actions
        }
    }

    /// State is what the bar holds: its position, the notices most important first, and those the user closed.
    public struct State: Equatable, Sendable {
        public var position: Position
        public private(set) var messages: [Message] = []
        // a closed notice comes back once it changes, or once it went away and returns
        private var dismissed: Set<Message> = []

        public init(position: Position = .top) {
            self.position = position
        }

        /// update takes the producers' notices in their order; errors go first, then progress, then info.
        public mutating func update(_ incoming: [Message]) {
            messages = incoming.enumerated().sorted { a, b in
                a.element.severity.rank != b.element.severity.rank ? a.element.severity.rank > b.element.severity.rank : a.offset < b.offset
            }.map(\.element)
            dismissed.formIntersection(messages)
        }

        /// shown is what the bar shows, nil while it is hidden.
        public var shown: Message? { messages.first { !dismissed.contains($0) } }

        /// waiting counts the other notices not dismissed, which the bar shows as a count.
        public var waiting: Int { max(messages.filter { !dismissed.contains($0) }.count - 1, 0) }

        /// dismissShown closes the shown notice, false when there is none.
        public mutating func dismissShown() -> Bool {
            guard let shown else { return false }
            dismissed.insert(shown)
            return true
        }

        public var control: ControlNoticeBar {
            ControlNoticeBar(position: position.rawValue, notices: messages.map { message in
                ControlNotice(text: message.text, severity: message.severity.rawValue,
                              actions: message.actions.isEmpty ? nil : message.actions.map(\.rawValue),
                              dismissed: dismissed.contains(message) ? true : nil)
            })
        }
    }

    /// MenuItem is a row of the bar's right-click menu.
    public enum MenuItem: Equatable, Sendable {
        case action(Action)
        case moveTo(Position)
        case dismiss
        case separator

        public var title: String {
            switch self {
            case .action(let action): action.title
            case .moveTo(.top): "Move to Top"
            case .moveTo(.bottom): "Move to Bottom"
            case .dismiss: "Dismiss"
            case .separator: ""
            }
        }
    }

    /// menu is the shown notice's actions, the moves, and Dismiss while a notice shows.
    public static func menu(_ state: State) -> [MenuItem] {
        var items = (state.shown?.actions ?? []).map(MenuItem.action)
        if !items.isEmpty { items.append(.separator) }
        items += Position.allCases.map(MenuItem.moveTo)
        if state.shown != nil { items += [.separator, .dismiss] }
        return items
    }

    /// countText is how the bar names the other notices waiting behind the shown one.
    public static func countText(_ waiting: Int) -> String { waiting > 0 ? "+\(waiting) more" : "" }

    /// height is the bar's height in pixels at `dpi`.
    public static func height(dpi: UInt32) -> Int32 { scaled(34, dpi) }

    /// snap is where a bar dropped with its top at `top` settles: the nearer end of the area it can sit in.
    public static func snap(top: Int32, height: Int32, areaTop: Int32, areaBottom: Int32) -> Position {
        top + height / 2 < (areaTop + areaBottom) / 2 ? .top : .bottom
    }

    /// dragTop is the bar's top while dragged: under the pointer by the offset it was pressed at, inside the area.
    public static func dragTop(pointer: Int32, pressOffset: Int32, height: Int32, areaTop: Int32, areaBottom: Int32) -> Int32 {
        min(max(pointer - pressOffset, areaTop), max(areaBottom - height, areaTop))
    }

    /// Layout is the bar's parts in its own pixels, left to right: the severity stripe, the grip, the icon, the text,
    /// the count of other notices, the action buttons and the close.
    public struct Layout: Equatable, Sendable {
        public struct Span: Equatable, Sendable {
            public let left, right: Int32

            public init(left: Int32, right: Int32) {
                self.left = left
                self.right = right
            }

            func contains(_ x: Int32) -> Bool { x >= left && x < right }
        }

        public enum Part: Equatable, Sendable {
            case action(Int)
            case close
            /// body is the rest of the bar, which drags it.
            case body
        }

        public let height: Int32
        public let stripe, grip, icon, text, count, close: Span
        /// actions are the buttons that fit, in the message's order; the bar's menu lists every one.
        public let actions: [Span]

        /// `labelWidths` are the action labels' widths and `countWidth` the count's, 0 for none, in pixels at `dpi`.
        public init(width: Int32, dpi: UInt32, labelWidths: [Int32], countWidth: Int32) {
            func s(_ value: Int32) -> Int32 { scaled(value, dpi) }
            height = NoticeBar.height(dpi: dpi)
            stripe = Span(left: 0, right: s(3))
            grip = Span(left: stripe.right, right: stripe.right + s(20))
            icon = Span(left: grip.right, right: grip.right + s(22))
            close = Span(left: max(width - s(40), icon.right), right: max(width, icon.right))
            let textLeft = icon.right + s(8)
            var right = close.left - s(4)
            var buttons: [Span] = []
            for label in labelWidths.reversed() {
                let left = right - label - s(24)
                guard left >= textLeft + s(120) else { break }
                buttons.insert(Span(left: left, right: right), at: 0)
                right = left - s(6)
            }
            actions = buttons
            let gap = buttons.isEmpty ? s(4) : s(10)
            let countRight = (buttons.first?.left ?? close.left) - gap
            count = countWidth > 0 ? Span(left: max(countRight - countWidth, textLeft), right: countRight) : Span(left: countRight, right: countRight)
            text = Span(left: textLeft, right: max(count.left - (countWidth > 0 ? s(10) : 0), textLeft))
        }

        public func part(x: Int32) -> Part {
            if close.contains(x) { return .close }
            if let index = actions.firstIndex(where: { $0.contains(x) }) { return .action(index) }
            return .body
        }
    }

    /// Colors are the bar's colors (0xRRGGBB), from the chrome palette the title bar and sidebar draw with.
    public struct Colors: Equatable, Sendable {
        public let background, text, dim, border, accent, button, buttonHover, buttonPressed: UInt32
    }

    public static func colors(_ palette: ChromePalette, theme: TerminalTheme?, severity: Severity) -> Colors {
        let dark = palette.isDark
        let accent = severity == .error ? errorColor(theme, dark: dark) : palette.chromeAccent
        let background = ChromePalette.mix(palette.palBg, accent, severity == .error ? (dark ? 0.18 : 0.10) : (dark ? 0.07 : 0.05))
        let text = palette.chromeText
        return Colors(background: background, text: text, dim: palette.chromeDim, border: palette.chromeBorder, accent: accent,
                      button: ChromePalette.mix(background, text, 0.10), buttonHover: ChromePalette.mix(background, text, 0.18),
                      buttonPressed: ChromePalette.mix(background, text, 0.26))
    }

    /// errorColor is the theme's red, else one that reads on the bar.
    private static func errorColor(_ theme: TerminalTheme?, dark: Bool) -> UInt32 {
        theme?.palette[dark ? 9 : 1] ?? theme?.palette[1] ?? (dark ? 0xF14C4C : 0xC42B1C)
    }

    static func scaled(_ value: Int32, _ dpi: UInt32) -> Int32 {
        Int32((Int64(value) * Int64(dpi) + 48) / 96)
    }
}
