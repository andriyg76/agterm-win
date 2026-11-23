/// NativeMenu is what the native window's menus hold: the terminal's context menu, and the ☰ menu, which adds the
/// window's own commands. Every command is also a shortcut, so a menu never holds the only way to do something.
public enum NativeMenu {
    public enum Command: Int, CaseIterable, Sendable {
        case copy = 1, paste, selectAll, clearScrollback, fontBigger, fontSmaller, fontReset, newSession, newServerSession, renameSession, restartSession, closeSession, nextSession, previousSession, find, quit,
             editKeymap, reloadKeymap, settings

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
            case .newServerSession: "New Session on Server"
            case .renameSession: "Rename Session"
            case .restartSession: "Restart Session"
            case .closeSession: "Close Session"
            case .nextSession: "Next Session"
            case .previousSession: "Previous Session"
            case .find: "Find…"
            case .quit: "Quit"
            case .editKeymap: "Edit Keymap…"
            case .reloadKeymap: "Reload Keymap"
            case .settings: "Settings…"
            }
        }

        /// shortcut is the shipped chord's label; the keymap's own come in as `Shortcuts`.
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
            case .newServerSession: "Ctrl+Shift+N"
            case .renameSession: "F2"
            case .restartSession: "Ctrl+Shift+R"
            case .closeSession: "Ctrl+Shift+W"
            case .nextSession: "Ctrl+Tab"
            case .previousSession: "Ctrl+Shift+Tab"
            case .find: "Ctrl+Shift+F"
            case .quit: "Alt+F4"
            case .settings: "Ctrl+,"
            case .editKeymap, .reloadKeymap: ""
            }
        }
    }

    /// Pick is what choosing an entry does: run a command, or start a new session from a launch profile.
    public enum Pick: Equatable, Sendable {
        case command(Command)
        case profile(Int)
        case defaultProfile(Int)

        static let profileBase = 1000
        static let defaultProfileBase = 2000

        /// id is the Win32 menu item id; 0 is reserved for a dismissed menu.
        public var id: Int {
            switch self {
            case .command(let command): command.rawValue
            case .profile(let index): Self.profileBase + index
            case .defaultProfile(let index): Self.defaultProfileBase + index
            }
        }

        public init?(id: Int) {
            if id >= Self.defaultProfileBase {
                self = .defaultProfile(id - Self.defaultProfileBase)
            } else if id >= Self.profileBase {
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
        public var checked = false

        static let separator = Entry(title: "", shortcut: "", pick: nil, enabled: false, children: [])

        static func command(_ command: Command, enabled: Bool = true, _ shortcuts: Shortcuts = [:]) -> Entry {
            Entry(title: command.title, shortcut: shortcuts[command] ?? command.shortcut, pick: .command(command), enabled: enabled,
                  children: [])
        }
    }

    /// Shortcuts are the labels the keymap gives commands, "" for one it left unbound; a missing command shows its
    /// shipped `shortcut`.
    public typealias Shortcuts = [Command: String]

    public static func terminal(hasSelection: Bool, canPaste: Bool, shortcuts: Shortcuts = [:]) -> [Entry] {
        [.command(.copy, enabled: hasSelection), .command(.paste, enabled: canPaste), .command(.selectAll),
         .command(.clearScrollback), .separator, .command(.fontBigger, shortcuts), .command(.fontSmaller, shortcuts),
         .command(.fontReset, shortcuts)]
    }

    /// defaultProfile is the index of the profile named `name`, the one New Session's shortcut starts; the first profile
    /// when none is named or the named one is gone.
    public static func defaultProfile(named name: String?, in profiles: [LaunchProfile]) -> Int {
        name.flatMap { name in profiles.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame } } ?? 0
    }

    /// sessions is the sidebar's menu: New Session lists the profiles, the default one on New Session's shortcut, then
    /// the agterm-server named `server`, enabled while it is connected; Default Profile picks that default.
    public static func sessions(profiles: [LaunchProfile], defaultProfile: Int = 0, server: String? = nil, serverConnected: Bool = false,
                                canCloseSession: Bool, sessionCount: Int, canRenameSession: Bool = false,
                                canRestartSession: Bool = false, shortcuts: Shortcuts = [:]) -> [Entry] {
        let newSessionShortcut = shortcuts[.newSession] ?? Command.newSession.shortcut
        var launches = profiles.enumerated().map { index, profile in
            Entry(title: profile.name, shortcut: index == defaultProfile ? newSessionShortcut : "", pick: .profile(index),
                  enabled: true, children: [])
        }
        let defaults = profiles.enumerated().map { index, profile in
            Entry(title: profile.name, shortcut: "", pick: .defaultProfile(index), enabled: true, children: [], checked: index == defaultProfile)
        }
        if let server {
            launches += [.separator, Entry(title: "\(server) (agterm-server)", shortcut: shortcuts[.newServerSession] ?? Command.newServerSession.shortcut,
                                           pick: .command(.newServerSession), enabled: serverConnected, children: [])]
        }
        return [Entry(title: Command.newSession.title, shortcut: "", pick: nil, enabled: !launches.isEmpty, children: launches),
                Entry(title: "Default Profile", shortcut: "", pick: nil, enabled: !defaults.isEmpty, children: defaults),
                .command(.renameSession, enabled: canRenameSession, shortcuts), .command(.restartSession, enabled: canRestartSession),
                .command(.closeSession, enabled: canCloseSession, shortcuts),
                .command(.nextSession, enabled: sessionCount > 1, shortcuts), .command(.previousSession, enabled: sessionCount > 1, shortcuts)]
    }

    /// window is the ☰ menu: the sidebar's menu, Find, the terminal's menu, the keymap's commands, and Quit.
    public static func window(profiles: [LaunchProfile], defaultProfile: Int = 0, server: String? = nil, serverConnected: Bool = false,
                              canCloseSession: Bool, sessionCount: Int, canRenameSession: Bool = false,
                              canRestartSession: Bool = false, hasSelection: Bool, canPaste: Bool, shortcuts: Shortcuts = [:]) -> [Entry] {
        sessions(profiles: profiles, defaultProfile: defaultProfile, server: server, serverConnected: serverConnected, canCloseSession: canCloseSession,
                 sessionCount: sessionCount, canRenameSession: canRenameSession, canRestartSession: canRestartSession, shortcuts: shortcuts)
            + [.separator, .command(.find, shortcuts)] + terminal(hasSelection: hasSelection, canPaste: canPaste, shortcuts: shortcuts)
            + [.separator, .command(.settings), .command(.editKeymap), .command(.reloadKeymap), .separator, .command(.quit)]
    }

    /// closeQuestion is what closing an agterm-server session asks: it ends that session's programs on the server.
    public static func closeQuestion(session name: String, server: String) -> String {
        "Close \(name) on \(server)? Its programs on the server end."
    }

    /// quitQuestion is what closing the window asks while local sessions still run, nil when nothing would be lost;
    /// agterm-server's sessions keep running on the server.
    public static func quitQuestion(runningLocalSessions count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "Quit agterm? A local session is still running and will end."
            : "Quit agterm? \(count) local sessions are still running and will end."
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
