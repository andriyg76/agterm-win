import Testing
@testable import agtermCore

@MainActor
@Suite struct SessionPaneReportsTests {
    @Test func cwdIsSanitizedAndRoutedToItsPane() {
        let session = Session(initialCwd: "/tmp/start")

        #expect(session.recordReportedCwd("/tmp/\u{7}main", pane: .left))
        #expect(session.recordReportedCwd("/tmp/right\n", pane: .right))
        #expect(session.recordReportedCwd("/tmp/docs", pane: .scratch))

        #expect(session.currentCwd == "/tmp/main")
        #expect(session.splitCwd == "/tmp/right")
        #expect(session.scratchCwd == "/tmp/docs")
    }

    @Test func anEqualCwdReportsNoChange() {
        let session = Session(initialCwd: "/tmp/start")
        session.recordReportedCwd("/tmp/repo", pane: .left)

        #expect(!session.recordReportedCwd("/tmp/repo", pane: .left))
    }

    @Test func titleIsSanitizedAndRoutedToItsPane() {
        let session = Session(initialCwd: "/tmp/start")

        #expect(session.recordReportedTitle("✳ main\u{7}", pane: .left))
        #expect(session.recordReportedTitle("split", pane: .right))

        #expect(session.oscTitle == "✳ main")
        #expect(session.splitTitle == "split")
        #expect(session.displayName == "✳ main")
    }

    @Test func anEqualTitleReportsNoChange() {
        let session = Session(initialCwd: "/tmp/start")
        session.recordReportedTitle("claude", pane: .left)

        #expect(!session.recordReportedTitle("claude", pane: .left))
    }

    @Test func aScratchTitleIsIgnored() {
        let session = Session(initialCwd: "/tmp/start")

        #expect(!session.recordReportedTitle("scratch", pane: .scratch))
        #expect(session.oscTitle == nil)
    }

    @Test func aTitleEqualToThePaneCwdIsDroppedAfterSanitizing() {
        let session = Session(initialCwd: "/tmp/start")
        session.oscTitle = "existing"
        session.recordReportedCwd("/tmp/repo", pane: .left)

        #expect(!session.recordReportedTitle("/tmp/\u{7}repo", pane: .left))
        #expect(session.oscTitle == "existing")
    }

    @Test func aSplitComparesItsOwnCwd() {
        let session = Session(initialCwd: "/tmp/start")
        session.initialSplitCwd = "/tmp/right"

        #expect(!session.recordReportedTitle("/tmp/right", pane: .right))
        #expect(session.recordReportedTitle("/tmp/start", pane: .right))
        #expect(session.splitTitle == "/tmp/start")
    }
}
