import Foundation
import agtermCore

/// NativeZmx is what `restore.mode` and the local `zmx` commands act on. NativeStructure answers them through agtermCore's
/// dispatcher, as macOS `ControlServer+RestoreMode` and `+Zmx` do; `zmx.reset` is not served yet.
@MainActor
public enum NativeZmx {
    public static let commands: Set<Command> = [.restoreMode, .zmxList, .zmxPrune, .zmxKill, .zmxKillPane, .zmxScreen]

    public struct Context {
        public var store: AppStore
        public var client: ZmxClient?
        public var decision: RestoreLaunchDecision
        public var configured: RestoreMode
        /// setConfigured saves the mode for the next launch, false when it could not.
        public var setConfigured: (RestoreMode) -> Bool

        public init(store: AppStore, client: ZmxClient?, decision: RestoreLaunchDecision, configured: RestoreMode,
                    setConfigured: @escaping (RestoreMode) -> Bool) {
            self.store = store
            self.client = client
            self.decision = decision
            self.configured = configured
            self.setConfigured = setConfigured
        }
    }

    public static func dispatch(_ request: ControlRequest, context: Context) async -> ControlResponse {
        await ControlDispatcher(actions: NativeStructure(store: context.store, zmx: context)).dispatch(request)
            ?? ControlResponse(ok: false, error: "\(request.cmd.rawValue) is not supported on Windows")
    }

    static let unavailable = "zmx is unavailable in this instance"
    static let incompleteInventory = "the pane inventory is incomplete or has conflicting owners, so no daemon can be safely pruned"

    /// claims walks the local window as `WindowLibrary.paneClaims` walks an open Mac window.
    public static func claims(_ store: AppStore) -> ZmxClaimWalk {
        struct Site {
            let workspace: (id: UUID, name: String)
            let session: Session
            let pendingClose: Bool
        }
        var sites = store.workspaces.flatMap { workspace in
            workspace.sessions.map { Site(workspace: (workspace.id, workspace.name), session: $0, pendingClose: false) }
        }
        sites += store.pendingCloseMembers().map {
            Site(workspace: ($0.workspaceID, $0.workspaceName), session: $0.session, pendingClose: true)
        }
        var claims: [ZmxPaneClaim] = []
        var complete = true
        for site in sites where !site.session.locallyManagedPaneIdentities.isEmpty {
            func claim(_ pane: ZmxPaneRole, _ identity: UUID) -> ZmxPaneClaim {
                ZmxPaneClaim(paneIdentity: identity, pane: pane, pendingClose: site.pendingClose, windowID: LocalWindow.id, windowName: nil,
                             windowState: .open, workspaceID: site.workspace.id, workspaceName: site.workspace.name,
                             sessionID: site.session.id, sessionName: site.session.displayName)
            }
            claims.append(claim(.left, site.session.paneIdentity))
            if site.session.hasSplit {
                if let split = site.session.splitPaneIdentity { claims.append(claim(.right, split)) } else { complete = false }
            }
        }
        return ZmxClaimWalk(claims: claims, complete: complete)
    }
}

/// The zmx requirements; `zmx` is set only for NativeZmx's commands.
extension NativeStructure {
    // a structure command's dispatcher never reaches these; were one to, it answers as an instance without zmx
    private var zmx: NativeZmx.Context {
        zmxContext ?? NativeZmx.Context(store: store, client: nil, decision: RestoreMode.none.launchDecision(liveUnavailableReason: nil),
                                        configured: .none, setConfigured: { _ in false })
    }

    // MARK: restore.mode

