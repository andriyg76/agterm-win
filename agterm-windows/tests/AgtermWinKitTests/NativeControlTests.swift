import AgtermWinKit
import Foundation
import Testing
import agtermCore

@MainActor
private final class FakeHost: NativeControlHost {
    var localSessions: [NativeControl.Local] = []
    var selectedSession: UUID?
    var serverWorkspaces: [ControlWorkspaceNode] = []
    var typed: [(String, UUID)] = []
    var renamed: [(UUID, String)] = []
    var closed: [UUID] = []
    var serverCreates = 0
    var notified: [UUID] = []
    var fontPoints: Float = 11
    var screens: [UUID: (lines: [String], rows: Int)] = [:]

    func add(_ name: String, command: String = "cmd.exe") -> UUID {
        let id = UUID()
        localSessions.append(NativeControl.Local(id: id, name: name, commandLine: command, exited: false, attention: false))
        return id
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

    var cwds: [String?] = []
    func newLocalSession(name: String?, command: String?, cwd: String?, select: Bool) -> UUID? {
        cwds.append(cwd)
        let id = add(name ?? "Windows PowerShell", command: command ?? "powershell.exe")
        if select { selectedSession = id }
        return id
    }

    func newServerSession() async -> ControlResponse {
        serverCreates += 1
        return ControlResponse(ok: true)
    }

    func closeSession(_ id: UUID) async -> ControlResponse {
        closed.append(id)
        return ControlResponse(ok: true)
    }

    func renameSession(_ id: UUID, to name: String) async -> ControlResponse {
        renamed.append((id, name))
        return ControlResponse(ok: true)
    }

    func restartSession(_ id: UUID) async -> ControlResponse { ControlResponse(ok: true) }
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
        editLocal(id) { applied = $0.activity.apply(update, hasSplit: $0.split != nil) }
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

    var wslServers = [ControlWSLServer(distribution: "Ubuntu", started: false, connected: false, launch: nil)]
    var startRefusal: String?
    func startWSLServer(_ distribution: String) -> String? {
        guard startRefusal == nil else { return startRefusal }
        wslServers = wslServers.map {
            $0.distribution == distribution ? ControlWSLServer(distribution: distribution, started: true, connected: false, launch: $0.launch) : $0
        }
        return nil
    }
    func setWSLLaunch(_ distribution: String, atLaunch: Bool) {
        wslServers = wslServers.map {
            $0.distribution == distribution ? ControlWSLServer(distribution: distribution, started: $0.started, connected: $0.connected,
                                                               launch: atLaunch ? "atLaunch" : "manual") : $0
        }
    }
    var settingsTabs: [SettingsTab] = []
    func openSettings(tab: SettingsTab) { settingsTabs.append(tab) }

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
        editLocal(id) { $0.htmlOverlay = overlay; $0.pageOverlaySizePercent = sizePercent }
    }

    func openOverlay(_ id: UUID, _ open: NativeOverlay.Open) {
        opened.append(open)
        if isServerSession(id) {
            serverOverlays[id] = NativeOverlay(sizePercent: open.sizePercent, wait: open.wait)
            serverOverlayExitCodes.removeValue(forKey: id)
            return
        }
        editLocal(id) {
            $0.overlay = NativeOverlay(sizePercent: open.sizePercent, wait: open.wait)
            $0.overlayExitCode = nil
        }
    }

    func closeOverlay(_ id: UUID) {
        if isServerSession(id) {
            serverOverlays.removeValue(forKey: id)
            serverOverlayExitCodes.removeValue(forKey: id)
        } else { editLocal(id) { $0.overlay = nil } }
    }

    func resizeOverlay(_ id: UUID, sizePercent: Int?) {
        if var overlay = serverOverlays[id] { overlay.sizePercent = sizePercent; serverOverlays[id] = overlay }
        else { editLocal(id) { $0.overlay?.sizePercent = sizePercent } }
    }

