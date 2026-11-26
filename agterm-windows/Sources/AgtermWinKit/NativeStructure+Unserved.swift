import agtermCore

/// The requirements NativeControl answers itself; the dispatcher never reaches them for `NativeStructure.commands`.
extension NativeStructure {
    public func controlTree(window: String?) -> ControlResponse { unserved("controlTree") }
    public func readEvents(_ options: ControlEventReadOptions) -> ControlResponse { unserved("readEvents") }
    public func duplicateSession(_ target: String?, window: String?) -> ControlResponse { unserved("duplicateSession") }
    public func selectSession(_ target: String?, window: String?) -> ControlResponse { unserved("selectSession") }
    public func goSession(window: String?, direction: SessionNavigation) -> ControlResponse { unserved("goSession") }
    public func closeSession(_ target: String?, window: String?) -> ControlResponse { unserved("closeSession") }
    public func closeSessions(_ targets: [String], window: String?) -> ControlResponse { unserved("closeSessions") }
    public func renameSession(_ target: String?, window: String?, name: String) -> ControlResponse { unserved("renameSession") }
    public func revealSession(_ target: String?, window: String?) -> ControlResponse { unserved("revealSession") }
    public func markSessionSeen(_ target: String?, window: String?) -> ControlResponse { unserved("markSessionSeen") }
    public func setSessionStatus(_ target: String?, window: String?, update: ControlSessionStatusUpdate) async -> ControlResponse { unserved("setSessionStatus") }
    public func setSessionRestore(_ target: String?, window: String?, update: ControlSessionRestoreUpdate) -> ControlResponse { unserved("setSessionRestore") }
    public func splitSession(_ target: String?, window: String?, mode: String?) -> ControlResponse { unserved("splitSession") }
    public func closeSessionSplit(_ target: String?, window: String?) -> ControlResponse { unserved("closeSessionSplit") }
    public func scratchSession(_ target: String?, window: String?, mode: String?, command: String?) -> ControlResponse { unserved("scratchSession") }
    public func focusSessionPane(_ target: String?, window: String?, pane: String?) -> ControlResponse { unserved("focusSessionPane") }
    public func resizeSplit(_ target: String?, window: String?, resize: ControlSplitResize) -> ControlResponse { unserved("resizeSplit") }
    public func setSurfaceZoom(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse { unserved("setSurfaceZoom") }
    public func readSurfaceCursor(_ target: String?, window: String?) -> ControlResponse { unserved("readSurfaceCursor") }
    public func setDashboard(targets: [String], window: String?, close: Bool, fontMode: DashboardFontMode, mru: Bool) -> ControlResponse { unserved("setDashboard") }
    public func font(_ target: String?, window: String?, pane: StatusPane?, action: String) -> ControlResponse { unserved("font") }
    public func reloadKeymap() -> ControlResponse { unserved("reloadKeymap") }
    public func listKeymap() -> ControlResponse { unserved("listKeymap") }
    public func appIdentity() -> ControlResponse { unserved("appIdentity") }
    public func reloadGhosttyConfig() -> ControlResponse { unserved("reloadGhosttyConfig") }
    public func sendNotification(_ target: String?, window: String?, title: String?, body: String) -> ControlResponse { unserved("sendNotification") }
    public func setTheme(args: ControlArgs?) -> ControlResponse { unserved("setTheme") }
    public func listThemes() -> ControlResponse { unserved("listThemes") }
    public func setSidebarVisibility(_ mode: ControlToggleMode) -> ControlResponse { unserved("setSidebarVisibility") }
    public func expandSidebar(window: String?) -> ControlResponse { unserved("expandSidebar") }
    public func collapseSidebar(window: String?) -> ControlResponse { unserved("collapseSidebar") }
    public func setQuickTerminal(mode: String?) -> ControlResponse { unserved("setQuickTerminal") }
    public func typeQuick(text: String) async -> ControlResponse { unserved("typeQuick") }
    public func readQuickText(all: Bool, lines: Int?) async -> ControlResponse { unserved("readQuickText") }
    public func typeSession(_ target: String?, window: String?, options: ControlSessionTypeOptions) async -> ControlResponse { unserved("typeSession") }
    public func copySessionSelection(_ target: String?, window: String?) -> ControlResponse { unserved("copySessionSelection") }
    public func pasteSession(_ target: String?, window: String?, pane: StatusPane?) async -> ControlResponse { unserved("pasteSession") }
    public func selectAllSession(_ target: String?, window: String?) -> ControlResponse { unserved("selectAllSession") }
    public func searchSession(_ target: String?, window: String?, text: String?, to: String?) async -> ControlResponse { unserved("searchSession") }
    public func openSessionOverlay(_ target: String?, window: String?, options: ControlSessionOverlayOpenOptions) -> ControlResponse { unserved("openSessionOverlay") }
    public func closeSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse { unserved("closeSessionOverlay") }
    public func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?) -> ControlResponse { unserved("resizeSessionOverlay") }
    public func sessionOverlayResult(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse { unserved("sessionOverlayResult") }
    public func copySessionOverlaySelection(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse { unserved("copySessionOverlaySelection") }
    public func readSessionOverlayText(_ target: String?, window: String?, options: ControlSessionOverlayTextOptions) -> ControlResponse { unserved("readSessionOverlayText") }
    public func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse { unserved("openHud") }
    public func updateHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse { unserved("updateHud") }
    public func closeHud(_ target: String?, window: String?) -> ControlResponse { unserved("closeHud") }
    public func setSessionBackground(_ target: String?, window: String?, options: ControlSessionBackgroundOptions) -> ControlResponse { unserved("setSessionBackground") }
    public func readSessionText(_ target: String?, window: String?, options: ControlSessionTextOptions) -> ControlResponse { unserved("readSessionText") }
    public func windowNew(name: String?, minimized: Bool) async -> ControlResponse { unserved("windowNew") }
    public func windowList() -> ControlResponse { unserved("windowList") }
    public func windowSelect(_ target: String?) async -> ControlResponse { unserved("windowSelect") }
    public func windowClose(_ target: String?) async -> ControlResponse { unserved("windowClose") }
    public func windowRename(_ target: String?, name: String) -> ControlResponse { unserved("windowRename") }
    public func windowDelete(_ target: String?) -> ControlResponse { unserved("windowDelete") }
    public func windowResize(_ target: String?, width: Int, height: Int) -> ControlResponse { unserved("windowResize") }
    public func windowMove(_ target: String?, x: Int, y: Int, display: Int?) -> ControlResponse { unserved("windowMove") }
    public func windowZoom(_ target: String?) -> ControlResponse { unserved("windowZoom") }
    public func windowFullscreen(_ target: String?) -> ControlResponse { unserved("windowFullscreen") }
    public func windowMinimize(_ target: String?, mode: ControlToggleMode) async -> ControlResponse { unserved("windowMinimize") }
    public func openPick(_ pick: PendingPick, window: String?, follow: Bool) -> ControlResponse { unserved("openPick") }
    public func pickResult(_ target: String, window: String?) -> ControlResponse { unserved("pickResult") }
    public func cancelPick(_ target: String, window: String?) -> ControlResponse { unserved("cancelPick") }
    public func clearRestoreCommands() -> ControlResponse { unserved("clearRestoreCommands") }
    public func captureRestoreCommands() -> ControlResponse { unserved("captureRestoreCommands") }

    private func unserved(_ name: String) -> ControlResponse { ControlResponse(ok: false, error: "\(name) is not served here") }
}
