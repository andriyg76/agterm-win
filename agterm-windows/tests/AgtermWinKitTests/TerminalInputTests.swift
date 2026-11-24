import AgtermWinKit
import Testing

struct TerminalInputTests {
    @Test func cursorKeysFollowDECCKM() {
        #expect(TerminalInput.sequence(for: .up) == "\u{1b}[A")
        #expect(TerminalInput.sequence(for: .up, applicationCursor: true) == "\u{1b}OA")
        #expect(TerminalInput.sequence(for: .end, applicationCursor: true) == "\u{1b}OF")
    }

    @Test func modifiedCursorKeysIgnoreDECCKM() {
        #expect(TerminalInput.sequence(for: .left, modifiers: .control, applicationCursor: true) == "\u{1b}[1;5D")
        #expect(TerminalInput.sequence(for: .right, modifiers: [.shift, .alt]) == "\u{1b}[1;4C")
    }

    @Test func editingAndFunctionKeys() {
        #expect(TerminalInput.sequence(for: .delete) == "\u{1b}[3~")
        #expect(TerminalInput.sequence(for: .pageUp, modifiers: .shift) == "\u{1b}[5;2~")
        #expect(TerminalInput.sequence(for: .function(1)) == "\u{1b}OP")
        #expect(TerminalInput.sequence(for: .function(4), modifiers: .control) == "\u{1b}[1;5S")
        #expect(TerminalInput.sequence(for: .function(5)) == "\u{1b}[15~")
        #expect(TerminalInput.sequence(for: .function(12)) == "\u{1b}[24~")
        #expect(TerminalInput.sequence(for: .function(13)) == nil)
    }

    @Test func charactersMapBackspaceAndAlt() {
        #expect(TerminalInput.character("\u{08}") == "\u{7f}")
        #expect(TerminalInput.character("x", alt: true) == "\u{1b}x")
        #expect(TerminalInput.character("ї") == "ї")
    }

    @Test func pasteTypesCarriageReturns() {
        #expect(TerminalInput.paste("a\r\nb\nc", bracketed: false) == "a\rb\rc")
        #expect(TerminalInput.paste("ls\n", bracketed: true) == "\u{1b}[200~ls\r\u{1b}[201~")
    }

    @Test func pasteSpacesTheBytesThatCouldEscapeTheBracket() {
        #expect(TerminalInput.paste("a\u{1b}[201~\u{03}b\tc", bracketed: true) == "\u{1b}[200~a [201~ b\tc\u{1b}[201~")
        #expect(TerminalInput.paste("\u{15}\u{17}\u{1a}\u{08}\u{7f}", bracketed: false) == "     ")
    }

    @Test func typedKeepsControlBytes() {
        #expect(TerminalInput.typed("\u{03}a\r\nb\n") == "\u{03}a\rb\r")
    }

    @Test func sgrMouseReports() {
        #expect(TerminalInput.mouse(button: 0, column: 5, row: 2, release: false, sgr: true) == Array("\u{1b}[<0;5;2M".utf8))
        #expect(TerminalInput.mouse(button: 0, column: 5, row: 2, release: true, sgr: true) == Array("\u{1b}[<0;5;2m".utf8))
        #expect(TerminalInput.mouse(button: 0, column: 1, row: 1, release: false, motion: true, modifiers: .control, sgr: true)
            == Array("\u{1b}[<48;1;1M".utf8))
        #expect(TerminalInput.mouse(button: 65, column: 3, row: 4, release: false, sgr: true) == Array("\u{1b}[<65;3;4M".utf8))
    }

    @Test func x10MouseReportsReleaseAsButtonThreeAndCapTheCell() {
        #expect(TerminalInput.mouse(button: 2, column: 1, row: 1, release: false, sgr: false) == [0x1B, 0x5B, 0x4D, 34, 33, 33])
        #expect(TerminalInput.mouse(button: 2, column: 1, row: 1, release: true, sgr: false) == [0x1B, 0x5B, 0x4D, 35, 33, 33])
        #expect(TerminalInput.mouse(button: 0, column: 400, row: 1, release: false, sgr: false)[4] == 255)
    }

    @Test func wheelOnAlternateScreenSendsThreeKeysANotch() {
        #expect(TerminalInput.wheel(up: true, notches: 2, applicationCursor: false) == String(repeating: "\u{1b}[A", count: 6))
        #expect(TerminalInput.wheel(up: false, notches: 0, applicationCursor: true) == String(repeating: "\u{1b}OB", count: 3))
    }

    @Test func selectionDragsScrollFasterFurtherOut() {
        #expect(TerminalInput.autoscrollLines(y: 10, height: 400, step: 20) == 0)
        #expect(TerminalInput.autoscrollLines(y: -1, height: 400, step: 20) == 1)
        #expect(TerminalInput.autoscrollLines(y: -45, height: 400, step: 20) == 3)
        #expect(TerminalInput.autoscrollLines(y: 400, height: 400, step: 20) == -1)
        #expect(TerminalInput.autoscrollLines(y: 5000, height: 400, step: 20) == -10)
    }

    @Test func wslIsTheCommandLinesProgram() {
        #expect(TerminalInput.runsInWSL("wsl.exe -d Ubuntu --cd ~"))
        #expect(TerminalInput.runsInWSL(#"C:\WINDOWS\System32\wsl.exe -d Ubuntu -e /bin/sh"#))
        #expect(TerminalInput.runsInWSL(#""C:\Program Files\WSL\wsl.exe" -d Debian"#))
        #expect(!TerminalInput.runsInWSL("powershell.exe -NoLogo"))
        #expect(!TerminalInput.runsInWSL("cmd.exe /c wsl.exe"))
    }

    @Test func droppedPathsAreQuotedForTheirShell() {
        #expect(TerminalInput.droppedPaths([#"C:\Users\me\a.txt"#, #"D:\My Files\b c.png"#], wsl: false)
            == #"C:\Users\me\a.txt "D:\My Files\b c.png" "#)
        #expect(TerminalInput.droppedPaths([#"C:\Users\me\a.txt"#], wsl: true) == "/mnt/c/Users/me/a.txt ")
        #expect(TerminalInput.droppedPaths([#"D:\it's here\x"#], wsl: true) == #"'/mnt/d/it'\''s here/x' "#)
        #expect(TerminalInput.droppedPaths([#"\\server\share\f"#], wsl: true) == "//server/share/f ")
    }
}
