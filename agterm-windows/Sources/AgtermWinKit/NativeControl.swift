import Foundation
import agtermCore

/// NativeControlHost is what the native window gives agtermctl: its local sessions, the agterm-server catalog's
/// workspaces, and the effects behind each command. Every session id is either a local session's or a server one's.
@MainActor
public protocol NativeControlHost: AnyObject {
    var localSessions: [NativeControl.Local] { get }
    var selectedSession: UUID? { get }
    /// serverWorkspaces is the catalog's tree, empty while no server is connected.
    var serverWorkspaces: [ControlWorkspaceNode] { get }
    func isServerSession(_ id: UUID) -> Bool
    /// isConnectedServerSession is whether `id` names a catalog row on a connected agterm-server.
    func isConnectedServerSession(_ id: UUID) -> Bool
    /// serverOverlayState is the overlay on a catalog session, when `id` names one.
    func serverOverlayState(for id: UUID) -> (overlay: NativeOverlay?, exitCode: Int?)?
    /// serverPageOverlay is the page the shell draws over a catalog session, nil for a program overlay or none.
    func serverPageOverlay(for id: UUID) -> (page: HtmlOverlay, hidden: Bool)?
    /// newLocalSession starts in `cwd` when given, else in the user's home, as a Mac's `session.new` does.
    func newLocalSession(name: String?, command: String?, cwd: String?, select: Bool) -> UUID?
    func newServerSession() async -> ControlResponse
    func closeSession(_ id: UUID) async -> ControlResponse
    func renameSession(_ id: UUID, to name: String) async -> ControlResponse
    func restartSession(_ id: UUID) async -> ControlResponse
    func selectSession(_ id: UUID)
    /// type sends `text` to the session's program in `pane`, the one on screen when nil; false when that pane has no
    /// terminal running here.
    func type(_ text: String, into id: UUID, pane: NativePane?) -> Bool
    /// screen is the pane's lines, oldest first, and how many of the last ones are on screen; nil when the pane has no
    /// terminal here.
    func screen(of id: UUID, pane: NativePane?) -> (lines: [String], rows: Int)?
    /// notify shows a `notify` for the session and returns why no banner was shown, nil when one was.
    func notify(_ id: UUID, title: String, body: String) -> String?
    /// setStatus applies a `session.status` write to a local or server session; false for an `ifIdle` skip.
    func setStatus(_ id: UUID, _ update: ControlSessionStatusUpdate) -> Bool
    /// setContext and setInfo set or, with nil, clear the title-bar context and the sidebar info line.
    func setContext(_ id: UUID, _ context: String?)
    func setInfo(_ id: UUID, _ info: SessionInfo?)
    /// markSeen clears the session's unseen badge without selecting it.
    func markSeen(_ id: UUID)
    var fontPoints: Float { get }
    func setFontPoints(_ points: Float)
    var keymap: ControlKeymap { get }
    /// reloadKeymap reads keymap.conf again and returns how many problems it found.
    func reloadKeymap() -> Int
    var appearance: Appearance { get }
    var themeCatalog: ThemeCatalog { get }
    var systemIsDark: Bool { get }
    /// setAppearance saves `appearance` and draws every terminal with it.
    func setAppearance(_ appearance: Appearance)
    /// remoteServers are the `remote.properties` remotes, each with whether its server is started and its stream's state.
    var remoteServers: [NativeControl.RemoteServer] { get }
    /// startRemoteServer starts `name`'s server without asking about launch, or probes a started one that is not
    /// connected again; nil once started, else why not.
    func startRemoteServer(_ name: String) -> String?
    /// newRemoteSession creates `create` on `name`'s connected server and selects it once the catalog brings it.
    func newRemoteSession(_ name: String, _ create: RemoteSessionCreate) async -> ControlResponse
    /// openOverlay starts a program overlay over a local session whose slot NativeControl found empty.
    func openOverlay(_ id: UUID, _ open: NativeOverlay.Open)
    /// openPageOverlay shows a local HTML or URL page in the session-wide overlay slot.
    func openPageOverlay(_ id: UUID, _ overlay: HtmlOverlay, sizePercent: Int?)
    /// closeOverlay ends a local session's overlay and its program, which then leaves no exit code.
    func closeOverlay(_ id: UUID)
    func resizeOverlay(_ id: UUID, sizePercent: Int?)
    func setOverlayHidden(_ id: UUID, _ hidden: Bool)
    /// overlayScreen and overlaySelection read the overlay's terminal, as `screen(of:)` reads the session's.
    func overlayScreen(of id: UUID) -> (lines: [String], rows: Int)?
    func overlaySelection(of id: UUID) -> String?
    /// setSplit gives a local session `split`, starting its second shell when it has none.
    func setSplit(_ id: UUID, _ split: NativeSplit)
    /// closeSplit ends a local session's split pane and whatever it runs.
    func closeSplit(_ id: UUID)
    /// swapPanes exchanges a split session's two terminals, focus following its terminal.
    func swapPanes(_ id: UUID)
    /// setScratch shows or hides a local session's scratch, starting its shell, or `command`, when it has none; a
    /// `command` replaces a running scratch.
    func setScratch(_ id: UUID, shown: Bool, command: String?)
    var quickShown: Bool { get }
    /// setQuick shows the quick terminal pinned, as `quick show` does on a Mac, or hides it.
    func setQuick(shown: Bool)
    /// typeQuick and quickScreen reach the quick terminal; false and nil before it was ever shown.
    func typeQuick(_ text: String) -> Bool
    var quickScreen: (lines: [String], rows: Int)? { get }
    var dashboard: NativeControl.Dashboard? { get }
    /// recentSessions are the window's sessions, most recently selected first.
    var recentSessions: [UUID] { get }
    /// sidebarWidthPoints is the stored divider position echoed by `sidebar.width`.
    var sidebarWidthPoints: Double { get }
    func setSidebarWidth(points: Double)
    func openDashboard(_ members: [DashboardMember], fontMode: DashboardFontMode)
    func closeDashboard()
}

