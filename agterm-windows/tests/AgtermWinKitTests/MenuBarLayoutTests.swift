import AgtermWinKit
import Testing

struct MenuBarLayoutTests {
    @Test func allFiveMenusFitOnAWideBar() {
        let limit: Int32 = 1200
        let start: Int32 = 100
        let spans = MenuBarLayout.menuSpans(origin: start, limit: limit, dpi: 96)
        #expect(spans.count == MenuBarLayout.titles.count)
        #expect(spans[0].index == 0 && spans[0].span.left == start)
    }

    @Test func dropsMenusThatWouldOverlapTheRightGroup() {
        let start: Int32 = 10
        let limit: Int32 = 80
        let spans = MenuBarLayout.menuSpans(origin: start, limit: limit, dpi: 96)
        #expect(spans.count < MenuBarLayout.titles.count)
    }
}