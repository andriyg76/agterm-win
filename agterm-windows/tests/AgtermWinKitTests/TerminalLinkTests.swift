import AgtermWinKit
import Testing

struct TerminalLinkTests {
    private func url(_ line: String, at index: Int) -> String? { TerminalLink.url(in: Array(line), at: index) }

    @Test func findsTheAddressUnderTheClick() {
        let line = "see https://agterm.com/docs for more"
        #expect(url(line, at: 4) == "https://agterm.com/docs")
        #expect(url(line, at: 26) == "https://agterm.com/docs")
        #expect(url(line, at: 2) == nil)
        #expect(url(line, at: 28) == nil)
    }

    @Test func trimsClosingPunctuationButKeepsBalancedParentheses() {
        #expect(url("(https://a.io/x).", at: 3) == "https://a.io/x")
        #expect(url("https://en.wikipedia.org/wiki/A_(b),", at: 0) == "https://en.wikipedia.org/wiki/A_(b)")
        #expect(url("'http://a.io/'", at: 5) == "http://a.io/")
    }

    @Test func wwwGetsHTTPS() {
        #expect(url("go to www.example.org now", at: 8) == "https://www.example.org")
    }

    @Test func otherSchemesAndBareWordsDoNotOpen() {
        #expect(url(#"file:///C:/Windows/notepad.exe"#, at: 3) == nil)
        #expect(url("example.org", at: 3) == nil)
        #expect(url("https://", at: 2) == nil)
        #expect(url("x=https://a.io", at: 0) == nil)
        #expect(url("x=https://a.io", at: 3) == "https://a.io")
    }

    @Test func rowSkipsWideTailsAndMapsTheClickedCell() {
        let runes: [UInt32] = [0x4F60, TerminalLink.wideTail, 0x20, 0x61, 0]
        let row = TerminalLink.row(runes, column: 1)
        #expect(String(row.text) == "你 a ")
        #expect(row.index == 0)
        #expect(TerminalLink.row(runes, column: 3).index == 2)
    }
}
