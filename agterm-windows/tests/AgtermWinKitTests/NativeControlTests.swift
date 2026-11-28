import AgtermWinKit
import Foundation
import Testing
import agtermCore

@MainActor
private func scratchStore() -> AppStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-control-\(UUID().uuidString)")
    let store = AppStore(persistence: PersistenceStore(directory: directory, fileName: "window.json"), paneFinalizer: nil)
    store.ensureRoot()
    return store
}

/// PaneSurface is a started pane carrying the token its shell's `AGTERM_PANE_ID` names.
private final class PaneSurface: TerminalSurface {
    let paneToken: String
    let isRealized = true
    init(_ pane: UUID) { paneToken = pane.uuidString }
    func teardown() {}
    func promoteToPrimaryPane() {}
}

@MainActor
private final class FakeHost: NativeControlHost {
    let localStore: AppStore
    let events = NativeEvents()
    var localSessions: [NativeControl.Local] = []
    var selectedSession: UUID?
    var serverWorkspaces: [ControlWorkspaceNode] = []
    var typed: [(String, UUID)] = []
    var renamed: [(UUID, String)] = []
    var closed: [UUID] = []
    var notified: [UUID] = []
    var fontPoints: Float = 11
    var screens: [UUID: (lines: [String], rows: Int)] = [:]

    init() {
        localStore = scratchStore()
    }

    func add(_ name: String, command: String = "cmd.exe", in workspace: UUID? = nil) -> UUID {
        let session = localStore.addSession(toWorkspace: workspace ?? localStore.rootWorkspace!.id, cwd: "", command: command, select: false)!
        localSessions.append(NativeControl.Local(id: session.id, name: name, commandLine: command, exited: false, attention: false))
        return session.id
    }

    func isServerSession(_ id: UUID) -> Bool { serverWorkspaces.flatMap(\.sessions).contains { $0.id == id.uuidString } }

    var serverConnected = false
    private var serverOverlays: [UUID: NativeOverlay] = [:]
    private var serverOverlayExitCodes: [UUID: Int] = [:]

    func isConnectedServerSession(_ id: UUID) -> Bool { serverConnected && isServerSession(id) }

    func serverOverlayState(for id: UUID) -> (overlay: NativeOverlay?, exitCode: Int?)? {
        guard isServerSession(id) else { return nil }
        return (serverOverlays[id], serverOverlayExitCodes[id])
    }

    func serverPageOverlay(for id: UUID) -> (page: HtmlOverlay, hidden: Bool)? { nil }

    var defaultCommand: String? = "powershell.exe"
    var newSession: NativeStructure.NewSession? {
        NativeStructure.NewSession(cwd: #"C:\home"#, command: defaultCommand) { _, _ in nil }
    }

    var restoreMode = RestoreMode.none
    var zmxClient: ZmxClient?
    var zmxContext: NativeZmx.Context {
        NativeZmx.Context(store: localStore, client: zmxClient, decision: RestoreMode.live.launchDecision(liveUnavailableReason: nil),
                          configured: restoreMode, setConfigured: { [unowned self] in restoreMode = $0; return true })
    }

    var remotes: [UUID: AppStore] = [:]
    func remoteStore(_ window: UUID) -> AppStore? { remotes[window] }

    var structureChanges = 0
    func structureChanged(_ store: AppStore, selectionMoved: Bool) {
        structureChanges += 1
        guard store === localStore else { return }
        let sessions = store.workspaces.flatMap(\.sessions)
        localSessions.removeAll { local in !sessions.contains { $0.id == local.id } }
        for session in sessions where !localSessions.contains(where: { $0.id == session.id }) {
            localSessions.append(NativeControl.Local(id: session.id, name: session.customName ?? "Windows PowerShell",
                                                     commandLine: session.initialCommand ?? "", exited: false, attention: false))
        }
        if selectionMoved { selectedSession = store.selectedSessionID }
    }

    var performed: [(RemoteOperation, UUID)] = []
    func performRemote(_ operation: RemoteOperation, window: UUID, select: Bool) async -> ControlResponse {
        performed.append((operation, window))
        return ControlResponse(ok: true, result: ControlResult(id: "S1"))
    }

    var navigationOrder: [UUID] { localSessions.map(\.id) }

    func closeSession(_ id: UUID) async -> ControlResponse {
        closed.append(id)
        return ControlResponse(ok: true)
    }

    func renameSession(_ id: UUID, to name: String) async -> ControlResponse {
        renamed.append((id, name))
        return ControlResponse(ok: true)
    }

    func restartSession(_ id: UUID) async -> ControlResponse { ControlResponse(ok: true) }
    var revealable: Set<UUID> = []
    var revealed: [UUID] = []
    func revealSession(_ id: UUID) -> Bool {
        guard revealable.contains(id) else { return false }
        revealed.append(id)
        return true
    }
    func selectSession(_ id: UUID) { selectedSession = id }

    var typedPanes: [NativePane?] = []
    func type(_ text: String, into id: UUID, pane: NativePane?) -> Bool {
        typed.append((text, id))
        typedPanes.append(pane)
        return true
    }

    func screen(of id: UUID, pane: NativePane?) -> (lines: [String], rows: Int)? { screens[id] }
    var bannersOff = false
    func notify(_ id: UUID, title: String, body: String) -> String? {
        notified.append(id)
        return bannersOff ? ControlNotify.bannersOffNote : nil
    }
    func setStatus(_ id: UUID, _ update: ControlSessionStatusUpdate) -> Bool {
        var applied = false
        editLocal(id) { applied = $0.activity.apply(update, hasSplit: localStore.session(withID: id)?.hasSplit == true) }
        return applied
    }
    func setContext(_ id: UUID, _ context: String?) { editLocal(id) { $0.context = context } }
    func setInfo(_ id: UUID, _ info: SessionInfo?) { editLocal(id) { $0.info = info } }
    var seen: [UUID] = []
    func markSeen(_ id: UUID) { seen.append(id) }
    func setFontPoints(_ points: Float) { fontPoints = points }
    var keymap = WindowsKeymap(text: "map ctrl+alt+t new_session").control
    var reloads = 0

    func reloadKeymap() -> Int {
        reloads += 1
        return 2
    }

    var appearance = Appearance()
    var themeCatalog = ThemeCatalog(names: ["Dracula", "Nord"])
    var systemIsDark = false
    func setAppearance(_ appearance: Appearance) { self.appearance = appearance }

    var remoteServers = [NativeControl.RemoteServer(name: "Ubuntu", started: false, state: nil)]
    var startRefusal: String?
    func startRemoteServer(_ name: String) -> String? {
        guard startRefusal == nil else { return startRefusal }
        remoteServers = remoteServers.map { $0.name == name ? NativeControl.RemoteServer(name: name, started: true, state: .connected) : $0 }
        return nil
    }
    var created: [(name: String, create: RemoteSessionCreate)] = []
    func newRemoteSession(_ name: String, _ create: RemoteSessionCreate) async -> ControlResponse {
        created.append((name, create))
        return ControlResponse(ok: true, result: ControlResult(id: "S1"))
    }

    var opened: [NativeOverlay.Open] = []
    var overlayScreens: [UUID: (lines: [String], rows: Int)] = [:]
    var overlaySelections: [UUID: String] = [:]

    private func editLocal(_ id: UUID, _ edit: (inout NativeControl.Local) -> Void) {
        guard let index = localSessions.firstIndex(where: { $0.id == id }) else { return }
        edit(&localSessions[index])
    }

    var openedPages: [(UUID, HtmlOverlay)] = []

    func openPageOverlay(_ id: UUID, _ overlay: HtmlOverlay, sizePercent: Int?) {
        openedPages.append((id, overlay))
        _ = localStore.openHtmlOverlay(id, pane: nil, overlay: overlay, sizePercent: sizePercent)
    }

    func openOverlay(_ id: UUID, _ open: NativeOverlay.Open) {
        opened.append(open)
        if isServerSession(id) {
            serverOverlays[id] = NativeOverlay(sizePercent: open.sizePercent, wait: open.wait)
            serverOverlayExitCodes.removeValue(forKey: id)
            return
        }
        localStore.openOverlay(id, command: open.command, cwd: open.cwd, wait: open.wait, sizePercent: open.sizePercent)
    }

    func closeOverlay(_ id: UUID) {
        if isServerSession(id) {
            serverOverlays.removeValue(forKey: id)
            serverOverlayExitCodes.removeValue(forKey: id)
        } else { localStore.closeOverlay(id) }
    }

    func resizeOverlay(_ id: UUID, sizePercent: Int?) {
        if var overlay = serverOverlays[id] { overlay.sizePercent = sizePercent; serverOverlays[id] = overlay }
        else { localStore.resizeOverlay(id, sizePercent: sizePercent) }
    }

    func setOverlayHidden(_ id: UUID, _ hidden: Bool) {
        if var overlay = serverOverlays[id] { overlay.hidden = hidden; serverOverlays[id] = overlay }
        else { localStore.setOverlaysHidden(id, pane: nil, hidden: hidden) }
    }
    func overlayScreen(of id: UUID) -> (lines: [String], rows: Int)? { overlayScreens[id] }
    func overlaySelection(of id: UUID) -> String? { overlaySelections[id] }

    /// exitOverlay is the overlay's program ending without `--wait`, which closes it.
    func panesChanged(_ id: UUID) {}
    func closeSplit(_ id: UUID) { localStore.closeSplit(id) }
    var swaps = 0
    func swapPanes(_ id: UUID) { swaps += 1 }
    var scratchCommands: [String?] = []
    func setScratch(_ id: UUID, shown: Bool, command: String?) {
        scratchCommands.append(command)
        if shown != localStore.session(withID: id)?.scratchActive { localStore.toggleScratch(id) }
    }
    var quickShown = false
    var quickShows = 0
    func setQuick(shown: Bool) {
        if shown { quickShows += 1 }
        quickShown = shown
    }
    var quickTyped: [String] = []
    func typeQuick(_ text: String) -> Bool {
        guard quickShown else { return false }
        quickTyped.append(text)
        return true
    }
    var quickScreen: (lines: [String], rows: Int)?
    var dashboard: NativeControl.Dashboard?
    var recentSessions: [UUID] = []
    func openDashboard(_ members: [DashboardMember], fontMode: DashboardFontMode) {
        dashboard = .init(members: members, highlighted: members.first, fontMode: fontMode,
                          fontSize: fontMode.appliedFontSize(memberCount: members.count, base: Double(fontPoints)))
    }
    func closeDashboard() { dashboard = nil }

    var sidebarVisible = true
    func setSidebarVisible(_ visible: Bool) { sidebarVisible = visible }
    var fullscreen = false
    func setFullscreen(_ on: Bool) { fullscreen = on }
    var sidebarWidthPoints: Double = AppStore.sidebarWidthDefault
    func setSidebarWidth(points: Double) { sidebarWidthPoints = AppStore.clampSidebarWidth(points) }
    var flaggedLayout = FlaggedViewLayout.flat
    func setFlaggedLayout(_ layout: FlaggedViewLayout) { flaggedLayout = layout }

    func exitOverlay(_ id: UUID, code: Int) {
        localStore.recordOverlayExit(id, code: code)
        localStore.closeOverlay(id)
    }

    func exitServerOverlay(_ id: UUID, code: Int) {
        serverOverlays.removeValue(forKey: id)
        serverOverlayExitCodes[id] = code
    }

    let pickController = PickController()
    var interactionChanges: [Bool] = []
    func interactionSession(_ id: UUID) -> Session? { localStore.session(withID: id) }
    func guiTargetShown(_ id: UUID) -> Bool { selectedSession == id && dashboard == nil }
    func interactionsChanged(follow: Bool) {
        SessionPickBook.shared.drain(pickController)
        interactionChanges.append(follow)
    }
}

@MainActor
struct NativeControlTests {
    private func handle(_ request: ControlRequest, _ host: FakeHost) async -> ControlResponse {
        await NativeControl.handle(request, host: host, version: "1.2.3")
    }

