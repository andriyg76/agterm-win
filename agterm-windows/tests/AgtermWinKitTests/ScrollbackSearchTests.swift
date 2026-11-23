import AgtermWinKit
import Testing

struct ScrollbackSearchTests {
    private let lines = ["make build", "error: Build failed", "", "BUILD again", "done"]
    private func runes(_ index: Int) -> [UInt32] { lines[index].unicodeScalars.map(\.value) }
    private func find(_ needle: String, after: ScrollbackSearch.Match?, backward: Bool = true) -> ScrollbackSearch.Match? {
        ScrollbackSearch.find(needle, lineCount: lines.count, line: runes, after: after, backward: backward)
    }

    @Test func firstBackwardMatchIsTheNewest() {
        #expect(find("build", after: nil) == .init(line: 3, column: 0, cells: 5))
    }

    @Test func backwardWalksToOlderMatchesThenWraps() {
        let newest = find("build", after: nil)
        let older = find("build", after: newest)
        #expect(older == .init(line: 1, column: 7, cells: 5))
        let oldest = find("build", after: older)
        #expect(oldest == .init(line: 0, column: 5, cells: 5))
        #expect(find("build", after: oldest) == newest)
    }

    @Test func forwardWalksToNewerMatches() {
        #expect(find("build", after: .init(line: 0, column: 5, cells: 5), backward: false) == .init(line: 1, column: 7, cells: 5))
        #expect(find("build", after: nil, backward: false) == .init(line: 0, column: 5, cells: 5))
    }

    @Test func aSingleMatchFindsItselfAgain() {
        let only = find("done", after: nil)
        #expect(only == .init(line: 4, column: 0, cells: 4))
        #expect(find("done", after: only) == only)
    }

    @Test func noMatchOrEmptyNeedleFindsNothing() {
        #expect(find("missing", after: nil) == nil)
        #expect(find("", after: nil) == nil)
    }

    @Test func matchesCountWideCharactersAsTwoCells() {
        let row: [UInt32] = [0x4F60, TerminalLink.wideTail, 0x597D, TerminalLink.wideTail, 0x21]
        let found = ScrollbackSearch.find("好!", lineCount: 1, line: { _ in row }, after: nil, backward: true)
        #expect(found == .init(line: 0, column: 2, cells: 3))
    }
}
