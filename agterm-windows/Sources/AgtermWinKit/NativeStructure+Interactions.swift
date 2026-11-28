import Foundation
import agtermCore

/// `pick.*` and `ask.*` go through agtermCore's dispatcher, which owns their validation and replies, to the window's
/// slots, as upstream's `ControlServer+Pick` and `ControlServer+Ask` do for a Mac window. agterm-win has one window,
/// so every pick and ask belongs to `LocalWindow.id`, whichever window `--window` names.
extension NativeStructure {
    public static let interactionCommands: Set<Command> = [.pickOpen, .pickResult, .pickCancel, .askOpen, .askResult, .askCancel]

    /// wireOwners lets AskRegistry read a pending ask back from the slot that holds it, as both upstream hosts wire it.
    public static func wireOwners(_ host: NativeControlHost) {
        AskRegistry.shared.resolveOwner = { [weak host] owner in
            switch owner {
            case .window: host?.pickController.pendingAsk
            case .session(let id, _): host?.interactionSession(id)?.askPending
            }
        }
    }

    // MARK: pick

    public func openPick(_ pick: PendingPick, window: String?, follow: Bool) -> ControlResponse {
        guard let host = interactions else { return refusal("pick is not served here") }
        if let refusal = windowRefusal(window, host: host) { return refusal }
        guard host.pickController.open(pick) else {
            return refusal(host.pickController.pendingAsk != nil ? "ask already pending" : "pick already pending")
        }
        host.interactionsChanged(follow: follow)
        return timed(ControlResponse(ok: true, result: ControlResult(id: pick.id)), deadline: pick.deadline) {
            _ = cancelPick(pick.id, window: nil)
        }
    }

    public func openPick(_ pick: PendingPick, session target: String, window: String?, follow: Bool) -> ControlResponse {
        guard let host = interactions else { return refusal("pick is not served here") }
        if let refusal = windowRefusal(window, host: host) { return refusal }
        switch NativeControl.resolve(target, host: host) {
        case .failure(let failed): return refusal(failed.message)
        case .success(let id):
            guard host.interactionSession(id) != nil else { return refusal("no such session") }
            if let error = SessionPickBook.shared.openLocal(pick, session: id, window: LocalWindow.id, controller: host.pickController) {
                return refusal(error)
            }
            host.interactionsChanged(follow: follow)
            return timed(ControlResponse(ok: true, result: ControlResult(id: pick.id)), deadline: pick.deadline) {
                _ = cancelPick(pick.id, window: nil)
            }
        }
    }

    public func pickResult(_ target: String, window: String?) -> ControlResponse {
        guard let host = interactions else { return refusal("pick is not served here") }
        if let refusal = windowRefusal(window, host: host) { return refusal }
        if let result = host.pickController.result(for: target) ?? PickRegistry.shared.retainedResult(for: target)?.result
            ?? SessionPickBook.shared.result(for: target) {
            return ControlResponse(ok: true, result: ControlResult(pick: result))
        }
        return refusal("unknown pick: \(target)")
    }

    public func cancelPick(_ target: String, window: String?) -> ControlResponse {
        guard let host = interactions else { return refusal("pick is not served here") }
        if let refusal = windowRefusal(window, host: host) { return refusal }
        let controller = host.pickController
        if controller.pending?.id == target {
            controller.cancel()
            host.interactionsChanged(follow: false)
            return ControlResponse(ok: true)
        }
        if controller.result(for: target) != nil || PickRegistry.shared.retainedResult(for: target) != nil {
            return ControlResponse(ok: true)
        }
        if SessionPickBook.shared.cancel(target) {
            host.interactionsChanged(follow: false)
            return ControlResponse(ok: true)
        }
        return refusal("unknown pick: \(target)")
    }

    // MARK: ask

    public func openAsk(_ ask: PendingAsk, target: String?, window: String?, placement: ControlAskPlacement,
                        follow: Bool) -> ControlResponse {
        guard let host = interactions else { return refusal("ask is not served here") }
        if let refusal = windowRefusal(window, host: host) { return refusal }
        let response: ControlResponse
        if ask.style == .terminal {
            response = openSessionAsk(ask, target: target, placement: placement, host: host)
        } else if let target {
            response = openWindowAsk(ask, target: target, placement: placement, host: host)
        } else {
            response = openWindowAsk(ask, anchor: nil, host: host)
        }
        guard response.ok else { return response }
        host.interactionsChanged(follow: follow)
        return timed(response, deadline: ask.deadline) { _ = cancelAsk(ask.id, window: nil) }
    }