    @Test func eventsReadIsServedFromTheHostsRing() async {
        let host = FakeHost()
        host.events.launched()
        let anchor = try! #require(await handle(ControlRequest(cmd: .eventsRead), host).result?.events)
        #expect(anchor.next == 1 && anchor.items.isEmpty)
        let page = await handle(ControlRequest(cmd: .eventsRead, args: ControlArgs(after: "0", run: anchor.run.uuidString)), host)
        #expect(page.result?.events?.items.map(\.kind) == [.appLaunched])
        #expect(await handle(ControlRequest(cmd: .eventsRead, args: ControlArgs(after: "0")), host).error
            == "events.read requires --run and --after together")
    }

    @Test func windowListReportsEveryRemoteAsARemoteWindow() async {
        let host = FakeHost()
        let before = await handle(ControlRequest(cmd: .windowList), host).result?.windows?.first { $0.remote != nil }
        #expect(before?.id == NativeControl.remoteWindowID("Ubuntu").uuidString && before?.open == false)
        #expect(before?.remote?.host == "Ubuntu" && before?.remote?.state == nil)
        let opened = await handle(ControlRequest(cmd: .windowRemoteOpen, args: ControlArgs(host: "Ubuntu")), host)
        #expect(opened.result?.id == before?.id)
        let after = await handle(ControlRequest(cmd: .windowList), host).result?.windows?.first { $0.remote != nil }
        #expect(after?.open == true && after?.remote?.state == "connected")
    }

    @Test func aRemoteWindowRefusesAnUndefinedNameAndPassesAStartRefusalOn() async {
        let host = FakeHost()
        let open = { (destination: String) in await self.handle(ControlRequest(cmd: .windowRemoteOpen, args: ControlArgs(host: destination)), host) }
        #expect(await open("buildbox").error == "window.remote.open: buildbox is not defined in remote.properties")
        host.startRefusal = "asking"
        #expect(await open("Ubuntu").error == "asking")
    }

    @Test func aRemoteSessionNeedsAConnectedRemote() async {
        let host = FakeHost()
        let request = ControlRequest(cmd: .sessionRemoteNew, args: ControlArgs(cwd: "/tmp", host: "Ubuntu"))
        #expect(await handle(request, host).error == "no connection to Ubuntu")
        _ = host.startRemoteServer("Ubuntu")
        #expect(await handle(request, host).result?.id == "S1")
        #expect(host.created.first?.name == "Ubuntu" && host.created.first?.create.cwd == "/tmp")
    }

    @Test func bareTreeIsTheLocalWindowAndAWindowTreeIsTheServers() async {
        let host = FakeHost()
        let dev = host.localStore.addWorkspace(name: "dev")
        let shell = host.add("Windows PowerShell", in: dev.id)
        _ = host.localStore.selectSession(shell)
        let tree = try! #require(await handle(ControlRequest(cmd: .tree), host).result?.tree)
        let named = try! #require(tree.workspaces.first { $0.name == "dev" })
        #expect(named.sessions.map(\.name) == ["Windows PowerShell"] && named.sessions[0].active && named.active)
        #expect(named.sessions[0].restoreCommand == "cmd.exe")
        let served = scratchStore()
        served.ensureRoot()
        _ = served.addWorkspace(name: "srv")
        let remote = NativeControl.remoteWindowID("Ubuntu")
        #expect(await handle(ControlRequest(cmd: .tree, args: ControlArgs(window: remote.uuidString)), host).error == "remote window is not connected")
        host.remotes[remote] = served
        let server = try! #require(await handle(ControlRequest(cmd: .tree, args: ControlArgs(window: remote.uuidString)), host).result?.tree)
        #expect(server.workspaces.contains { $0.name == "srv" } && !tree.workspaces.contains { $0.name == "srv" })
    }

    @Test func sidebarExpandOpensEveryWorkspaceAndCollapseKeepsTheCurrentOneOpen() async {
        let host = FakeHost()
        let dev = host.localStore.addWorkspace(name: "dev", collapsed: true)
        let ops = host.localStore.addWorkspace(name: "ops", collapsed: true)
        _ = host.localStore.selectSession(host.add("shell", in: dev.id))
        let folds = { [dev.id, ops.id].map { id in host.localStore.workspaces.first { $0.id == id }?.isExpanded } }
        #expect(await handle(ControlRequest(cmd: .sidebarExpand), host).ok)
        let opened = folds()
        #expect(opened == [true, true])
        #expect(await handle(ControlRequest(cmd: .sidebarCollapse), host).ok)
        let collapsed = folds()
        #expect(collapsed == [true, false])
        host.localStore.setSidebarMode(.flagged)
        #expect(await handle(ControlRequest(cmd: .sidebarExpand), host).ok)
        let flagged = folds()
        #expect(flagged == [true, false])
    }

    @Test func windowFullscreenTogglesTheOneWindowAndWindowListReadsItBack() async {
        let host = FakeHost()
        let entered = await handle(ControlRequest(cmd: .windowFullscreen), host)
        #expect(entered.ok && entered.result?.id == LocalWindow.id.uuidString && host.fullscreen)
        let windows = await handle(ControlRequest(cmd: .windowList), host).result?.windows ?? []
        #expect(windows.first?.fullscreen == true)
        #expect(await handle(ControlRequest(cmd: .windowFullscreen, target: LocalWindow.id.uuidString), host).ok && !host.fullscreen)
        #expect(await handle(ControlRequest(cmd: .windowFullscreen, target: "ffffffff"), host).ok == false && !host.fullscreen)
    }

