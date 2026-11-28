import Foundation
import AgtermWinKit
import agtermCore

/// RemoteWindow is one window onto an agterm-server, wired as the Mac wires its remote windows: an AppStore the
/// catalog mirror keeps equal to the server's catalog, fed by RemoteCatalogClient over the remote's own command.
@MainActor
final class RemoteWindow: RemoteCatalogEffects {
    let host: RemoteHost
    let store: AppStore
    private(set) var mirror: RemoteCatalogMirror!
    private var client: RemoteCatalogClient!
    private(set) var actions: RemoteCatalogActions!
    private let transport: RemoteTransport
    /// changed runs whenever what the sidebar shows may have moved.
    var changed: () -> Void = {}
    /// onNotification runs with a notification a server session posted, from its program or a `notify` there.
    var onNotification: (UUID, PresentationNotify) -> Void = { _, _ in }
    /// onReplicaOverlay shows a program overlay the origin handed over on a catalog session row.
    var onReplicaOverlay: (@MainActor (UUID, PresentationOverlay) -> Bool)?
    var onReplicaOverlayClose: (@MainActor (UUID, PresentationOverlayChange) -> Void)?
    var onReplicaOverlayResize: (@MainActor (UUID, PresentationOverlayChange) -> Void)?
    /// onReplicaAsk shows a button-only ask the origin handed over on a catalog session row.
    var onReplicaAsk: (@MainActor (UUID, PresentationAsk) -> Bool)?
    /// onReplicaAskDismiss takes down an ask the origin ended without an answer.
    var onReplicaAskDismiss: (@MainActor (UUID, PresentationAskRef) -> Void)?
    /// onReplicaPick shows a session pick the origin handed over on a catalog session row.
    var onReplicaPick: (@MainActor (UUID, PresentationPick) -> Bool)?
    /// onReplicaPickDismiss takes down a pick the origin ended without an answer.
    var onReplicaPickDismiss: (@MainActor (UUID, PresentationPickRef) -> Void)?
    /// onReplicaHud shows, updates, or clears the HUD the origin mirrors on a catalog session row.
    var onReplicaHud: (@MainActor (UUID, PresentationHud?) -> Void)?
    /// onReplicaPage shows a page the origin handed over; nil when shown, otherwise the refusal sent upstream.
    var onReplicaPage: (@MainActor (UUID, PresentationPage) -> String?)?
    var onReplicaPageClose: (@MainActor (UUID, PresentationPageChange) -> Void)?
    var onReplicaPageCommand: (@MainActor (UUID, PresentationPageCommand) -> Void)?
    /// onPaneNeedsAttach runs with a pane identity and its row when the row's pane must attach again.
    var onPaneNeedsAttach: (UUID, UUID) -> Void = { _, _ in }
    /// onPresentationStopped runs when a session's `zmx present` stream is torn down.
    var onPresentationStopped: (UUID) -> Void = { _ in }
    // a presentation stream per server session, as a Mac's remote window keeps them
    private var presenters: [UUID: RemotePresentationClient] = [:]
    private var ticking: Task<Void, Never>?

    init(host: RemoteHost, stateDirectory: URL, controlEventSink: ((ControlEventDraft) -> Void)? = nil) {
        self.host = host
        transport = RemoteTransport(host: host)
        let windows = stateDirectory.appendingPathComponent("windows")
        try? FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
        store = AppStore(persistence: PersistenceStore(directory: windows, fileName: "remote-\(NativeControl.remoteWindowID(host.name).uuidString).json"),
                         controlEventSink: controlEventSink, paneFinalizer: nil)
        mirror = RemoteCatalogMirror(host: host.name, store: store, effects: self,
                                     viewState: RemoteWindowViewState())
        client = RemoteCatalogClient(mirror: mirror, transport: transport, runner: transport.runner)
        actions = RemoteCatalogActions(mirror: mirror, runner: transport.runner)
        store.remoteActions = actions
        // RemoteCatalogActions installs its own hook; chain it, or deltas never redraw the sidebar
        let actionsMoved = mirror.onCatalogMoved
        mirror.onCatalogMoved = { [weak self] whole in
            actionsMoved?(whole)
            log("catalog moved (snapshot: \(whole)), \(self?.store.workspaces.count ?? 0) workspace(s)")
            self?.changed()
        }
    }

    var connected: Bool { mirror.state == .connected }

    /// answerPresentation sends one frame upstream on `id`'s presentation stream, for replica overlay close and the like.
    func answerPresentation(_ id: UUID, _ body: PresentationFrame.Body) {
        presenters[id]?.answer(body)
    }

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

    /// startPresentation opens `session`'s `zmx present` stream. While the session is shown here, this Mac is a
    /// presenter: notifications, program overlays the origin hands over, and related replica surfaces arrive here.
    private func startPresentation(_ session: Session) {
        let id = session.id
        guard presenters[id] == nil, session.content == .terminal, let binding = session.remotePresentation?.binding else { return }
        let argv: [String]
        do {
            argv = try RemoteSession.presentCommand(host: host.name, session: binding.remoteSessionID)
        } catch {
            log("presentation for \(id): \(error)")
            return
        }
        let effects = RemotePresentationEffects(
            // the agents running on the server report there; its stream carries their status, context and info here
            status: { [weak self] status in
                self?.store.applyRemoteStatus(status, forSession: id)
                self?.changed()
            },
            snapshotStatus: { [weak self] status in
                self?.store.applyRemoteSnapshotStatus(status, forSession: id)
                self?.changed()
            },
            hud: { [weak self] hud in self?.onReplicaHud?(id, hud) },
            notify: { [weak self] in self?.onNotification(id, $0) },
            connection: { log("presentation for \(id): \($0)") },
            context: { [weak self] context in
                self?.store.applyRemoteContext(context, forSession: id)
                self?.changed()
            },
            info: { [weak self] info in
                self?.store.applyRemoteInfo(info, forSession: id)
                self?.changed()
            },
            askRequest: { [weak self] ask in
                guard let self else { return false }
                return self.onReplicaAsk?(id, ask) ?? false
            },
            askDismiss: { [weak self] ref in
                self?.onReplicaAskDismiss?(id, ref)
            },
            pickRequest: { [weak self] pick in
                guard let self else { return false }
                return self.onReplicaPick?(id, pick) ?? false
            },
            pickDismiss: { [weak self] ref in
                self?.onReplicaPickDismiss?(id, ref)
            },
            overlayRequest: { [weak self] overlay in
                guard let self else { return false }
                return self.onReplicaOverlay?(id, overlay) ?? false
            },
            overlayClose: { [weak self] change in
                self?.onReplicaOverlayClose?(id, change)
            },
            overlayResize: { [weak self] change in
                self?.onReplicaOverlayResize?(id, change)
            },
            pageRequest: { [weak self] page in
                guard let self else { return RemotePresentationClient.pagesUnsupported }
                return self.onReplicaPage?(id, page) ?? RemotePresentationClient.pagesUnsupported
            },
            pageClose: { [weak self] change in
                self?.onReplicaPageClose?(id, change)
            },
            pageCommand: { [weak self] command in
                self?.onReplicaPageCommand?(id, command)
            },
            warn: { log("presentation for \(id): \($0)") })
        let client = RemotePresentationClient(argv: argv, presentationVersion: binding.presentationVersion, transport: transport,
                                              effects: effects, presents: true)
        presenters[id] = client
        client.start()
        startTicking()
    }

    private func stopPresentation(_ id: UUID) {
        presenters.removeValue(forKey: id)?.stop()
        onPresentationStopped(id)
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
        onPaneNeedsAttach(identity, session)
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