    public func readRestoreMode() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(restore: restoreStatus(configured: zmx.configured)))
    }

    /// setRestoreMode saves the mode for the next launch; this process keeps the one it started with. Re-run commands
    /// is refused until agterm-win reads a pane's foreground command.
    public func setRestoreMode(_ mode: RestoreMode) -> ControlResponse {
        guard mode != .rerun else { return ControlResponse(ok: false, error: "restore mode rerun is not available on Windows yet") }
        guard zmx.setConfigured(mode) else {
            return ControlResponse(ok: false, error: "could not save the restore mode; settings keep \(zmx.configured.rawValue)")
        }
        return ControlResponse(ok: true, result: ControlResult(restore: restoreStatus(configured: mode)))
    }

    func restoreStatus(configured: RestoreMode) -> ControlRestoreStatus {
        ControlRestoreStatus(configured: configured, requestedAtLaunch: zmx.decision.requested, active: zmx.decision.active,
                             unavailableReason: zmx.decision.liveUnavailableReason)
    }

    // MARK: zmx

    public func listZmxDaemons() -> ControlResponse {
        guard let client = zmx.client else { return ControlResponse(ok: false, error: NativeZmx.unavailable) }
        guard let observed = client.listSessions() else { return ControlResponse(ok: false, error: "could not read the zmx session list") }
        let walk = NativeZmx.claims(zmx.store)
        let result = ZmxInventory.join(observed: observed, claims: walk.claims, inventoryComplete: walk.complete)
        let inventory = ControlZmxInventory(restore: restoreStatus(configured: zmx.configured), result: result, endpoint: client.endpoint)
        return ControlResponse(ok: true, result: ControlResult(zmx: inventory))
    }

    public func pruneZmxDaemons() -> ControlResponse {
        guard let client = zmx.client else { return ControlResponse(ok: false, error: NativeZmx.unavailable) }
        guard let observed = client.listSessions() else { return ControlResponse(ok: false, error: "could not read the zmx session list") }
        let walk = NativeZmx.claims(zmx.store)
        let inventory = ZmxInventory.join(observed: observed, claims: walk.claims, inventoryComplete: walk.complete)
        guard let candidates = ZmxPrunePolicy.namesToPrune(inventory) else {
            return ControlResponse(ok: false, error: NativeZmx.incompleteInventory)
        }
        guard !candidates.isEmpty else { return ControlResponse(ok: true, result: ControlResult(text: "no orphan daemons", affected: 0)) }
        guard let recheck = client.listSessions() else {
            return ControlResponse(ok: false, error: "could not re-read the zmx session list before pruning")
        }
        let stillDetached = Set(recheck.filter { $0.clients == 0 }.map(\.name))
        let names = candidates.filter { stillDetached.contains($0) }
        guard !names.isEmpty else {
            return ControlResponse(ok: true, result: ControlResult(text: "no orphan daemons left to prune", affected: 0))
        }
        let outcomes = client.killObservedOrphan(names: names)
        let killed = outcomes.filter { $0.value == .killed }.count
        return ControlResponse(ok: true, result: ControlResult(text: Self.pruneReport(outcomes), affected: killed))
    }

    static func pruneReport(_ outcomes: [String: ZmxKillOutcome]) -> String {
        outcomes.keys.sorted().map { name in
            switch outcomes[name] {
            case .killed: "killed \(name)"
            case .staleSocket: "\(name): cleaned up a stale socket, the daemon may still be running"
            case .failed(let reason): "\(name): not killed (\(reason))"
            case nil: "\(name): no result"
            }
        }
        .joined(separator: "; ")
    }

    public func readZmxScreen(name: String, fullBuffer: Bool, lines: Int?) -> ControlResponse {
        guard let client = zmx.client else { return ControlResponse(ok: false, error: NativeZmx.unavailable) }
        guard let screen = client.screen(name: name, all: fullBuffer) else {
            return ControlResponse(ok: false, error: "could not read the zmx screen of \(name)")
        }
        return ControlResponse(ok: true, result: ControlResult(text: lines.map(screen.lastLines) ?? screen.text))
    }

    public func killZmxDaemon(target: String, window: String?, pane: ZmxPaneRole) -> ControlResponse {
        kill(target: target, window: window, pane: pane, pinned: nil)
    }

    public func killZmxPane(target: String, window: String?, pane: ZmxPaneRole, paneID: String) -> ControlResponse {
        kill(target: target, window: window, pane: pane, pinned: paneID)
    }

    private func kill(target: String, window: String?, pane: ZmxPaneRole, pinned: String?) -> ControlResponse {
        guard let client = zmx.client else { return ControlResponse(ok: false, error: NativeZmx.unavailable) }
        guard target != "active" else { return ControlResponse(ok: false, error: "zmx.kill needs a session id; 'active' is not accepted") }
        guard window != "active" else { return ControlResponse(ok: false, error: "zmx.kill needs a window id; 'active' is not accepted") }
        guard let observed = client.listSessions() else { return ControlResponse(ok: false, error: "could not read the zmx session list") }
        let walk = NativeZmx.claims(zmx.store)
        let inventory = ZmxInventory.join(observed: observed, claims: walk.claims, inventoryComplete: walk.complete)
        var owned = inventory.rows.filter { $0.claim?.pane == pane }
        if let window, !window.isEmpty {
            guard case .resolved(let windowID) = ControlResolve.resolve(window, candidates: [LocalWindow.id], active: nil) else {
                return ControlResponse(ok: false, error: "no such window: \(window)")
            }
            owned = owned.filter { $0.claim?.windowID == windowID }
        }
        guard case .resolved(let sessionID) = ControlResolve.resolve(target, candidates: owned.compactMap { $0.claim?.sessionID }, active: nil),
              let row = owned.first(where: { $0.claim?.sessionID == sessionID }), let claim = row.claim else {
            return ControlResponse(ok: false, error: "no \(pane.rawValue) pane daemon for session \(target)")
        }
        if let refusal = Self.killRefusal(row) { return ControlResponse(ok: false, error: refusal) }
        if let pinned, let refusal = ZmxPaneRole.pinRefusal(pinned, identity: claim.paneIdentity, pane: pane) {
            return ControlResponse(ok: false, error: refusal)
        }
        switch client.killConfirmed(name: row.daemon) {
        case .killed: break
        case .staleSocket:
            return ControlResponse(ok: false, error: "\(row.daemon) did not confirm the kill; zmx cleaned up a stale socket and the daemon may still be running")
        case .failed(let reason):
            return ControlResponse(ok: false, error: "could not kill \(row.daemon): \(reason)")
        }
        // the pane's attach client exits with its daemon, and that exit closes or ends the pane as any exit does
        return ControlResponse(ok: true, result: ControlResult(id: claim.sessionID.uuidString, text: "killed \(row.daemon)", pane: claim.pane.rawValue))
    }

    static func killRefusal(_ row: ZmxInventoryRow) -> String? {
        switch row.observation {
        case .absent: return "\(row.daemon) is not running"
        case .unreadable: return "\(row.daemon) is unreadable; killing it could orphan a live daemon"
        case .running: break
        }
        switch row.state {
        case .claimed: return nil
        case .pendingClose: return "\(row.daemon) belongs to a session waiting out its undo window"
        case .unknown, .conflicted: return NativeZmx.incompleteInventory
        case .orphan, .foreign: return "\(row.daemon) is not claimed by that pane"
        }
    }
}
