import Foundation
import Testing
@testable import agtermCore

struct ControlNoticeBarTests {
    @Test func noticeBarRoundTripsAndIsOmittedWhenAbsent() throws {
        let bar = ControlNoticeBar(position: "bottom", notices: [
            ControlNotice(text: "WSL Ubuntu: install failed", severity: "error", actions: ["retry", "openLog"]),
            ControlNotice(text: "Connecting to WSL Debian…", severity: "progress", dismissed: true),
        ])
        var result = ControlResult()
        result.noticeBar = bar
        #expect(try JSONDecoder().decode(ControlResult.self, from: JSONEncoder().encode(result)) == result)
        var tree = ControlTree(workspaces: [])
        #expect(!String(decoding: try JSONEncoder().encode(tree), as: UTF8.self).contains("noticeBar"))
        tree.noticeBar = bar
        #expect(try JSONDecoder().decode(ControlTree.self, from: JSONEncoder().encode(tree)).noticeBar == bar)
        let plain = String(decoding: try JSONEncoder().encode(ControlNotice(text: "a", severity: "info")), as: UTF8.self)
        #expect(!plain.contains("actions") && !plain.contains("dismissed"))
    }
}
