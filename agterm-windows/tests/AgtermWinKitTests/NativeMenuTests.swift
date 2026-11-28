import AgtermWinKit
import Testing

struct NativeMenuTests {
    private let profiles = [LaunchProfile(name: "Windows PowerShell", commandLine: "powershell.exe"),
                            LaunchProfile(name: "WSL Ubuntu", commandLine: "wsl.exe -d Ubuntu")]

    @Test func terminalMenuEnablesCopyAndPasteByState() {
        let menu = NativeMenu.terminal(hasSelection: false, canPaste: true)
        #expect(menu.first { $0.pick == .command(.copy) }?.enabled == false)
        #expect(menu.first { $0.pick == .command(.paste) }?.enabled == true)
        #expect(NativeMenu.terminal(hasSelection: true, canPaste: false).first { $0.pick == .command(.copy) }?.enabled == true)
        #expect(!menu.contains { $0.pick == .command(.quit) || $0.pick == .command(.closeSession) })
    }

    @Test func windowMenuOffersEveryProfileUnderNewSession() {
        let menu = NativeMenu.window(profiles: profiles, canCloseSession: false, sessionCount: 1, hasSelection: false, canPaste: false)
        let newSession = menu.first { $0.title == "New Session" }!
        #expect(newSession.title == "New Session")
        #expect(newSession.children.map(\.title) == ["Windows PowerShell", "WSL Ubuntu"])
        #expect(newSession.children.map(\.pick) == [.profile(0), .profile(1)])
        #expect(newSession.children.map(\.shortcut) == ["Ctrl+N", ""])
        #expect(menu.first { $0.pick == .command(.closeSession) }?.enabled == false)
        #expect(menu.first { $0.pick == .command(.nextSession) }?.enabled == false)
        #expect(menu.last?.pick == .command(.quit))
    }

    @Test func fileGroupsWorkspaceAndCompanionActionsAndOwnsSettings() {
        let state = NativeMenu.Structure(workspace: true, flagged: false, canConvert: true)
        let file = NativeMenu.file(profiles: profiles, canCloseSession: true, structure: state)
        #expect(file.prefix(3).map(\.pick) == [.command(.newWorkspace), .command(.renameWorkspace), .command(.deleteWorkspace)])
        #expect(file.first { $0.pick == .command(.newCompanion) }?.enabled == true)
        #expect(file.first { $0.pick == .command(.convertCompanion) }?.enabled == true)
        #expect(file.last?.title == "Settings")
        #expect(file.last?.children.compactMap(\.pick) == [.command(.settings), .command(.editKeymap), .command(.editProfiles), .command(.reloadKeymap)])
        #expect(!file.contains { $0.pick == .command(.copy) || $0.pick == .command(.nextSession) })
    }

    @Test func editAndHelpOwnTheirActions() {
        let edit = NativeMenu.edit(hasSelection: true, canPaste: true)
        #expect(edit.compactMap(\.pick) == [.command(.copy), .command(.paste), .command(.selectAll), .command(.clearScrollback)])
        #expect(NativeMenu.help().map(\.title) == ["About"])
        #expect(NativeMenu.help().compactMap(\.pick) == [.command(.about)])
    }

    @Test func picksRoundTripThroughMenuIDs() {
        for pick in NativeMenu.Command.allCases.map(NativeMenu.Pick.command) + [.profile(0), .profile(7), .defaultProfile(2), .startServer(0), .startServer(5), .serverSession(0), .serverSession(3), .sidebarSession] {
            #expect(NativeMenu.Pick(id: pick.id) == pick)
        }
        #expect(NativeMenu.Pick(id: 0) == nil)
    }

    @Test func localSidebarOffersLocalLaunchWithoutSessionActionsOnTheWorkspace() {
        let menu = NativeMenu.sidebar(profiles: profiles, defaultProfile: 1, servers: [], destination: nil,
                                       canLaunch: true, canRename: nil, canRestart: false, canClose: false)
        #expect(menu.map(\.title) == ["New Local Session", "Local Profiles", "Default Local Profile"])
        #expect(menu.first?.pick == .sidebarSession && menu.first?.enabled == true)
        #expect(menu[1].children.map(\.pick) == [.profile(0), .profile(1)])
        #expect(menu[2].children.map(\.checked) == [false, true])
    }

