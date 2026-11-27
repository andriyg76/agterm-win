import Foundation
import Testing
@testable import agtermCore

@Suite("Ctrl-Tab session switcher")
struct SessionSwitcherTests {
    @Test("session switcher starts from the previous MRU entry and wraps")
    func sessionSwitcher() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        var switcher = SessionSwitcherModel()
        switcher.begin([first])
        #expect(!switcher.isActive)
        switcher.begin([first, second, third])
        #expect(switcher.current == second)
        switcher.advance(reverse: true)
        #expect(switcher.current == first)
        switcher.advance(reverse: true)
        #expect(switcher.current == third)
        switcher.advance()
        #expect(switcher.current == first)
        switcher.end()
        #expect(!switcher.isActive)
    }

    @Test("Ctrl release commits the highlighted candidate, or nothing")
    func sessionSwitcherCommitTarget() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let live: Set<UUID> = [first, second, third]
        var switcher = SessionSwitcherModel()
        #expect(switcher.commitTarget(liveIDs: live) == nil)
        switcher.begin([first])
        #expect(switcher.commitTarget(liveIDs: live) == nil)

        switcher.begin([first, second, third])
        #expect(switcher.commitTarget(liveIDs: live) == second)
        switcher.advance()
        #expect(switcher.commitTarget(liveIDs: live) == third)
        #expect(switcher.commitTarget(liveIDs: live.subtracting([third])) == nil)
        switcher.advance(reverse: true)
        #expect(switcher.commitTarget(liveIDs: live) == second)

        switcher.end()
        switcher.end()
        #expect(!switcher.isActive)
        #expect(switcher.commitTarget(liveIDs: live) == nil)
    }

    @Test("the switcher cycles at most ten candidates")
    func sessionSwitcherCandidateCap() {
        let ids = (0..<12).map { _ in UUID() }
        var recency = RecencyStack<UUID>()
        for id in ids { recency.push(id) }
        var switcher = SessionSwitcherModel()
        switcher.begin(recency.top(SessionSwitcherModel.maxCandidates, in: Set(ids)))
        #expect(switcher.ordered.count == 10)
    }

    @Test("the switcher runs only when nothing modal owns the keyboard")
    func canSwitch() {
        func allowed(zoomed: Bool = false, dashboardOpen: Bool = false, modalPending: Bool = false,
                     dialogVisible: Bool = false, popoverOpen: Bool = false) -> Bool {
            SessionSwitcherModel.canSwitch(zoomed: zoomed, dashboardOpen: dashboardOpen, modalPending: modalPending,
                                           dialogVisible: dialogVisible, popoverOpen: popoverOpen)
        }
        #expect(allowed())
        #expect(!allowed(zoomed: true))
        #expect(!allowed(dashboardOpen: true))
        #expect(!allowed(modalPending: true))
        #expect(!allowed(dialogVisible: true))
        #expect(!allowed(popoverOpen: true))
    }
}
