import AgtermWinKit
import Foundation
import Testing
import agtermCore

struct AgentActivityTests {
    private func update(_ status: AgentStatus, pane: StatusPane? = nil, autoReset: Bool = false, ifIdle: Bool = false)
        -> ControlSessionStatusUpdate {
        ControlSessionStatusUpdate(status: status, blink: nil, autoReset: autoReset, sound: nil, pane: pane, ifIdle: ifIdle)
    }

    @Test func blockHoldsAgainstAnotherPanesWrites() {
        var activity = AgentActivity()
        activity.apply(update(.blocked, pane: .left), hasSplit: true)
        activity.apply(update(.active, pane: .right), hasSplit: true)
        activity.apply(update(.idle, pane: .right), hasSplit: true)
        #expect(activity.indicator.status == .blocked)
        activity.apply(update(.active, pane: .left), hasSplit: true)
        #expect(activity.indicator.status == .active)
    }

    @Test func turnEndShowsAnotherPanesWork() {
        var activity = AgentActivity()
        activity.apply(update(.active, pane: .right), hasSplit: true)
        activity.apply(update(.active, pane: .left), hasSplit: true)
        activity.apply(update(.completed, pane: .left), hasSplit: true)
        #expect(activity.indicator.status == .active && activity.indicator.statusPane == .right)
        #expect(activity.activePanes == ["right"])
    }

    @Test func ifIdleSkipsABusyRowWithoutStamping() {
        var activity = AgentActivity()
        activity.apply(update(.active), hasSplit: false, now: Date(timeIntervalSince1970: 1))
        #expect(!activity.apply(update(.active, ifIdle: true), hasSplit: false, now: Date(timeIntervalSince1970: 2)))
        #expect(activity.changedAt == Date(timeIntervalSince1970: 1))
    }

    @Test func keystrokesClearByTheResetRule() {
        var activity = AgentActivity()
        activity.apply(update(.active), hasSplit: false)
        activity.clear(by: .other, pane: .left, reset: .firstKey)
        #expect(activity.indicator.status == .active)
        activity.clear(by: .interrupt, pane: .left, reset: .firstKey)
        #expect(activity.indicator.status == .idle)
        activity.apply(update(.blocked), hasSplit: false)
        activity.clear(by: .other, pane: .right, reset: .firstKey)
        #expect(activity.indicator.status == .blocked)
        activity.clear(by: .other, pane: .left, reset: .firstKey)
        #expect(activity.indicator.status == .idle)
    }

    @Test func visitEndsOnlyAnAutoResetStatus() {
        var activity = AgentActivity()
        activity.apply(update(.blocked), hasSplit: false)
        activity.visited()
        #expect(activity.indicator.status == .blocked)
        activity.apply(update(.completed, autoReset: true), hasSplit: false)
        activity.visited()
        #expect(activity.indicator.status == .idle)
    }

    @Test func aClosedPaneTakesItsStatusWithIt() {
        var activity = AgentActivity()
        activity.apply(update(.active, pane: .left), hasSplit: true)
        activity.apply(update(.blocked, pane: .right), hasSplit: true)
        activity.paneEnded(.right)
        #expect(activity.indicator.status == .active && activity.indicator.statusPane == .left)
    }

    @Test func glyphFollowsShapeAndColor() {
        #expect(StatusGlyph.character(.star) == "★")
        #expect(StatusGlyph.rgb(AgentIndicator(status: .blocked)) == 0xFF9F0A)
        #expect(StatusGlyph.rgb(AgentIndicator(status: .active, color: "#102030")) == 0x102030)
        #expect(StatusGlyph.rgb(AgentIndicator()) == nil)
    }

    @Test func swapMovesEachPanesReportWithItsTerminal() {
        var activity = AgentActivity()
        activity.apply(update(.active, pane: .left), hasSplit: true)
        activity.apply(update(.blocked, pane: .right), hasSplit: true)
        activity.swapped()
        #expect(activity.indicator.statusPane == .left && activity.activePanes == ["right"])
    }

    @Test func typedTextMapsToTheKeystrokeAMacReads() {
        #expect(AgentActivity.keystroke("\u{1B}") == .interrupt)
        #expect(AgentActivity.keystroke("\u{03}") == .interrupt)
        #expect(AgentActivity.keystroke("ls\r") == .submit)
        #expect(AgentActivity.keystroke("a") == .other)
        #expect(AgentActivity.keystroke("") == nil)
    }

    @Test func captionAddsTheAgentsContext() {
        #expect(TitleBar.caption(name: "build", context: "PR 12") == "build \u{2014} PR 12")
        #expect(TitleBar.caption(name: "build", context: nil) == "build")
        #expect(TitleBar.caption(name: nil, context: "x") == "agterm")
    }
}