    @Test func windowListPutsTheLocalWindowFirst() async {
        let windows = await handle(ControlRequest(cmd: .windowList), FakeHost()).result?.windows ?? []
        #expect(windows.first?.id == LocalWindow.id.uuidString && windows.first?.active == true)
    }

    @Test func workspaceCommandsShapeTheLocalTree() async {
        let host = FakeHost()
        let created = await handle(ControlRequest(cmd: .workspaceNew, args: ControlArgs(name: "api")), host)
        let id = try! #require(created.result?.id)
        #expect(await handle(ControlRequest(cmd: .workspaceRename, target: id, args: ControlArgs(name: "backend")), host).ok)
        let session = host.add("a")
        var move = ControlArgs()
        move.workspace = id
        #expect(await handle(ControlRequest(cmd: .sessionMove, target: session.uuidString, args: move), host).ok)
        var flag = ControlArgs()
        flag.mode = "on"
        #expect(await handle(ControlRequest(cmd: .sessionFlag, target: session.uuidString, args: flag), host).ok)
        let tree = try! #require(await handle(ControlRequest(cmd: .tree), host).result?.tree)
        let backend = try! #require(tree.workspaces.first { $0.name == "backend" })
        #expect(backend.sessions.map(\.id) == [session.uuidString] && backend.sessions[0].flagged == true)
        #expect(await handle(ControlRequest(cmd: .workspaceDelete, target: id), host).ok)
        #expect(host.localSessions.isEmpty && host.localStore.workspace(named: "backend") == nil)
    }

    @Test func tintCommandsTintTheLocalRowsAndTreeReadsThemBack() async {
        let host = FakeHost()
        let workspace = try! #require(await handle(ControlRequest(cmd: .workspaceNew, args: ControlArgs(name: "api")), host).result?.id)
        let session = host.add("a")
        var set = ControlArgs()
        set.mode = "set"
        set.tint = "teal"
        set.tintOn = ["name"]
        #expect(await handle(ControlRequest(cmd: .sessionTint, target: session.uuidString, args: set), host).ok)
        set.tint = "#AB12CD"
        set.tintOn = nil
        #expect(await handle(ControlRequest(cmd: .workspaceTint, target: workspace, args: set), host).ok)
        let tree = try! #require(await handle(ControlRequest(cmd: .tree), host).result?.tree)
        let node = try! #require(tree.workspaces.flatMap(\.sessions).first { $0.id == session.uuidString })
        #expect(node.tint == "teal" && node.tintOn == ["name"])
        let api = try! #require(tree.workspaces.first { $0.id == workspace })
        #expect(api.tint == "#ab12cd" && api.tintOn == ["icon"])
        var clear = ControlArgs()
        clear.mode = "clear"
        #expect(await handle(ControlRequest(cmd: .sessionTint, target: session.uuidString, args: clear), host).ok)
        #expect(host.localStore.session(withID: session)?.tint == nil)
    }

    @Test func flaggedLayoutIsSetToggledAndReadBack() async {
        let host = FakeHost()
        var args = ControlArgs()
        args.mode = "plain"
        #expect(await handle(ControlRequest(cmd: .sidebarFlaggedLayout, args: args), host).result?.text == "plain")
        #expect(host.flaggedLayout == .plain)
        #expect(await handle(ControlRequest(cmd: .sidebarFlaggedLayout), host).result?.text == "tree")
        #expect(await handle(ControlRequest(cmd: .tree), host).result?.tree?.sidebarFlaggedLayout == "tree")
        args.mode = "nested"
        #expect(await handle(ControlRequest(cmd: .sidebarFlaggedLayout, args: args), host).error == "invalid flagged layout: nested")
    }

    @Test func flaggedViewListsByTheLayout() {
        let host = FakeHost()
        let store = host.localStore
        let dev = store.addWorkspace(name: "dev")
        let top = host.add("top")
        let api = host.add("api")
        store.renameSession(top, to: "top")
        store.renameSession(api, to: "api")
        _ = store.moveSession(api, toWorkspace: dev.id)
        store.setFlag(true, forSessions: store.workspaces.flatMap(\.sessions).map(\.id))
        store.setSidebarMode(.flagged)
        let titles = { SessionSidebar.items(store).map { $0.isWorkspace ? "[\($0.title)] \($0.children.map(\.title))" : $0.title } }
        store.useFlaggedLayout(.flat)
        #expect(titles().contains("api : dev"))
        store.useFlaggedLayout(.plain)
        #expect(titles().contains("api") && !titles().contains("api : dev"))
        store.useFlaggedLayout(.tree)
        #expect(titles() == ["top", "[dev] [\"api\"]"])
    }

    @Test func aCompanionNestsUnderItsSessionInTheTree() async {
        let host = FakeHost()
        let parent = host.add("a")
        let companion = await handle(ControlRequest(cmd: .sessionCompanionNew, target: parent.uuidString), host)
        let id = try! #require(companion.result?.id)
        let sessions = try! #require(await handle(ControlRequest(cmd: .tree), host).result?.tree?.workspaces.flatMap(\.sessions))
        #expect(sessions.first { $0.id == id }?.parent == parent.uuidString)
        #expect(host.localSessions.count == 2)
    }

    @Test func aServerWorkspacesStructureGoesToItsServer() async {
        let host = FakeHost()
        let served = scratchStore()
        served.ensureRoot()
        let srv = served.addWorkspace(name: "srv")
        let remote = NativeControl.remoteWindowID("Ubuntu")
        host.remotes[remote] = served
        #expect(await handle(ControlRequest(cmd: .workspaceRename, target: srv.id.uuidString, args: ControlArgs(name: "x")), host).ok)
        #expect(host.performed.map(\.1) == [remote] && served.workspace(named: "srv") != nil)
        #expect(await handle(ControlRequest(cmd: .sessionNew, args: ControlArgs(workspace: srv.id.uuidString)), host).ok)
        #expect(host.performed.count == 2 && host.localSessions.isEmpty)
    }
    @Test func sidebarVisibilityUsesTheSameStateAsTreeWithoutChangingItsWidth() async {
        let host = FakeHost()
        let width = host.sidebarWidthPoints
        #expect(await handle(ControlRequest(cmd: .sidebar, args: ControlArgs(mode: "hide")), host).ok)
        let hidden = await handle(ControlRequest(cmd: .tree), host)
        #expect(hidden.result?.tree?.sidebarVisible == false)
        #expect(hidden.result?.tree?.sidebarWidth == width)
        #expect(await handle(ControlRequest(cmd: .sidebar), host).ok)
        let visible = await handle(ControlRequest(cmd: .tree), host)
        #expect(visible.result?.tree?.sidebarVisible == true)
        #expect(!(await handle(ControlRequest(cmd: .sidebar, args: ControlArgs(mode: "invalid")), host)).ok)
        #expect(host.sidebarVisible)
    }

    @Test func sidebarWidthSetsAndEchoesOnTree() async {
        let host = FakeHost()
        let set = await handle(ControlRequest(cmd: .sidebarWidth, args: ControlArgs(sidebarWidth: 271.3)), host)
        #expect(set.ok == true)
        #expect(set.result?.sidebarWidth == 271.3)
        let tree = await handle(ControlRequest(cmd: .tree), host)
        #expect(tree.result?.tree?.sidebarWidth == 271.3)
    }

    @Test func typeGoesToTheSelectedSessionWithoutATarget() async {
        let host = FakeHost()
        _ = host.add("a")
        let b = host.add("b")
        host.selectedSession = b
        let response = await handle(ControlRequest(cmd: .sessionType, args: ControlArgs(text: "dir\n")), host)
        #expect(response.ok && host.typed.map(\.1) == [b] && host.typed.map(\.0) == ["dir\n"])
    }

    @Test func revealShowsAnExistingFolderAndRefusesOneThatIsNotHere() async {
        let host = FakeHost()
        let here = host.add("here")
        let gone = host.add("gone")
        host.revealable = [here]
        #expect(await handle(ControlRequest(cmd: .sessionReveal, target: here.uuidString), host).ok)
        let refused = await handle(ControlRequest(cmd: .sessionReveal, target: gone.uuidString), host)
        #expect(!refused.ok && refused.error == "session cwd is not an existing directory" && host.revealed == [here])
    }

