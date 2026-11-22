/// NativeMenu is what the native window's menus hold: the terminal's context menu, and the ☰ menu, which adds the
/// window's own commands. Every command is also a shortcut, so a menu never holds the only way to do something.
public enum NativeMenu {
    public enum Command: Int, CaseIterable, Sendable {
        case copy = 1, paste, selectAll, clearScrollback, fontBigger, fontSmaller, fontReset, newSession, closeSession, nextSession, previousSession, find, quit

        public var title: String {
            switch self {
            case .copy: "Copy"
            case .paste: "Paste"
            case .selectAll: "Select All"
            case .clearScrollback: "Clear Scrollback"
            case .fontBigger: "Bigger Font"
            case .fontSmaller: "Smaller Font"
            case .fontReset: "Default Font Size"
            case .newSession: "New Session"
            case .closeSession: "Close Session"
            case .nextSession: "Next Session"
            case .previousSession: "Previous Session"
            case .find: "Find…"
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
            case .newSession: "Ctrl+Shift+T"
            case .closeSession: "Ctrl+Shift+W"
            case .nextSession: "Ctrl+Tab"
            case .previousSession: "Ctrl+Shift+Tab"
            case .find: "Ctrl+Shift+F"
            case .quit: "Alt+F4"
            }
        }
    }

    /// Pick is what choosing an entry does: run a command, or start a new session from a launch profile.
    public enum Pick: Equatable, Sendable {
        case command(Command)
        case profile(Int)

        static let profileBase = 1000

        /// id is the Win32 menu item id; 0 is reserved for a dismissed menu.
        public var id: Int {
            switch self {
            case .command(let command): command.rawValue
            case .profile(let index): Self.profileBase + index
            }
        }

        public init?(id: Int) {
            if id >= Self.profileBase {
                self = .profile(id - Self.profileBase)
            } else if let command = Command(rawValue: id) {
                self = .command(command)
            } else {
                return nil
            }
        }
    }

    /// Entry is a pick, a submenu when `children` is not empty, or a separator when it has neither.
    public struct Entry: Equatable, Sendable {
        public let title: String
        public let shortcut: String
        public let pick: Pick?
        public let enabled: Bool
        public let children: [Entry]

        static let separator = Entry(title: "", shortcut: "", pick: nil, enabled: false, children: [])

        static func command(_ command: Command, enabled: Bool = true) -> Entry {
            Entry(title: command.title, shortcut: command.shortcut, pick: .command(command), enabled: enabled, children: [])
        }
    }

    public static func terminal(hasSelection: Bool, canPaste: Bool) -> [Entry] {
        [.command(.copy, enabled: hasSelection), .command(.paste, enabled: canPaste), .command(.selectAll),
         .command(.clearScrollback), .separator, .command(.fontBigger), .command(.fontSmaller), .command(.fontReset)]
    }

    /// sessions is the sidebar's menu: New Session lists the profiles, the first of them on New Session's shortcut.
    public static func sessions(profiles: [LaunchProfile], canCloseSession: Bool, sessionCount: Int) -> [Entry] {
        let launches = profiles.enumerated().map { index, profile in
            Entry(title: profile.name, shortcut: index == 0 ? Command.newSession.shortcut : "", pick: .profile(index), enabled: true,
                  children: [])
        }
        return [Entry(title: Command.newSession.title, shortcut: "", pick: nil, enabled: !launches.isEmpty, children: launches),
                .command(.closeSession, enabled: canCloseSession),
                .command(.nextSession, enabled: sessionCount > 1), .command(.previousSession, enabled: sessionCount > 1)]
    }

    /// window is the ☰ menu: the sidebar's menu, Find, the terminal's menu, and Quit.
    public static func window(profiles: [LaunchProfile], canCloseSession: Bool, sessionCount: Int, hasSelection: Bool,
                              canPaste: Bool) -> [Entry] {
        sessions(profiles: profiles, canCloseSession: canCloseSession, sessionCount: sessionCount) + [.separator, .command(.find)]
            + terminal(hasSelection: hasSelection, canPaste: canPaste) + [.separator, .command(.quit)]
    }

    public static let defaultPoints: Float = 11
    public static let pointRange: ClosedRange<Float> = 6...36

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
