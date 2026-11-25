import AgtermWinKit
import Testing

struct ChromePaletteTests {
    @Test func darkThemeYieldsDarkChrome() {
        var theme = TerminalTheme()
        theme.background = 0x1E1E1E
        theme.foreground = 0xD4D4D4
        theme.palette[12] = 0x569CD6
        let palette = ChromePalette.recompute(theme: theme, sidebarTint: 0)
        #expect(palette.isDark)
        #expect(palette.chromeText != palette.chromeDim)
        #expect(palette.chromeAccent == 0x569CD6)
    }

    @Test func lightThemeYieldsLightChrome() {
        var theme = TerminalTheme()
        theme.background = 0xFFFFFF
        theme.foreground = 0x000000
        let palette = ChromePalette.recompute(theme: theme)
        #expect(!palette.isDark)
        #expect(palette.chromeBg != palette.sbBg)
    }

    @Test func sidebarTintShiftsSidebarWithoutChangingTitleBar() {
        var theme = TerminalTheme()
        theme.background = 0x1E1E1E
        theme.foreground = 0xCCCCCC
        let base = ChromePalette.recompute(theme: theme, sidebarTint: 0)
        let warm = ChromePalette.recompute(theme: theme, sidebarTint: 50)
        #expect(base.chromeBg == warm.chromeBg)
        #expect(base.sbBg != warm.sbBg)
    }

    @Test func colorrefSwapsRedAndBlue() {
        #expect(ChromePalette.colorref(0x282A36) == 0x362A28)
        #expect(ChromePalette.colorref(0xFF282A36) == 0x362A28)
    }

    @Test func nilThemeUsesDefaults() {
        let palette = ChromePalette.recompute(theme: nil)
        #expect(palette.isDark)
        #expect(palette.chromeBg != 0)
    }
}