    @Test func targetsResolveByUniquePrefixAndRefuseAnUnknownOne() async {
        let host = FakeHost()
        let a = host.add("a")
        let prefix = String(a.uuidString.prefix(8))
        #expect(await handle(ControlRequest(cmd: .sessionRename, target: prefix, args: ControlArgs(name: "build")), host).ok)
        #expect(host.renamed.map(\.1) == ["build"])
        let missing = await handle(ControlRequest(cmd: .sessionClose, target: "ffffffff"), host)
        #expect(!missing.ok && missing.error == "no such session: ffffffff" && host.closed.isEmpty)
    }

    @Test func themeSetChangesTheAppearanceAndReadsItBack() async {
        let host = FakeHost()
        let set = await handle(ControlRequest(cmd: .themeSet, args: ControlArgs(name: "Nord")), host)
        #expect(set.ok && set.result?.theme == "Nord" && host.appearance.theme == "Nord")
        let list = await handle(ControlRequest(cmd: .themeList), host)
        #expect(list.result?.themes == ["Dracula", "Nord"] && list.result?.sync == false)
        #expect(await handle(ControlRequest(cmd: .themeSet, args: ControlArgs(name: "Missing")), host).error == "unknown theme: Missing")
    }

    @Test func aDarkThemeFollowsTheSystem() async {
        let host = FakeHost()
        host.systemIsDark = true
        let set = await handle(ControlRequest(cmd: .themeSet, args: ControlArgs(light: "Nord", dark: "Dracula")), host)
        #expect(set.result?.theme == "Dracula" && set.result?.light == "Nord" && set.result?.sync == true)
        _ = await handle(ControlRequest(cmd: .themeSet, args: ControlArgs(dark: "none")), host)
        #expect(!host.appearance.followsSystem && host.appearance.activeTheme(dark: true) == "Nord")
    }

    @Test func keymapListAndReloadReachTheHost() async {
        let host = FakeHost()
        let list = await handle(ControlRequest(cmd: .keymapList), host)
        #expect(list.result?.keymap?.actions.first { $0.action == "new_session" }?.chord == "ctrl+opt+t")
        let reload = await handle(ControlRequest(cmd: .keymapReload), host)
        #expect(reload.result?.count == 2 && host.reloads == 1)
    }

    @Test func aBlankRenameReachesTheHostToRestoreTheAutomaticName() async {
        let host = FakeHost()
        host.selectedSession = host.add("a")
        #expect(await handle(ControlRequest(cmd: .sessionRename, args: ControlArgs(name: "")), host).ok)
        #expect(host.renamed.map(\.1) == [""])
        #expect(await handle(ControlRequest(cmd: .sessionRename), host).error == "session.rename requires a name")
    }