    @Test func serverSidebarKeepsLocalProfilesInElsewhereAndDisablesDisconnectedLaunch() {
        let servers = [NativeMenu.Server(label: "WSL Ubuntu", started: true, connected: true),
                       NativeMenu.Server(label: "WSL Debian", started: true), NativeMenu.Server(label: "WSL Arch")]
        let menu = NativeMenu.sidebar(profiles: profiles, defaultProfile: 0, servers: servers, destination: "WSL Debian / API",
                                       canLaunch: false, canRename: false, canRestart: false, canClose: false)
        #expect(menu.first?.title == "New Session in WSL Debian / API")
        #expect(menu.first?.pick == .sidebarSession && menu.first?.enabled == false)
        #expect(!menu.contains { $0.title == "Local Profiles" })
        let elsewhere = menu.first { $0.title == "New Session Elsewhere" }?.children ?? []
        #expect(elsewhere.first?.children.map(\.pick) == [.profile(0), .profile(1)])
        #expect(elsewhere.first { $0.pick == .serverSession(0) }?.enabled == true)
        #expect(elsewhere.first { $0.pick == .serverSession(1) }?.enabled == false)
        #expect(elsewhere.last?.children.last?.pick == .startServer(2))
        #expect(menu.last?.pick == .command(.closeSession) && menu.last?.enabled == false)
    }

