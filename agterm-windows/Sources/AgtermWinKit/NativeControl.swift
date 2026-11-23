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
    func newLocalSession(name: String?, command: String?, select: Bool) -> UUID?
    func newServerSession() async -> ControlResponse
    func closeSession(_ id: UUID) async -> ControlResponse
    func renameSession(_ id: UUID, to name: String) async -> ControlResponse
    func restartSession(_ id: UUID) async -> ControlResponse
    func selectSession(_ id: UUID)
    /// type sends `text` to the session's program; false when it has no terminal running here.
    func type(_ text: String, into id: UUID) -> Bool
    /// screen is the session's lines, oldest first, and how many of the last ones are on screen; nil when the session
    /// has no terminal here.
    func screen(of id: UUID) -> (lines: [String], rows: Int)?
    /// notify shows a `notify` for the session and returns why no banner was shown, nil when one was.
    func notify(_ id: UUID, title: String, body: String) -> String?
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

        public init(id: UUID, name: String, commandLine: String, exited: Bool, attention: Bool, unseen: Int = 0, cwd: String = "",
                    title: String? = nil) {
            self.id = id
            self.name = name
            self.commandLine = commandLine
            self.exited = exited
            self.attention = attention
            self.unseen = unseen
            self.cwd = cwd
            self.title = title
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
            return await withSession(request.target, host: host) { id in
                host.type(text, into: id) ? ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
                    : failure("session not realized")
            }
        case .sessionText:
            let args = request.args
            if args?.all == true, args?.lines != nil { return failure("--all and --lines are exclusive") }
            if let lines = args?.lines, lines <= 0 { return failure("--lines must be positive") }
            return await withSession(request.target, host: host) { id in
                guard let screen = host.screen(of: id) else { return failure("session not realized") }
                let text = text(screen.lines, rows: screen.rows, all: args?.all == true, last: args?.lines)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: text))
            }
        case .notify:
            guard let body = request.args?.body, !body.isEmpty else { return failure("notify requires a body") }
            return await withSession(request.target, host: host) { id in
                let note = host.notify(id, title: request.args?.title ?? "", body: body)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: note))
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
        default:
            return failure("\(request.cmd.rawValue) is not supported on Windows")
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
        guard let id = host.newLocalSession(name: args?.name, command: args?.command, select: args?.noSelect != true) else {
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

    /// tree is the Local group, while it has sessions, ahead of the server's workspaces, as the sidebar shows them.
    public static func tree(_ host: NativeControlHost) -> ControlTree {
        let selected = host.selectedSession
        let locals = host.localSessions.map { local in
            ControlSessionNode(id: local.id.uuidString, name: local.name, cwd: local.cwd, title: local.title, active: local.id == selected, split: false,
                               backedByZmx: nil, ended: local.exited ? true : nil, restoreCommand: local.commandLine,
                               unseen: local.unseen > 0 ? local.unseen : local.attention ? 1 : nil, fontSize: Double(host.fontPoints))
        }
        let local = locals.isEmpty ? [] : [ControlWorkspaceNode(id: localWorkspace.uuidString, name: "Local",
                                                                active: locals.contains { $0.active }, sessions: locals)]
        return ControlTree(workspaces: local + host.serverWorkspaces)
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
