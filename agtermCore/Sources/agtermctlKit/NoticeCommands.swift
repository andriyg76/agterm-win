import ArgumentParser
import agtermCore

// MARK: - notice

#if os(Windows)
struct Notice: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notice",
        abstract: "The window's notice bar (agterm-win).",
        subcommands: [List.self, Position.self, Dismiss.self]
    )

    struct List: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Show where the bar sits and its notices, most important first.")
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .noticeList) }
    }

    struct Position: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Move the bar to the top or the bottom of the window.")
        @Argument(help: "top or bottom.") var position: String
        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard position == "top" || position == "bottom" else { throw ValidationError("Position must be top or bottom.") }
        }

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .noticePosition, args: ControlArgs(mode: position)) }
    }

    struct Dismiss: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Dismiss the notice the bar shows.",
            discussion: "It stays dismissed until its text changes; the next notice, if any, takes its place.")
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .noticeDismiss) }
    }
}
#endif
