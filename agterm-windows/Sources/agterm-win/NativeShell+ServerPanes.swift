import Foundation
import WinSDK
import AgtermWinKit
import agtermCore

/// ServerPanes is what the running server session's split and scratch terminals attached, nil while one shows nothing.
struct ServerPanes {
    var owner: Foundation.UUID?
    var split: String?
    var scratch: String?
}

/// The running server session shows the panes a local session does. Its catalog row carries the attach for each one,
/// in `splitInitialCommand` and `scratchCommand`, and the terminals follow the row the way agterm-linux's remote catalog
/// does. Axis, visibility and the scratch are the server's, while ratio and focus belong to this viewer.
extension NativeShell {
    /// makeServerTerminal is one of the running session's terminals; `pane` names what its keys and title report, and
    /// a scratch reports no title.
    func makeServerTerminal(_ pane: StatusPane?) -> NativeTerminal {
        let terminal = makeTerminal()
        // OSC 9/777 of the pane it attaches; the server sends only `notify` through its stream
        terminal.onNotification = { [unowned self] title, body in
            if let running { deliver(running, title: title, body: body, source: .terminal) }
        }
        // the store forwards the clear to the server, as a Mac's bridged row does
        terminal.onKeystroke = { [unowned self] keystroke in
            guard let running, let store = server(of: running)?.remote.store, let session = store.session(withID: running) else { return }
            let before = session.agentIndicator
            store.clearStatus(by: keystroke, pane: pane ?? .scratch, reset: .firstKey, forSession: running)
            if session.agentIndicator != before { rebuild() }
        }
        if let pane, let named = CommandContext.Pane(rawValue: pane.rawValue) {
            terminal.onNaming = { [unowned self, unowned terminal] in if let running { serverNaming(running, terminal, pane: named) } }
            terminal.onFocus = { [unowned self, unowned terminal] in serverPaneFocused(terminal) }
        }
        return terminal
    }

    /// runningRow is the running session's catalog row and the store that mirrors it.
    var runningRow: (row: Session, store: AppStore)? {
        guard let running, let store = server(of: running)?.remote.store, let row = store.session(withID: running) else { return nil }
        return (row, store)
    }

    /// paneRow is the row behind session `id`'s panes here and its store: a local session's, or the running server row.
    func paneRow(_ id: Foundation.UUID) -> (row: Session, store: AppStore)? {
        if let session = local(id) { return (session.stored, localStore) }
        return id == running ? runningRow : nil
    }

    /// serverRowInView is the running row while its session is the one selected.
    var serverRowInView: Session? { selected == running && local(selected) == nil ? runningRow?.row : nil }

    /// sendServerPane sends a pane key's operation to the server; the row change it makes comes back through the catalog.
    func sendServerPane(_ operation: RemoteOperation) {
        guard let running else { return }
        Task { _ = await perform(operation, on: running) }
    }

    /// serverSplit is the running row's split while its terminal attached one.
    var serverSplit: NativeSplit? {
        guard let row = runningRow?.row, row.hasSplit, serverPanes.split != nil else { return nil }
        return NativeSplit(axis: row.splitAxis, ratio: row.splitRatio ?? NativeSplit.defaultRatio, shown: row.isSplit, focused: row.splitFocused)
    }

    var serverScratchShown: Bool { runningRow?.row.scratchActive == true && serverPanes.scratch != nil }

    /// serverOnScreen is the running session's pane in view: a shown scratch, else the focused pane.
    var serverOnScreen: NativeTerminal { serverPane(NativePane.onScreen(split: serverSplit, scratchShown: serverScratchShown)) ?? remoteTerminal }

    func serverPane(_ pane: NativePane) -> NativeTerminal? {
        switch pane {
        case .primary: remoteTerminal
        case .split: serverPanes.split == nil ? nil : remoteSplitTerminal
        case .scratch: serverPanes.scratch == nil ? nil : remoteScratchTerminal
        }
    }

    /// syncServerPanes attaches, re-attaches or drops the running session's panes to match its row, then lays them out.
    func syncServerPanes() {
        let current = runningRow
        if serverPanes.owner != running {
            serverPanes = ServerPanes(owner: running)
            remoteSplitTerminal.show(notice: "")
            remoteScratchTerminal.show(notice: "")
        }
        if let current, let owner = server(of: current.row.id) { attachServerPrimary(current.row, hostLabel: owner.label) }
        let row = current?.row
        attach(remoteSplitTerminal, row?.hasSplit == true ? row?.splitInitialCommand : nil, &serverPanes.split)
        // a hidden scratch keeps its attach, and the row names it again only once its daemon changes
        let scratch = row?.scratchDaemon == nil ? nil : row?.scratchCommand ?? serverPanes.scratch
        attach(remoteScratchTerminal, scratch, &serverPanes.scratch)
        placeSessions()
    }

    /// serverPaneNeedsAttach starts the running row's pane `identity` attaching again, as agterm-linux replaces the pane.
    func serverPaneNeedsAttach(_ identity: Foundation.UUID, session id: Foundation.UUID) {
        guard id == running, let row = runningRow?.row, let owner = server(of: id) else { return }
        if identity == row.splitPaneIdentity {
            serverPanes.split = nil
        } else if identity == row.scratchDaemon?.identity {
            guard let command = row.scratchCommand ?? serverPanes.scratch else { return }
            serverPanes.scratch = command
            remoteScratchTerminal.start(command)
        } else {
            attachServerPrimary(row, hostLabel: owner.label, again: true)
        }
        syncServerPanes()
    }

    private func attach(_ terminal: NativeTerminal, _ command: String?, _ attached: inout String?) {
        guard command != attached else { return }
        attached = command
        if let command { terminal.start(command) } else { terminal.show(notice: "") }
    }

    /// placeServerPanes lays the running session's panes over `area`, all hidden while a local session is in view.
    func placeServerPanes(in area: Rect, inView: Bool) {
        let covered = serverScratchShown
        let layout = PaneLayout(area: area, split: serverSplit, divider: dividerThickness)
        placePane(remoteTerminal, layout.primary, shown: inView && !covered)
        placePane(remoteSplitTerminal, layout.split, shown: inView && !covered && serverSplit != nil)
        placePane(remoteScratchTerminal, area, shown: inView && covered)
    }

    /// serverPaneFocused follows a click into the other pane of the running session's shown split.
    private func serverPaneFocused(_ terminal: NativeTerminal) {
        guard let row = runningRow?.row, serverSplit?.shown == true else { return }
        let inSplit = terminal === remoteSplitTerminal
        guard inSplit != row.splitFocused else { return }
        row.splitFocused = inSplit
        rebuild()
        titleChanged()
    }
}