    func setOverlayHidden(_ id: UUID, _ hidden: Bool) {
        if var overlay = serverOverlays[id] { overlay.hidden = hidden; serverOverlays[id] = overlay }
        else { editLocal(id) { $0.overlay?.hidden = hidden } }
    }
    func overlayScreen(of id: UUID) -> (lines: [String], rows: Int)? { overlayScreens[id] }
    func overlaySelection(of id: UUID) -> String? { overlaySelections[id] }

    /// exitOverlay is the overlay's program ending without `--wait`, which closes it.
    func setSplit(_ id: UUID, _ split: NativeSplit) { editLocal(id) { $0.split = split } }
    func closeSplit(_ id: UUID) { editLocal(id) { $0.split = nil } }
    var swaps = 0
    func swapPanes(_ id: UUID) { swaps += 1 }
    var scratchCommands: [String?] = []
    func setScratch(_ id: UUID, shown: Bool, command: String?) {
        scratchCommands.append(command)
        editLocal(id) {
            $0.scratch = shown
            $0.scratchRunning = true
        }
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

    var sidebarWidthPoints: Double = AppStore.sidebarWidthDefault
    func setSidebarWidth(points: Double) { sidebarWidthPoints = AppStore.clampSidebarWidth(points) }

    var noticeBar = NoticeBar.State()
    func setNoticePosition(_ position: NoticeBar.Position) { noticeBar.position = position }
    func dismissNotice() -> Bool { noticeBar.dismissShown() }

    func exitOverlay(_ id: UUID, code: Int) {
        editLocal(id) {
            $0.overlay = nil
            $0.overlayExitCode = code
        }
    }

    func exitServerOverlay(_ id: UUID, code: Int) {
        serverOverlays.removeValue(forKey: id)
        serverOverlayExitCodes[id] = code
    }
}

@MainActor
struct NativeControlTests {
    private func handle(_ request: ControlRequest, _ host: FakeHost) async -> ControlResponse {
        await NativeControl.handle(request, host: host, version: "1.2.3")
    }

    #if os(Windows)
    @Test func wslStartAndLaunchAnswerWithEveryServer() async {
        let host = FakeHost()
        #expect(await handle(ControlRequest(cmd: .wslList), host).result?.wsl == host.wslServers)
        let started = await handle(ControlRequest(cmd: .wslStart, args: ControlArgs(name: "ubuntu")), host)
        #expect(started.ok && started.result?.wsl?.first?.started == true)
        let launch = await handle(ControlRequest(cmd: .wslLaunch, args: ControlArgs(name: "Ubuntu", mode: "off")), host)
        #expect(launch.result?.wsl?.first?.launch == "manual")
        #expect(await handle(ControlRequest(cmd: .tree), host).result?.tree?.wslServers == host.wslServers)
    }

    @Test func wslRefusesAnUnknownDistributionAndPassesAStartRefusalOn() async {
        let host = FakeHost()
        #expect(await handle(ControlRequest(cmd: .wslStart, args: ControlArgs(name: "Arch")), host).error == "no WSL distribution named Arch")
        #expect(await handle(ControlRequest(cmd: .wslLaunch, args: ControlArgs(name: "Ubuntu")), host).error == "wsl.launch requires on or off")
        host.startRefusal = "asking"
        #expect(await handle(ControlRequest(cmd: .wslStart, args: ControlArgs(name: "Ubuntu")), host).error == "asking")
    }

