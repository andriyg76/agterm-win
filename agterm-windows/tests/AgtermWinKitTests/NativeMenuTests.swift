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
        let menu = NativeMenu.window(profiles: profiles, canCloseSession: false, hasSelection: false, canPaste: false)
        let newSession = menu[0]
        #expect(newSession.title == "New Session")
        #expect(newSession.children.map(\.title) == ["Windows PowerShell", "WSL Ubuntu"])
        #expect(newSession.children.map(\.pick) == [.profile(0), .profile(1)])
        #expect(newSession.children.map(\.shortcut) == ["Ctrl+Shift+T", ""])
        #expect(menu.first { $0.pick == .command(.closeSession) }?.enabled == false)
        #expect(menu.last?.pick == .command(.quit))
    }

    @Test func windowMenuContainsTheTerminalMenu() {
        let terminal = NativeMenu.terminal(hasSelection: true, canPaste: true)
        let window = NativeMenu.window(profiles: profiles, canCloseSession: true, hasSelection: true, canPaste: true)
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
}
