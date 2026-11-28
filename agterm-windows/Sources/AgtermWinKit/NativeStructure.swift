import Foundation
import agtermCore

/// NativeStructure answers the workspace, order, flag, focus and companion commands against one window's store,
/// through agtermCore's dispatcher so they parse and refuse exactly as on a Mac. It only changes the store:
/// NativeControl starts or ends terminals for the sessions that came or went, and shows the store's selection.
/// Every other requirement refuses, since NativeControl answers those commands itself.
@MainActor
public struct NativeStructure: ControlActions {
    /// commands are the ones NativeControl hands to the dispatcher.
    public static let commands: Set<Command> = [
        .workspaceNew, .workspaceRename, .workspaceDelete, .workspaceSelect, .workspaceGo, .workspaceMove, .workspaceFocus,
        .workspaceFilter, .workspaceCollapse, .workspaceExpand, .workspaceFlag, .workspaceTint, .sessionMove, .sessionFlag, .sessionTint,
        .sessionCollapse, .sessionExpand, .sessionCompanionNew, .sessionCompanionConvert, .sessionCompanionMove,
        .sessionCompanionPromote, .sidebarMode, .sidebarExpand, .sidebarCollapse,
    ]

    /// NewSession is what a `session.new` without those options gets: Settings ▸ General's folder and the default
    /// profile's program, at the place Settings ▸ General puts a session started without a placement.
    public struct NewSession {
        public var cwd: String
        public var command: String?
        public var index: (Workspace, UUID?) -> Int?

        public init(cwd: String, command: String?, index: @escaping (Workspace, UUID?) -> Int?) {
            self.cwd = cwd
            self.command = command
            self.index = index
        }
    }

    let store: AppStore
    let newSession: NewSession?
    let zmxContext: NativeZmx.Context?
    let events: NativeEvents?
    /// interactions is the window whose pick and ask slots `interactionCommands` reach.
    let interactions: NativeControlHost?
    /// messages is the host whose local and server windows the `msg.*` addresses resolve across.
    let messages: NativeControlHost?

    public init(store: AppStore, newSession: NewSession? = nil, zmx: NativeZmx.Context? = nil, events: NativeEvents? = nil,
                interactions: NativeControlHost? = nil, messages: NativeControlHost? = nil) {
        self.store = store
        self.interactions = interactions
        self.messages = messages
        self.newSession = newSession
        zmxContext = zmx
        self.events = events
    }

    public static func dispatch(_ request: ControlRequest, store: AppStore, newSession: NewSession? = nil) async -> ControlResponse {
        await ControlDispatcher(actions: NativeStructure(store: store, newSession: newSession)).dispatch(request)
            ?? ControlResponse(ok: false, error: "\(request.cmd.rawValue) is not supported on Windows")
    }

    // MARK: session.new

    public func createSession(_ options: ControlSessionCreateOptions) -> ControlResponse { createSession(options, tint: nil) }