    @Test func noticeCommandsMoveAndDismissAndAnswerWithTheBar() async {
        let host = FakeHost()
        host.noticeBar.update([NoticeBar.Message(source: "Ubuntu", text: "WSL Ubuntu: install failed", severity: .error, actions: [.retry, .openLog])])
        let moved = await handle(ControlRequest(cmd: .noticePosition, args: ControlArgs(mode: "bottom")), host)
        #expect(moved.result?.noticeBar?.position == "bottom" && host.noticeBar.position == .bottom)
        #expect(await handle(ControlRequest(cmd: .noticePosition, args: ControlArgs(mode: "left")), host).error
            == "notice.position requires top or bottom")
        let dismissed = await handle(ControlRequest(cmd: .noticeDismiss), host)
        #expect(dismissed.result?.noticeBar?.notices == [ControlNotice(text: "WSL Ubuntu: install failed", severity: "error",
                                                                     actions: ["retry", "openLog"], dismissed: true)])
        #expect(await handle(ControlRequest(cmd: .noticeDismiss), host).error == "no notice shown")
        #expect(await handle(ControlRequest(cmd: .tree), host).result?.tree?.noticeBar == host.noticeBar.control)
        #expect(await handle(ControlRequest(cmd: .noticeList), host).result?.noticeBar == host.noticeBar.control)
    }
    #endif

    @Test func treeListsLocalSessionsAheadOfTheServersWorkspaces() async {
        let host = FakeHost()
        let shell = host.add("Windows PowerShell")
        host.selectedSession = shell
        let server = ControlSessionNode(id: UUID().uuidString, name: "zsh", cwd: "~", active: false, split: false, backedByZmx: true)
        host.serverWorkspaces = [ControlWorkspaceNode(id: UUID().uuidString, name: "dev", active: false, sessions: [server])]
        let tree = try! #require(await handle(ControlRequest(cmd: .tree), host).result?.tree)
        #expect(tree.workspaces.map(\.name) == ["Local", "dev"])
        #expect(tree.workspaces[0].sessions.map(\.name) == ["Windows PowerShell"])
        #expect(tree.workspaces[0].sessions[0].active && tree.workspaces[0].active)
        #expect(tree.workspaces[0].sessions[0].restoreCommand == "cmd.exe")
    }

    @Test func treeHasNoLocalGroupWithoutLocalSessions() async {
        let host = FakeHost()
        #expect(await handle(ControlRequest(cmd: .tree), host).result?.tree?.workspaces.isEmpty == true)
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

    #if os(Windows)
    @Test func settingsOpenShowsTheNamedTab() async {
        let host = FakeHost()
        #expect(await handle(ControlRequest(cmd: .settingsOpen, args: ControlArgs(name: "appearance")), host).result?.text == "appearance")
        #expect(await handle(ControlRequest(cmd: .settingsOpen), host).result?.text == "general")
        #expect(await handle(ControlRequest(cmd: .settingsOpen, args: ControlArgs(name: "keys")), host).error
            == "unknown settings tab: keys (general|appearance|notifications)")
        #expect(host.settingsTabs == [.appearance, .general])
    }
    #endif

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
        host.localSessions = [NativeControl.Local(id: UUID(), name: "agterm", commandLine: "pwsh.exe", exited: false, attention: false,
                                                  cwd: #"C:\dev\agterm"#, title: "vim")]
        let session = try! #require(await handle(ControlRequest(cmd: .tree), host).result?.tree?.workspaces.first?.sessions.first)
        #expect(session.cwd == #"C:\dev\agterm"# && session.title == "vim")
    }

    @Test func newSessionStartsLocallyUnlessTheWorkspaceIsTheServers() async {
        let host = FakeHost()
        let workspace = UUID()
        host.serverWorkspaces = [ControlWorkspaceNode(id: workspace.uuidString, name: "dev", active: false, sessions: [])]
        let local = await handle(ControlRequest(cmd: .sessionNew, args: ControlArgs(name: "logs", cwd: #"C:\dev"#, command: "cmd.exe /k")), host)
        #expect(host.cwds == [#"C:\dev"#])
        #expect(local.ok && host.localSessions.map(\.name) == ["logs"] && host.selectedSession?.uuidString == local.result?.id)
        #expect(await handle(ControlRequest(cmd: .sessionNew, args: ControlArgs(workspace: "dev-no")), host).error == "no such workspace: dev-no")
        #expect(await handle(ControlRequest(cmd: .sessionNew, args: ControlArgs(workspace: workspace.uuidString)), host).ok)
        #expect(host.serverCreates == 1)
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
        #expect(host.localSessions[0].overlay?.sizePercent == nil)
        #expect(await overlay(.sessionOverlayResize, host, ControlArgs(sizePercent: 70, full: true)).error
            == "session.overlay.resize: --full is mutually exclusive with --size-percent")
        #expect(await overlay(.sessionOverlayText, host).error == "overlay not realized")
        host.overlayScreens[a] = (["one", "two  ", ""], 2)
        #expect(await overlay(.sessionOverlayText, host).result?.text == "two")
        #expect(await overlay(.sessionOverlayText, host, ControlArgs(all: true)).result?.text == "one\ntwo")
        #expect(await overlay(.sessionOverlayCopy, host).error == "no selection")
        host.overlaySelections[a] = "picked"
        #expect(await overlay(.sessionOverlayCopy, host).result?.text == "picked")
        #expect(await overlay(.sessionOverlayClose, host).ok && host.localSessions[0].overlay == nil)
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
        #expect(await overlay(.sessionOverlayResize, host, ControlArgs(sizePercent: 40)).ok && host.localSessions[0].overlay?.sizePercent == 40)
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
        #expect(node.split && node.hasSplit == true && node.splitAxis == "horizontal" && node.splitFocused == true && node.splitRatio == 0.5)
        #expect(await handle(ControlRequest(cmd: .sessionSplit, args: ControlArgs(mode: "off")), host).ok)
        node = NativeControl.tree(host).workspaces[0].sessions[0]
        #expect(!node.split && node.hasSplit == true)
        #expect(await handle(ControlRequest(cmd: .sessionSplit, args: ControlArgs(axis: "diagonal")), host).error == "invalid split axis: diagonal (vertical|horizontal)")
        #expect(await handle(ControlRequest(cmd: .sessionSplitClose), host).ok)
        #expect(NativeControl.tree(host).workspaces[0].sessions[0].hasSplit == false)
        #expect(await handle(ControlRequest(cmd: .sessionSplitClose), host).ok)
    }

    @Test func focusResizeAndSwapNeedASplit() async {
        let host = FakeHost()
        host.selectedSession = host.add("a")
        #expect(await handle(ControlRequest(cmd: .sessionFocus), host).error == "session has no split")
        #expect(await handle(ControlRequest(cmd: .sessionSwap), host).error == "session has no split")
        _ = await handle(ControlRequest(cmd: .sessionSplit), host)
        #expect(await handle(ControlRequest(cmd: .sessionFocus, args: ControlArgs(pane: "left")), host).ok)
        #expect(host.localSessions[0].split?.focused == false)
        #expect(await handle(ControlRequest(cmd: .sessionFocus), host).ok)
        #expect(host.localSessions[0].split?.focused == true)
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

    @Test func aServerSessionsPanesAreRefused() async {
        let host = FakeHost()
        let server = ControlSessionNode(id: UUID().uuidString, name: "zsh", cwd: "~", active: false, split: false, backedByZmx: true)
        host.serverWorkspaces = [ControlWorkspaceNode(id: UUID().uuidString, name: "dev", active: false, sessions: [server])]
        for cmd in [agtermCore.Command.sessionSplit, .sessionScratch, .sessionFocus, .sessionSwap] {
            #expect(await handle(ControlRequest(cmd: cmd, target: server.id), host).error == NativeControl.serverPanesRefusal)
        }
        #expect(await handle(ControlRequest(cmd: .sessionType, target: server.id, args: ControlArgs(text: "x", pane: "right")), host).error
            == NativeControl.serverPanesRefusal)
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
        #expect(await handle(ControlRequest(cmd: .sessionInfo, target: target, args: ControlArgs(text: "**3** tests", mode: "set",
                                                                                                   markdown: true)), host).ok)
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
}
