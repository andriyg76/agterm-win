import AgtermWinKit
import Foundation
import Testing
import agtermCore

struct TerminalThemeTests {
    @Test func aGhosttyThemeFileParses() {
        let theme = TerminalTheme(parsing: """
            palette = 0=#21222c
            palette = 15 = #ffffff
            background = #282a36
            foreground = f8f8f2
            cursor-color = #f8f8f2
            cursor-text = #282a36
            selection-background = #44475a
            # comment
            font-size = 14
            palette = 300=#000000
            """)
        #expect(theme.background == 0x282A36 && theme.foreground == 0xF8F8F2 && theme.cursor == 0xF8F8F2 && theme.cursorText == 0x282A36)
        #expect(theme.selectionBackground == 0x44475A && theme.palette == [0: 0x21222C, 15: 0xFFFFFF])
    }

    @Test func theUsersFolderComesFirstAndTheLicenseIsNoTheme() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("themes-\(UUID().uuidString)")
        let user = root.appendingPathComponent("user"), bundled = root.appendingPathComponent("bundled")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in [user, bundled] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "background = #000001".write(to: user.appendingPathComponent("Nord"), atomically: true, encoding: .utf8)
        try "background = #000002".write(to: bundled.appendingPathComponent("Nord"), atomically: true, encoding: .utf8)
        try "background = #000003".write(to: bundled.appendingPathComponent("Dracula"), atomically: true, encoding: .utf8)
        try "MIT".write(to: bundled.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
        let themes = TerminalThemes(userDirectory: user, bundledDirectory: bundled)
        #expect(themes.catalog.names == ["Dracula", "Nord"])
        #expect(themes.theme(named: "Nord")?.background == 1 && themes.theme(named: "Dracula")?.background == 3)
        #expect(themes.theme(named: "../Nord") == nil && themes.theme(named: "Missing") == nil)
    }

    @Test func theDarkThemeShowsOnlyInDarkModeWhileFollowing() {
        let appearance = Appearance(theme: "Nord", darkTheme: "Dracula", followsSystem: true)
        #expect(appearance.activeTheme(dark: true) == "Dracula" && appearance.activeTheme(dark: false) == "Nord")
        #expect(Appearance(theme: "Nord", darkTheme: "Dracula").activeTheme(dark: true) == "Nord")
    }

    @Test func themeSetFollowsTheMacRules() throws {
        let catalog = ThemeCatalog(names: ["Dracula", "Nord"])
        let start = Appearance(theme: "Nord")
        #expect(start.setting(name: "Nord", light: "Dracula", dark: nil, catalog: catalog) == .failure(.both))
        #expect(start.setting(name: nil, light: nil, dark: "Gone", catalog: catalog) == .failure(.unknown("Gone")))
        #expect(try start.setting(name: nil, light: nil, dark: nil, catalog: catalog).get().theme == nil)
        let following = try! start.setting(name: nil, light: nil, dark: "Dracula", catalog: catalog).get()
        #expect(following.followsSystem && following.theme == "Nord" && following.darkTheme == "Dracula")
        let stopped = try! following.setting(name: nil, light: nil, dark: "none", catalog: catalog).get()
        #expect(!stopped.followsSystem && stopped.darkTheme == nil && stopped.theme == "Nord")
    }

    @Test func savedAppearanceSurvivesAndAnOlderFileHasNone() throws {
        var settings = NativeSettings()
        settings.appearance = Appearance(theme: "Nord", darkTheme: "Dracula", followsSystem: true, fontFamily: "Consolas")
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(NativeSettings.self, from: data).appearance == settings.appearance)
        #expect(try JSONDecoder().decode(NativeSettings.self, from: Data(#"{"appearance": {"theme": "Nord"}}"#.utf8)).appearance == Appearance(theme: "Nord"))
        #expect(try JSONDecoder().decode(NativeSettings.self, from: Data("{}".utf8)).appearance == Appearance())
    }
}