    @Test func everyCommandNamesItsShortcut() {
        #expect(NativeMenu.Command.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(NativeMenu.Command.allCases.filter { $0.shortcut.isEmpty } == [.clearScrollback, .newServerSession, .renameSession, .restartSession, .editKeymap, .reloadKeymap,
                                                                                      .toggleHorizontalSplit, .closeSplit, .swapPanes, .toggleScratch,
                                                                                      .newWorkspace, .renameWorkspace, .deleteWorkspace, .toggleFlag, .toggleFlaggedView,
                                                                                      .focusWorkspace, .toggleWorkspaceFilter, .previousWorkspace, .nextWorkspace,
                                                                                      .newCompanion, .convertCompanion, .selectTheme, .about, .toggleSidebar, .editProfiles,
                                                                                      .copyName, .revealSession, .expandWorkspaces, .collapseWorkspaces,
                                                                                      .toggleWorkspaceCollapse])
    }

    @Test func revealSitsBeforeCloseOnTheRowAndInTheFileMenu() {
        let row = NativeMenu.sidebar(profiles: profiles, defaultProfile: 0, servers: [], destination: nil, canLaunch: true,
                                     canRename: true, canRestart: false, canClose: true, canReveal: true)
        #expect(Array(row.compactMap(\.pick).suffix(2)) == [.command(.revealSession), .command(.closeSession)])
        #expect(row.first { $0.pick == .command(.revealSession) }?.enabled == true)
        let file = NativeMenu.file(profiles: profiles, canCloseSession: true).compactMap { $0.pick == .command(.revealSession) ? $0 : nil }
        #expect(file.count == 1 && file.first?.enabled == false)
    }

    @Test func workspaceFoldIsTitledForWhatItDoesAndNeedsWorkspaceRows() {
        var structure = NativeMenu.Structure(workspace: true)
        structure.workspaceRows = true
        structure.collapsed = true
        let view = NativeMenu.view(NativeMenu.View(), structure: structure)
        #expect(view.first { $0.pick == .command(.toggleWorkspaceCollapse) }?.title == "Expand Workspace")
        let bulk = view.filter { $0.pick == .command(.expandWorkspaces) || $0.pick == .command(.collapseWorkspaces) }.map(\.enabled)
        #expect(bulk == [true, true])
        let row = NativeMenu.structure(structure).first { $0.pick == .command(.toggleWorkspaceCollapse) }
        #expect(row?.title == "Expand Workspace" && row?.enabled == true)
        structure.collapsed = false
        structure.workspaceRows = false
        let flat = NativeMenu.view(NativeMenu.View(), structure: structure)
        let fold = flat.first { $0.pick == .command(.toggleWorkspaceCollapse) }
        #expect(fold?.title == "Collapse Workspace" && fold?.enabled == false)
        #expect(flat.first { $0.pick == .command(.expandWorkspaces) }?.enabled == false)
    }

    @Test func fullScreenIsTitledForWhatItDoesOnF11() {
        var view = NativeMenu.View()
        let enter = NativeMenu.view(view).first { $0.pick == .command(.toggleFullscreen) }
        #expect(enter?.title == "Enter Full Screen" && enter?.shortcut == "F11")
        view.fullscreen = true
        #expect(NativeMenu.view(view).first { $0.pick == .command(.toggleFullscreen) }?.title == "Exit Full Screen")
    }

    @Test func copyNameFollowsRenameOnSessionAndWorkspaceRows() {
        let session = NativeMenu.sidebar(profiles: profiles, defaultProfile: 0, servers: [], destination: nil,
                                         canLaunch: true, canRename: true, canRestart: true, canClose: true).compactMap(\.pick)
        let rename = try! #require(session.firstIndex(of: .command(.renameSession)))
        #expect(session[rename + 1] == .command(.copyName))
        let named = NativeMenu.structure(NativeMenu.Structure(workspace: true))
        let index = try! #require(named.firstIndex { $0.pick == .command(.renameWorkspace) })
        #expect(named[index + 1].pick == .command(.copyName) && named[index + 1].enabled)
        #expect(NativeMenu.structure(NativeMenu.Structure(workspace: false)).first { $0.pick == .command(.copyName) }?.enabled == false)
        #expect(!NativeMenu.structure(NativeMenu.Structure(flagged: false)).contains { $0.pick == .command(.copyName) })
    }

    @Test func viewOwnsDisplayActionsAndNavigateOwnsSessionAndPaneMovement() {
        let state = NativeMenu.View(canSplit: true, hasSplit: true, scratchShown: true, canDashboard: true)
        let view = NativeMenu.view(state)
        #expect(view.first { $0.pick == .command(.toggleSplit) }?.shortcut == "Ctrl+Shift+D")
        #expect(view.first { $0.pick == .command(.toggleScratch) }?.checked == true)
        #expect(view.contains { $0.pick == .command(.find) })
        #expect(view.first { $0.pick == .command(.toggleSidebar) }?.title == "Hide Sidebar")
        #expect(NativeMenu.view(.init(sidebarVisible: false)).first { $0.pick == .command(.toggleSidebar) }?.title == "Show Sidebar")
        #expect(view.contains { $0.pick == .command(.selectTheme) })
        #expect(!view.contains { $0.pick == .command(.dashboard) || $0.pick == .command(.focusRightPane) })
        let nav = NativeMenu.navigate(state, sessionCount: 2)
        for command: NativeMenu.Command in [.dashboard, .focusRightPane, .previousSession, .nextSession] {
            #expect(nav.first { $0.pick == .command(command) }?.enabled == true)
        }
        #expect(!nav.contains { $0.pick == .command(.find) })
        #expect(NativeMenu.view(.init()).first { $0.pick == .command(.toggleSplit) }?.enabled == false)
    }

    @Test func fontStepsStayInRange() {
        #expect(NativeMenu.points(after: .fontBigger, from: 11) == 12)
        #expect(NativeMenu.points(after: .fontBigger, from: 36) == 36)
        #expect(NativeMenu.points(after: .fontSmaller, from: 6) == 6)
        #expect(NativeMenu.points(after: .fontReset, from: 20) == NativeMenu.defaultPoints)
        #expect(NativeMenu.points(after: .copy, from: 14) == 14)
    }

    @Test func quitAsksOnlyWhileLocalSessionsRun() {
        #expect(NativeMenu.quitQuestion(runningLocalSessions: 0) == nil)
        #expect(NativeMenu.quitQuestion(runningLocalSessions: 1) == "Quit agterm? A local session is still running and will end.")
        #expect(NativeMenu.quitQuestion(runningLocalSessions: 3)?.contains("3 local sessions") == true)
    }

    @Test func newSessionOffersEachStartedServerWhileConnected() {
        let servers = [NativeMenu.Server(label: "WSL Ubuntu", started: true, connected: true, current: true),
                       NativeMenu.Server(label: "WSL Debian", started: true, connected: false),
                       NativeMenu.Server(label: "WSL Arch")]
        let launches = NativeMenu.sessions(profiles: profiles, servers: servers, canCloseSession: false)[0].children
        let sessions = launches.filter { if case .serverSession = $0.pick { true } else { false } }
        #expect(sessions.map(\.title) == ["WSL Ubuntu (agterm-server)", "WSL Debian (agterm-server)"])
        #expect(sessions.map(\.pick) == [.serverSession(0), .serverSession(1)])
        #expect(sessions.map(\.enabled) == [true, false])
        #expect(sessions.map(\.shortcut) == ["", ""])
        #expect(NativeMenu.sessions(profiles: profiles, canCloseSession: false)[0].children.count == profiles.count)
    }

    @Test func startListsEveryServerEnabledUntilItIsStarted() {
        let servers = [NativeMenu.Server(label: "WSL Ubuntu", started: true), NativeMenu.Server(label: "WSL Debian")]
        let start = NativeMenu.sessions(profiles: profiles, servers: servers, canCloseSession: false)[0].children.last
        #expect(start?.title == "Start agterm-server in")
        #expect(start?.children.map(\.title) == ["WSL Ubuntu", "WSL Debian"])
        #expect(start?.children.map(\.pick) == [.startServer(0), .startServer(1)])
        #expect(start?.children.map(\.enabled) == [false, true])
    }

    @Test func closingAServerSessionNamesWhatEnds() {
        #expect(NativeMenu.closeQuestion(session: "api", server: "WSL Ubuntu") == "Close api on WSL Ubuntu? Its programs on the server end.")
    }

    @Test func renameIsEnabledByTheCaller() {
        #expect(NativeMenu.sessions(profiles: profiles, canCloseSession: true)
            .first { $0.pick == .command(.renameSession) }?.enabled == false)
        #expect(NativeMenu.sessions(profiles: profiles, canCloseSession: true, canRenameSession: true)
            .first { $0.pick == .command(.renameSession) }?.enabled == true)
    }

    @Test func theDefaultProfileCarriesTheShortcutAndTheCheck() {
        let menu = NativeMenu.sessions(profiles: profiles, defaultProfile: 1, canCloseSession: false)
        #expect(menu[0].children.map(\.shortcut) == profiles.indices.map { $0 == 1 ? "Ctrl+N" : "" })
        #expect(menu[1].title == "Default Profile")
        #expect(menu[1].children.map(\.checked) == profiles.indices.map { $0 == 1 })
        #expect(menu[1].children[1].pick == .defaultProfile(1))
        #expect(NativeMenu.Pick(id: NativeMenu.Pick.defaultProfile(1).id) == .defaultProfile(1))
    }

    @Test func aMissingDefaultProfileFallsBackToTheFirst() {
        #expect(NativeMenu.defaultProfile(named: profiles[1].name.uppercased(), in: profiles) == 1)
        #expect(NativeMenu.defaultProfile(named: "Gone", in: profiles) == 0)
        #expect(NativeMenu.defaultProfile(named: nil, in: profiles) == 0)
    }

    @Test func restartIsEnabledByTheCaller() {
        let menu = { (restart: Bool) in
            NativeMenu.window(profiles: self.profiles, canCloseSession: true, sessionCount: 1, canRestartSession: restart, hasSelection: false,
                              canPaste: false).first { $0.pick == .command(.restartSession) }
        }
        #expect(menu(false)?.enabled == false)
        #expect(menu(true)?.enabled == true && menu(true)?.shortcut == "")
    }
}