/// NativeControl answers the control requests the native window serves, in agtermCore's wire shapes so agtermctl's
/// output is the same as on a Mac; the rest are refused by name.
@MainActor
public enum NativeControl {
    public struct Local: Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let commandLine: String
        public let exited: Bool
        public let attention: Bool
        public let unseen: Int
        public let cwd: String
        public let title: String?
        /// overlay is the program overlay in the session's slot, nil while it is empty.
        public var overlay: NativeOverlay?
        /// overlayExitCode is how the last overlay's program exited, until another opens.
        public var overlayExitCode: Int?
        /// htmlOverlay is a page in the session-wide slot, nil while a program overlay is shown or the slot is empty.
        public var htmlOverlay: HtmlOverlay?
        /// pageOverlayHidden keeps a page running with the session in view.
        public var pageOverlayHidden = false
        /// pageOverlaySizePercent is the floating page panel's share, when a page overlay is open.
        public var pageOverlaySizePercent: Int?
        /// split is the session's second pane, nil without one.
        public var split: NativeSplit?
        public var splitCwd: String?
        /// scratch is whether the scratch is shown; scratchRunning whether its shell runs, shown or not.
        public var scratch = false
        public var scratchRunning = false
        public var scratchCwd: String?
        public var activity = AgentActivity()
        /// context is the title-bar context (`session.context`), info the sidebar info line (`session.info`).
        public var context: String?
        public var info: SessionInfo?

