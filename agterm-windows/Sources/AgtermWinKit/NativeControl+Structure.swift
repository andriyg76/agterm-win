import Foundation
import agtermCore

/// Structure commands go to the window they name: `--window`, else the window holding the target session or
/// workspace, else the local window. A remote window's structural changes are its server's to make, as a Mac's
/// remote window sends them; its folds, focus and flagged view are its own.
extension NativeControl {
    enum Destination {
        case local
        case remote(UUID, AppStore)
    }

    /// window resolves `--window` to nil for the local window or a remote window's id.
    static func window(_ target: String?, host: NativeControlHost) -> Result<UUID?, Refusal> {
        guard let target, target.lowercased() != "active" else { return .success(nil) }
        let remotes = host.remoteServers.map { remoteWindowID($0.name) }
        switch ControlResolve.resolve(target, candidates: [LocalWindow.id] + remotes, active: LocalWindow.id) {
        case .resolved(let id): return .success(id == LocalWindow.id ? nil : id)
        case let resolution: return .failure(Refusal(message: ControlResolve.errorMessage(noun: "window", target: target, resolution: resolution)))
        }
    }

    private static let sessionTargeted: Set<Command> = [
        .sessionMove, .sessionFlag, .sessionTint, .sessionCollapse, .sessionExpand, .sessionCompanionNew, .sessionCompanionConvert,
        .sessionCompanionMove, .sessionCompanionPromote,
    ]

    private static let workspaceTargeted: Set<Command> = [
        .workspaceRename, .workspaceDelete, .workspaceSelect, .workspaceMove, .workspaceFocus, .workspaceCollapse,
        .workspaceExpand, .workspaceFlag, .workspaceTint,
    ]

    /// destination is where `request` runs, with its session target resolved to an id the store there resolves.
    static func destination(_ request: inout ControlRequest, host: NativeControlHost) -> Result<Destination, Refusal> {
        switch window(request.args?.window, host: host) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let remote?):
            guard let store = host.remoteStore(remote) else { return .failure(Refusal(message: "remote window is not connected")) }
            request.args?.window = nil
            return .success(.remote(remote, store))
        case .success(nil):
            request.args?.window = nil
        }
        if sessionTargeted.contains(request.cmd), !(request.cmd == .sessionFlag && request.args?.mode == "clear") {
            switch resolve(request.target, host: host) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let id):
                request.target = id.uuidString
                return .success(owner(ofSession: id, host: host))
            }
        }
        if request.cmd == .sessionNew, let anchor = request.args?.after ?? request.args?.before,
           case .success(let id) = resolve(anchor, host: host) {
            return .success(owner(ofSession: id, host: host))
        }
        let workspace = request.cmd == .sessionNew ? request.args?.workspace : workspaceTargeted.contains(request.cmd) ? request.target : nil
        if let workspace, case .notFound = host.localStore.resolveWorkspaceTarget(workspace) {
            for server in host.remoteServers {
                let id = remoteWindowID(server.name)
                guard let store = host.remoteStore(id) else { continue }
                let named = store.workspaces.filter { !$0.isRoot }.map(\.id)
                if case .resolved = ControlResolve.resolve(workspace, candidates: named, active: nil) { return .success(.remote(id, store)) }
            }
        }
        return .success(.local)
    }

    static func owner(ofSession id: UUID, host: NativeControlHost) -> Destination {
        guard host.localStore.session(withID: id) == nil else { return .local }
        for server in host.remoteServers {
            let window = remoteWindowID(server.name)
            if let store = host.remoteStore(window), store.session(withID: id) != nil { return .remote(window, store) }
        }
        return .local
    }

    public static func structure(_ request: ControlRequest, host: NativeControlHost) async -> ControlResponse {
        var request = request
        switch destination(&request, host: host) {
        case .failure(let refusal):
            return failure(refusal.message)
        case .success(.local):
            let store = host.localStore
            let before = store.selectedSessionID
            if request.cmd == .sessionNew, request.args?.command?.isEmpty == true { return failure("session.new command must not be blank") }
            let response = await NativeStructure.dispatch(request, store: store, newSession: request.cmd == .sessionNew ? host.newSession : nil)
            host.structureChanged(store, selectionMoved: store.selectedSessionID != before)
            return response
        case .success(.remote(let window, let store)):
            if RemoteOperation.structuralCommands.contains(request.cmd), !RemoteOperation.runsLocally(request, in: store) {
                switch RemoteOperation.parse(request, in: store) {
                case .refused(let response): return response
                case .operation(let operation, let select): return await host.performRemote(operation, window: window, select: select)
                }
            }
            let before = store.selectedSessionID
            let response = await NativeStructure.dispatch(request, store: store)
            host.structureChanged(store, selectionMoved: store.selectedSessionID != before)
            return response
        }
    }
}
