import Foundation
import agtermCore

/// The message bus's host side, as the Mac's `ControlServer+Messages`: a session resolves across the local and server
/// windows, and its store answers for the pane, refusing a server row whose panes live in its server's bus.
extension NativeStructure {
    public func resolveMessagePane(_ address: MessageAddress) -> Result<MessageRecipient, MessagePaneError> {
        guard let host = messages else { return .failure(.unsupported) }
        switch NativeControl.resolve(address.session, host: host) {
        case .failure(let refusal): return .failure(MessagePaneError(refusal.message))
        case .success(let id): return messageStore(holding: id, host: host).messagePane(session: id, pane: address.pane)
        }
    }

    public func messagePanes(workspace: String?, window: String?) -> Result<[MessageRecipient], MessagePaneError> {
        guard let host = messages else { return .failure(.unsupported) }
        guard let workspace else { return .success(host.localStore.messageRecipients()) }
        let scoped: AppStore
        switch NativeControl.window(window, host: host) {
        case .failure(let refusal): return .failure(MessagePaneError(refusal.message))
        case .success(nil): scoped = host.localStore
        case .success(let remote?):
            guard let store = host.remoteStore(remote) else { return .failure(MessagePaneError("remote window is not connected")) }
            scoped = store
        }
        switch scoped.resolveWorkspaceTarget(workspace) {
        case .resolved(let id): return .success(scoped.messageRecipients(workspace: id))
        case let resolution:
            return .failure(MessagePaneError(ControlResolve.errorMessage(noun: "workspace", target: workspace, resolution: resolution)))
        }
    }

    public func messageQueued(_ messageID: UUID, from: String?, to recipients: [MessageRecipient]) {
        guard let host = messages else { return }
        let stores = [host.localStore] + host.remoteServers.compactMap { host.remoteStore(NativeControl.remoteWindowID($0.name)) }
        for recipient in recipients {
            for store in stores where store.emitMessageQueued(messageID, from: from, to: recipient) {
                store.publishMessageQueued(messageID, from: from, to: recipient)
                break
            }
        }
    }

    private func messageStore(holding id: UUID, host: NativeControlHost) -> AppStore {
        if case .remote(_, let store) = NativeControl.owner(ofSession: id, host: host) { return store }
        return host.localStore
    }
}
