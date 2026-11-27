import Foundation
import agtermCore

/// NativeEvents is agterm-win's `events.read` history, the `ControlEventRing` a Mac app and agterm-server keep. A store's
/// events arrive through `sink(window:)`, stamped with that window and bursts of `tree.changed` folded into one. The
/// local sessions' status and panes live in the shell's runtime, not the store, so `sync` reports their changes.
@MainActor
public final class NativeEvents {
    /// Pane is what `sync` compares for one local session between calls.
    public struct Pane: Equatable {
        public var indicator: AgentIndicator
        public var splitShown: Bool
        public var scratchShown: Bool
        /// focusedPane is the split pane with the keyboard, `.left` without a split; focusedTerminal is that pane's
        /// terminal, which a swap carries along, so a swap reads as no focus change, as a Mac's pane identity does.
        public var focusedPane: StatusPane
        public var focusedTerminal: ObjectIdentifier?

        public init(indicator: AgentIndicator, splitShown: Bool, scratchShown: Bool, focusedPane: StatusPane, focusedTerminal: ObjectIdentifier?) {
            self.indicator = indicator
            self.splitShown = splitShown
            self.scratchShown = scratchShown
            self.focusedPane = focusedPane
            self.focusedTerminal = focusedTerminal
        }
    }

    // the local window's store mirrors split fields only now and then; `sync` owns these kinds there
    private static let runtimeKinds: Set<ControlEventKind> = [.status, .paneSplit, .paneScratch, .paneFocused]

    public let ring: ControlEventRing
    private var treeDebouncers: [UUID: Debouncer] = [:]
    private var recording = false
    private var panes: [UUID: Pane] = [:]

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

    /// sync compares each local session's runtime with the last call's and records `status`, `pane.split`,
    /// `pane.scratch` and `pane.focused` for what changed. A session new to it or gone from it records nothing.
    public func sync(_ sessions: [(id: UUID, name: String, pane: Pane)], store: AppStore) {
        let previous = panes
        panes = Dictionary(sessions.map { ($0.id, $0.pane) }) { first, _ in first }
        guard recording else { return }
        let window = LocalWindow.id.uuidString
        for session in sessions {
            guard let before = previous[session.id], before != session.pane else { continue }
            let now = session.pane
            let workspace = store.workspace(forSession: session.id)?.id.uuidString
            func record(_ kind: ControlEventKind, _ payload: ControlEventPayload) {
                ring.append(ControlEventDraft(kind: kind, window: window, workspace: workspace, session: session.id.uuidString,
                                              payload: payload))
            }
            if before.indicator != now.indicator {
                let indicator = now.indicator
                record(.status, ControlEventPayload(name: session.name, status: indicator.status.rawValue, pane: indicator.statusPane?.rawValue,
                                                    blink: indicator.blink, color: indicator.color, shape: indicator.shape?.rawValue,
                                                    previous: before.indicator.status.rawValue))
            }
            if before.splitShown != now.splitShown {
                record(.paneSplit, ControlEventPayload(name: session.name, status: now.splitShown ? "shown" : "hidden"))
            }
            if before.scratchShown != now.scratchShown {
                record(.paneScratch, ControlEventPayload(name: session.name, status: now.scratchShown ? "shown" : "hidden"))
            }
            if before.focusedTerminal != now.focusedTerminal {
                record(.paneFocused, ControlEventPayload(name: session.name, pane: now.focusedPane.rawValue))
            }
        }
    }

    /// read answers `events.read`, a pending `tree.changed` recorded first so a reader never misses it.
    public func read(_ options: ControlEventReadOptions) -> ControlResponse {
        for debouncer in treeDebouncers.values { debouncer.flush() }
        return ring.readResponse(options)
    }
}
