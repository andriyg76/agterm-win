import AgtermWinKit
import Testing

struct TitleBarTests {
    private let bar = TitleBar(width: 1300, sidebarWidth: 240, dpi: 96)

    @Test func actionGroupsPrecedeTheNativeCaptionControls() {
        #expect(TitleBar.Button.trailing == [.scratch, .split, .overlays, .dashboard, .quick])
        #expect(bar.span(of: .scratch) == .init(left: 952, right: 992))
        #expect(bar.span(of: .overlays).right + 10 == bar.span(of: .dashboard).left)
        #expect(bar.span(of: .quick).right == bar.span(of: .minimize).left)
        #expect(bar.span(of: .maximize) == .init(left: 1208, right: 1254))
        #expect(bar.span(of: .close) == .init(left: 1254, right: 1300))
    }

    @Test func titleClearsTheMenuInTheCombinedCaption() {
        #expect(bar.title == .init(left: 388, right: 942))
        #expect(TitleBar(width: 1300, sidebarWidth: 0, dpi: 96).title.left == 388)
        #expect(TitleBar(width: 200, sidebarWidth: 240, dpi: 96).title.isEmpty)
        #expect(bar.menuSpans.map { MenuBarLayout.titles[$0.index] } == ["File", "Edit", "View", "Navigate", "Help"])
    }

    @Test func spansScaleWithTheMonitor() {
        let scaled = TitleBar(width: 2600, sidebarWidth: 480, dpi: 192)
        #expect(scaled.height == 80 && scaled.contentTop == 80)
        #expect(scaled.title.left == 776)
        #expect(scaled.span(of: .close) == .init(left: 2508, right: 2600))
    }

    @Test func hitSeparatesCombinedCaptionControlsFromContent() {
        #expect(bar.hit(x: 10, y: 20, topBorder: 6) == .appIcon)
        #expect(bar.hit(x: 100, y: 20, topBorder: 6) == .menuTab(0))
        #expect(bar.hit(x: 100, y: 40, topBorder: 6) == .outside)
        #expect(bar.hit(x: 600, y: 20, topBorder: 6) == .caption)
        for button in TitleBar.Button.allCases {
            let span = bar.span(of: button)
            #expect(bar.hit(x: (span.left + span.right) / 2, y: 20, topBorder: 6) == .button(button))
        }
        #expect(bar.hit(x: 1299, y: 2, topBorder: 6) == .top)
        #expect(bar.hit(x: 1299, y: 2, topBorder: 0) == .button(.close))
    }

    @Test func captionButtonsWinWhenTheWindowIsNarrow() {
        let narrow = TitleBar(width: 150, sidebarWidth: 240, dpi: 96)
        #expect(narrow.hit(x: 7, y: 20, topBorder: 0) == .appIcon)
        #expect(narrow.hit(x: 20, y: 20, topBorder: 0) == .button(.minimize))
        #expect(narrow.hit(x: 149, y: 20, topBorder: 0) == .button(.close))
    }

    @Test func tipsNameTheCommandAndTheKeymapsChord() {
        #expect(TitleBar.Button.scratch.tip([.toggleScratch: "Ctrl+Alt+J"]) == "Scratch (Ctrl+Alt+J)")
        #expect(TitleBar.Button.scratch.tip([.toggleScratch: ""]) == "Scratch")
        #expect(TitleBar.Button.close.tip() == nil)
        #expect(TitleBar.Button.sidebar.command == .toggleSidebar)
        #expect(bar.span(of: .sidebar).right <= bar.menuSpans[0].span.left)
        #expect(TitleBar.Button.dashboard.tip() == "Dashboard (Ctrl+Shift+G)")
        #expect(TitleBar.Button.split.command == .toggleSplit && TitleBar.Button.quick.command == .quickTerminal)
        #expect(TitleBar.Button.allCases.filter(\.isCaption) == [.minimize, .maximize, .close])
    }
}
