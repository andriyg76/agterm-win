import ArgumentParser
import Testing
import agtermCore
@testable import agtermctlKit

struct WSLCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        guard let command = try Agtermctl.parseAsRoot(argv) as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test func subcommandsBuildTheirRequests() throws {
        #expect(try request(["wsl", "list"]) == ControlRequest(cmd: .wslList))
        #expect(try request(["wsl", "start", "Ubuntu"]) == ControlRequest(cmd: .wslStart, args: ControlArgs(name: "Ubuntu")))
        #expect(try request(["wsl", "launch", "Debian", "off"]) == ControlRequest(cmd: .wslLaunch, args: ControlArgs(name: "Debian", mode: "off")))
    }

    @Test func launchTakesOnlyOnOrOff() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["wsl", "launch", "Ubuntu", "yes"]) }
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["wsl", "launch", "Ubuntu"]) }
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["wsl", "start"]) }
    }

    @Test func humanOutputIsALineADistribution() {
        let servers = [ControlWSLServer(distribution: "Ubuntu", started: true, connected: true, launch: "atLaunch"),
                       ControlWSLServer(distribution: "Debian", started: true, connected: false, launch: "manual"),
                       ControlWSLServer(distribution: "Arch", started: false, connected: false, launch: nil)]
        let text = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(wsl: servers)))
        #expect(text == "Ubuntu\tconnected\tstarts at launch\nDebian\tstarted\tmanual\nArch\tstopped\tasks on first start")
        #expect(SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(wsl: []))) == "no WSL distributions")
    }
}
