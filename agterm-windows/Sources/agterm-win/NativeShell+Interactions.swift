import AgtermWinKit
import Foundation
import NativeShim
import WinSDK
import agtermCore

/// The window's pick and asks, shown as their slots hold them: the palette for a pick, an `AskPanel` for the GUI ask
/// in the window modal slot and one for the terminal ask of the session in view. agterm on a Mac draws the same slots
/// (upstream `WindowContentView` and `AskDialogView`); agterm-linux shows them the same way (`LinuxAskSurface`).
extension NativeShell {
    func interactionSession(_ id: Foundation.UUID) -> Session? {
        localStore.session(withID: id) ?? server(of: id)?.remote.session(id)
    }

    func guiTargetShown(_ id: Foundation.UUID) -> Bool {
        selected == id && dashboard == nil
    }

    func interactionsChanged(follow: Bool) {
        if follow, let window {
            ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW)
            SetForegroundWindow(window)
        }
        syncInteractions()
    }

    /// syncInteractions brings the palette and the ask panels in line with the slots: a pick opens the palette, a GUI
    /// ask whose anchor left the screen is cancelled, and each shown ask gets the keyboard unless a modal is over it.
    func syncInteractions() {
        SessionPickBook.shared.drain(pickController)
        if let pending = pickController.pending {
            if pickPalette?.id != pending.id {
                closePalette(refocus: false)
                openPickPalette(pending)
            }
        } else if pickPalette != nil {
            dropPickPalette()
        }
        syncAskPanels()
    }

    /// A GUI ask anchored to a session ends cancelled once that session or its pane is no longer shown, as on a Mac.
    private func cancelUnanchoredWindowAsk() {
        guard let anchor = pickController.pendingAsk?.anchor else { return }
        let session = interactionSession(anchor.sessionID)
        let paneShown = anchor.paneIdentity == nil || session?.askTargetPane.map { session?.rendersPane($0) == true } == true
        if session == nil || !guiTargetShown(anchor.sessionID) || !paneShown { pickController.cancelAsk() }
    }

    /// syncAskPanels shows the window slot's GUI ask over its anchor, and the session in view's own ask over the session
    /// or its pane while that region is on screen; an ask out of sight stays pending with its draft.
    func syncAskPanels() {
        guard let window else { return }
        cancelUnanchoredWindowAsk()
        let windowSlot = NativeAsk.Slot.window(pickController)
        windowAskPanel = panel(windowAskPanel, for: windowSlot, parent: window)
        if let panel = windowAskPanel, let ask = pickController.pendingAsk {
            panel.place(in: anchorRect(ask.anchor.flatMap { interactionSession($0.sessionID) }) ?? sessionArea, shown: true)
        }
        let session = selected.flatMap(interactionSession)
        let shown = session.map { $0.askPending != nil && $0.askCoversAnyPane && dashboard == nil } == true
        sessionAskPanel = panel(sessionAskPanel, for: shown ? session.map(NativeAsk.Slot.session) : nil, parent: window)
        if let panel = sessionAskPanel, let session {
            panel.place(in: anchorRect(session) ?? sessionArea, shown: true)
        }
        // a modal over the window takes the keyboard first: the palette, then the GUI ask
        if let panel = windowAskPanel {
            if paletteMode == nil, pickPalette == nil { panel.focusIfActive(window) }
        } else if let panel = sessionAskPanel, paletteMode == nil, pickPalette == nil {
            panel.focusIfActive(window)
        }
    }

    /// panel keeps `current` while it still draws the slot's ask, else replaces it with one for `slot`'s, or none.
    private func panel(_ current: AskPanel?, for slot: NativeAsk.Slot?, parent: HWND) -> AskPanel? {
        let ask = slot?.ask
        if let current, current.askID == ask?.id {
            current.restyle(askLook(ask))
            return current
        }
        let hadFocus = current?.owns(GetFocus()) == true
        current?.destroy()
        guard let slot, let ask else {
            if hadFocus { focus() }
            return nil
        }
        let panel = AskPanel(parent: parent, slot: slot, look: askLook(ask))
        panel?.onFinished = { [unowned self] in
            rebuild()
            syncInteractions()
            if windowAskPanel == nil, sessionAskPanel == nil { focus() }
        }
        return panel
    }

    /// anchorRect is where a session's ask goes: its pane while one is named, else the session's whole area.
    private func anchorRect(_ session: Session?) -> NativeOverlay.Rect? {
        guard let session, let pane = session.askTargetPane, let local = local(session.id) else { return nil }
        let layout = PaneLayout(area: sessionArea, split: local.splitTerminal == nil ? nil : local.split, divider: dividerThickness)
        return pane == .left ? layout.primary : layout.split
    }

    /// askLook is the terminal's font and theme for a terminal ask, the palette's for a GUI one.
    private func askLook(_ ask: PendingAsk?) -> AskPanel.Look {
        let theme = NativeTerminal.theme
        let palette = chromePalette
        let gui = ask?.style == .gui
        let background = gui ? palette.palBg : theme?.background ?? ChromePalette.defaultBackground
        let foreground = gui ? palette.chromeText : theme?.foreground ?? ChromePalette.defaultForeground
        return AskPanel.Look(gui: gui, background: background, foreground: foreground,
                             dim: gui ? palette.chromeDim : AskPanel.mix(foreground, background, 0.7),
                             border: gui ? palette.palBorder : AskPanel.mix(foreground, background, 0.2), accent: palette.chromeAccent,
                             fontFamily: gui ? "Segoe UI" : NativeTerminal.fontFamily ?? "Cascadia Mono",
                             fontPoints: gui ? 10 : fontPoints, dpi: dpi)
    }

    /// focusAsk gives the keyboard to the ask in view, ahead of the terminal under it; false when none is shown.
    func focusAsk() -> Bool {
        guard paletteMode == nil, pickPalette == nil, let panel = windowAskPanel ?? sessionAskPanel, panel.shown else { return false }
        panel.focus()
        return true
    }

    /// paneFocusedUnderAsk hands the keyboard back to an ask covering the pane that just took it, as a click on a Mac's
    /// covered region focuses its dialog.
    func paneFocusedUnderAsk(_ id: Foundation.UUID) {
        guard id == selected, windowAskPanel == nil, let panel = sessionAskPanel, panel.shown else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { if panel.shown { panel.focus() } } }
    }

    /// endInteractions settles a session's asks and picks before the session goes, as a Mac does on close.
    func endInteractions(of session: Session) {
        session.cancelPendingAsk()
        SessionPickBook.shared.sessionEnded(session.id)
        if pickController.pendingAsk?.anchor?.sessionID == session.id { pickController.cancelAsk() }
    }
}