        public init(id: UUID, name: String, commandLine: String, exited: Bool, attention: Bool, unseen: Int = 0, cwd: String = "",
                    title: String? = nil, overlay: NativeOverlay? = nil, overlayExitCode: Int? = nil, htmlOverlay: HtmlOverlay? = nil) {
            self.id = id
            self.name = name
            self.commandLine = commandLine
            self.exited = exited
            self.attention = attention
            self.unseen = unseen
            self.cwd = cwd
            self.title = title
            self.overlay = overlay
            self.overlayExitCode = overlayExitCode
            self.htmlOverlay = htmlOverlay
        }
    }

    /// Dashboard is the open dashboard as `tree` reads it back.
    public struct Dashboard: Equatable, Sendable {
        public var members: [DashboardMember]
        public var highlighted: DashboardMember?
        public var fontMode: DashboardFontMode
        public var fontSize: Double?

        public init(members: [DashboardMember], highlighted: DashboardMember?, fontMode: DashboardFontMode, fontSize: Double?) {
            self.members = members
            self.highlighted = highlighted
            self.fontMode = fontMode
            self.fontSize = fontSize
        }
    }

    /// RemoteServer is one `remote.properties` remote, which `window.list` reports as a remote window.
    public struct RemoteServer: Equatable {
        public let name: String
        public let started: Bool
        /// state is the started server's catalog stream, nil before it is started.
        public let state: RemoteCatalogMirror.State?

        public init(name: String, started: Bool, state: RemoteCatalogMirror.State?) {
            self.name = name
            self.started = started
            self.state = state
        }
    }

    /// localWorkspace is the id the Local group reports, fixed so a script can address it across launches.
    public static let localWorkspace = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    public static let localWorkspaceTarget = "local"

    public static func handle(_ request: ControlRequest, host: NativeControlHost, version: String) async -> ControlResponse {
        switch request.cmd {
        case .tree:
            return ControlResponse(ok: true, result: ControlResult(tree: tree(host)))
        case .version:
            return ControlResponse(ok: true, result: ControlResult(app: AppIdentity(version: version)))
        case .sessionNew:
            return await newSession(request.args, host: host)
        case .sessionClose, .sessionTerminate:
            return await withSession(request.target, host: host) { await host.closeSession($0) }
        case .sessionRename:
            // a blank name restores the automatic one, as on a Mac
            guard let name = request.args?.name else { return failure("session.rename requires a name") }
            return await withSession(request.target, host: host) { await host.renameSession($0, to: name) }
        case .sessionRestart:
            return await withSession(request.target, host: host) { await host.restartSession($0) }
        case .sessionSelect:
            return await withSession(request.target, host: host) { id in
                host.selectSession(id)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionGo:
            return go(request.args?.to ?? "", host: host)
        case .sessionType:
            guard let text = request.args?.text else { return failure("session.type requires text") }
            guard !text.contains("\0") else { return failure("text must not contain a NUL byte") }
            return await withPane(request, host: host) { id, pane in
                host.type(text, into: id, pane: pane) ? ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
                    : failure(pane == nil ? "session not realized" : "no \(pane!.rawValue) pane")
            }
        case .sessionText:
            let args = request.args
            if args?.all == true, args?.lines != nil { return failure("--all and --lines are exclusive") }
            if let lines = args?.lines, lines <= 0 { return failure("--lines must be positive") }
            return await withPane(request, host: host) { id, pane in
                guard let screen = host.screen(of: id, pane: pane) else { return failure(pane == nil ? "session not realized" : "no \(pane!.rawValue) pane") }
                let text = text(screen.lines, rows: screen.rows, all: args?.all == true, last: args?.lines)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: text))
            }
        case .notify:
            guard let body = request.args?.body, !body.isEmpty else { return failure("notify requires a body") }
            return await withSession(request.target, host: host) { id in
                let note = host.notify(id, title: request.args?.title ?? "", body: body)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: note))
            }
        case .sessionStatus:
            let update: ControlSessionStatusUpdate
            switch ControlSessionMetadata.status(request.args) {
            case .failure(let rejection): return failure(rejection.message)
            case .success(let parsed): update = parsed
            }
            if let sound = update.sound, !sound.isEmpty, !StatusGlyph.acceptsSound(sound) {
                return failure("unknown sound: \(sound) (use 'default', 'beep', or one of: \(StatusGlyph.macSoundNames.joined(separator: ", ")))")
            }
            return await withSession(request.target, host: host) { id in
                _ = host.setStatus(id, update)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionContext:
            switch ControlSessionMetadata.context(request.args) {
            case .failure(let rejection): return failure(rejection.message)
            case .success(let context):
                return await withSession(request.target, host: host) { id in
                    host.setContext(id, context)
                    return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
                }
            }
        case .sessionInfo:
            switch ControlSessionMetadata.info(request.args) {
            case .failure(let rejection): return failure(rejection.message)
            case .success(let info):
                return await withSession(request.target, host: host) { id in
                    host.setInfo(id, info)
                    return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
                }
            }
        case .sessionSeen:
            return await withSession(request.target, host: host) { id in
                host.markSeen(id)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .fontInc, .fontDec, .fontReset:
            let command: NativeMenu.Command = request.cmd == .fontInc ? .fontBigger : request.cmd == .fontDec ? .fontSmaller : .fontReset
            let points = NativeMenu.points(after: command, from: host.fontPoints)
            host.setFontPoints(points)
            return ControlResponse(ok: true, result: ControlResult(text: String(format: "%g", points)))
        case .themeList:
            return ControlResponse(ok: true, result: themeResult(host, themes: host.themeCatalog.names))
        case .themeSet:
            let args = request.args
            switch host.appearance.setting(name: args?.name, light: args?.light, dark: args?.dark, catalog: host.themeCatalog) {
            case .failure(let refusal): return failure(refusal.description)
            case .success(let next):
                host.setAppearance(next)
                return ControlResponse(ok: true, result: themeResult(host, themes: nil))
            }
        case .keymapList:
            return ControlResponse(ok: true, result: ControlResult(keymap: host.keymap))
        case .keymapReload:
            return ControlResponse(ok: true, result: ControlResult(count: host.reloadKeymap()))
        case .sessionOverlayOpen, .sessionOverlayClose, .sessionOverlayResize, .sessionOverlayResult, .sessionOverlayText,
             .sessionOverlayCopy, .sessionOverlayHide, .sessionOverlayShow, .sessionOverlayToggle:
            return await overlay(request, host: host)
        case .windowList:
            return ControlResponse(ok: true, result: ControlResult(windows: remoteWindows(host)))
        case .windowRemoteOpen:
            return openRemoteWindow(request.args?.host, host: host)
        case .sessionRemoteNew:
            return await newRemoteSession(request, host: host)
        case .sessionSplit, .sessionSplitClose, .sessionSwap, .sessionFocus, .sessionResize, .sessionScratch:
            return await panes(request, host: host)
        case .quick, .quickType, .quickText:
            return quick(request, host: host)
        case .dashboard:
            return dashboard(request, host: host)
        case .sidebarWidth:
            guard let points = request.args?.sidebarWidth, points.isFinite else {
                return failure("sidebar.width requires a width in points")
            }
            host.setSidebarWidth(points: points)
            return ControlResponse(ok: true, result: ControlResult(sidebarWidth: host.sidebarWidthPoints))
        default:
            return failure("\(request.cmd.rawValue) is not supported on Windows")
        }
    }

    /// withPane resolves the session and `--pane`; a server session takes no pane, since its split and scratch are not
    /// shown here.
    private static func withPane(_ request: ControlRequest, host: NativeControlHost,
                                 _ body: (UUID, NativePane?) async -> ControlResponse) async -> ControlResponse {
        var pane: NativePane?
        if let name = request.args?.pane {
            guard let parsed = NativePane(controlName: name) else { return failure("invalid pane: \(name) (left|right|scratch)") }
            pane = parsed
        }
        return await withSession(request.target, host: host) { id in
            if pane != nil, host.isServerSession(id) { return failure(NativeControl.serverPanesRefusal) }
            return await body(id, pane)
        }
    }

    static func failure(_ message: String) -> ControlResponse { ControlResponse(ok: false, error: message) }

    /// themeResult is `theme.list` and `theme.set`'s read-back, the macOS app's shape: the theme on screen, the light and
    /// dark slots, and whether they follow the system.
    private static func themeResult(_ host: NativeControlHost, themes: [String]?) -> ControlResult {
        let appearance = host.appearance
        return ControlResult(theme: appearance.activeTheme(dark: host.systemIsDark), themes: themes, sync: appearance.followsSystem,
                             light: appearance.theme, dark: appearance.darkTheme)
    }

    /// resolve maps a target (id, unique prefix, or `active`/none for the selected session) to a session id.
    struct Refusal: Error {
        let message: String
    }

    static func resolve(_ target: String?, host: NativeControlHost) -> Result<UUID, Refusal> {
        let target = target ?? "active"
        let candidates = host.localSessions.map(\.id) + host.serverWorkspaces.flatMap(\.sessions).compactMap { UUID(uuidString: $0.id) }
        switch ControlResolve.resolve(target, candidates: candidates, active: host.selectedSession) {
        case .resolved(let id): return .success(id)
        case let resolution: return .failure(Refusal(message: ControlResolve.errorMessage(noun: "session", target: target, resolution: resolution)))
        }
    }

    private static func withSession(_ target: String?, host: NativeControlHost,
                                    _ body: (UUID) async -> ControlResponse) async -> ControlResponse {
        switch resolve(target, host: host) {
        case .success(let id): await body(id)
        case .failure(let refusal): failure(refusal.message)
        }
    }

    /// newSession starts a local session, running `command` or the default profile's, or one on the server when the
    /// workspace names a server workspace; the server names its own sessions.
    private static func newSession(_ args: ControlArgs?, host: NativeControlHost) async -> ControlResponse {
        let workspace = args?.workspace
        if let workspace, workspace.lowercased() != localWorkspaceTarget, workspace != localWorkspace.uuidString {
            let ids = host.serverWorkspaces.compactMap { UUID(uuidString: $0.id) }
            guard case .resolved = ControlResolve.resolve(workspace, candidates: ids, active: nil) else {
                return failure("no such workspace: \(workspace)")
            }
            return await host.newServerSession()
        }
        guard args?.command?.isEmpty != true else { return failure("session.new command must not be blank") }
        guard let id = host.newLocalSession(name: args?.name, command: args?.command, cwd: args?.cwd, select: args?.noSelect != true) else {
            return failure("no launch profile to start a session from")
        }
        return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
    }

    private static func go(_ to: String, host: NativeControlHost) -> ControlResponse {
        let order = tree(host).workspaces.flatMap(\.sessions).compactMap { UUID(uuidString: $0.id) }
        guard let direction = SessionNavigation(wire: to) else { return failure("unknown direction: \(to)") }
        let next: UUID?
        switch direction {
        case .next, .nextAttention: next = SessionSidebar.neighbor(of: host.selectedSession, in: order, forward: true)
        case .previous, .previousAttention: next = SessionSidebar.neighbor(of: host.selectedSession, in: order, forward: false)
        case .first: next = order.first
        case .last: next = order.last
        case .position(let place): next = order.indices.contains(place - 1) ? order[place - 1] : nil
        }
        guard let next else { return failure("no session to navigate to") }
        host.selectSession(next)
        return ControlResponse(ok: true, result: ControlResult(id: next.uuidString))
    }

    /// remoteWindows are the `remote.properties` remotes as remote windows: open while the server is started, with its
    /// stream's state, under an id derived from the name.
    static func remoteWindows(_ host: NativeControlHost) -> [ControlWindowNode] {
        host.remoteServers.map { server in
            var node = ControlWindowNode(id: remoteWindowID(server.name).uuidString, name: server.name, open: server.started,
                                         active: false)
            node.remote = ControlRemoteWindow(host: server.name, catalogID: nil, state: server.state)
            return node
        }
    }

    /// remoteWindowID is the stable id of a remote's window: an FNV-1a hash of its name, the same every launch.
    public static func remoteWindowID(_ name: String) -> UUID {
        var high: UInt64 = 0xcbf2_9ce4_8422_2325, low: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in name.utf8 {
            high = (high ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            low = (low ^ UInt64(byte) ^ (high >> 32)) &* 0x0000_0100_0000_01b3
        }
        var uuid = withUnsafeBytes(of: high.bigEndian) { Array($0) } + withUnsafeBytes(of: low.bigEndian) { Array($0) }
        uuid[6] = (uuid[6] & 0x0f) | 0x80
        uuid[8] = (uuid[8] & 0x3f) | 0x80
        return UUID(uuid: (uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5], uuid[6], uuid[7],
                           uuid[8], uuid[9], uuid[10], uuid[11], uuid[12], uuid[13], uuid[14], uuid[15]))
    }

    /// remoteServer resolves a destination to a `remote.properties` remote, or says why it names none: agterm-win reaches
    /// no ssh host.
    private static func remoteServer(_ destination: String?, command: String, host: NativeControlHost) -> Result<String, Refusal> {
        guard let destination, !destination.isEmpty else { return .failure(Refusal(message: "\(command) requires a host")) }
        guard host.remoteServers.contains(where: { $0.name == destination }) else {
            return .failure(Refusal(message: "\(command): \(destination) is not defined in \(RemoteCommands.fileName)"))
        }
        return .success(destination)
    }

    /// openRemoteWindow starts the remote's server, or probes a started one again, and answers its window's id.
    private static func openRemoteWindow(_ destination: String?, host: NativeControlHost) -> ControlResponse {
        switch remoteServer(destination, command: "window.remote.open", host: host) {
        case .failure(let refusal): return failure(refusal.message)
        case .success(let name):
            if let refusal = host.startRemoteServer(name) { return failure(refusal) }
            return ControlResponse(ok: true, result: ControlResult(id: remoteWindowID(name).uuidString))
        }
    }

    private static func newRemoteSession(_ request: ControlRequest, host: NativeControlHost) async -> ControlResponse {
        let create: RemoteSessionCreate
        switch RemoteSessionCreate.parse(request) {
        case .failure(let refusal): return failure(refusal.message)
        case .success(let parsed): create = parsed
        }
        switch remoteServer(create.host, command: "session.remote.new", host: host) {
        case .failure(let refusal): return failure(refusal.message)
        case .success(let name):
            guard host.remoteServers.contains(where: { $0.name == name && $0.state == .connected }) else {
                return failure("no connection to \(name)")
            }
            return await host.newRemoteSession(name, create)
        }
    }

    /// tree is the Local group, while it has sessions, ahead of the server's workspaces, as the sidebar shows them.
    public static func tree(_ host: NativeControlHost) -> ControlTree {
        let selected = host.selectedSession
        let locals = host.localSessions.map { local in
            let indicator = local.activity.indicator
            let shown = indicator.status != .idle
            return ControlSessionNode(id: local.id.uuidString, name: local.name, cwd: local.cwd, title: local.title, active: local.id == selected,
                               split: local.split?.shown == true, hasSplit: local.split != nil, backedByZmx: nil,
                               splitAxis: local.split?.axisName, splitRatio: local.split?.ratio, splitFocused: local.split?.focused,
                               overlay: local.overlay != nil || local.htmlOverlay != nil,
                               overlaySizePercent: local.overlay?.sizePercent ?? local.pageOverlaySizePercent,
                               scratch: local.scratch, ended: local.exited ? true : nil, restoreCommand: local.commandLine,
                               status: shown ? indicator.status.rawValue : nil, statusPane: shown ? indicator.statusPane?.rawValue : nil,
                               statusBlink: shown && indicator.blink ? true : nil, statusColor: shown ? indicator.color : nil,
                               statusShape: shown ? indicator.shape?.rawValue : nil,
                               statusChangedAt: local.activity.changedAt?.timeIntervalSince1970, activePanes: local.activity.activePanes,
                               unseen: local.unseen > 0 ? local.unseen : local.attention ? 1 : nil, fontSize: Double(host.fontPoints),
                               context: local.context,
                               splitCwd: local.split == nil ? nil : local.splitCwd, scratchCwd: local.scratchRunning ? local.scratchCwd : nil,
                               htmlOverlays: local.htmlOverlay.map { [$0.controlNode(hidden: local.pageOverlayHidden)] },
                               hiddenOverlays: local.pageOverlayHidden || local.overlay?.hidden == true ? ["session"] : nil,
                               info: local.info)
        }
        let local = locals.isEmpty ? [] : [ControlWorkspaceNode(id: localWorkspace.uuidString, name: "Local",
                                                                active: locals.contains { $0.active }, sessions: locals)]
        let dashboard = host.dashboard
        let tree = ControlTree(workspaces: local + host.serverWorkspaces, sidebarWidth: host.sidebarWidthPoints,
                               quickVisible: host.quickShown, dashboardMembers: dashboard?.members.map(\.controlRef),
                               dashboardHighlighted: dashboard?.highlighted?.controlRef, dashboardFontSize: dashboard?.fontSize,
                               dashboardFontMode: dashboard.map { NativeDashboard.fontModeName($0.fontMode) })
        return tree
    }

    /// text is what `session.text` reads: the screen by default, every line with `all`, or the last `last` lines once
    /// trailing blank lines are dropped. Lines lose their trailing blanks, as a terminal's copy does.
    public nonisolated static func text(_ lines: [String], rows: Int, all: Bool, last: Int?) -> String {
        var trimmed = lines.map { line in String(line.reversed().drop { $0 == " " }.reversed()) }
        if !all, last == nil { trimmed = Array(trimmed.suffix(rows)) }
        while trimmed.last?.isEmpty == true { trimmed.removeLast() }
        if let last { trimmed = Array(trimmed.suffix(last)) }
        return trimmed.joined(separator: "\n")
    }
}
