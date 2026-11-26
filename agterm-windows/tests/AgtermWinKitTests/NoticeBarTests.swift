import AgtermWinKit
import Testing
import agtermCore

struct NoticeBarTests {
    private let connecting = NoticeBar.Message(source: "Debian", text: "Connecting to WSL Debian…", severity: .progress)
    private let failed = NoticeBar.Message(source: "Ubuntu", text: "WSL Ubuntu: install failed", severity: .error, actions: [.retry, .openLog])
    private let installed = NoticeBar.Message(source: "Arch", text: "WSL Arch: agterm-server installed.", severity: .info)

    @Test func errorsShowFirstThenProgressThenInfoInProducerOrder() {
        var state = NoticeBar.State()
        let other = NoticeBar.Message(source: "Kali", text: "Checking WSL Kali…", severity: .progress)
        state.update([installed, connecting, failed, other])
        #expect(state.messages == [failed, connecting, other, installed])
        #expect(state.shown == failed && state.waiting == 3)
    }

    @Test func aDismissedNoticeStaysClosedUntilItChanges() {
        var state = NoticeBar.State()
        state.update([connecting, failed])
        let dismissed = state.dismissShown()
        #expect(dismissed && state.shown == connecting && state.waiting == 0)
        state.update([connecting, failed])
        #expect(state.shown == connecting)
        let retried = NoticeBar.Message(source: "Ubuntu", text: "WSL Ubuntu: install exited 1. See agterm-win.log.", severity: .error)
        state.update([connecting, retried])
        #expect(state.shown == retried)
    }

    @Test func aDismissedNoticeThatGoesAwayShowsWhenItReturns() {
        var state = NoticeBar.State()
        state.update([failed])
        let first = state.dismissShown()
        #expect(first && state.shown == nil)
        let second = state.dismissShown()
        #expect(!second)
        state.update([])
        state.update([failed])
        #expect(state.shown == failed)
    }

    @Test func menuOffersTheActionsTheMovesAndDismiss() {
        var state = NoticeBar.State()
        #expect(NoticeBar.menu(state) == [.moveTo(.top), .moveTo(.bottom)])
        state.update([failed, connecting])
        #expect(NoticeBar.menu(state) == [.action(.retry), .action(.openLog), .separator, .moveTo(.top), .moveTo(.bottom), .separator, .dismiss])
        #expect(NoticeBar.countText(state.waiting) == "+1 more" && NoticeBar.countText(0).isEmpty)
    }

    @Test func aDropSnapsToTheNearerEnd() {
        #expect(NoticeBar.snap(top: 40, height: 34, areaTop: 32, areaBottom: 800) == .top)
        #expect(NoticeBar.snap(top: 380, height: 34, areaTop: 32, areaBottom: 800) == .top)
        #expect(NoticeBar.snap(top: 420, height: 34, areaTop: 32, areaBottom: 800) == .bottom)
        #expect(NoticeBar.snap(top: 766, height: 34, areaTop: 32, areaBottom: 800) == .bottom)
    }

    @Test func aDraggedBarStaysInsideItsArea() {
        #expect(NoticeBar.dragTop(pointer: 10, pressOffset: 12, height: 34, areaTop: 32, areaBottom: 800) == 32)
        #expect(NoticeBar.dragTop(pointer: 400, pressOffset: 12, height: 34, areaTop: 32, areaBottom: 800) == 388)
        #expect(NoticeBar.dragTop(pointer: 2000, pressOffset: 12, height: 34, areaTop: 32, areaBottom: 800) == 766)
    }

    @Test func layoutScalesWithDPIAndPutsCloseAtTheRightEdge() {
        let normal = NoticeBar.Layout(width: 1000, dpi: 96, labelWidths: [40, 60], countWidth: 50)
        let double = NoticeBar.Layout(width: 2000, dpi: 192, labelWidths: [80, 120], countWidth: 100)
        #expect(normal.height == 34 && double.height == 68)
        #expect(normal.close == .init(left: 960, right: 1000) && double.close == .init(left: 1920, right: 2000))
        #expect(normal.actions.count == 2 && normal.actions[1].right == 956 && normal.actions[0].right < normal.actions[1].left)
        #expect(normal.count.right <= normal.actions[0].left && normal.text.right <= normal.count.left)
        #expect(double.actions[1].left == normal.actions[1].left * 2)
        #expect(normal.part(x: 980) == .close && normal.part(x: normal.actions[0].left + 1) == .action(0) && normal.part(x: 300) == .body)
    }

    @Test func buttonsThatDoNotFitAreLeftToTheMenu() {
        let narrow = NoticeBar.Layout(width: 320, dpi: 96, labelWidths: [60, 60], countWidth: 0)
        #expect(narrow.actions.count < 2)
        #expect(narrow.text.right - narrow.text.left >= 120)
    }

    @Test func colorsComeFromTheChromePaletteWithTheThemesRedForErrors() {
        var theme = TerminalTheme()
        theme.background = 0xFFFFFF
        theme.foreground = 0x222222
        theme.palette[1] = 0xC91B00
        let light = ChromePalette.recompute(theme: theme)
        let error = NoticeBar.colors(light, theme: theme, severity: .error)
        let info = NoticeBar.colors(light, theme: theme, severity: .info)
        #expect(error.accent == 0xC91B00 && info.accent == light.chromeAccent)
        #expect(error.text == light.chromeText && error.border == light.chromeBorder)
        #expect(error.background != info.background && info.background != light.chromeBg)
        theme.background = 0x1E1E1E
        theme.foreground = 0xD4D4D4
        theme.palette[9] = 0xF14C4C
        let dark = ChromePalette.recompute(theme: theme)
        #expect(NoticeBar.colors(dark, theme: theme, severity: .error).accent == 0xF14C4C)
    }
}
