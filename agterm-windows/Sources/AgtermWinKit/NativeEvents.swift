import Foundation
import agtermCore

/// NativeEvents is agterm-win's `events.read` history, the `ControlEventRing` a Mac app and agterm-server keep. A store's
/// events arrive through `sink(window:)`, stamped with that window and bursts of `tree.changed` folded into one. The
/// local sessions' agent status lives in the shell's runtime, not the store, so `sync` reports its changes.
@MainActor
public final class NativeEvents {
    // a local session's agent status lives in the shell's runtime, not the store; `sync` owns that kind there
    private static let runtimeKinds: Set<ControlEventKind> = [.status]

    public let ring: ControlEventRing
    private var treeDebouncers: [UUID: Debouncer] = [:]
    private var recording = false
    private var indicators: [UUID: AgentIndicator] = [:]

    public init(ring: ControlEventRing = ControlEventRing()) {
        self.ring = ring
    }

    /// sink is the event sink of `window`'s store. Nothing is recorded before `launched`, so loading the saved tree
    /// reports nothing, as a Mac's bootstrap does not.
    public func sink(window: UUID) -> (ControlEventDraft) -> Void {
        { [weak self] draft in self?.receive(draft, window: window) }
    }

    func receive(_ draft: ControlEventDraft, window: UUID) {
        guard recording else { return }
        if window == LocalWindow.id, Self.runtimeKinds.contains(draft.kind) { return }
        guard draft.kind != .treeChanged else {
            let debouncer = treeDebouncers[window] ?? Debouncer()
            treeDebouncers[window] = debouncer
            debouncer.schedule(after: 0.1) { [weak self] in
                self?.ring.append(ControlEventDraft(kind: .treeChanged, window: window.uuidString))
            }
            return
        }
        ring.append(ControlEventDraft(kind: draft.kind, window: window.uuidString, workspace: draft.workspace,
                                      session: draft.session, payload: draft.payload))
    }

    /// launched records `app.launched` once the control socket answers, and starts recording.
    public func launched() {
        guard !recording else { return }
        recording = true
        ring.append(ControlEventDraft(kind: .appLaunched))
    }

    /// sync compares each local session's agent status with the last call's and records `status` for one that changed. A
    /// session new to it or gone from it records nothing.
    public func sync(_ sessions: [(id: UUID, name: String, indicator: AgentIndicator)], store: AppStore) {
        let previous = indicators
        indicators = Dictionary(sessions.map { ($0.id, $0.indicator) }) { first, _ in first }
        guard recording else { return }
        for session in sessions {
            guard let before = previous[session.id], before != session.indicator else { continue }
            let indicator = session.indicator
            ring.append(ControlEventDraft(kind: .status, window: LocalWindow.id.uuidString,
                                          workspace: store.workspace(forSession: session.id)?.id.uuidString, session: session.id.uuidString,
                                          payload: ControlEventPayload(name: session.name, status: indicator.status.rawValue,
                                                                       pane: indicator.statusPane?.rawValue, blink: indicator.blink,
                                                                       color: indicator.color, shape: indicator.shape?.rawValue,
                                                                       previous: before.status.rawValue)))
        }
    }

    /// read answers `events.read`, a pending `tree.changed` recorded first so a reader never misses it.
    public func read(_ options: ControlEventReadOptions) -> ControlResponse {
        for debouncer in treeDebouncers.values { debouncer.flush() }
        return ring.readResponse(options)
    }
}
