/// NativeMenu is what the native window's menus hold: the terminal's context menu, and the ☰ menu, which adds the
/// window's own commands. Every entry is also a shortcut, so a menu never holds the only way to do something.
public enum NativeMenu {
    public enum Command: Int, CaseIterable, Sendable {
        case copy = 1, paste, selectAll, clearScrollback, fontBigger, fontSmaller, fontReset, quit

        public var title: String {
            switch self {
            case .copy: "Copy"
            case .paste: "Paste"
            case .selectAll: "Select All"
            case .clearScrollback: "Clear Scrollback"
            case .fontBigger: "Bigger Font"
            case .fontSmaller: "Smaller Font"
            case .fontReset: "Default Font Size"
            case .quit: "Quit"
            }
        }

        public var shortcut: String {
            switch self {
            case .copy: "Ctrl+Shift+C"
            case .paste: "Ctrl+Shift+V"
            case .selectAll: "Ctrl+Shift+A"
            case .clearScrollback: "Ctrl+Shift+K"
            case .fontBigger: "Ctrl+="
            case .fontSmaller: "Ctrl+-"
            case .fontReset: "Ctrl+0"
            case .quit: "Alt+F4"
            }
        }
    }

    /// Entry is a command, or a separator when `command` is nil.
    public struct Entry: Equatable, Sendable {
        public let command: Command?
        public let enabled: Bool

        static let separator = Entry(command: nil, enabled: false)
    }

    public static func terminal(hasSelection: Bool, canPaste: Bool) -> [Entry] {
        [Entry(command: .copy, enabled: hasSelection), Entry(command: .paste, enabled: canPaste),
         Entry(command: .selectAll, enabled: true), Entry(command: .clearScrollback, enabled: true), .separator,
         Entry(command: .fontBigger, enabled: true), Entry(command: .fontSmaller, enabled: true),
         Entry(command: .fontReset, enabled: true)]
    }

    public static func window(hasSelection: Bool, canPaste: Bool) -> [Entry] {
        terminal(hasSelection: hasSelection, canPaste: canPaste) + [.separator, Entry(command: .quit, enabled: true)]
    }

    public static let defaultPoints: Float = 11
    static let pointRange: ClosedRange<Float> = 6...36

    /// points is the font size a font command leaves: one point a step, within 6 to 36.
    public static func points(after command: Command, from current: Float) -> Float {
        switch command {
        case .fontBigger: min(current + 1, pointRange.upperBound)
        case .fontSmaller: max(current - 1, pointRange.lowerBound)
        case .fontReset: defaultPoints
        default: current
        }
    }
}
