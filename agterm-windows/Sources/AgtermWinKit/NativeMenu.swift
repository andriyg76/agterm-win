import agtermCore

/// NativeMenu is what the native window's menus hold: the terminal's context menu, the title-bar menus, and the
/// commands those add. Commands without a standard shortcut remain available from the menus.
public enum NativeMenu {
    public enum Command: Int, CaseIterable, Sendable {
        case copy = 1, paste, selectAll, clearScrollback, fontBigger, fontSmaller, fontReset, newSession, newServerSession, renameSession, restartSession, closeSession, nextSession, previousSession, find, quit,
             editKeymap, reloadKeymap, settings, sessionPalette, commandPalette, toggleSplit, toggleHorizontalSplit, closeSplit, swapPanes,
             focusLeftPane, focusRightPane, toggleScratch, quickTerminal, dashboard, toggleOverlay, newWorkspace, renameWorkspace,
             deleteWorkspace, toggleFlag, toggleFlaggedView, focusWorkspace, toggleWorkspaceFilter, previousWorkspace, nextWorkspace,
             newCompanion, convertCompanion, attentionPalette, selectTheme, about, toggleSidebar, editProfiles, copyName, revealSession,
             expandWorkspaces, collapseWorkspaces, toggleWorkspaceCollapse

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
            case .editProfiles: "Edit Launch Profiles…"
            case .reloadKeymap: "Reload Keymap"
            case .settings: "Settings…"
            case .selectTheme: "Select Theme…"
            case .about: "About"
            case .toggleSidebar: "Toggle Sidebar"
            case .sessionPalette: "Go to Session…"
            case .commandPalette: "Command Palette…"
            case .attentionPalette: "Go to Attention…"
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
            case .newWorkspace: "New Workspace"
            case .renameWorkspace: "Rename Workspace"
            case .deleteWorkspace: "Delete Workspace"
            case .toggleFlag: "Flag Session"
            case .toggleFlaggedView: "Show Flagged Sessions"
            case .focusWorkspace: "Focus"
            case .toggleWorkspaceFilter: "Toggle Workspace Filter"
            case .previousWorkspace: "Previous Workspace"
            case .nextWorkspace: "Next Workspace"
            case .newCompanion: "New Companion"
            case .convertCompanion: "Convert to Companion"
            case .copyName: "Copy Name"
            case .revealSession: "Reveal in Explorer"
            case .expandWorkspaces: "Expand Workspaces"
            case .collapseWorkspaces: "Collapse Workspaces"
            case .toggleWorkspaceCollapse: "Collapse Workspace"
            }
        }

        /// isStructure is a workspace, flag or companion command, which acts on a sidebar row.
        public var isStructure: Bool {
            switch self {
            case .newWorkspace, .renameWorkspace, .deleteWorkspace, .focusWorkspace, .toggleWorkspaceFilter, .toggleFlaggedView,
                 .previousWorkspace, .nextWorkspace, .toggleFlag, .newCompanion, .convertCompanion, .expandWorkspaces,
                 .collapseWorkspaces, .toggleWorkspaceCollapse: true
            default: false
            }
        }

        /// shortcut is the shipped chord's label; the keymap's own come in as `Shortcuts`.
        public var shortcut: String {
            if let action = WindowsKeymap.actions.first(where: { $0.command == self })?.action {
                guard let chord = action.windowsDefaultChord else { return "" }
                let label = WindowsKeymap.label(chord)
                return self == .closeSession ? "\(label) / \(WindowsKeymap.label(WindowsKeymap.closeSessionAlias))" : label
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
        case sidebarSession
        case moveToWorkspace(Int)

        static let sidebarSessionID = 999
        static let profileBase = 1000
        static let defaultProfileBase = 2000
        static let startServerBase = 3000
        static let serverSessionBase = 4000
        static let moveToWorkspaceBase = 5000

        /// id is the Win32 menu item id; 0 is reserved for a dismissed menu.
        public var id: Int {
            switch self {
            case .command(let command): command.rawValue
            case .profile(let index): Self.profileBase + index
            case .defaultProfile(let index): Self.defaultProfileBase + index
            case .startServer(let index): Self.startServerBase + index
            case .serverSession(let index): Self.serverSessionBase + index
            case .sidebarSession: Self.sidebarSessionID
            case .moveToWorkspace(let index): Self.moveToWorkspaceBase + index
            }
        }

        public init?(id: Int) {
            if id == Self.sidebarSessionID {
                self = .sidebarSession
            } else if id >= Self.moveToWorkspaceBase {
                self = .moveToWorkspace(id - Self.moveToWorkspaceBase)
            } else if id >= Self.serverSessionBase {
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

        public static let separator = Entry(title: "", shortcut: "", pick: nil, enabled: false, children: [])

        static func command(_ command: Command, enabled: Bool = true, _ shortcuts: Shortcuts = [:]) -> Entry {
            Entry(title: command.title, shortcut: shortcuts[command] ?? command.shortcut, pick: .command(command), enabled: enabled,
                  children: [])
        }
    }

    /// Shortcuts are the labels the keymap gives commands, "" for one it left unbound; a missing command shows its
    /// shipped `shortcut`.
    public typealias Shortcuts = [Command: String]

    public static func terminal(hasSelection: Bool, canPaste: Bool, shortcuts: Shortcuts = [:]) -> [Entry] {
        edit(hasSelection: hasSelection, canPaste: canPaste) + [.separator] + fontSizing(shortcuts)
    }

    public static func edit(hasSelection: Bool, canPaste: Bool) -> [Entry] {
        [.command(.copy, enabled: hasSelection), .command(.paste, enabled: canPaste), .command(.selectAll), .command(.clearScrollback)]
    }

    private static func fontSizing(_ shortcuts: Shortcuts) -> [Entry] {
        [.command(.fontBigger, shortcuts), .command(.fontSmaller, shortcuts), .command(.fontReset, shortcuts)]
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

    public static func sidebar(profiles: [LaunchProfile], defaultProfile: Int, servers: [Server], destination: String?,
                               canLaunch: Bool, canRename: Bool?, canRestart: Bool, canClose: Bool, canReveal: Bool = false,
                               shortcuts: Shortcuts = [:]) -> [Entry] {
        let local = profiles.enumerated().map { index, profile in
            Entry(title: profile.name, shortcut: "", pick: .profile(index), enabled: true, children: [])
        }
        let defaults = profiles.enumerated().map { index, profile in
            Entry(title: profile.name, shortcut: "", pick: .defaultProfile(index), enabled: true,
                  children: [], checked: index == defaultProfile)
        }
        let serverSessions = servers.enumerated().filter { $0.element.started }.map { index, server in
            Entry(title: server.label, shortcut: "", pick: .serverSession(index), enabled: server.connected, children: [])
        }
        let starts = servers.enumerated().map { index, server in
            Entry(title: server.label, shortcut: "", pick: .startServer(index), enabled: !server.started, children: [])
        }
        let localProfiles = Entry(title: "Local Profiles", shortcut: "", pick: nil, enabled: !local.isEmpty, children: local)
        var menu = [Entry(title: destination.map { "New Session in \($0)" } ?? "New Local Session", shortcut: "",
                          pick: .sidebarSession, enabled: canLaunch, children: [])]
        var elsewhere: [Entry] = []
        if destination == nil {
            menu += [localProfiles, Entry(title: "Default Local Profile", shortcut: "", pick: nil, enabled: !defaults.isEmpty,
                                          children: defaults)]
        } else if !local.isEmpty {
            elsewhere.append(localProfiles)
        }
        if !serverSessions.isEmpty {
            if !elsewhere.isEmpty { elsewhere.append(.separator) }
            elsewhere += serverSessions
        }
        if !starts.isEmpty {
            if !elsewhere.isEmpty { elsewhere.append(.separator) }
            elsewhere.append(Entry(title: "Start WSL Server", shortcut: "", pick: nil, enabled: starts.contains(where: \.enabled),
                                   children: starts))
        }
        if !elsewhere.isEmpty {
            menu.append(Entry(title: "New Session Elsewhere", shortcut: "", pick: nil, enabled: true, children: elsewhere))
        }
        if let canRename {
            menu += [.separator, .command(.renameSession, enabled: canRename, shortcuts), .command(.copyName, shortcuts),
                     .command(.restartSession, enabled: canRestart, shortcuts), .command(.revealSession, enabled: canReveal, shortcuts),
                     .command(.closeSession, enabled: canClose, shortcuts)]
        }
        return menu
    }

    /// sessions is the File menu's session section: New Session lists the profiles, the default one on New Session's shortcut, then
    /// a session on each started server, enabled while it is connected, and Start agterm-server in, which lists every
    /// server, enabled until it is started; Default Profile picks that default.
    public static func sessions(profiles: [LaunchProfile], defaultProfile: Int = 0, servers: [Server] = [], canCloseSession: Bool,
                                canRenameSession: Bool = false, canRestartSession: Bool = false, canRevealSession: Bool = false,
                                structure: Structure = Structure(),
                                localDefaultShortcut: Bool = true, shortcuts: Shortcuts = [:]) -> [Entry] {
        let newSessionShortcut = shortcuts[.newSession] ?? Command.newSession.shortcut
        var launches = profiles.enumerated().map { index, profile in
            Entry(title: profile.name, shortcut: localDefaultShortcut && index == defaultProfile ? newSessionShortcut : "", pick: .profile(index),
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
                .command(.newCompanion, enabled: structure.flagged != nil, shortcuts),
                .command(.convertCompanion, enabled: structure.canConvert, shortcuts),
                .command(.revealSession, enabled: canRevealSession, shortcuts), .command(.closeSession, enabled: canCloseSession, shortcuts)]
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
        public var sidebarVisible = true

        public init(canSplit: Bool = false, hasSplit: Bool = false, scratchShown: Bool = false, quickShown: Bool = false,
                    canDashboard: Bool = false, dashboardOpen: Bool = false, canToggleOverlay: Bool = false, overlayShown: Bool = false,
                    sidebarVisible: Bool = true) {
            self.canSplit = canSplit
            self.hasSplit = hasSplit
            self.scratchShown = scratchShown
            self.quickShown = quickShown
            self.canDashboard = canDashboard
            self.dashboardOpen = dashboardOpen
            self.canToggleOverlay = canToggleOverlay
            self.overlayShown = overlayShown
            self.sidebarVisible = sidebarVisible
        }
    }

    public static func view(_ view: View, structure: Structure = Structure(), shortcuts: Shortcuts = [:]) -> [Entry] {
        let scratch = toggle(.toggleScratch, checked: view.scratchShown, enabled: view.canSplit, shortcuts)
        let overlay = toggle(.toggleOverlay, checked: view.overlayShown, enabled: view.canToggleOverlay, shortcuts)
        let quick = toggle(.quickTerminal, checked: view.quickShown, enabled: true, shortcuts)
        let flag = toggle(.toggleFlag, checked: structure.flagged == true, enabled: structure.flagged != nil, shortcuts)
        let focus = toggle(.focusWorkspace, checked: structure.focused, enabled: structure.workspace == true, shortcuts)
        let sidebar = Entry(title: view.sidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                            shortcut: shortcuts[.toggleSidebar] ?? Command.toggleSidebar.shortcut, pick: .command(.toggleSidebar), enabled: true,
                            children: [])
        return [sidebar, .separator]
            + fontSizing(shortcuts) + [.separator, .command(.selectTheme), .separator, flaggedView(structure, shortcuts), flag,
                .separator, focus, workspaceFilter(structure, shortcuts), .command(.expandWorkspaces, enabled: structure.workspaceRows, shortcuts),
                .command(.collapseWorkspaces, enabled: structure.workspaceRows, shortcuts), workspaceFold(structure, shortcuts), .separator,
                .command(.toggleSplit, enabled: view.canSplit, shortcuts), .command(.toggleHorizontalSplit, enabled: view.canSplit, shortcuts),
                .command(.swapPanes, enabled: view.hasSplit), .command(.closeSplit, enabled: view.hasSplit), scratch, overlay,
                .separator, .command(.find, shortcuts), quick]
    }

    /// File groups workspace and session actions, followed by configuration.
    public static func file(profiles: [LaunchProfile], defaultProfile: Int = 0, servers: [Server] = [], canCloseSession: Bool,
                            canRenameSession: Bool = false, canRestartSession: Bool = false, canRevealSession: Bool = false,
                            structure: Structure = Structure(), localDefaultShortcut: Bool = true, shortcuts: Shortcuts = [:]) -> [Entry] {
        let named = structure.workspace == true
        let settings = Entry(title: "Settings", shortcut: "", pick: nil, enabled: true,
                             children: [.command(.settings), .command(.editKeymap), .command(.editProfiles), .command(.reloadKeymap)])
        return [.command(.newWorkspace, shortcuts), .command(.renameWorkspace, enabled: named, shortcuts),
                .command(.deleteWorkspace, enabled: named, shortcuts), .separator]
            + sessions(profiles: profiles, defaultProfile: defaultProfile, servers: servers, canCloseSession: canCloseSession,
                       canRenameSession: canRenameSession, canRestartSession: canRestartSession, canRevealSession: canRevealSession,
                       structure: structure, localDefaultShortcut: localDefaultShortcut, shortcuts: shortcuts)
            + [.separator, settings]
    }

    public static func navigate(_ view: View, sessionCount: Int, shortcuts: Shortcuts = [:]) -> [Entry] {
        let dashboard = toggle(.dashboard, checked: view.dashboardOpen, enabled: view.canDashboard || view.dashboardOpen, shortcuts)
        return [.command(.sessionPalette, shortcuts), .command(.commandPalette, shortcuts), .command(.attentionPalette, shortcuts), dashboard,
                .separator, .command(.previousSession, enabled: sessionCount > 1, shortcuts),
                .command(.nextSession, enabled: sessionCount > 1, shortcuts), .separator,
                .command(.previousWorkspace, shortcuts), .command(.nextWorkspace, shortcuts), .separator,
                .command(.focusLeftPane, enabled: view.hasSplit, shortcuts), .command(.focusRightPane, enabled: view.hasSplit, shortcuts)]
    }

    /// Structure is what the sidebar's workspace section acts on: a workspace row (`workspace` not nil, true for a named
    /// one) or a session (`flagged` not nil), the workspaces a session can move to, and the view's flagged and filter state.
    public struct Structure: Equatable, Sendable {
        public var workspace: Bool?
        public var focused = false
        public var flagged: Bool?
        public var canConvert = false
        public var moveTargets: [String] = []
        public var flaggedView = false
        public var filtered = false
        public var canToggleFlaggedView = true
        public var canFilter = true
        /// collapsed is whether the workspace row is folded; workspaceRows is a tree with a named workspace to fold.
        public var collapsed = false
        public var workspaceRows = false

        public init(workspace: Bool? = nil, focused: Bool = false, flagged: Bool? = nil, canConvert: Bool = false, moveTargets: [String] = [],
                    flaggedView: Bool = false, filtered: Bool = false) {
            self.workspace = workspace
            self.focused = focused
            self.flagged = flagged
            self.canConvert = canConvert
            self.moveTargets = moveTargets
            self.flaggedView = flaggedView
            self.filtered = filtered
        }
    }

    /// structure is the sidebar's workspace section, as the Mac's sidebar menu has it: the workspace row's rename,
    /// delete and focus, or the session's flag, companions and move, then the flagged view and focus filter.
    public static func structure(_ structure: Structure, shortcuts: Shortcuts = [:]) -> [Entry] {
        var menu = [Entry.command(.newWorkspace, shortcuts)]
        if let named = structure.workspace {
            var focus = Entry.command(.focusWorkspace, enabled: named, shortcuts)
            focus.checked = structure.focused
            menu += [.command(.renameWorkspace, enabled: named, shortcuts), .command(.copyName, enabled: named, shortcuts),
                     .command(.deleteWorkspace, enabled: named, shortcuts), workspaceFold(structure, shortcuts), focus]
        }
        if let flagged = structure.flagged {
            var flag = Entry.command(.toggleFlag, shortcuts)
            flag.checked = flagged
            let targets = structure.moveTargets.enumerated().map { index, name in
                Entry(title: name, shortcut: "", pick: .moveToWorkspace(index), enabled: true, children: [])
            }
            menu += [flag, .command(.newCompanion, shortcuts), .command(.convertCompanion, enabled: structure.canConvert, shortcuts),
                     Entry(title: "Move to", shortcut: "", pick: nil, enabled: !targets.isEmpty, children: targets)]
        }
        return menu + [.separator, flaggedView(structure, shortcuts), workspaceFilter(structure, shortcuts)]
    }

    private static func toggle(_ command: Command, checked: Bool, enabled: Bool, _ shortcuts: Shortcuts) -> Entry {
        var entry = Entry.command(command, enabled: enabled, shortcuts)
        entry.checked = checked
        return entry
    }

    /// workspaceFold folds or unfolds the workspace, titled for what it will do, as the Mac's Collapse/Expand Workspace.
    private static func workspaceFold(_ structure: Structure, _ shortcuts: Shortcuts) -> Entry {
        let command = Command.toggleWorkspaceCollapse
        return Entry(title: structure.collapsed ? "Expand Workspace" : command.title, shortcut: shortcuts[command] ?? command.shortcut,
                     pick: .command(command), enabled: structure.workspace == true && structure.workspaceRows, children: [])
    }

    private static func flaggedView(_ structure: Structure, _ shortcuts: Shortcuts) -> Entry {
        toggle(.toggleFlaggedView, checked: structure.flaggedView, enabled: structure.canToggleFlaggedView, shortcuts)
    }

    private static func workspaceFilter(_ structure: Structure, _ shortcuts: Shortcuts) -> Entry {
        toggle(.toggleWorkspaceFilter, checked: structure.filtered, enabled: structure.canFilter, shortcuts)
    }

    public static func help() -> [Entry] { [.command(.about)] }

    /// The command palette lists the same actions as the menu bar, plus native Quit.
    public static func window(profiles: [LaunchProfile], defaultProfile: Int = 0, servers: [Server] = [], canCloseSession: Bool,
                              sessionCount: Int, canRenameSession: Bool = false, canRestartSession: Bool = false,
                              canRevealSession: Bool = false, hasSelection: Bool,
                              canPaste: Bool, view: View = View(), structure: Structure = Structure(), localDefaultShortcut: Bool = true,
                              shortcuts: Shortcuts = [:]) -> [Entry] {
        file(profiles: profiles, defaultProfile: defaultProfile, servers: servers, canCloseSession: canCloseSession,
             canRenameSession: canRenameSession, canRestartSession: canRestartSession, canRevealSession: canRevealSession,
             structure: structure, localDefaultShortcut: localDefaultShortcut, shortcuts: shortcuts)
            + edit(hasSelection: hasSelection, canPaste: canPaste)
            + [Entry(title: "View", shortcut: "", pick: nil, enabled: true, children: Self.view(view, structure: structure, shortcuts: shortcuts))]
            + navigate(view, sessionCount: sessionCount, shortcuts: shortcuts) + help() + [.command(.quit)]
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
