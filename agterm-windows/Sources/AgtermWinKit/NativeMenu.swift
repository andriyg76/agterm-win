import agtermCore

/// NativeMenu is what the native window's menus hold: the terminal's context menu, the title-bar menus, and the
/// commands those add. Commands without a standard shortcut remain available from the menus.
public enum NativeMenu {
    public enum Command: Int, CaseIterable, Sendable {
        case copy = 1, paste, selectAll, clearScrollback, fontBigger, fontSmaller, fontReset, newSession, newServerSession, renameSession, restartSession, closeSession, nextSession, previousSession, find, quit,
             editKeymap, reloadKeymap, settings, sessionPalette, commandPalette, toggleSplit, toggleHorizontalSplit, closeSplit, swapPanes,
             focusLeftPane, focusRightPane, toggleScratch, quickTerminal, dashboard, toggleOverlay

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
            case .sessionPalette: "Go to Session…"
            case .commandPalette: "Command Palette…"
            case .toggleSplit: "Split Side by Side"
            case .toggleHorizontalSplit: "Split Top and Bottom"
            case .closeSplit: "Close Split"
            case .swapPanes: "Swap Panes"
            case .focusLeftPane: "Focus Left or Top Pane"
            case .focusRightPane: "Focus Right or Bottom Pane"
            case .toggleScratch: "Scratch"
            case .toggleOverlay: "Overlay"
            case .quickTerminal: "Quick Terminal"
            case .dashboard: "Dashboard"
            }
        }

        /// shortcut is the shipped chord's label; the keymap's own come in as `Shortcuts`.
        public var shortcut: String {
            if let action = WindowsKeymap.actions.first(where: { $0.command == self })?.action {
                return action.windowsDefaultChord.map(WindowsKeymap.label) ?? ""
            }
            switch self {
            case .copy: return "Ctrl+Shift+C / Ctrl+Insert"
            case .paste: return "Ctrl+Shift+V / Shift+Insert / Ctrl+Shift+I"
            case .selectAll: return "Ctrl+Shift+A"
            case .settings: return "Ctrl+, / Ctrl+Alt+S"
            case .quit: return "Alt+F4"
            default: return ""
            }
        }
    }

    /// Pick is what choosing an entry does: run a command, start a new session from a launch profile, or start or open
    /// a session on one of the `servers` the menu was given, by index.
    public enum Pick: Equatable, Sendable {
        case command(Command)
        case profile(Int)
        case defaultProfile(Int)
        case startServer(Int)
        case serverSession(Int)

        static let profileBase = 1000
        static let defaultProfileBase = 2000
        static let startServerBase = 3000
        static let serverSessionBase = 4000

        /// id is the Win32 menu item id; 0 is reserved for a dismissed menu.
        public var id: Int {
            switch self {
            case .command(let command): command.rawValue
            case .profile(let index): Self.profileBase + index
            case .defaultProfile(let index): Self.defaultProfileBase + index
            case .startServer(let index): Self.startServerBase + index
            case .serverSession(let index): Self.serverSessionBase + index
            }
        }

        public init?(id: Int) {
            if id >= Self.serverSessionBase {
                self = .serverSession(id - Self.serverSessionBase)
            } else if id >= Self.startServerBase {
                self = .startServer(id - Self.startServerBase)
            } else if id >= Self.defaultProfileBase {
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

    /// Server is a WSL distribution's agterm-server as the menu shows it: its label, whether it was started this launch
    /// and is connected, and whether New Session on Server's shortcut opens a session on it.
    public struct Server: Equatable, Sendable {
        public var label: String
        public var started: Bool
        public var connected: Bool
        public var current: Bool

        public init(label: String, started: Bool = false, connected: Bool = false, current: Bool = false) {
            self.label = label
            self.started = started
            self.connected = connected
            self.current = current
        }
    }

    /// sessions is the sidebar's menu: New Session lists the profiles, the default one on New Session's shortcut, then
    /// a session on each started server, enabled while it is connected, and Start agterm-server in, which lists every
    /// server, enabled until it is started; Default Profile picks that default.
    public static func sessions(profiles: [LaunchProfile], defaultProfile: Int = 0, servers: [Server] = [], canCloseSession: Bool,
                                sessionCount: Int, canRenameSession: Bool = false, canRestartSession: Bool = false,
                                shortcuts: Shortcuts = [:]) -> [Entry] {
        let newSessionShortcut = shortcuts[.newSession] ?? Command.newSession.shortcut
        var launches = profiles.enumerated().map { index, profile in
            Entry(title: profile.name, shortcut: index == defaultProfile ? newSessionShortcut : "", pick: .profile(index),
                  enabled: true, children: [])
        }
        let defaults = profiles.enumerated().map { index, profile in
            Entry(title: profile.name, shortcut: "", pick: .defaultProfile(index), enabled: true, children: [], checked: index == defaultProfile)
        }
        if !servers.isEmpty {
            let serverShortcut = shortcuts[.newServerSession] ?? Command.newServerSession.shortcut
            let started = servers.enumerated().filter { $0.element.started }.map { index, server in
                Entry(title: "\(server.label) (agterm-server)", shortcut: server.current ? serverShortcut : "", pick: .serverSession(index),
                      enabled: server.connected, children: [])
            }
            let starts = servers.enumerated().map { index, server in
                Entry(title: server.label, shortcut: "", pick: .startServer(index), enabled: !server.started, children: [])
            }
            launches += [.separator] + started
                + [Entry(title: "Start agterm-server in", shortcut: "", pick: nil, enabled: true, children: starts)]
        }
        return [Entry(title: Command.newSession.title, shortcut: "", pick: nil, enabled: !launches.isEmpty, children: launches),
                Entry(title: "Default Profile", shortcut: "", pick: nil, enabled: !defaults.isEmpty, children: defaults),
                .command(.renameSession, enabled: canRenameSession, shortcuts), .command(.restartSession, enabled: canRestartSession),
                .command(.closeSession, enabled: canCloseSession, shortcuts),
                .command(.nextSession, enabled: sessionCount > 1, shortcuts), .command(.previousSession, enabled: sessionCount > 1, shortcuts)]
    }

    /// View is what the View submenu reads from the window: what the selected session can do and what is shown.
    public struct View: Equatable, Sendable {
        /// canSplit is a selected session that takes a split and a scratch: a local one.
        public var canSplit = false
        public var hasSplit = false
        public var scratchShown = false
        public var quickShown = false
        public var canDashboard = false
        public var dashboardOpen = false
        public var canToggleOverlay = false
        public var overlayShown = false

        public init(canSplit: Bool = false, hasSplit: Bool = false, scratchShown: Bool = false, quickShown: Bool = false,
                    canDashboard: Bool = false, dashboardOpen: Bool = false, canToggleOverlay: Bool = false, overlayShown: Bool = false) {
            self.canSplit = canSplit
            self.hasSplit = hasSplit
            self.scratchShown = scratchShown
            self.quickShown = quickShown
            self.canDashboard = canDashboard
            self.dashboardOpen = dashboardOpen
            self.canToggleOverlay = canToggleOverlay
            self.overlayShown = overlayShown
        }
    }

    /// view is the View submenu: the selected session's panes and scratch, the quick terminal and the dashboard.
    public static func view(_ view: View, shortcuts: Shortcuts = [:]) -> [Entry] {
        var scratch = Entry.command(.toggleScratch, enabled: view.canSplit, shortcuts)
        scratch.checked = view.scratchShown
        var overlay = Entry.command(.toggleOverlay, enabled: view.canToggleOverlay, shortcuts)
        overlay.checked = view.overlayShown
        var quick = Entry.command(.quickTerminal, shortcuts)
        quick.checked = view.quickShown
        var dashboard = Entry.command(.dashboard, enabled: view.canDashboard || view.dashboardOpen, shortcuts)
        dashboard.checked = view.dashboardOpen
        return [.command(.toggleSplit, enabled: view.canSplit, shortcuts), .command(.toggleHorizontalSplit, enabled: view.canSplit, shortcuts),
                .command(.focusLeftPane, enabled: view.hasSplit, shortcuts), .command(.focusRightPane, enabled: view.hasSplit, shortcuts),
                .command(.swapPanes, enabled: view.hasSplit), .command(.closeSplit, enabled: view.hasSplit), .separator, scratch, overlay, quick, dashboard]
    }

    /// file is the File menu: sessions and the terminal's edit commands.
    public static func file(profiles: [LaunchProfile], defaultProfile: Int = 0, servers: [Server] = [], canCloseSession: Bool,
                            sessionCount: Int, canRenameSession: Bool = false, canRestartSession: Bool = false, hasSelection: Bool,
                            canPaste: Bool, shortcuts: Shortcuts = [:]) -> [Entry] {
        sessions(profiles: profiles, defaultProfile: defaultProfile, servers: servers, canCloseSession: canCloseSession,
                 sessionCount: sessionCount, canRenameSession: canRenameSession, canRestartSession: canRestartSession, shortcuts: shortcuts)
            + [.separator] + terminal(hasSelection: hasSelection, canPaste: canPaste, shortcuts: shortcuts)
    }

    /// navigate is the Navigate menu: the palettes and Find.
    public static func navigate(shortcuts: Shortcuts = [:]) -> [Entry] {
        [.command(.sessionPalette, shortcuts), .command(.commandPalette, shortcuts), .command(.find, shortcuts)]
    }

    /// help is the Help menu: settings, the keymap, and Quit.
    public static func help(shortcuts: Shortcuts = [:]) -> [Entry] {
        [.command(.settings), .command(.editKeymap), .command(.reloadKeymap), .separator, .command(.quit)]
    }

    /// window is every menu tab flattened, which the command palette lists.
    public static func window(profiles: [LaunchProfile], defaultProfile: Int = 0, servers: [Server] = [], canCloseSession: Bool,
                              sessionCount: Int, canRenameSession: Bool = false, canRestartSession: Bool = false, hasSelection: Bool,
                              canPaste: Bool, view: View = View(), shortcuts: Shortcuts = [:]) -> [Entry] {
        file(profiles: profiles, defaultProfile: defaultProfile, servers: servers, canCloseSession: canCloseSession, sessionCount: sessionCount,
             canRenameSession: canRenameSession, canRestartSession: canRestartSession, hasSelection: hasSelection, canPaste: canPaste,
             shortcuts: shortcuts)
            + [.separator] + navigate(shortcuts: shortcuts)
            + [Entry(title: "View", shortcut: "", pick: nil, enabled: true, children: Self.view(view, shortcuts: shortcuts))]
            + [.separator] + help(shortcuts: shortcuts)
    }

    /// closeQuestion is what closing an agterm-server session asks: it ends that session's programs on the server.
    public static func closeQuestion(session name: String, server: String) -> String {
        "Close \(name) on \(server)? Its programs on the server end."
    }

    /// closeLocalQuestion is what closing a local session asks while Settings ▸ General asks first.
    public static func closeLocalQuestion(session name: String) -> String {
        "Close \(name)? Its program ends."
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
