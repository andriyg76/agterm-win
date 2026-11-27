import Foundation

/// What a pane's program reports about itself (OSC 7 working directory, OSC 0/2 title), recorded on the
/// session the same way by every host. Both values flow unquoted into `/bin/sh -c` lines through
/// `{AGT_SESSION_PWD}`/`{AGT_SESSION_NAME}`, so they are stored sanitized. Neither saves: both re-fire on
/// every prompt redraw, and live state is persisted on quit and on structural mutations. The equality
/// guards matter for the same reason: an equal write still notifies observers.
extension Session {
    /// recordReportedCwd stores `rawCwd` as `pane`'s working directory and reports whether it changed.
    @discardableResult
    public func recordReportedCwd(_ rawCwd: String, pane: CommandContext.Pane) -> Bool {
        let cwd = TerminalText.sanitized(rawCwd)
        switch pane {
        case .left:
            guard currentCwd != cwd else { return false }
            currentCwd = cwd
        case .right:
            guard splitCwd != cwd else { return false }
            splitCwd = cwd
        case .scratch:
            guard scratchCwd != cwd else { return false }
            scratchCwd = cwd
        }
        return true
    }

    /// recordReportedTitle stores `rawTitle` as `pane`'s title and reports whether it changed; a scratch has no
    /// title of its own.
    ///
    /// A title equal to the pane's cwd is dropped: libghostty answers OSC 7 with a synthetic title equal to the
    /// pwd, and the cwd report does not reliably arrive first, so no arming handshake catches it. A shell titles
    /// with a basename or an abbreviated path, never the bare absolute cwd. Residual: between a cd and its OSC 7
    /// the stored cwd is still the old one, so a synthetic title for the NEW directory is accepted.
    @discardableResult
    public func recordReportedTitle(_ rawTitle: String, pane: CommandContext.Pane) -> Bool {
        let title = TerminalText.sanitized(rawTitle)
        guard pane != .scratch, title != cwd(for: pane) else { return false }
        if pane == .right {
            guard splitTitle != title else { return false }
            splitTitle = title
        } else {
            guard oscTitle != title else { return false }
            oscTitle = title
        }
        return true
    }
}
