import Foundation
import Testing
@testable import agtermCore

@Suite("palette row model")
struct PalettePresentationTests {
    private let newSessionChord = Chord(mods: [.control, .shift], key: "t")
    private let dashboardChord = Chord(mods: [.control, .shift], key: "m")

    @Test("a bound catalog command carries its chord in kitty syntax")
    func actionWithChord() {
        let row = PaletteRowModel.action(.newSession, in: PaletteContext(), chord: newSessionChord)

        #expect(row.title == "New Session")
        #expect(row.shortcut == "ctrl+shift+t")
        #expect(row.badge == nil)
    }

    @Test("an unbound catalog command has no shortcut")
    func actionWithoutChord() {
        #expect(PaletteRowModel.action(.editKeymap, in: PaletteContext(), chord: nil)
            == PaletteRowModel(title: "Edit Keymap"))
    }

    @Test("origin history remains available through the remote-window palette")
    func originHistoryEnablement() {
        let connected = PaletteContext(hasRecentClosed: true, remoteWindow: true, remoteConnected: true)
        #expect(!PaletteCommand.reopenRecent.isEnabled(in: connected))
        #expect(PaletteRowModel.action(.reopenRecent, in: connected, chord: nil).enabled)
        for context in [
            PaletteContext(hasRecentClosed: true, remoteWindow: true),
            PaletteContext(remoteWindow: true, remoteConnected: true),
            PaletteContext(hasRecentClosed: true, pickerActive: true, remoteWindow: true, remoteConnected: true)
        ] {
            #expect(!PaletteRowModel.action(.reopenRecent, in: context, chord: nil).enabled)
        }
    }

    /// Two catalog titles flip with UI state, so a row must be built against the LIVE `PaletteContext`.
    /// The context-free `PaletteCommand.title` left the palette offering "Flag Session" for an already
    /// flagged session and "Show Flagged Sessions" while the flagged view was already on; macOS passes
    /// the context for exactly this reason (`agterm/AppActions+Palette.swift`).
    @Test("a context-dependent catalog title flips with the UI state")
    func actionTitleFollowsContext() {
        #expect(PaletteRowModel.action(.toggleFlag, in: PaletteContext(), chord: nil).title == "Flag Session")
        #expect(PaletteRowModel.action(.toggleFlag, in: PaletteContext(activeSessionFlagged: true), chord: nil).title
            == "Unflag Session")
        #expect(PaletteRowModel.action(.toggleFlaggedView, in: PaletteContext(), chord: nil).title
            == "Show Flagged Sessions")
        #expect(PaletteRowModel.action(.toggleFlaggedView, in: PaletteContext(sidebarShowsFlaggedOnly: true),
                                       chord: nil).title == "Show All Sessions")
    }

    @Test("a closed persisted window is offered as Open Window, not Switch to Window")
    func persistedWindowTitleFollowsOpenState() {
        #expect(PaletteRowModel.window(name: "archive", isOpen: false).title == "Open Window: archive")
        #expect(PaletteRowModel.window(name: "active", isOpen: true).title == "Switch to Window: active")
    }

    @Test("a custom command is badged and shows its own chord")
    func customWithShortcut() {
        let row = PaletteRowModel.custom(
            CustomCommand(name: "Deploy", command: "make deploy", shortcut: "ctrl+shift+e"))

        #expect(row.title == "Deploy")
        #expect(row.badge == "custom")
        #expect(row.shortcut == "ctrl+shift+e")
    }

    /// `parseCommandLine` stores the chord token exactly as written, so the palette must show the user's
    /// own text — no normalizing through `Chord.displayString`, which would lowercase a `Ctrl+Shift+E`
    /// and cannot represent a leader sequence at all.
    @Test("a custom command's shortcut is the raw keymap token, verbatim", arguments: ["Ctrl+Shift+E", "ctrl+a>g"])
    func customShortcutPassesThroughVerbatim(token: String) {
        let row = PaletteRowModel.custom(CustomCommand(name: "Deploy", command: "make deploy", shortcut: token))

        #expect(row.shortcut == token)
        #expect(row.searchKeys == ["Deploy", "Deploy custom \(token)"])
    }

    @Test("a palette-only custom command is badged with no shortcut")
    func customWithoutShortcut() {
        let empty = PaletteRowModel.custom(
            CustomCommand(name: "Launch Failure", command: "false", shortcut: ""))
        let blank = PaletteRowModel.custom(
            CustomCommand(name: "Slow Failure", command: "sleep 1", shortcut: "   \t "))

        #expect(empty == PaletteRowModel(title: "Launch Failure", badge: "custom"))
        #expect(blank.shortcut == nil)
        #expect(blank.badge == "custom")
    }

    @Test("only a row with a badge or a shortcut gains the composite search key")
    func searchKeys() {
        #expect(PaletteRowModel(title: "Copy Selection").searchKeys == ["Copy Selection"])
        #expect(PaletteRowModel.action(.dashboard, in: PaletteContext(), chord: dashboardChord).searchKeys
            == ["Dashboard", "Dashboard ctrl+shift+m"])
        #expect(PaletteRowModel.custom(CustomCommand(name: "Launch Failure", command: "false", shortcut: "")).searchKeys
            == ["Launch Failure", "Launch Failure custom"])
        // both fields present → title, then badge, then shortcut, in that order
        #expect(PaletteRowModel(title: "Deploy", shortcut: "ctrl+shift+e", badge: "custom").searchKeys
            == ["Deploy", "Deploy custom ctrl+shift+e"])
    }
}
