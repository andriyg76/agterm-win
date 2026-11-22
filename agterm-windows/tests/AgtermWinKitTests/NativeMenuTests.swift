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
        let newSession = menu[0]
        #expect(newSession.title == "New Session")
        #expect(newSession.children.map(\.title) == ["Windows PowerShell", "WSL Ubuntu"])
        #expect(newSession.children.map(\.pick) == [.profile(0), .profile(1)])
        #expect(newSession.children.map(\.shortcut) == ["Ctrl+Shift+T", ""])
        #expect(menu.first { $0.pick == .command(.closeSession) }?.enabled == false)
        #expect(menu.first { $0.pick == .command(.nextSession) }?.enabled == false)
        #expect(menu.last?.pick == .command(.quit))
    }

    @Test func sessionsMenuIsTheWindowMenusHead() {
        let sessions = NativeMenu.sessions(profiles: profiles, canCloseSession: true, sessionCount: 2)
        let window = NativeMenu.window(profiles: profiles, canCloseSession: true, sessionCount: 2, hasSelection: false, canPaste: false)
        #expect(Array(window.prefix(sessions.count)) == sessions)
        #expect(sessions.first { $0.pick == .command(.previousSession) }?.enabled == true)
        #expect(!sessions.contains { $0.pick == .command(.copy) })
        #expect(window.contains { $0.pick == .command(.find) })
    }

    @Test func windowMenuContainsTheTerminalMenu() {
        let terminal = NativeMenu.terminal(hasSelection: true, canPaste: true)
        let window = NativeMenu.window(profiles: profiles, canCloseSession: true, sessionCount: 3, hasSelection: true, canPaste: true)
        #expect(window.contains(terminal[0]) && window.contains(terminal[terminal.count - 1]))
    }

    @Test func picksRoundTripThroughMenuIDs() {
        for pick in NativeMenu.Command.allCases.map(NativeMenu.Pick.command) + [.profile(0), .profile(7)] {
            #expect(NativeMenu.Pick(id: pick.id) == pick)
        }
        #expect(NativeMenu.Pick(id: 0) == nil)
    }

    @Test func everyCommandNamesItsShortcut() {
        #expect(NativeMenu.Command.allCases.allSatisfy { !$0.title.isEmpty && !$0.shortcut.isEmpty })
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

    @Test func newSessionOffersTheServerWhileConnected() {
        let connected = NativeMenu.sessions(profiles: profiles, server: "WSL Ubuntu", serverConnected: true, canCloseSession: false,
                                            sessionCount: 1)[0].children
        #expect(connected.last?.title == "WSL Ubuntu (agterm-server)")
        #expect(connected.last?.pick == .command(.newServerSession) && connected.last?.enabled == true)
        let offline = NativeMenu.sessions(profiles: profiles, server: "WSL Ubuntu", serverConnected: false, canCloseSession: false,
                                          sessionCount: 1)[0].children
        #expect(offline.last?.enabled == false)
        #expect(NativeMenu.sessions(profiles: profiles, canCloseSession: false, sessionCount: 1)[0].children.count == profiles.count)
    }

    @Test func closingAServerSessionNamesWhatEnds() {
        #expect(NativeMenu.closeQuestion(session: "api", server: "WSL Ubuntu") == "Close api on WSL Ubuntu? Its programs on the server end.")
    }

    @Test func renameIsEnabledByTheCaller() {
        #expect(NativeMenu.sessions(profiles: profiles, canCloseSession: true, sessionCount: 1)
            .first { $0.pick == .command(.renameSession) }?.enabled == false)
        #expect(NativeMenu.sessions(profiles: profiles, canCloseSession: true, sessionCount: 1, canRenameSession: true)
            .first { $0.pick == .command(.renameSession) }?.enabled == true)
    }

    @Test func theDefaultProfileCarriesTheShortcutAndTheCheck() {
        let menu = NativeMenu.sessions(profiles: profiles, defaultProfile: 1, canCloseSession: false, sessionCount: 1)
        #expect(menu[0].children.map(\.shortcut) == profiles.indices.map { $0 == 1 ? "Ctrl+Shift+T" : "" })
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
}
