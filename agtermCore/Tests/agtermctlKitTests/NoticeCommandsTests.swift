import ArgumentParser
import Testing
import agtermCore
@testable import agtermctlKit

struct NoticeCommandsTests {
    #if os(Windows)
    private func request(_ argv: [String]) throws -> ControlRequest {
        guard let command = try Agtermctl.parseAsRoot(argv) as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test func subcommandsBuildTheirRequests() throws {
        #expect(try request(["notice", "list"]) == ControlRequest(cmd: .noticeList))
        #expect(try request(["notice", "position", "bottom"]) == ControlRequest(cmd: .noticePosition, args: ControlArgs(mode: "bottom")))
        #expect(try request(["notice", "dismiss"]) == ControlRequest(cmd: .noticeDismiss))
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["notice", "position", "left"]) }
    }
    #endif

    @Test func humanOutputIsThePositionThenALineANotice() {
        var result = ControlResult()
        result.noticeBar = ControlNoticeBar(position: "top", notices: [
            ControlNotice(text: "WSL Ubuntu: install failed", severity: "error", actions: ["retry", "openLog"]),
            ControlNotice(text: "Connecting to WSL Debian…", severity: "progress", dismissed: true),
        ])
        #expect(SocketClient.formatResponse(ControlResponse(ok: true, result: result))
            == "bar at top\nerror\tWSL Ubuntu: install failed\tretry,openLog\nprogress\tConnecting to WSL Debian…\tdismissed")
        result.noticeBar = ControlNoticeBar(position: "bottom", notices: [])
        #expect(SocketClient.formatResponse(ControlResponse(ok: true, result: result)) == "bar at bottom\nno notices")
    }
}