    @Test func treeReportsALocalSessionsDirectoryAndTitle() async {
        let host = FakeHost()
        let id = host.add("agterm", command: "pwsh.exe")
        host.localSessions = [NativeControl.Local(id: id, name: "agterm", commandLine: "pwsh.exe", exited: false, attention: false,
                                                  cwd: #"C:\dev\agterm"#, title: "vim")]
        let sessions = try! #require(await handle(ControlRequest(cmd: .tree), host).result?.tree?.workspaces.flatMap(\.sessions))
        let session = try! #require(sessions.first { $0.id == id.uuidString })
        #expect(session.cwd == #"C:\dev\agterm"# && session.title == "vim")
    }

    @Test func newSessionStartsInTheLocalTreeWithItsNameFolderAndCommand() async {
        let host = FakeHost()
        let local = await handle(ControlRequest(cmd: .sessionNew, args: ControlArgs(name: "logs", cwd: #"C:\dev"#, command: "cmd.exe /k")), host)
        let id = try! #require(local.result?.id.flatMap(UUID.init(uuidString:)))
        let stored = try! #require(host.localStore.session(withID: id))
        #expect(stored.initialCwd == #"C:\dev"# && stored.initialCommand == "cmd.exe /k" && stored.customName == "logs")
        #expect(host.localSessions.map(\.name) == ["logs"] && host.selectedSession == id)
        #expect(await handle(ControlRequest(cmd: .sessionNew, args: ControlArgs(workspace: "dev-no")), host).error == "no such workspace: dev-no")
        let plain = await handle(ControlRequest(cmd: .sessionNew), host)
        let profile = try! #require(plain.result?.id.flatMap(UUID.init(uuidString:)).flatMap(host.localStore.session(withID:)))
        #expect(profile.initialCommand == "powershell.exe" && profile.initialCwd == #"C:\home"#)
    }

    @Test func newSessionWithNoSelectKeepsTheSelection() async {
        let host = FakeHost()
        let a = host.add("a")
        host.selectedSession = a
        _ = await handle(ControlRequest(cmd: .sessionNew, args: ControlArgs(noSelect: true)), host)
        #expect(host.selectedSession == a && host.localSessions.count == 2)
    }

    @Test func goWrapsThroughTheSidebarOrder() async {
        let host = FakeHost()
        let a = host.add("a"), b = host.add("b")
        host.selectedSession = b
        #expect(await handle(ControlRequest(cmd: .sessionGo, args: ControlArgs(to: "next")), host).result?.id == a.uuidString)
        #expect(await handle(ControlRequest(cmd: .sessionGo, args: ControlArgs(to: "2")), host).result?.id == b.uuidString)
        #expect(!(await handle(ControlRequest(cmd: .sessionGo, args: ControlArgs(to: "sideways")), host).ok))
    }

    @Test func textReadsTheScreenByDefaultAndTheLastLinesOnRequest() async {
        let host = FakeHost()
        let a = host.add("a")
        host.selectedSession = a
        host.screens[a] = (["old", "PS C:\\> dir  ", "out", "", ""], 4)
        #expect(await handle(ControlRequest(cmd: .sessionText), host).result?.text == "PS C:\\> dir\nout")
        #expect(await handle(ControlRequest(cmd: .sessionText, args: ControlArgs(all: true)), host).result?.text == "old\nPS C:\\> dir\nout")
        #expect(await handle(ControlRequest(cmd: .sessionText, args: ControlArgs(lines: 1)), host).result?.text == "out")
    }

    @Test func fontCommandsStepThePointSize() async {
        let host = FakeHost()
        _ = await handle(ControlRequest(cmd: .fontInc), host)
        #expect(host.fontPoints == 12)
        _ = await handle(ControlRequest(cmd: .fontReset), host)
        #expect(host.fontPoints == NativeMenu.defaultPoints)
    }

    @Test func notifyNeedsABody() async {
        let host = FakeHost()
        host.selectedSession = host.add("a")
        #expect(await handle(ControlRequest(cmd: .notify, args: ControlArgs(title: "t")), host).error == "notify requires a body")
        #expect(await handle(ControlRequest(cmd: .notify, args: ControlArgs(title: "t", body: "done")), host).ok && host.notified.count == 1)
        host.bannersOff = true
        #expect(await handle(ControlRequest(cmd: .notify, args: ControlArgs(body: "done")), host).result?.text == ControlNotify.bannersOffNote)
    }

    @Test func versionAndUnsupportedCommands() async {
        let host = FakeHost()
        #expect(await handle(ControlRequest(cmd: .version), host).result?.app?.version == "1.2.3")
        #expect(await handle(ControlRequest(cmd: .sessionLead), host).error == "session.lead is not supported on Windows")
    }

    private func overlay(_ cmd: agtermCore.Command, _ host: FakeHost, target: String? = nil, _ args: ControlArgs? = nil) async -> ControlResponse {
        await handle(ControlRequest(cmd: cmd, target: target, args: args), host)
    }

    @Test func anOverlayOpensOverTheSessionAndReadsBackInTheTree() async {
        let host = FakeHost()
        let a = host.add("a")
        host.selectedSession = host.add("b")
        let open = await overlay(.sessionOverlayOpen, host, target: a.uuidString,
                                 ControlArgs(cwd: "C:\\src", command: "git log", wait: true, sizePercent: 60, color: "#102030"))
        #expect(open.ok && open.result?.id == a.uuidString)
        #expect(host.opened == [NativeOverlay.Open(command: "git log", cwd: "C:\\src", wait: true, sizePercent: 60, background: 0x102030)])
        #expect(host.selectedSession != a)
        let node = await handle(ControlRequest(cmd: .tree), host).result?.tree?.workspaces[0].sessions[0]
        #expect(node?.overlay == true && node?.overlaySizePercent == 60 && node?.hiddenOverlays == nil)
        #expect(await overlay(.sessionOverlayOpen, host, target: a.uuidString, ControlArgs(command: "dir")).error == "overlay already open")
    }

    @Test func followSelectsTheSessionAnOverlayOpensOver() async {
        let host = FakeHost()
        let a = host.add("a")
        host.selectedSession = host.add("b")
        _ = await overlay(.sessionOverlayOpen, host, target: a.uuidString, ControlArgs(command: "top", follow: true))
        #expect(host.selectedSession == a)
    }

    @Test func openRefusesWhatWindowsCannotShowBeforeTouchingASession() async {
        let host = FakeHost()
        let a = host.add("a")
        host.selectedSession = a
        #expect(await overlay(.sessionOverlayOpen, host, ControlArgs(command: "")).error == "session.overlay.open requires a command")
        #expect(await overlay(.sessionOverlayOpen, host, ControlArgs(markdownFile: "C:\\x.md")).error == NativeOverlay.pageRefusal)
        let html = await overlay(.sessionOverlayOpen, host, target: a.uuidString, ControlArgs(html: "C:\\page.html"))
        #expect(html.ok)
        #expect(host.openedPages.count == 1)
        #expect(await overlay(.sessionOverlayOpen, host, target: a.uuidString, ControlArgs(html: "C:\\page2.html")).error == "overlay already open")
        #expect(await overlay(.sessionOverlayOpen, host, ControlArgs(command: "x", pane: "right")).error == NativeOverlay.paneRefusal)
        #expect(await overlay(.sessionOverlayOpen, host, ControlArgs(command: "x", sizePercent: 50, width: 400)).error == NativeOverlay.pointsRefusal)
        #expect(await overlay(.sessionOverlayOpen, host, ControlArgs(command: "x", sizePercent: 0)).error
            == "session.overlay.open: --size-percent must be 1...100")
        #expect(await overlay(.sessionOverlayOpen, host, ControlArgs(command: "x", color: "red")).error == "invalid color: red (#rrggbb)")
        #expect(host.opened.isEmpty)
    }

    @Test func aServerSessionsOverlayNeedsAConnectedServer() async {
        let host = FakeHost()
        let server = ControlSessionNode(id: UUID().uuidString, name: "zsh", cwd: "~", active: false, split: false, backedByZmx: true)
        host.serverWorkspaces = [ControlWorkspaceNode(id: UUID().uuidString, name: "dev", active: false, sessions: [server])]
        #expect(await overlay(.sessionOverlayOpen, host, target: server.id, ControlArgs(command: "top")).error
            == NativeOverlay.serverDisconnectedRefusal)
    }

    @Test func aConnectedServerSessionAcceptsAProgramOverlay() async {
        let host = FakeHost()
        host.serverConnected = true
        let server = ControlSessionNode(id: UUID().uuidString, name: "zsh", cwd: "~", active: false, split: false, backedByZmx: true)
        host.serverWorkspaces = [ControlWorkspaceNode(id: UUID().uuidString, name: "dev", active: false, sessions: [server])]
        let open = await overlay(.sessionOverlayOpen, host, target: server.id, ControlArgs(command: "top", sizePercent: 50))
        #expect(open.ok && open.result?.id == server.id)
        #expect(host.opened == [NativeOverlay.Open(command: "top", cwd: nil, wait: false, sizePercent: 50, background: nil)])
    }

    @Test func resultIsRunningWhileOpenThenTheExitCode() async {
        let host = FakeHost()
        let a = host.add("a")
        host.selectedSession = a
        #expect(await overlay(.sessionOverlayResult, host).error == OverlayResultError.noResult)
        _ = await overlay(.sessionOverlayOpen, host, ControlArgs(command: "exit 3"))
        #expect(await overlay(.sessionOverlayResult, host).error == OverlayResultError.stillRunning)
        host.exitOverlay(a, code: 3)
        let result = await overlay(.sessionOverlayResult, host)
        #expect(result.ok && result.result?.exitCode == 3)
        _ = await overlay(.sessionOverlayOpen, host, ControlArgs(command: "exit 0"))
        _ = await overlay(.sessionOverlayClose, host)
        #expect(await overlay(.sessionOverlayResult, host).error == OverlayResultError.noResult)
    }

    @Test func closeResizeAndReadsNeedAnOpenOverlay() async {
        let host = FakeHost()
        let a = host.add("a")
        host.selectedSession = a
        for cmd: agtermCore.Command in [.sessionOverlayClose, .sessionOverlayText, .sessionOverlayCopy, .sessionOverlayHide] {
            #expect(await overlay(cmd, host).error == "no overlay")
        }
        #expect(await overlay(.sessionOverlayResize, host, ControlArgs(full: true)).error == "no overlay")
        _ = await overlay(.sessionOverlayOpen, host, ControlArgs(command: "less x", sizePercent: 50))
        #expect(await overlay(.sessionOverlayResize, host, ControlArgs(full: true)).ok)
        #expect(host.localStore.session(withID: a)?.overlaySizePercent == nil)
        #expect(await overlay(.sessionOverlayResize, host, ControlArgs(sizePercent: 70, full: true)).error
            == "session.overlay.resize: --full is mutually exclusive with --size-percent")
        #expect(await overlay(.sessionOverlayText, host).error == "overlay not realized")
        host.overlayScreens[a] = (["one", "two  ", ""], 2)
        #expect(await overlay(.sessionOverlayText, host).result?.text == "two")
        #expect(await overlay(.sessionOverlayText, host, ControlArgs(all: true)).result?.text == "one\ntwo")
        #expect(await overlay(.sessionOverlayCopy, host).error == "no selection")
        host.overlaySelections[a] = "picked"
        #expect(await overlay(.sessionOverlayCopy, host).result?.text == "picked")
        #expect(await overlay(.sessionOverlayClose, host).ok && host.localStore.session(withID: a)?.overlayActive == false)
    }

    @Test func hideShowAndToggleReportTheStateTheyLeft() async {
        let host = FakeHost()
        host.selectedSession = host.add("a")
        _ = await overlay(.sessionOverlayOpen, host, ControlArgs(command: "top"))
        #expect(await overlay(.sessionOverlayToggle, host).result?.text == "hidden")
        #expect(await handle(ControlRequest(cmd: .tree), host).result?.tree?.workspaces[0].sessions[0].hiddenOverlays == ["session"])
        #expect(await overlay(.sessionOverlayOpen, host, ControlArgs(command: "dir")).error == OverlayVisibilityError.hidden)
        #expect(await overlay(.sessionOverlayToggle, host).result?.text == "shown")
        #expect(await overlay(.sessionOverlayHide, host).result?.text == "hidden")
        #expect(await overlay(.sessionOverlayShow, host).result?.text == "shown")
    }

    @Test func resizeTextAndResultRefuseBadArgumentsBeforeTheSession() async {
        let host = FakeHost()
        host.selectedSession = host.add("a")
        _ = await overlay(.sessionOverlayOpen, host, ControlArgs(command: "top"))
        #expect(await overlay(.sessionOverlayResize, host).error == "session.overlay.resize requires --size-percent, --width/--height or --full")
        #expect(await overlay(.sessionOverlayResize, host, ControlArgs(sizePercent: 101)).error
            == "session.overlay.resize: --size-percent must be 1...100")
        #expect(await overlay(.sessionOverlayResize, host, ControlArgs(sizePercent: 50, pane: "left")).error == PaneOverlayError.resizeUnsupported)
        #expect(await overlay(.sessionOverlayText, host, ControlArgs(all: true, lines: 3)).error == "--all and --lines are exclusive")
        #expect(await overlay(.sessionOverlayText, host, ControlArgs(lines: 0)).error == "--lines must be positive")
        #expect(await overlay(.sessionOverlayResult, host, ControlArgs(page: UUID().uuidString)).error == OverlayHtmlError.unknownPage)
        #expect(await overlay(.sessionOverlayClose, host, ControlArgs(pane: "right")).error == NativeOverlay.paneRefusal)
        #expect(await overlay(.sessionOverlayResize, host, ControlArgs(sizePercent: 40)).ok && host.localStore.session(withID: host.localSessions[0].id)?.overlaySizePercent == 40)
    }

    @Test func overlayCommandsOnAServerSessionNeedAConnection() async {
        let host = FakeHost()
        let server = ControlSessionNode(id: UUID().uuidString, name: "zsh", cwd: "~", active: false, split: false, backedByZmx: true)
        host.serverWorkspaces = [ControlWorkspaceNode(id: UUID().uuidString, name: "dev", active: false, sessions: [server])]
        for cmd: agtermCore.Command in [.sessionOverlayClose, .sessionOverlayResult, .sessionOverlayText, .sessionOverlayToggle] {
            #expect(await overlay(cmd, host, target: server.id).error == NativeOverlay.serverDisconnectedRefusal)
        }
    }

    @Test func overlayCommandsOnAConnectedServerSessionMatchLocalOnes() async {
        let host = FakeHost()
        host.serverConnected = true
        let server = ControlSessionNode(id: UUID().uuidString, name: "zsh", cwd: "~", active: false, split: false, backedByZmx: true)
        host.serverWorkspaces = [ControlWorkspaceNode(id: UUID().uuidString, name: "dev", active: false, sessions: [server])]
        let id = UUID(uuidString: server.id)!
        #expect(await overlay(.sessionOverlayResult, host, target: server.id).error == OverlayResultError.noResult)
        _ = await overlay(.sessionOverlayOpen, host, target: server.id, ControlArgs(command: "exit 2", wait: true))
        #expect(await overlay(.sessionOverlayResult, host, target: server.id).error == OverlayResultError.stillRunning)
        host.exitServerOverlay(id, code: 2)
        let result = await overlay(.sessionOverlayResult, host, target: server.id)
        #expect(result.ok && result.result?.exitCode == 2)
        _ = await overlay(.sessionOverlayOpen, host, target: server.id, ControlArgs(command: "top"))
        #expect(await overlay(.sessionOverlayClose, host, target: server.id).ok)
    }

    @Test func anUnknownTargetIsRefusedAsForEveryCommand() async {
        let host = FakeHost()
        _ = host.add("a")
        #expect(await overlay(.sessionOverlayOpen, host, target: "ffffffff", ControlArgs(command: "top")).error == "no such session: ffffffff")
        #expect(host.opened.isEmpty)
    }

    @Test func closingTheSessionsOverlayKeepsTheSession() async {
        let host = FakeHost()
        let a = host.add("a")
        host.selectedSession = a
        _ = await overlay(.sessionOverlayOpen, host, ControlArgs(command: "top"))
        _ = await overlay(.sessionOverlayClose, host)
        #expect(host.closed.isEmpty && host.localSessions.map(\.id) == [a])
        #expect(await handle(ControlRequest(cmd: .tree), host).result?.tree?.workspaces[0].sessions[0].overlay == false)
    }

    @Test func splitTogglesAndReadsBackInTheTree() async {
        let host = FakeHost()
        let a = host.add("a")
        host.selectedSession = a
        #expect(await handle(ControlRequest(cmd: .sessionSplit, args: ControlArgs(axis: "horizontal")), host).ok)
        var node = NativeControl.tree(host).workspaces[0].sessions[0]
        #expect(node.split && node.hasSplit == true && node.splitAxis == "horizontal" && node.splitFocused == true && node.splitRatio == nil)
        #expect(await handle(ControlRequest(cmd: .sessionSplit, args: ControlArgs(mode: "off")), host).ok)
        node = NativeControl.tree(host).workspaces[0].sessions[0]
        #expect(!node.split && node.hasSplit == true)
        #expect(await handle(ControlRequest(cmd: .sessionSplit, args: ControlArgs(axis: "diagonal")), host).error == "invalid split axis: diagonal (vertical|horizontal)")
        #expect(await handle(ControlRequest(cmd: .sessionSplitClose), host).ok)
        #expect(NativeControl.tree(host).workspaces[0].sessions[0].hasSplit == nil)
        #expect(await handle(ControlRequest(cmd: .sessionSplitClose), host).ok)
    }

    @Test func focusResizeAndSwapNeedASplit() async {
        let host = FakeHost()
        host.selectedSession = host.add("a")
        #expect(await handle(ControlRequest(cmd: .sessionFocus), host).error == "session has no split")
        #expect(await handle(ControlRequest(cmd: .sessionSwap), host).error == "session has no split")
        _ = await handle(ControlRequest(cmd: .sessionSplit), host)
        #expect(await handle(ControlRequest(cmd: .sessionFocus, args: ControlArgs(pane: "left")), host).ok)
        #expect(host.localStore.session(withID: host.localSessions[0].id)?.splitFocused == false)
        #expect(await handle(ControlRequest(cmd: .sessionFocus), host).ok)
        #expect(host.localStore.session(withID: host.localSessions[0].id)?.splitFocused == true)
        #expect(await handle(ControlRequest(cmd: .sessionResize, args: ControlArgs(ratio: 0.99)), host).result?.ratio == 0.95)
        let grown = await handle(ControlRequest(cmd: .sessionResize, args: ControlArgs(ratioDelta: -0.2)), host).result?.ratio ?? 0
        #expect(abs(grown - 0.75) < 1e-9)
        #expect(await handle(ControlRequest(cmd: .sessionResize), host).error == "session.resize requires --split-ratio, --grow-left, or --grow-right")
        #expect(await handle(ControlRequest(cmd: .sessionSwap), host).ok && host.swaps == 1)
    }

    @Test func scratchShowsHidesAndACommandReplacesIt() async {
        let host = FakeHost()
        let a = host.add("a"), b = host.add("b")
        host.selectedSession = a
        #expect(await handle(ControlRequest(cmd: .sessionScratch, target: b.uuidString, args: ControlArgs(mode: "on")), host).ok)
        #expect(host.selectedSession == a && NativeControl.tree(host).workspaces[0].sessions[1].scratch)
        #expect(await handle(ControlRequest(cmd: .sessionScratch, target: b.uuidString, args: ControlArgs(mode: "on")), host).ok)
        #expect(host.scratchCommands.count == 1)
        _ = await handle(ControlRequest(cmd: .sessionScratch, target: b.uuidString, args: ControlArgs(mode: "on", command: "dir", follow: true)), host)
        #expect(host.scratchCommands.last == "dir" && host.selectedSession == b)
        #expect(await handle(ControlRequest(cmd: .sessionScratch, target: b.uuidString), host).ok)
        #expect(!NativeControl.tree(host).workspaces[0].sessions[1].scratch)
        #expect(await handle(ControlRequest(cmd: .sessionScratch, args: ControlArgs(mode: "up")), host).error == "invalid scratch mode: up")
    }

    @Test func typeAndTextTakeAPaneAndRefuseAnUnknownOne() async {
        let host = FakeHost()
        host.selectedSession = host.add("a")
        _ = await handle(ControlRequest(cmd: .sessionType, args: ControlArgs(text: "x", pane: "scratch")), host)
        _ = await handle(ControlRequest(cmd: .sessionType, args: ControlArgs(text: "x")), host)
        #expect(host.typedPanes == [.scratch, nil])
        #expect(await handle(ControlRequest(cmd: .sessionText, args: ControlArgs(pane: "middle")), host).error == "invalid pane: middle (left|right|scratch)")
    }

    @Test func aServerSessionsSplitAndScratchGoToItsServerWhileFocusAndRatioStayHere() async {
        let host = FakeHost()
        let served = scratchStore()
        served.ensureRoot()
        let row = try! #require(served.addSession(toWorkspace: served.rootWorkspace!.id, cwd: "", select: false))
        row.hasSplit = true
        row.isSplit = true
        let remote = NativeControl.remoteWindowID("Ubuntu")
        host.remotes[remote] = served
        host.serverWorkspaces = served.controlTree(paneForeground: { _ in nil }).workspaces
        let target = row.id.uuidString
        for cmd in [agtermCore.Command.sessionSplit, .sessionScratch, .sessionSwap, .sessionSplitClose] {
            #expect(await handle(ControlRequest(cmd: cmd, target: target), host).ok)
        }
        #expect(host.performed.map(\.0) == [.setSplit(row.id, shown: false, axis: nil), .setScratch(row.id, shown: true), .swap(row.id),
                                             .closeSplit(row.id)])
        #expect(host.performed.allSatisfy { $0.1 == remote })
        #expect(await handle(ControlRequest(cmd: .sessionFocus, target: target, args: ControlArgs(pane: "right")), host).ok)
        #expect(row.splitFocused && host.performed.count == 4)
        let resized = await handle(ControlRequest(cmd: .sessionResize, target: target, args: ControlArgs(ratio: 0.3)), host)
        #expect(resized.result?.ratio == 0.3 && row.splitRatio == 0.3)
        _ = await handle(ControlRequest(cmd: .sessionType, target: target, args: ControlArgs(text: "x", pane: "right")), host)
        #expect(host.typedPanes == [.split])
    }

    @Test func messagesGoBetweenLocalPanesWhileAServerRowIsRefused() async throws {
        let host = FakeHost()
        let panes = [UUID(), UUID()]
        let ids = [host.add("a"), host.add("b")]
        for (id, pane) in zip(ids, panes) { try #require(host.localStore.session(withID: id)).surface = PaneSurface(pane) }
        let sender = MessageAddress.canonical(session: ids[0], pane: panes[0])
        let receiver = MessageAddress.canonical(session: ids[1], pane: panes[1])

        let sent = await handle(ControlRequest(cmd: .msgSend, args: ControlArgs(body: "hi", recipients: ["\(ids[1].uuidString):left"],
                                                                               identity: sender)), host)
        #expect(sent.result?.delivered == [receiver])
        let node = NativeControl.tree(host).workspaces.flatMap(\.sessions).first { $0.id == ids[1].uuidString }
        #expect(node?.surfaces?.first { $0.paneID == panes[1].uuidString }?.pendingMessages == 1)
        let read = await handle(ControlRequest(cmd: .msgRead, args: ControlArgs(identity: receiver, ack: true)), host)
        #expect(read.result?.messages?.map(\.body) == ["hi"] && read.result?.messages?.first?.from == sender)
        let all = await handle(ControlRequest(cmd: .msgSend, args: ControlArgs(body: "all", all: true, identity: sender)), host)
        #expect(all.result?.delivered == [receiver])
        _ = await handle(ControlRequest(cmd: .msgRead, args: ControlArgs(identity: receiver, ack: true)), host)

        let served = scratchStore()
        let row = Session(initialCwd: "", remoteHost: "Ubuntu")
        served.workspaces[served.workspaces.count - 1].sessions.append(row)
        host.remotes[NativeControl.remoteWindowID("Ubuntu")] = served
        host.serverWorkspaces = served.controlTree(paneForeground: { _ in nil }).workspaces
        let refused = await handle(ControlRequest(cmd: .msgSend, args: ControlArgs(body: "x", recipients: ["\(row.id.uuidString):left"],
                                                                                  identity: sender)), host)
        #expect(refused.result?.rejected?.first?.detail == "remote session")
    }

    @Test func quickShowsPinnedTypesAndReadsBack() async {
        let host = FakeHost()
        #expect(await handle(ControlRequest(cmd: .quickType, args: ControlArgs(text: "x")), host).error == "quick terminal not open")
        #expect(await handle(ControlRequest(cmd: .quick, args: ControlArgs(mode: "show")), host).ok)
        #expect(await handle(ControlRequest(cmd: .quick, args: ControlArgs(mode: "show")), host).ok && host.quickShows == 2)
        #expect(NativeControl.tree(host).quickVisible == true)
        #expect(await handle(ControlRequest(cmd: .quickType, args: ControlArgs(text: "dir")), host).ok && host.quickTyped == ["dir"])
        host.quickScreen = (["a", "b", ""], 3)
        #expect(await handle(ControlRequest(cmd: .quickText), host).result?.text == "a\nb")
        #expect(await handle(ControlRequest(cmd: .quick), host).ok && !host.quickShown)
        #expect(await handle(ControlRequest(cmd: .quick, args: ControlArgs(mode: "open")), host).error == "invalid quick mode: open")
    }

    @Test func dashboardOpensOnSessionsAndPanesAndReadsBack() async {
        let host = FakeHost()
        let a = host.add("a"), b = host.add("b")
        host.selectedSession = a
        _ = await handle(ControlRequest(cmd: .sessionSplit), host)
        let reply = await handle(ControlRequest(cmd: .dashboard, args: ControlArgs(targets: [a.uuidString, "\(b.uuidString):right", "nope"], fontSize: 9)), host)
        #expect(reply.ok && reply.result?.text == "unresolved: \(b.uuidString):right, nope")
        let tree = NativeControl.tree(host)
        #expect(tree.dashboardMembers == ["\(a.uuidString):left", "\(a.uuidString):right"])
        #expect(tree.dashboardHighlighted == "\(a.uuidString):left" && tree.dashboardFontSize == 9 && tree.dashboardFontMode == "fixed")
        #expect(await handle(ControlRequest(cmd: .dashboard, args: ControlArgs(close: true)), host).ok && NativeControl.tree(host).dashboardMembers == nil)
        #expect(await handle(ControlRequest(cmd: .dashboard, args: ControlArgs(mru: true)), host).error == "no recent sessions")
        host.recentSessions = [b, a]
        _ = await handle(ControlRequest(cmd: .dashboard, args: ControlArgs(mru: true)), host)
        #expect(host.dashboard?.members.first?.session == b && host.dashboard?.members.count == 3)
        #expect(await handle(ControlRequest(cmd: .dashboard), host).error == "dashboard requires at least one session id")
        #expect(await handle(ControlRequest(cmd: .dashboard, args: ControlArgs(targets: ["x:up"])), host).error
            == "dashboard: invalid session id 'x:up' — use <id>, <id>:left, or <id>:right")
    }

    @Test func statusReadsBackWhileShownAndOmitsIdle() async {
        let host = FakeHost()
        let id = host.add("a")
        let set = ControlArgs(pane: "split", status: "blocked", blink: true, color: "#112233", shape: "star")
        #expect(await handle(ControlRequest(cmd: .sessionStatus, target: id.uuidString, args: set), host).ok)
        var node = NativeControl.tree(host).workspaces[0].sessions[0]
        #expect(node.status == "blocked" && node.statusBlink == true && node.statusColor == "#112233" && node.statusShape == "star")
        #expect(node.statusPane == "left" && node.statusChangedAt != nil)
        #expect(await handle(ControlRequest(cmd: .sessionStatus, target: id.uuidString, args: ControlArgs(status: "idle")), host).ok)
        node = NativeControl.tree(host).workspaces[0].sessions[0]
        #expect(node.status == nil && node.statusBlink == nil && node.statusColor == nil && node.statusPane == nil)
        #expect(node.statusChangedAt != nil && node.activePanes == [])
    }

    @Test func statusRefusesWhatAMacRefuses() async {
        let host = FakeHost()
        host.selectedSession = host.add("a")
        #expect(await handle(ControlRequest(cmd: .sessionStatus, args: ControlArgs(status: "busy")), host).error == "invalid status")
        #expect(await handle(ControlRequest(cmd: .sessionStatus, args: ControlArgs(status: "active", color: "red")), host).error
            == "invalid color (expected #rrggbb)")
        #expect(await handle(ControlRequest(cmd: .sessionStatus, args: ControlArgs(pane: "middle", status: "active")), host).error
            == "--pane must be left, right, or scratch")
        #expect(await handle(ControlRequest(cmd: .sessionStatus, args: ControlArgs(status: "active", sound: "Gong")), host).error?
            .hasPrefix("unknown sound: Gong (use 'default', 'beep', or one of: Basso,") == true)
        #expect(NativeControl.tree(host).workspaces[0].sessions[0].statusChangedAt == nil)
        #expect(await handle(ControlRequest(cmd: .sessionStatus, args: ControlArgs(status: "active", sound: "Glass")), host).ok)
    }

    @Test func contextAndInfoSetAndClear() async {
        let host = FakeHost()
        let id = host.add("a")
        let target = id.uuidString
        #expect(await handle(ControlRequest(cmd: .sessionContext, target: target, args: ControlArgs(text: " PR 12 ", mode: "set")), host).ok)
        let infoReply = await handle(ControlRequest(cmd: .sessionInfo, target: target, args: ControlArgs(text: "**3** tests", mode: "set",
                                                                                                        markdown: true)), host)
        #expect(infoReply.error == nil)
        var node = NativeControl.tree(host).workspaces[0].sessions[0]
        #expect(node.context == "PR 12" && node.info == "**3** tests" && node.infoMarkdown == true && node.infoHideAfter == 0)
        #expect(StatusGlyph.infoText(host.localSessions[0].info) == "3 tests")
        #expect(await handle(ControlRequest(cmd: .sessionContext, target: target, args: ControlArgs(mode: "set")), host).error
            == "session.context set requires text")
        #expect(await handle(ControlRequest(cmd: .sessionContext, target: target, args: ControlArgs(mode: "clear")), host).ok)
        #expect(await handle(ControlRequest(cmd: .sessionInfo, target: target, args: ControlArgs(mode: "clear")), host).ok)
        node = NativeControl.tree(host).workspaces[0].sessions[0]
        #expect(node.context == nil && node.info == nil && node.infoMarkdown == nil)
    }

    @Test func seenReachesTheHost() async {
        let host = FakeHost()
        let id = host.add("a")
        #expect(await handle(ControlRequest(cmd: .sessionSeen, target: id.uuidString), host).ok && host.seen == [id])
    }

    @Test func restoreModeSavesLiveAndRefusesRerunOnWindows() async {
        let host = FakeHost()
        let live = await handle(ControlRequest(cmd: .restoreMode, args: ControlArgs(mode: "live")), host)
        #expect(live.ok && host.restoreMode == .live)
        let rerun = await handle(ControlRequest(cmd: .restoreMode, args: ControlArgs(mode: "rerun")), host)
        #expect(!rerun.ok && host.restoreMode == .live)
        #expect(await handle(ControlRequest(cmd: .restoreMode), host).result?.restore?.configured == "live")
    }

    @Test func zmxKillEndsOnlyTheDaemonItsPaneClaims() async throws {
        let host = FakeHost()
        let id = host.add("a")
        let daemon = ZmxSupport.localDaemonName(for: try #require(host.localStore.session(withID: id)).paneIdentity)
        let stranger = ZmxSupport.localDaemonName(for: UUID())
        var calls: [[String]] = []
        host.zmxClient = ZmxClient(executablePath: #"C:\zmx.exe"#, socketDirectory: #"C:\zmx"#) { _, invocation in
            calls.append(invocation.arguments)
            if invocation.arguments == ["list"] { return (0, "name=\(daemon)\tclients=1\nname=\(stranger)\tclients=0\n") }
            return (0, "killed session \(invocation.arguments[1])\n")
        }
        let kill = { (pane: String) in
            await self.handle(ControlRequest(cmd: .zmxKill, target: id.uuidString, args: ControlArgs(force: true, pane: pane)), host)
        }
        #expect(await kill("left").ok)
        #expect(calls.last == ["kill", daemon, "--force"])
        #expect(await !kill("right").ok)
        #expect(!calls.contains { $0.contains(stranger) })
    }

    @Test func zmxCommandsWithoutZmxSayItIsUnavailable() async {
        let response = await handle(ControlRequest(cmd: .zmxList), FakeHost())
        #expect(!response.ok && response.error == "zmx is unavailable in this instance")
    }
}