    public func createSession(_ options: ControlSessionCreateOptions, tint: SidebarTint?) -> ControlResponse {
        guard let newSession else { return failure("session.new is not served here") }
        guard let command = options.command ?? newSession.command else { return failure("no launch profile to start a session from") }
        let destination: (workspace: UUID, index: Int?)
        if let anchor = options.after ?? options.before {
            switch anchorLocation(anchor) {
            case .failure(let refusal): return failure(refusal.message)
            case .success(let location): destination = (location.workspace, options.before != nil ? location.index : location.index + 1)
            }
        } else if let name = options.workspaceName {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return failure("workspace name must not be blank") }
            let found = options.createWorkspace == true ? store.ensureWorkspace(named: name, revealNewWorkspace: options.noSelect != true)
                : store.workspace(named: name)
            guard let found else { return failure("no workspace named \"\(name)\" (pass --create-workspace to add it)") }
            destination = (found.id, nil)
        } else {
            switch resolveWorkspace(options.workspace) {
            case .failure(let refusal): return failure(refusal.message)
            case .success(let id):
                let workspace = store.workspaces.first { $0.id == id }
                destination = (id, options.workspace == nil ? workspace.flatMap { newSession.index($0, store.selectedSessionID) } : nil)
            }
        }
        guard let session = store.addSession(toWorkspace: destination.workspace, cwd: options.cwd ?? newSession.cwd, command: command,
                                             name: options.name, at: destination.index, select: !options.noSelect, tint: tint) else {
            return failure("could not create session")
        }
        return ok(session.id)
    }

    private static let companionMoveError = "a companion moves only among its siblings; use --parent to move it under another session, "
        + "or --top-level to make it a top-level session"

    // MARK: resolution

    private func failure(_ message: String) -> ControlResponse { ControlResponse(ok: false, error: message) }

    private func resolveSession(_ target: String?) -> Result<UUID, Refusal> {
        let target = target ?? "active"
        let ids = store.workspaces.flatMap { $0.sessions.map(\.id) }
        switch ControlResolve.resolve(target, candidates: ids, active: store.selectedSessionID) {
        case .resolved(let id): return .success(id)
        case let resolution: return .failure(Refusal(ControlResolve.errorMessage(noun: "session", target: target, resolution: resolution)))
        }
    }

    private func resolveWorkspace(_ target: String?) -> Result<UUID, Refusal> {
        let target = target ?? "active"
        let resolution = store.resolveWorkspaceTarget(target)
        guard case .resolved(let id) = resolution else {
            return .failure(Refusal(ControlResolve.errorMessage(noun: "workspace", target: target, resolution: resolution)))
        }
        return .success(id)
    }

    private struct Refusal: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func withSession(_ target: String?, _ body: (UUID) -> ControlResponse) -> ControlResponse {
        switch resolveSession(target) {
        case .success(let id): body(id)
        case .failure(let refusal): failure(refusal.message)
        }
    }

    private func withWorkspace(_ target: String?, _ body: (UUID) -> ControlResponse) -> ControlResponse {
        switch resolveWorkspace(target) {
        case .success(let id): body(id)
        case .failure(let refusal): failure(refusal.message)
        }
    }

    private func withNamedWorkspace(_ target: String?, _ body: (UUID) -> ControlResponse) -> ControlResponse {
        withWorkspace(target) { store.rootRefusal($0) ?? body($0) }
    }

    private func ok(_ id: UUID) -> ControlResponse { ControlResponse(ok: true, result: ControlResult(id: id.uuidString)) }

    // MARK: workspaces

    public func createWorkspace(window: String?, name: String?, collapsed: Bool) -> ControlResponse {
        createWorkspace(window: window, name: name, collapsed: collapsed, tint: nil)
    }

    public func createWorkspace(window: String?, name: String?, collapsed: Bool, tint: SidebarTint?) -> ControlResponse {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = store.addWorkspace(name: trimmed?.isEmpty == false ? trimmed! : store.defaultWorkspaceName, collapsed: collapsed,
                                           revealNewWorkspace: !collapsed, tint: tint)
        return ok(workspace.id)
    }

    public func selectWorkspace(_ target: String?, window: String?) -> ControlResponse {
        withNamedWorkspace(target) { id in
            store.selectWorkspace(id)
            return ok(id)
        }
    }

    public func goWorkspace(window: String?, direction: WorkspaceNavigation) -> ControlResponse {
        guard let step = store.navigateWorkspace(direction) else { return failure("no other workspace to navigate to") }
        return ok(step.workspaceID)
    }

    public func renameWorkspace(_ target: String?, window: String?, name: String) -> ControlResponse {
        withNamedWorkspace(target) { id in
            store.renameWorkspace(id, to: name)
            return ok(id)
        }
    }

    public func deleteWorkspace(_ target: String?, window: String?) -> ControlResponse {
        withNamedWorkspace(target) { id in
            store.removeWorkspace(id)
            return ok(id)
        }
    }

    public func moveWorkspace(_ target: String?, window: String?, direction: ReorderDirection) -> ControlResponse {
        withNamedWorkspace(target) { id in
            store.reorderWorkspace(id, direction)
            return ok(id)
        }
    }

    public func focusWorkspace(_ target: String?, window: String?, mode: ControlWorkspaceFocusMode) -> ControlResponse {
        withWorkspace(target) { id in
            store.applyFocusMode(mode, to: id)
            return ok(id)
        }
    }

    public func setWorkspaceFilter(window: String?, mode: ControlToggleMode) -> ControlResponse {
        store.applyWorkspaceFilter(mode)
        return ControlResponse(ok: true)
    }

    public func setWorkspaceExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse {
        withNamedWorkspace(target) { id in
            store.setWorkspaceExpanded(id, expanded: expanded)
            return ok(id)
        }
    }

    public func setWorkspaceFlag(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse {
        withWorkspace(target) { id in
            store.applyWorkspaceFlag(mode, to: id)
            return ok(id)
        }
    }

    public func setWorkspaceTint(_ target: String?, window: String?, update: ControlTintUpdate) -> ControlResponse {
        withNamedWorkspace(target) { id in
            store.setTint(update.resolved(over: store.workspaces.first { $0.id == id }?.tint), forWorkspace: id)
            return ok(id)
        }
    }

    public func setSidebarViewMode(_ mode: ControlSidebarViewMode) -> ControlResponse {
        switch mode {
        case .tree: store.setSidebarMode(.tree)
        case .flagged: store.setSidebarMode(.flagged)
        case .toggle: store.setSidebarMode(store.sidebarMode == .tree ? .flagged : .tree)
        }
        return ControlResponse(ok: true)
    }

    /// expandSidebar opens every workspace; collapseSidebar folds all but the current one, as the Mac's do. The flat
    /// flagged list has no workspace rows, so both leave it alone.
    public func expandSidebar(window: String?) -> ControlResponse {
        if store.sidebarMode == .tree { store.setWorkspacesExpanded(Set(store.workspaces.map(\.id))) }
        return ControlResponse(ok: true)
    }

    public func collapseSidebar(window: String?) -> ControlResponse {
        if store.sidebarMode == .tree { store.setWorkspacesExpanded(store.currentWorkspaceID.map { [$0] } ?? []) }
        return ControlResponse(ok: true)
    }

    // MARK: sessions

    public func setSessionFlag(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        if mode == "clear" {
            store.clearFlags()
            return ControlResponse(ok: true)
        }
        return withSession(target) { id in
            let want: Bool
            switch mode {
            case "on": want = true
            case "off": want = false
            case "toggle": want = store.session(withID: id)?.flagged != true
            default: return failure("invalid flag mode: \(mode)")
            }
            store.setFlag(want, forSession: id)
            return ok(id)
        }
    }

    public func setSessionTint(_ target: String?, window: String?, update: ControlTintUpdate) -> ControlResponse {
        withSession(target) { id in
            store.setTint(update.resolved(over: store.session(withID: id)?.tint), forSession: id)
            return ok(id)
        }
    }

    public func moveFlaggedSession(_ target: String?, window: String?, anchor: String, placement: FlaggedOrderPlacement) -> ControlResponse {
        withSession(target) { id in
            switch resolveSession(anchor) {
            case .failure(let refusal): return failure(refusal.message)
            case .success(let anchorID):
                guard anchorID != id else { return failure("a session cannot be its own anchor") }
                guard store.session(withID: id)?.flagged == true, store.session(withID: anchorID)?.flagged == true else {
                    return failure("session.flag move needs a flagged session and a flagged anchor")
                }
                store.moveFlagged([id], to: placement, of: anchorID)
                return ok(id)
            }
        }
    }

    public func moveSession(_ target: String?, window: String?, move: ControlSessionMove) -> ControlResponse {
        withSession(target) { id in
            switch move {
            case .reorder(let direction):
                store.reorderSession(id, direction)
            case .workspace(let workspace):
                switch resolveWorkspace(workspace) {
                case .failure(let refusal): return failure(refusal.message)
                case .success(let destination):
                    guard store.moveSession(id, toWorkspace: destination) else { return failure(Self.companionMoveError) }
                }
            case .place(let anchor, let after):
                guard let source = store.sessionLocation(ofSession: id) else { return failure("no such session") }
                switch anchorLocation(anchor) {
                case .failure(let refusal): return failure(refusal.message)
                case .success(let location):
                    if let resolution = SidebarDrop.resolveRelative(
                        source: (workspace: source.workspace, index: source.index),
                        anchor: (workspace: location.workspace, index: location.index, count: location.count), placeAfter: after),
                       !store.moveSession(id, toWorkspace: resolution.workspace, at: resolution.destination) {
                        return failure(Self.companionMoveError)
                    }
                }
            }
            return ok(id)
        }
    }

    public func moveSessions(_ targets: [String], window: String?, move: ControlSessionMove) -> ControlResponse {
        var ids: [UUID] = []
        for target in targets {
            switch resolveSession(target) {
            case .failure(let refusal): return failure(refusal.message)
            case .success(let id): if !ids.contains(id) { ids.append(id) }
            }
        }
        let affected: Int
        switch move {
        case .reorder:
            return failure("session.move --target can be repeated only with a workspace or --after/--before")
        case .workspace(let workspace):
            switch resolveWorkspace(workspace) {
            case .failure(let refusal): return failure(refusal.message)
            case .success(let destination): affected = store.moveSessions(ids, toWorkspace: destination)
            }
        case .place(let anchor, let after):
            let sources = ids.compactMap { id in
                store.sessionLocation(ofSession: id).map { SidebarDrop.SessionSource(workspace: $0.workspace, index: $0.index) }
            }
            guard sources.count == ids.count else { return failure("no such session") }
            switch anchorLocation(anchor) {
            case .failure(let refusal): return failure(refusal.message)
            case .success(let location):
                let drop = SidebarDrop.SessionDropTarget.sessionRow(workspace: location.workspace, sessionIndex: location.index,
                                                                    sessionCount: location.count)
                guard let resolution = SidebarDrop.resolveSessions(sources: sources, target: drop,
                                                                   childIndex: after ? SidebarDrop.onItemIndex : location.index) else {
                    return ControlResponse(ok: true, result: ControlResult(affected: 0))
                }
                affected = store.moveSessions(ids, toWorkspace: resolution.workspace, at: resolution.destination)
            }
        }
        if affected == 0, ids.allSatisfy({ store.session(withID: $0)?.parentID != nil }) { return failure(Self.companionMoveError) }
        return ControlResponse(ok: true, result: ControlResult(affected: affected))
    }

    private func anchorLocation(_ anchor: String) -> Result<(workspace: UUID, index: Int, count: Int), Refusal> {
        resolveSession(anchor).flatMap { id in store.sessionLocation(ofSession: id).map { .success($0) } ?? .failure(Refusal("no such session")) }
    }

    public func setSessionExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse {
        withSession(target) { id in
            store.setSessionExpanded(id, expanded: expanded) ? ok(id) : failure("session has no companions")
        }
    }

    // MARK: companions

    public func createCompanion(_ target: String?, options: CompanionOptions, window: String?) async -> ControlResponse {
        withSession(target) { id in
            switch store.addCompanion(to: id, options: options) {
            case .success(let companion):
                return ControlResponse(ok: true, result: ControlResult(id: companion.id.uuidString, parent: companion.parentID?.uuidString))
            case .failure(.remoteParent): return failure("a remote session's companion is created by its server")
            case .failure: return failure("no such session")
            }
        }
    }

    public func convertToCompanion(_ target: String?, window: String?) -> ControlResponse {
        withSession(target) { id in
            switch store.convertToCompanion(id) {
            case .failure(let refusal): return failure(refusal.message)
            case .success(let parent): return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, parent: parent.id.uuidString))
            }
        }
    }

    public func moveCompanion(_ target: String?, parent: String, index: Int?, window: String?) async -> ControlResponse {
        withSession(target) { id in
            switch resolveSession(parent) {
            case .failure(let refusal): return failure(refusal.message)
            case .success(let destination):
                if case .failure(let refusal) = store.moveCompanion(id, under: destination, at: index) { return failure(refusal.message) }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, parent: destination.uuidString))
            }
        }
    }

    public func promoteCompanion(_ target: String?, placement: ControlCompanionPromotion, window: String?) async -> ControlResponse {
        withSession(target) { id in
            let promotion: CompanionPromotion
            switch placement {
            case .afterOwnGroup:
                promotion = .afterOwnGroup
            case .workspace(let workspace):
                switch resolveWorkspace(workspace) {
                case .failure(let refusal): return failure(refusal.message)
                case .success(let destination): promotion = .workspace(destination, slot: nil)
                }
            case .beside(let anchor, let after):
                switch resolveSession(anchor) {
                case .failure(let refusal): return failure(refusal.message)
                case .success(let destination): promotion = .beside(destination, after: after)
                }
            }
            if case .failure(let refusal) = store.promoteCompanion(id, to: promotion) { return failure(refusal.message) }
            return ok(id)
        }
    }
}
