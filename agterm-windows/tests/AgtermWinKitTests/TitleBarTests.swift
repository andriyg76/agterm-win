import AgtermWinKit
import Testing

struct TitleBarTests {
    private let bar = TitleBar(width: 1300, sidebarWidth: 240, dpi: 96)

    @Test func buttonsSitAtTheEdgesInOrder() {
        #expect(bar.height == 40)
        #expect(bar.span(of: .newSession) == .init(left: 240, right: 280))
        #expect(bar.span(of: .close) == .init(left: 1254, right: 1300))
        #expect(bar.span(of: .maximize) == .init(left: 1208, right: 1254))
        #expect(bar.span(of: .minimize) == .init(left: 1162, right: 1208))
        #expect(bar.span(of: .settings) == .init(left: 1122, right: 1162))
        #expect(bar.span(of: .find) == .init(left: 1082, right: 1122))
        #expect(bar.span(of: .dashboard) == .init(left: 1042, right: 1082))
        #expect(bar.span(of: .split) == .init(left: 1002, right: 1042))
        #expect(bar.span(of: .quick) == .init(left: 962, right: 1002))
    }

    @Test func titleStartsAtTheTerminalAndStopsBeforeTheTrailingButtons() {
        #expect(bar.title == .init(left: 535, right: 952))
        #expect(TitleBar(width: 1300, sidebarWidth: 0, dpi: 96).title.left == 295)
        #expect(TitleBar(width: 200, sidebarWidth: 240, dpi: 96).title.isEmpty)
    }

    @Test func spansScaleWithTheMonitor() {
        let scaled = TitleBar(width: 2600, sidebarWidth: 480, dpi: 192)
        #expect(scaled.height == 80)
        #expect(scaled.span(of: .close) == .init(left: 2508, right: 2600))
        #expect(scaled.span(of: .newSession) == .init(left: 480, right: 560))
    }

    @Test func hitTellsButtonsCaptionMenuTabsAndTheTopEdgeApart() {
        #expect(bar.hit(x: 10, y: 20, topBorder: 6) == .appIcon)
        #expect(bar.hit(x: bar.appIcon.right + 1, y: 20, topBorder: 6) == .caption)
        #expect(bar.hit(x: 300, y: 20, topBorder: 6) == .menuTab(0))
        #expect(bar.hit(x: 60, y: 20, topBorder: 6) == .caption)
        #expect(bar.hit(x: 260, y: 20, topBorder: 6) == .button(.newSession))
        #expect(bar.hit(x: 600, y: 20, topBorder: 6) == .caption)
        #expect(bar.hit(x: 1130, y: 20, topBorder: 6) == .button(.settings))
        #expect(bar.hit(x: 1090, y: 20, topBorder: 6) == .button(.find))
        #expect(bar.hit(x: 1050, y: 20, topBorder: 6) == .button(.dashboard))
        #expect(bar.hit(x: 1010, y: 20, topBorder: 6) == .button(.split))
        #expect(bar.hit(x: 970, y: 20, topBorder: 6) == .button(.quick))
        #expect(bar.hit(x: 1170, y: 20, topBorder: 6) == .button(.minimize))
        #expect(bar.hit(x: 1220, y: 20, topBorder: 6) == .button(.maximize))
        #expect(bar.hit(x: 1299, y: 20, topBorder: 6) == .button(.close))
        #expect(bar.hit(x: 1299, y: 2, topBorder: 6) == .top)
        #expect(bar.hit(x: 1299, y: 2, topBorder: 0) == .button(.close))
        #expect(bar.hit(x: 600, y: 40, topBorder: 6) == .outside)
    }

    @Test func captionButtonsWinWhenTheWindowIsNarrow() {
        let narrow = TitleBar(width: 150, sidebarWidth: 240, dpi: 96)
        #expect(narrow.hit(x: 20, y: 20, topBorder: 0) == .appIcon)
        #expect(narrow.hit(x: 50, y: 20, topBorder: 0) == .button(.minimize))
        #expect(narrow.hit(x: 149, y: 20, topBorder: 0) == .button(.close))
    }

    @Test func tipsNameTheCommandAndTheKeymapsChord() {
        #expect(TitleBar.Button.newSession.tip() == "New Session (Ctrl+Shift+T)")
        #expect(TitleBar.Button.find.tip([.find: "Ctrl+F"]) == "Find… (Ctrl+F)")
        #expect(TitleBar.Button.find.tip([.find: ""]) == "Find…")
        #expect(TitleBar.Button.close.tip() == nil)
        #expect(TitleBar.Button.settings.tip() == "Settings… (Ctrl+,)")
        #expect(TitleBar.Button.dashboard.tip() == "Dashboard (Ctrl+Shift+G)")
        #expect(TitleBar.Button.split.command == .toggleSplit && TitleBar.Button.quick.command == .quickTerminal)
        #expect(TitleBar.Button.allCases.filter(\.isCaption) == [.minimize, .maximize, .close])
    }
}