/// pick.* and ask.* share the process-wide PickRegistry, SessionPickBook and AskRegistry, so they run one at a time.
@MainActor
@Suite(.serialized)
struct NativeInteractionTests {
    private func handle(_ request: ControlRequest, _ host: FakeHost) async -> ControlResponse {
        PickRegistry.shared.register(LocalWindow.id, controller: host.pickController)
        NativeStructure.wireOwners(host)
        return await NativeControl.handle(request, host: host, version: "1.2.3")
    }

    private func pickArgs(_ ids: [String]) -> ControlArgs {
        var args = ControlArgs()
        args.items = ids.map { ControlPickItem(id: $0, label: $0.uppercased()) }
        return args
    }

    private func askArgs(style: String? = nil) -> ControlArgs {
        var args = ControlArgs(buttons: [ControlAskButton(id: "yes", label: "Yes"), ControlAskButton(id: "no", label: "No")], title: "Go?")
        args.style = style
        return args
    }

    @Test func aPickFillsTheWindowSlotUntilItIsAnswered() async throws {
        let host = FakeHost()
        let opened = await handle(ControlRequest(cmd: .pickOpen, args: pickArgs(["a", "b"])), host)
        let id = try #require(opened.result?.id)
        #expect(host.pickController.pending?.id == id)
        #expect(host.interactionChanges == [false])
        #expect(await handle(ControlRequest(cmd: .pickOpen, args: pickArgs(["c"])), host).error == "pick already pending")
        #expect(await handle(ControlRequest(cmd: .pickResult, target: id), host).result?.pick?.result == .pending)

        host.pickController.resolve(ControlPickResult(result: .picked, id: "b", label: "B", index: 1))
        let result = try #require(await handle(ControlRequest(cmd: .pickResult, target: id), host).result?.pick)
        #expect(result.result == .picked)
        #expect(result.id == "b")
        #expect(await handle(ControlRequest(cmd: .pickCancel, target: id), host).ok)
    }

