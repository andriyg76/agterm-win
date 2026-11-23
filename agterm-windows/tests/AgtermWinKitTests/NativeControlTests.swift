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

    func newLocalSession(name: String?, command: String?, select: Bool) -> UUID? {
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

    func type(_ text: String, into id: UUID) -> Bool {
        typed.append((text, id))
        return true
    }

    func screen(of id: UUID) -> (lines: [String], rows: Int)? { screens[id] }
    var bannersOff = false
    func notify(_ id: UUID, title: String, body: String) -> String? {
        notified.append(id)
        return bannersOff ? ControlNotify.bannersOffNote : nil
    }
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
}

@MainActor
struct NativeControlTests {
    private func handle(_ request: ControlRequest, _ host: FakeHost) async -> ControlResponse {
        await NativeControl.handle(request, host: host, version: "1.2.3")
    }

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
        let local = await handle(ControlRequest(cmd: .sessionNew, args: ControlArgs(name: "logs", command: "cmd.exe /k")), host)
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
        #expect(await handle(ControlRequest(cmd: .sessionSplit), host).error == "session.split is not supported on Windows")
    }
}
