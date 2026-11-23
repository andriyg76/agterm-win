import AgtermWinKit
import Foundation
import Testing
import agtermCore

struct WindowsKeymapTests {
    private func press(_ keymap: inout WindowsKeymap, _ key: Character, control: Bool = false, alt: Bool = false, shift: Bool = false,
                       win: Bool = false) -> WindowsKeymap.Press {
        let chord = WindowsKeymap.chord(virtualKey: Int32(key.uppercased().first!.asciiValue!), control: control, alt: alt, shift: shift, win: win)!
        return keymap.press(chord)
    }

    @Test func keysAreNamedAsKeymapConfWritesThem() {
        #expect(WindowsKeymap.chord(virtualKey: 0x54, control: true, alt: false, shift: true, win: false) == Chord(mods: [.control, .shift], key: "t"))
        #expect(WindowsKeymap.chord(virtualKey: 0xBB, control: true, alt: false, shift: false, win: false)?.key == "=")
        #expect(WindowsKeymap.chord(virtualKey: 0x71, control: false, alt: false, shift: false, win: false)?.key == "f2")
        #expect(WindowsKeymap.chord(virtualKey: 0x25, control: false, alt: false, shift: false, win: true) == Chord(mods: [.command], key: "left"))
        #expect(WindowsKeymap.chord(virtualKey: 0x10, control: false, alt: false, shift: true, win: false) == nil)
    }

    @Test func labelsReadAsWindowsMenusWriteThem() {
        #expect(WindowsKeymap.label(Chord(mods: [.control, .shift], key: "t")) == "Ctrl+Shift+T")
        #expect(WindowsKeymap.label(Chord(mods: [.command, .option], key: "return")) == "Win+Alt+Enter")
        #expect(WindowsKeymap.label(Chord(mods: [], key: "f2")) == "F2")
    }

    @Test func aMappedChordRunsItsCommandAndShowsInTheMenu() {
        var keymap = WindowsKeymap(text: "map cmd+t new_session")
        #expect(press(&keymap, "t", win: true) == .command(.newSession))
        #expect(press(&keymap, "t") == .pass)
        #expect(keymap.shortcuts[.newSession] == "Win+T")
        #expect(keymap.usesWinKey)
    }

    @Test func aLeaderSequenceHoldsItsFirstChordThenFires() {
        var keymap = WindowsKeymap(text: "map ctrl+a>n new_session")
        #expect(press(&keymap, "a", control: true) == .consumed)
        #expect(press(&keymap, "n") == .command(.newSession))
        #expect(press(&keymap, "a", control: true) == .consumed)
        #expect(press(&keymap, "x") == .consumed)
        #expect(press(&keymap, "x") == .pass)
        #expect(keymap.shortcuts[.newSession] == "Ctrl+A, N")
        #expect(!keymap.usesWinKey)
    }

    @Test func escAbandonsALeader() {
        var keymap = WindowsKeymap(text: "map ctrl+a>n new_session")
        #expect(press(&keymap, "a", control: true) == .consumed)
        #expect(keymap.press(WindowsKeymap.chord(virtualKey: 0x1B, control: false, alt: false, shift: false, win: false)!) == .consumed)
        #expect(press(&keymap, "n") == .pass)
    }

    @Test func aReservedChordNeverFiresAndSaysWhose() {
        var keymap = WindowsKeymap(text: "map ctrl+shift+c new_session")
        #expect(press(&keymap, "c", control: true, shift: true) == .pass)
        #expect(keymap.diagnostics.map(\.message).contains("ctrl+shift+c for 'new_session' is Copy's on Windows"))
    }

    @Test func whatWindowsLacksIsReported() {
        let keymap = WindowsKeymap(text: "map ctrl+alt+d toggle_split\ncommand \"git\" ctrl+alt+g lazygit")
        let messages = keymap.diagnostics.map(\.message)
        #expect(messages.contains("'toggle_split' is not available on Windows"))
        #expect(messages.contains("custom commands are not supported on Windows yet; 1 skipped"))
        #expect(keymap.control.actions.allSatisfy { $0.action != "toggle_split" } && keymap.control.commands.isEmpty)
    }

    #if os(Windows)
    @Test func theDefaultsAreTheWindowsChords() {
        var keymap = WindowsKeymap(text: "")
        #expect(press(&keymap, "t", control: true, shift: true) == .command(.newSession))
        #expect(keymap.shortcuts[.nextSession] == "Ctrl+Tab" && keymap.shortcuts[.fontBigger] == "Ctrl+=")
        #expect(keymap.shortcuts[.renameSession] == "F2" && keymap.diagnostics.isEmpty)
    }

    @Test func movingAnActionFreesItsDefault() {
        var keymap = WindowsKeymap(text: "map ctrl+alt+w close_session")
        #expect(press(&keymap, "w", control: true, shift: true) == .pass)
        #expect(press(&keymap, "w", control: true, alt: true) == .command(.closeSession))
    }
    #endif
}
