import Foundation
import agtermCore

/// A local session's split and scratch, the quick terminal and the dashboard, in the Mac's wording and reply shapes.
/// agterm-server sessions are refused by name until their panes are shown here.
extension NativeControl {
    public static let serverPanesRefusal = "split panes and scratch of agterm-server sessions are not shown on Windows yet"

    static func panes(_ request: ControlRequest, host: NativeControlHost) async -> ControlResponse {
        let args = request.args
        let id: UUID
        switch resolve(request.target, host: host) {
        case .failure(let refusal): return failure(refusal.message)
        case .success(let resolved): id = resolved
        }
        if host.isServerSession(id) { return failure(serverPanesRefusal) }
        let store = host.localStore
        guard let session = store.session(withID: id) else { return failure("no such session: \(id.uuidString)") }
        let done = ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        switch request.cmd {
        case .sessionSplit:
            var axis: SplitAxis?
            if let raw = args?.axis {
                guard let parsed = SplitAxis(rawValue: raw) else { return failure("invalid split axis: \(raw) (vertical|horizontal)") }
                axis = parsed
            }
            guard let mode = ControlToggleMode.parse(args?.mode) else { return failure("invalid split mode: \(args?.mode ?? "toggle")") }
            switch mode {
            case .on: store.setSplitVisibility(id, shown: true, axis: axis)
            case .off: store.setSplitVisibility(id, shown: false)
            case .toggle: store.toggleSplit(id, axis: axis)
            }
            host.panesChanged(id)
            return done
        case .sessionSplitClose:
            if session.hasSplit { host.closeSplit(id) }
            return done
        case .sessionScratch:
            guard let mode = ControlToggleMode.parse(args?.mode) else { return failure("invalid scratch mode: \(args?.mode ?? "toggle")") }
            let want = mode.desiredValue(current: session.scratchActive)
            let command = args?.command.flatMap { $0.isEmpty ? nil : $0 }
            if want, args?.follow == true, host.selectedSession != id { host.selectSession(id) }
            if want != session.scratchActive || want && command != nil { host.setScratch(id, shown: want, command: want ? command : nil) }
            return done
        default:
            break
        }
        guard session.hasSplit else { return failure("session has no split") }
        switch request.cmd {
        case .sessionSwap:
            host.swapPanes(id)
        case .sessionFocus:
            guard let pane = ControlPaneFocusMode.parse(args?.pane) else { return failure("invalid pane: \(args?.pane ?? "other")") }
            session.splitFocused = pane.wantsSplit(currentSplitFocused: session.splitFocused)
            host.panesChanged(id)
        case .sessionResize:
            let ratio: Double
            switch (args?.ratio, args?.ratioDelta) {
            case (nil, nil): return failure("session.resize requires --split-ratio, --grow-left, or --grow-right")
            case (.some, .some): return failure("session.resize: --split-ratio is mutually exclusive with --grow-left/--grow-right")
            case (.some(let value), nil): ratio = value
            case (nil, .some(let delta)): ratio = (session.splitRatio ?? NativeSplit.defaultRatio) + delta
            }
            let applied = store.applySplitRatio(ratio, forSession: id)
            host.panesChanged(id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, ratio: applied))
        default:
            break
        }
        return done
    }

    static func quick(_ request: ControlRequest, host: NativeControlHost) -> ControlResponse {
        switch request.cmd {
        case .quickType:
            guard let text = request.args?.text else { return failure("quick.type requires text") }
            guard !text.contains("\0") else { return failure("text must not contain a NUL byte") }
            return host.typeQuick(text) ? ControlResponse(ok: true) : failure(host.quickShown ? "quick terminal not realized" : "quick terminal not open")
        case .quickText:
            let args = request.args
            if args?.all == true, args?.lines != nil { return failure("--all and --lines are exclusive") }
            if let lines = args?.lines, lines <= 0 { return failure("--lines must be positive") }
            guard let screen = host.quickScreen else { return failure("quick terminal not open") }
            return ControlResponse(ok: true, result: ControlResult(text: text(screen.lines, rows: screen.rows, all: args?.all == true, last: args?.lines)))
        default:
            guard let mode = ControlToggleMode.parse(request.args?.mode, on: "show", off: "hide") else {
                return failure("invalid quick mode: \(request.args?.mode ?? "toggle")")
            }
            // show runs while already shown too: it pins a panel a key summoned
            let want = mode.desiredValue(current: host.quickShown)
            if want || host.quickShown { host.setQuick(shown: want) }
            return ControlResponse(ok: true)
        }
    }

    /// dashboard opens the dashboard on named sessions, the most recently used ones, or closes it, with the reply notes a
    /// Mac gives: what did not resolve, and what the nine cells left out.
    static func dashboard(_ request: ControlRequest, host: NativeControlHost) -> ControlResponse {
        let args = request.args
        let targets = args?.targets ?? []
        let fontSize = args?.fontSize, autoSize = args?.autoSize ?? false, mru = args?.mru ?? false
        if args?.close == true {
            guard targets.isEmpty, !mru, fontSize == nil, !autoSize else {
                return failure("dashboard --close takes no ids, --mru, or font options")
            }
            host.closeDashboard()
            return ControlResponse(ok: true)
        }
        if fontSize != nil, autoSize { return failure("dashboard: --font-size is mutually exclusive with --auto-size") }
        if let fontSize, !fontSize.isFinite || fontSize <= 0 { return failure("dashboard --font-size must be a positive number") }
        let fontMode: DashboardFontMode = autoSize ? .auto : (fontSize.map(DashboardFontMode.fixed) ?? .untouched)
        let splits = Set(host.localSessions.map(\.id).filter { host.localStore.session(withID: $0)?.hasSplit == true })
        let locals = Set(host.localSessions.map(\.id))
        var resolved: [NativeDashboard.Target] = []
        var unresolved: [String] = []
        if mru {
            guard targets.isEmpty else { return failure("dashboard --mru cannot be combined with explicit session ids") }
            let recent = host.recentSessions.filter(locals.contains)
            guard !recent.isEmpty else { return failure("no recent sessions") }
            resolved = recent.map { NativeDashboard.Target(session: $0, pane: nil) }
        } else {
            guard !targets.isEmpty else { return failure("dashboard requires at least one session id") }
            if let malformed = targets.first(where: { DashboardTarget(rawValue: $0) == nil }) {
                return failure("dashboard: invalid session id '\(malformed)' — use <id>, <id>:left, or <id>:right")
            }
            for target in targets {
                // a server session's terminal is shared with the others, so it cannot be a cell of its own yet
                guard let parsed = DashboardTarget(rawValue: target),
                      case .resolved(let id) = ControlResolve.resolve(parsed.head, candidates: Array(locals), active: host.selectedSession),
                      parsed.pane != .split || splits.contains(id) else {
                    unresolved.append(target)
                    continue
                }
                resolved.append(NativeDashboard.Target(session: id, pane: parsed.pane))
            }
        }
        let (members, dropped) = NativeDashboard.members(for: resolved, hasSplit: splits.contains)
        guard !members.isEmpty else { return failure("no dashboard sessions resolved") }
        host.openDashboard(members, fontMode: fontMode)
        var notes: [String] = []
        if !unresolved.isEmpty { notes.append("unresolved: \(unresolved.joined(separator: ", "))") }
        if dropped > 0 { notes.append("dropped \(dropped) pane(s) beyond the \(DashboardLayout.maxCells)-cell limit") }
        return notes.isEmpty ? ControlResponse(ok: true) : ControlResponse(ok: true, result: ControlResult(text: notes.joined(separator: "; ")))
    }
}
