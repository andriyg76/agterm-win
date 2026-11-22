import Foundation
import agtermCore

/// An agterm-server inside a WSL distribution, reached through `wsl.exe` where the Mac reaches a host through ssh. The
/// remote command lines are agtermCore's own: `wsl.exe -e /bin/sh -c LINE` stands in for sshd running the account
/// shell with LINE, so the last argument of `RemoteSession`'s ssh argv is all this needs.
struct WSLHost {
    let distribution: String

    private static let wsl = (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows") + "\\System32\\wsl.exe"
    // RemoteSession validates an ssh destination; the name only reaches its argv prefix, which is dropped here
    private static let placeholderHost = "wsl"

    enum Failure: Error, CustomStringConvertible {
        case command(String, Int32, String)
        case reply(String)

        var description: String {
            switch self {
            case .command(let what, let code, let stderr): "\(what) exited \(code): \(stderr)"
            case .reply(let message): message
            }
        }
    }

    func tree() throws -> ControlRemoteTree {
        let line = try RemoteSession.treeCommand(host: Self.placeholderHost).last!
        let data = try run(line, what: "zmx tree")
        let response = try JSONDecoder().decode(ControlResponse.self, from: data)
        guard response.ok, let tree = response.result?.remote else {
            throw Failure.reply("zmx tree refused: \(response.error ?? "no remote tree in the reply")")
        }
        return tree
    }

    /// attachCommandLine is the Windows command line that attaches a ConPTY to `daemon` for the pane's lifetime.
    func attachCommandLine(endpoint: ControlZmxEndpoint, daemon: String) throws -> String {
        let line = try RemoteSession.attachCommand(host: Self.placeholderHost, endpoint: endpoint, daemon: daemon).last!
        return ([Self.wsl] + arguments(line)).map(Self.windowsQuoted).joined(separator: " ")
    }

    private func arguments(_ line: String) -> [String] {
        ["-d", distribution, "-e", "/bin/sh", "-c", line]
    }

    private func run(_ line: String, what: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.wsl)
        process.arguments = arguments(line)
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.command(what, process.terminationStatus, String(decoding: stderr, as: UTF8.self))
        }
        return data
    }

    /// windowsQuoted quotes one argument for CommandLineToArgvW, which is how wsl.exe splits its command line.
    static func windowsQuoted(_ argument: String) -> String {
        if !argument.isEmpty, !argument.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) { return argument }
        var quoted = "\""
        var backslashes = 0
        for character in argument {
            switch character {
            case "\\":
                backslashes += 1
            case "\"":
                quoted += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
                backslashes = 0
            default:
                quoted += String(repeating: "\\", count: backslashes) + String(character)
                backslashes = 0
            }
        }
        return quoted + String(repeating: "\\", count: backslashes * 2) + "\""
    }
}
