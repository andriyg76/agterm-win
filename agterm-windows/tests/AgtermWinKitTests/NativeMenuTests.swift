import AgtermWinKit
import Testing

struct NativeMenuTests {
    @Test func terminalMenuEnablesCopyAndPasteByState() {
        let menu = NativeMenu.terminal(hasSelection: false, canPaste: true)
        #expect(menu.first { $0.command == .copy }?.enabled == false)
        #expect(menu.first { $0.command == .paste }?.enabled == true)
        #expect(NativeMenu.terminal(hasSelection: true, canPaste: false).first { $0.command == .copy }?.enabled == true)
        #expect(!menu.contains { $0.command == .quit })
    }

    @Test func windowMenuIsTheTerminalMenuPlusQuit() {
        let terminal = NativeMenu.terminal(hasSelection: true, canPaste: true)
        let window = NativeMenu.window(hasSelection: true, canPaste: true)
        #expect(Array(window.prefix(terminal.count)) == terminal)
        #expect(window.last?.command == .quit)
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