    /// openSessionAsk puts a terminal ask in its session's own slot, over the session or one of its panes.
    private func openSessionAsk(_ ask: PendingAsk, target: String?, placement: ControlAskPlacement,
                                host: NativeControlHost) -> ControlResponse {
        switch NativeControl.resolve(target, host: host) {
        case .failure(let failed): return refusal(failed.message)
        case .success(let id):
            guard let session = host.interactionSession(id) else { return refusal("no such session") }
            switch session.panePlacement(placement.pane, paneID: placement.paneID, requireVisible: true,
                                         invalidPaneError: "ask pane must be left or right") {
            case .rejected(let response): return response
            case let .resolved(identity, pane):
                guard session.openAsk(ask, paneIdentity: identity) else { return refusal("ask already pending") }
                AskRegistry.shared.register(id: ask.id, owner: .session(id, window: LocalWindow.id))
                return ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: pane?.rawValue))
            }
        }
    }

    /// openWindowAsk puts a GUI ask anchored to a shown session, or one of its panes, in the window modal slot.
    private func openWindowAsk(_ ask: PendingAsk, target: String, placement: ControlAskPlacement,
                               host: NativeControlHost) -> ControlResponse {
        switch NativeControl.resolve(target, host: host) {
        case .failure(let failed): return refusal(failed.message)
        case .success(let id):
            guard let session = host.interactionSession(id) else { return refusal("no such session") }
            guard host.guiTargetShown(id) else { return refusal("session not visible") }
            switch session.panePlacement(placement.pane, paneID: placement.paneID, requireVisible: true,
                                         invalidPaneError: "ask pane must be left or right") {
            case .rejected(let response): return response
            case let .resolved(identity, pane):
                return openWindowAsk(ask, anchor: AskAnchor(sessionID: id, pane: pane, paneIdentity: identity), host: host)
            }
        }
    }

    private func openWindowAsk(_ ask: PendingAsk, anchor: AskAnchor?, host: NativeControlHost) -> ControlResponse {
        guard host.pickController.openAsk(ask.anchored(at: anchor)) else {
            return refusal(host.pickController.pendingAsk != nil ? "ask already pending" : "pick already pending")
        }
        AskRegistry.shared.register(id: ask.id, owner: .window(LocalWindow.id))
        return ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: anchor?.pane?.rawValue))
    }

    public func askResult(_ target: String, window: String?) -> ControlResponse {
        guard let host = interactions else { return refusal("ask is not served here") }
        if let refusal = windowRefusal(window, host: host) { return refusal }
        guard let retained = AskRegistry.shared.result(for: target) else { return refusal("unknown ask: \(target)") }
        return ControlResponse(ok: true, result: ControlResult(ask: retained.result))
    }

    public func cancelAsk(_ target: String, window: String?) -> ControlResponse {
        guard let host = interactions else { return refusal("ask is not served here") }
        if let refusal = windowRefusal(window, host: host) { return refusal }
        guard let retained = AskRegistry.shared.result(for: target) else { return refusal("unknown ask: \(target)") }
        guard retained.result.result == .pending else { return ControlResponse(ok: true) }
        switch AskRegistry.shared.owner(for: target) {
        case .window:
            if host.pickController.pendingAsk?.id == target { host.pickController.cancelAsk() }
        case .session(let id, _):
            host.interactionSession(id)?.cancelAsk(id: target)
        case nil:
            return refusal("unknown ask: \(target)")
        }
        host.interactionsChanged(follow: false)
        return ControlResponse(ok: true)
    }

    // MARK: helpers

    /// windowRefusal refuses a `--window` naming no window; any window it names is the one agterm-win window.
    private func windowRefusal(_ window: String?, host: NativeControlHost) -> ControlResponse? {
        guard case .failure(let failed) = NativeControl.window(window, host: host) else { return nil }
        return refusal(failed.message)
    }

    /// timed ends an ask or pick that opened at its `--timeout` deadline through `cancel`, when it is still pending.
    private func timed(_ response: ControlResponse, deadline: Date?, cancel: @escaping @MainActor () -> Void) -> ControlResponse {
        guard response.ok, let deadline else { return response }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(deadline.timeIntervalSinceNow, 0) * 1_000_000_000))
            cancel()
        }
        return response
    }

    private func refusal(_ message: String) -> ControlResponse { ControlResponse(ok: false, error: message) }
}
