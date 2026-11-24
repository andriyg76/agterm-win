import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlWSLTests {
    @Test func parseNamesTheDistributionAndTheLaunchState() throws {
        #expect(try ControlWSL.parse(ControlRequest(cmd: .wslList)).get() == .list)
        #expect(try ControlWSL.parse(ControlRequest(cmd: .wslStart, args: ControlArgs(name: " Ubuntu "))).get() == .start("Ubuntu"))
        #expect(try ControlWSL.parse(ControlRequest(cmd: .wslLaunch, args: ControlArgs(name: "Ubuntu", mode: "on"))).get()
            == .launch("Ubuntu", true))
        #expect(try ControlWSL.parse(ControlRequest(cmd: .wslLaunch, args: ControlArgs(name: "Ubuntu", mode: "off"))).get()
            == .launch("Ubuntu", false))
    }

    @Test func parseRefusesAMissingDistributionOrState() {
        func message(_ request: ControlRequest) -> String? {
            if case .failure(let rejection) = ControlWSL.parse(request) { return rejection.message }
            return nil
        }
        #expect(message(ControlRequest(cmd: .wslStart)) == "wsl.start requires a distribution")
        #expect(message(ControlRequest(cmd: .wslLaunch, args: ControlArgs(name: "  "))) == "wsl.launch requires a distribution")
        #expect(message(ControlRequest(cmd: .wslLaunch, args: ControlArgs(name: "Ubuntu", mode: "toggle"))) == "wsl.launch requires on or off")
    }

    @Test func aMacRefusesEveryWSLCommand() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        for command in [Command.wslList, .wslStart, .wslLaunch] {
            let response = await dispatcher.dispatch(ControlRequest(cmd: command, args: ControlArgs(name: "Ubuntu", mode: "on")))
            #expect(response == ControlResponse(ok: false, error: "\(command.rawValue) is only available in agterm for Windows"))
        }
        #expect(actions.calls.isEmpty)
    }

    @Test func wslFieldsRoundTripAndAreOmittedWhenAbsent() throws {
        let server = ControlWSLServer(distribution: "Ubuntu", started: true, connected: false, launch: nil)
        let result = ControlResult(wsl: [server])
        #expect(try JSONDecoder().decode(ControlResult.self, from: JSONEncoder().encode(result)) == result)
        let json = String(decoding: try JSONEncoder().encode(server), as: UTF8.self)
        #expect(!json.contains("launch"))
        var tree = ControlTree(workspaces: [])
        #expect(!String(decoding: try JSONEncoder().encode(tree), as: UTF8.self).contains("wslServers"))
        tree.wslServers = [server]
        #expect(try JSONDecoder().decode(ControlTree.self, from: JSONEncoder().encode(tree)).wslServers == [server])
    }
}
