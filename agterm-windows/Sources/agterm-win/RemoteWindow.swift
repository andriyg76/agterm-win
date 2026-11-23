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
    /// onNotification runs with a notification a server session posted, from its program or a `notify` there.
    var onNotification: (UUID, PresentationNotify) -> Void = { _, _ in }
    // a presentation stream per server session, as a Mac's remote window keeps them
    private var presenters: [UUID: RemotePresentationClient] = [:]
    private var ticking: Task<Void, Never>?

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

    func catalogRowAdded(_ session: Session) {
        startPresentation(session)
        changed()
    }

    func catalogRowRemoved(_ id: UUID) {
        stopPresentation(id)
        changed()
    }

    func catalogRowEnded(_ id: UUID) {
        stopPresentation(id)
        changed()
    }

    // MARK: presentation

    /// startPresentation opens `session`'s `zmx present` stream as the presenter, which the server sends its
    /// notifications to. What agterm-win cannot show yet, asks, picks, overlays and pages, it declines, so the program
    /// asking hears so at once.
    private func startPresentation(_ session: Session) {
        let id = session.id
        guard presenters[id] == nil, session.content == .terminal, let binding = session.remotePresentation?.binding else { return }
        let argv: [String]
        do {
            argv = try RemoteSession.presentCommand(host: "wsl", session: binding.remoteSessionID)
        } catch {
            log("presentation for \(id): \(error)")
            return
        }
        let effects = RemotePresentationEffects(
            status: { _ in }, snapshotStatus: { _ in }, hud: { _ in },
            notify: { [weak self] in self?.onNotification(id, $0) },
            connection: { log("presentation for \(id): \($0)") },
            warn: { log("presentation for \(id): \($0)") })
        let client = RemotePresentationClient(argv: argv, presentationVersion: binding.presentationVersion, transport: transport,
                                              effects: effects)
        presenters[id] = client
        client.start()
        startTicking()
    }

    private func stopPresentation(_ id: UUID) {
        presenters.removeValue(forKey: id)?.stop()
    }

    /// startTicking drives the streams' retries and liveness once a second while any is open.
    private func startTicking() {
        guard ticking == nil else { return }
        ticking = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !self.presenters.isEmpty else {
                    self?.ticking = nil
                    return
                }
                for client in self.presenters.values { client.tick() }
            }
        }
    }
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
