import Foundation
import agtermCore

/// RemoteWindow is one window onto an agterm-server, wired as the Mac wires its remote windows: an AppStore the
/// catalog mirror keeps equal to the server's catalog, fed by RemoteCatalogClient over the WSL transport.
@MainActor
final class RemoteWindow: RemoteCatalogEffects {
    let host: WSLHost
    let store: AppStore
    private(set) var mirror: RemoteCatalogMirror!
    private var client: RemoteCatalogClient!
    private(set) var actions: RemoteCatalogActions!
    private let transport: WSLTransport
    /// changed runs whenever what the sidebar shows may have moved.
    var changed: () -> Void = {}

    init(host: WSLHost, stateDirectory: URL) {
        self.host = host
        transport = WSLTransport(host: host)
        let windows = stateDirectory.appendingPathComponent("windows")
        try? FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
        store = AppStore(persistence: PersistenceStore(directory: windows, fileName: "wsl-\(host.distribution).json"),
                         paneFinalizer: nil)
        mirror = RemoteCatalogMirror(host: "wsl-\(host.distribution)", store: store, effects: self,
                                     viewState: RemoteWindowViewState())
        mirror.onCatalogMoved = { [weak self] whole in
            log("catalog moved (snapshot: \(whole)), \(self?.store.workspaces.count ?? 0) workspace(s)")
            self?.changed()
        }
        client = RemoteCatalogClient(mirror: mirror, transport: transport, runner: transport.runner)
        actions = RemoteCatalogActions(mirror: mirror, runner: transport.runner)
        store.remoteActions = actions
    }

    var connected: Bool { mirror.state == .connected }

    /// perform sends a structural operation to the server; the catalog stream brings back what it changed.
    func perform(_ operation: RemoteOperation) async -> ControlResponse {
        switch actions.prepare(operation) {
        case .ready(let prepared): await actions.send(prepared)
        case .refused(let response): response
        }
    }

    func start() {
        client.start()
    }

    func session(_ id: UUID) -> Session? {
        store.workspaces.lazy.flatMap(\.sessions).first { $0.id == id }
    }

    // MARK: RemoteCatalogEffects

    func attachCommand(host _: String, pane: CatalogPane, claim _: Bool) -> String {
        do {
            return try host.attachCommandLine(endpoint: pane.endpoint, daemon: pane.daemon)
        } catch {
            log("attach command for \(pane.daemon) failed: \(error)")
            return "cmd.exe /k echo agterm: cannot attach \(pane.daemon)"
        }
    }

    func catalogRowAdded(_ session: Session) { changed() }
    func catalogRowRemoved(_: UUID) { changed() }
    func catalogRowEnded(_: UUID) { changed() }
    func catalogPaneNeedsAttach(_ identity: UUID, session: UUID) {
        log("pane \(identity) of \(session) needs an attach")
    }
    func catalogBound(_ catalogID: UUID) -> Bool {
        log("bound to catalog \(catalogID)")
        return true
    }
    func catalogStateChanged(_ state: RemoteCatalogMirror.State) {
        log("catalog state: \(state)")
        changed()
    }
}
