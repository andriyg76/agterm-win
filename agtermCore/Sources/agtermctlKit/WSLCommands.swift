import ArgumentParser
import agtermCore

// MARK: - wsl

#if os(Windows)
struct WSL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wsl",
        abstract: "The agterm-server in each WSL distribution (agterm-win).",
        subcommands: [List.self, Start.self, Launch.self]
    )

    struct List: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "List the distributions, which servers run, and which start at launch.")
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .wslList) }
    }

    struct Start: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start a distribution's agterm-server.",
            discussion: "It never asks whether the server starts at launch; `wsl launch` sets that.")
        @Argument(help: "The WSL distribution, as `wsl list` names it.") var distribution: String
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .wslStart, args: ControlArgs(name: distribution)) }
    }

    struct Launch: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set whether a distribution's agterm-server starts as agterm opens.",
            discussion: "off is a choice too: starting that server from the menu no longer asks.")
        @Argument(help: "The WSL distribution, as `wsl list` names it.") var distribution: String
        @Argument(help: "on or off.") var state: String
        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard state == "on" || state == "off" else { throw ValidationError("State must be on or off.") }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .wslLaunch, args: ControlArgs(name: distribution, mode: state))
        }
    }
}
#endif
