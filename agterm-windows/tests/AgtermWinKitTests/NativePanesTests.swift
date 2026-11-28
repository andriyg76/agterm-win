import AgtermWinKit
import Foundation
import Testing
import agtermCore

struct NativeSplitTests {
    @Test func ratiosClampAsOnAMac() {
        #expect(NativeSplit.clamp(0) == 0.05 && NativeSplit.clamp(2) == 0.95 && NativeSplit.clamp(.nan) == 0.5)
    }

    @Test func aShownSplitSharesTheAreaAroundItsDivider() {
        let area = NativeOverlay.Rect(x: 240, y: 36, width: 1004, height: 600)
        let layout = PaneLayout(area: area, split: NativeSplit(axis: .leftRight, ratio: 0.5), divider: 4)
        #expect(layout.primary == .init(x: 240, y: 36, width: 500, height: 600))
        #expect(layout.divider == .init(x: 740, y: 36, width: 4, height: 600))
        #expect(layout.split == .init(x: 744, y: 36, width: 500, height: 600))
        #expect(layout.onDivider(x: 741, y: 100) && !layout.onDivider(x: 700, y: 100) && layout.onDivider(x: 738, y: 100, slop: 2))
        let rows = PaneLayout(area: area, split: NativeSplit(axis: .topBottom, ratio: 0.25), divider: 4)
        #expect(rows.primary?.height == 149 && rows.split?.y == 36 + 149 + 4)
    }

    @Test func aHiddenSplitShowsTheFocusedPaneAlone() {
        let area = NativeOverlay.Rect(x: 0, y: 0, width: 100, height: 100)
        let focusedSplit = PaneLayout(area: area, split: NativeSplit(shown: false, focused: true), divider: 4)
        #expect(focusedSplit.split == area && focusedSplit.primary == nil && focusedSplit.divider == nil)
        #expect(PaneLayout(area: area, split: nil, divider: 4).primary == area)
    }

    @Test func aDragPutsTheDividersMiddleUnderThePointer() {
        let area = NativeOverlay.Rect(x: 100, y: 0, width: 404, height: 100)
        #expect(PaneLayout.ratio(at: 302, 50, area: area, axis: .leftRight, divider: 4) == 0.5)
        #expect(PaneLayout.ratio(at: 0, 50, area: area, axis: .leftRight, divider: 4) == 0.05)
    }

    @Test func panesParseAsOnAMacAndTheScratchIsOnScreenFirst() {
        #expect(NativePane(controlName: "top") == .primary && NativePane(controlName: "bottom") == .split)
        #expect(NativePane(controlName: "scratch") == .scratch && NativePane(controlName: "overlay") == nil)
        #expect(NativePane.onScreen(split: NativeSplit(focused: true), scratchShown: false) == .split)
        #expect(NativePane.onScreen(split: NativeSplit(focused: true), scratchShown: true) == .scratch)
        #expect(NativePane.onScreen(split: nil, scratchShown: false) == .primary)
    }
}

struct NativeDashboardTests {
    @Test func cellsFillTheGridRowByRow() {
        let cells = NativeDashboard.cells(in: .init(x: 0, y: 0, width: 306, height: 206), count: 3, gap: 2, caption: 20)
        #expect(cells.count == 3)
        #expect(cells[0].frame == .init(x: 2, y: 2, width: 150, height: 100))
        #expect(cells[1].frame.x == 154 && cells[2].frame.y == 104)
        #expect(cells[0].caption.height == 20 && cells[0].terminal == .init(x: 2, y: 22, width: 150, height: 80))
        #expect(NativeDashboard.cell(at: 160, 10, in: cells) == 1 && NativeDashboard.cell(at: 153, 10, in: cells) == nil)
    }

    @Test func membersExpandSplitsDropRepeatsAndCapAtNine() {
        let split = UUID(), plain = UUID()
        let both = NativeDashboard.members(for: [.init(session: split, pane: nil), .init(session: split, pane: .primary), .init(session: plain, pane: nil)],
                                           hasSplit: { $0 == split })
        #expect(both.members.map(\.surface) == [.primary, .split, .primary] && both.dropped == 0)
        let many = NativeDashboard.members(for: (0..<6).map { _ in .init(session: UUID(), pane: nil) }, hasSplit: { _ in true })
        #expect(many.members.count == 9 && many.dropped == 3)
    }

    @Test func aSplitCellSaysWhichPaneItShows() {
        let member = DashboardMember(session: UUID(), surface: .split)
        #expect(NativeDashboard.caption(name: "api", member: member, split: .topBottom) == "api · bottom")
        #expect(NativeDashboard.caption(name: "api", member: member, split: nil) == "api")
    }

    @Test func theQuickPanelSitsOnTheMonitorCappedAsOnAMac() {
        let large = QuickPanel.frame(work: .init(x: 0, y: 0, width: 2560, height: 1400), dpi: 96)
        #expect(large.width == 1100 && large.height == 700 && large.x == 730 && large.y == 48)
        let small = QuickPanel.frame(work: .init(x: 1920, y: 0, width: 1000, height: 600), dpi: 96)
        #expect(small.width == 900 && small.height == 540 && small.x == 1970)
        #expect(QuickPanel.frame(work: .init(x: 0, y: 0, width: 5120, height: 2800), dpi: 192).width == 2200)
    }
}
