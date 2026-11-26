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

    private func defaults() -> WindowsKeymap {
        #if os(Windows)
        WindowsKeymap(text: "")
        #else
        let chords = BuiltinAction.allCases.compactMap { action in action.windowsDefaultChord.map { (action, $0) } }
        let unbound = Set(BuiltinAction.allCases.filter { $0.windowsDefaultChord == nil })
        return WindowsKeymap(keymap: Keymap(builtinOverrides: Dictionary(uniqueKeysWithValues: chords), commands: [],
                                            builtinUnbound: unbound), diagnostics: [], path: "keymap.conf")
        #endif
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
        #if os(Windows)
        #expect(!keymap.usesWinKey)
        #endif
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
        let keymap = WindowsKeymap(text: "map ctrl+alt+d toggle_sidebar\ncommand \"git\" ctrl+alt+g lazygit")
        let messages = keymap.diagnostics.map(\.message)
        #expect(messages.contains("'toggle_sidebar' is not available on Windows"))
        #expect(messages.contains("custom commands are not supported on Windows yet; 1 skipped"))
        #expect(keymap.control.actions.allSatisfy { $0.action != "toggle_sidebar" } && keymap.control.commands.isEmpty)
    }

    @Test func aGlobalHotkeyBecomesRegisterHotKeysChord() {
        #expect(WindowsKeymap(text: "global-hotkey ctrl+alt+space").globalHotkey == .init(modifiers: 0x4003, key: 0x20))
        #expect(WindowsKeymap(text: "global-hotkey ctrl+shift+`").globalHotkey == .init(modifiers: 0x4006, key: 0xC0))
        #expect(WindowsKeymap(text: "").globalHotkey == nil)
        #expect(WindowsKeymap.virtualKey("f5") == 0x74 && WindowsKeymap.virtualKey("=") == 0xBB && WindowsKeymap.virtualKey("nope") == nil)
    }

    @Test func fixedEditingAliasesAndShellKeys() {
        for chord in [Chord(mods: [.control, .shift], key: "c"), Chord(mods: [.control], key: "insert")] {
            #expect(WindowsKeymap.fixedCommand(for: chord, hasSelection: false) == .copy)
        }
        for chord in [Chord(mods: [.control, .shift], key: "v"), Chord(mods: [.shift], key: "insert"),
                      Chord(mods: [.control, .shift], key: "i")] {
            #expect(WindowsKeymap.fixedCommand(for: chord, hasSelection: false) == .paste)
        }
        let copyOrInterrupt = Chord(mods: [.control], key: "c")
        #expect(WindowsKeymap.fixedCommand(for: copyOrInterrupt, hasSelection: true) == .copy)
        #expect(WindowsKeymap.fixedCommand(for: copyOrInterrupt, hasSelection: false) == nil)
        for key in ["d", "j", "z", "a", "v"] {
            #expect(WindowsKeymap.fixedCommand(for: Chord(mods: [.control], key: key), hasSelection: true) == nil)
        }
        for key in ["k", "r"] {
            #expect(WindowsKeymap.fixedCommand(for: Chord(mods: [.control, .shift], key: key), hasSelection: false) == nil)
        }
        #expect(WindowsKeymap.fixedCommand(for: Chord(mods: [.control, .option], key: "s"), hasSelection: false) == .settings)
        #expect(WindowsKeymap.chord(virtualKey: 0x2D, control: true, alt: false, shift: false, win: false)
                == Chord(mods: [.control], key: "insert"))
    }

    @Test func theDefaultsAreTheWindowsChords() {
        var keymap = defaults()
        #expect(press(&keymap, "n", control: true) == .command(.newSession))
        #expect(press(&keymap, "w", control: true) == .command(.closeSession))
        #expect(keymap.press(Chord(mods: [.control], key: "f4")) == .command(.closeSession))
        #expect(keymap.shortcuts[.closeSession] == "Ctrl+W / Ctrl+F4")
        #expect(press(&keymap, "f", control: true) == .command(.find))
        #expect(keymap.shortcuts[.nextSession] == "Ctrl+Alt+Right" && keymap.shortcuts[.fontBigger] == "Ctrl+Shift+=")
        #expect(keymap.shortcuts[.renameSession] == "" && keymap.diagnostics.isEmpty)
        #expect(press(&keymap, "p", control: true) == .command(.sessionPalette))
        #expect(press(&keymap, "p", control: true, shift: true) == .command(.commandPalette))
        #expect(press(&keymap, "i", control: true, alt: true) == .command(.attentionPalette))
        #expect(WindowsKeymap.fixedCommand(for: Chord(mods: [.control, .option], key: "i"), hasSelection: false) == nil)
        #expect(press(&keymap, "g", control: true, shift: true) == .command(.dashboard))
        #expect(press(&keymap, "j", control: true, shift: true) == .command(.toggleOverlay))
        #expect(press(&keymap, "d", control: true, shift: true) == .command(.toggleSplit))
        #expect(press(&keymap, "1", control: true) == .command(.focusLeftPane))
        #expect(press(&keymap, "2", control: true) == .command(.focusRightPane))
        #expect(keymap.press(Chord(mods: [.control, .option], key: "left")) == .command(.previousSession))
        #expect(keymap.press(Chord(mods: [.control], key: "`")) == .command(.quickTerminal))
        for (command, _) in WindowsKeymap.actions { #expect(keymap.shortcuts[command] == command.shortcut) }
    }

    @Test func retiredDefaultsAndShellKeysPassThrough() {
        var keymap = defaults()
        for chord in [Chord(mods: [.control], key: "d"), Chord(mods: [.control], key: "j"), Chord(mods: [.control], key: "z"),
                      Chord(mods: [.control, .shift], key: "t"), Chord(mods: [.control, .shift], key: "n"),
                      Chord(mods: [.control, .shift], key: "w"), Chord(mods: [.control, .shift], key: "f"),
                      Chord(mods: [.control], key: "="), Chord(mods: [.control], key: "tab"),
                      Chord(mods: [.control, .shift], key: "tab"), Chord(mods: [], key: "f2"),
                      Chord(mods: [.option], key: "left"), Chord(mods: [.option], key: "right"),
                      Chord(mods: [.option, .shift], key: "="), Chord(mods: [.option, .shift], key: "-")] {
            #expect(keymap.press(chord) == .pass)
        }
    }

    #if os(Windows)
    @Test func existingExplicitBindingsKeepTheirChords() {
        var keymap = WindowsKeymap(text: "map ctrl+n toggle_scratch")
        #expect(keymap.diagnostics.isEmpty)
        #expect(press(&keymap, "n", control: true) == .command(.toggleScratch))
        #expect(keymap.shortcuts[.newSession] == "")
    }

    @Test func movingAnActionFreesItsDefault() {
        var keymap = WindowsKeymap(text: "map ctrl+alt+w close_session")
        #expect(press(&keymap, "w", control: true) == .pass)
        #expect(press(&keymap, "w", control: true, alt: true) == .command(.closeSession))
    }

    @Test func anExplicitBindingTakesPrecedenceOverTheCloseAlias() {
        var keymap = WindowsKeymap(text: "map ctrl+f4 new_session")
        #expect(keymap.press(Chord(mods: [.control], key: "f4")) == .command(.newSession))
        #expect(keymap.shortcuts[.closeSession] == "Ctrl+W")
    }
    #endif
}