    @Test func pickCancelEndsThePendingPick() async throws {
        let host = FakeHost()
        let id = try #require(await handle(ControlRequest(cmd: .pickOpen, args: pickArgs(["a"])), host).result?.id)
        #expect(await handle(ControlRequest(cmd: .pickCancel, target: id), host).ok)
        #expect(host.pickController.pending == nil)
        #expect(await handle(ControlRequest(cmd: .pickResult, target: id), host).result?.pick?.result == .cancelled)
        #expect(await handle(ControlRequest(cmd: .pickResult, target: "nope"), host).error == "unknown pick: nope")
    }

    @Test func aSessionPickTakesTheSlotAndEndsWithItsSession() async throws {
        let host = FakeHost()
        let session = host.add("api")
        let id = try #require(await handle(ControlRequest(cmd: .pickOpen, target: session.uuidString, args: pickArgs(["a"])), host).result?.id)
        #expect(host.pickController.pending?.id == id)
        #expect(await handle(ControlRequest(cmd: .pickOpen, target: UUID().uuidString, args: pickArgs(["a"])), host).ok == false)
        SessionPickBook.shared.sessionEnded(session)
        host.pickController.cancel()
        #expect(await handle(ControlRequest(cmd: .pickResult, target: id), host).result?.pick?.result == .cancelled)
    }

    @Test func aTerminalAskFillsItsSessionsSlotAndReportsTheAnswer() async throws {
        let host = FakeHost()
        let id = host.add("api")
        host.selectedSession = id
        let opened = await handle(ControlRequest(cmd: .askOpen, target: id.uuidString, args: askArgs()), host)
        let ask = try #require(opened.result?.id)
        let session = try #require(host.localStore.session(withID: id))
        #expect(session.askPending?.id == ask)
        #expect(host.pickController.pendingAsk == nil)
        #expect(await handle(ControlRequest(cmd: .askOpen, target: id.uuidString, args: askArgs()), host).error == "ask already pending")
        #expect(await handle(ControlRequest(cmd: .askResult, target: ask), host).result?.ask?.result == .pending)

        _ = session.answerAsk(id: ask, buttonAt: 1)
        let result = try #require(await handle(ControlRequest(cmd: .askResult, target: ask), host).result?.ask)
        #expect(result.result == .answered)
        #expect(result.id == "no")
    }

    @Test func aGuiAskNeedsItsSessionInViewAndGoesToTheWindowSlot() async throws {
        let host = FakeHost()
        let id = host.add("api")
        let hidden = await handle(ControlRequest(cmd: .askOpen, target: id.uuidString, args: askArgs(style: "gui")), host)
        #expect(hidden.error == "session not visible")

        host.selectedSession = id
        let ask = try #require(await handle(ControlRequest(cmd: .askOpen, target: id.uuidString, args: askArgs(style: "gui")), host).result?.id)
        #expect(host.pickController.pendingAsk?.id == ask)
        #expect(host.pickController.pendingAsk?.anchor?.sessionID == id)
        #expect(await handle(ControlRequest(cmd: .pickOpen, args: pickArgs(["a"])), host).error == "ask already pending")
        #expect(await handle(ControlRequest(cmd: .askCancel, target: ask), host).ok)
        #expect(host.pickController.pendingAsk == nil)
        #expect(await handle(ControlRequest(cmd: .askResult, target: ask), host).result?.ask?.result == .cancelled)
    }

    @Test func anUnanchoredGuiAskOpensWithNoSession() async throws {
        let host = FakeHost()
        let ask = try #require(await handle(ControlRequest(cmd: .askOpen, args: askArgs(style: "gui")), host).result?.id)
        #expect(host.pickController.pendingAsk?.id == ask)
        #expect(host.pickController.pendingAsk?.anchor == nil)
        host.pickController.cancelAsk()
    }

    @Test func aNamedWindowOtherThanThisOneIsRefused() async {
        let host = FakeHost()
        var args = pickArgs(["a"])
        args.window = "nowhere"
        #expect(await handle(ControlRequest(cmd: .pickOpen, args: args), host).ok == false)
        #expect(host.pickController.pending == nil)
    }

    @Test func theTreeReportsTheWindowSlotAndASessionsAsk() async throws {
        let host = FakeHost()
        let id = host.add("api")
        host.selectedSession = id
        let ask = try #require(await handle(ControlRequest(cmd: .askOpen, target: id.uuidString, args: askArgs()), host).result?.id)
        let pick = try #require(await handle(ControlRequest(cmd: .pickOpen, args: pickArgs(["a"])), host).result?.id)
        let tree = try #require(await handle(ControlRequest(cmd: .tree), host).result?.tree)
        #expect(tree.pickPending == pick)
        #expect(tree.workspaces.flatMap(\.sessions).first { $0.id == id.uuidString }?.ask?.id == ask)
        host.pickController.cancel()
        host.localStore.session(withID: id)?.cancelPendingAsk()
    }
}
