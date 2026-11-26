import Foundation
import AgtermWinKit
import agtermCore

/// WSLServerInspection is the outcome of probing a remote before the catalog connects.
struct WSLServerInspection: Equatable {
    var health: WSLServerHealth
    /// detail carries probe stderr or install context for logs and notices.
    var detail: String
}

/// An agterm-server on a `remote.properties` remote, such as a WSL distribution. Every command is agtermCore's own argv
/// for the name, its defined command first, run here as one Windows command line.
struct RemoteHost {
    let name: String

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

    /// inspect probes whether agterm-server is installed, which version runs, and whether its user service is active;
    /// the Mac has no such step, since a Mac user installs and starts the server once and agterm-win does it on demand.
    func inspect() -> WSLServerInspection {
        let ping = runLine(":")
        guard ping.status == 0 else {
            let detail = ping.stderr.isEmpty ? "exit \(ping.status)" : ping.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return WSLServerInspection(health: .distributionUnreachable(detail), detail: detail)
        }
        let binary = runLine("test -x \"$HOME/.local/bin/agtermctl\" -o -x \"$HOME/.local/lib/agterm-server/agtermctl\"")
        guard binary.status == 0 else {
            return WSLServerInspection(health: .missingInstall,
                                     detail: "no agtermctl in ~/.local/bin or ~/.local/lib/agterm-server")
        }
        let version: (status: Int32, stdout: String, stderr: String)
        do {
            version = try run(RemoteSession.controlCommand(host: name, arguments: ["version"]))
        } catch {
            return WSLServerInspection(health: .versionUnknown("\(error)"), detail: "\(error)")
        }
        guard version.status == 0 else {
            let detail = version.stderr.isEmpty ? "agtermctl version exited \(version.status)" : version.stderr
            return WSLServerInspection(health: .versionUnknown(detail), detail: detail)
        }
        guard let data = version.stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(ControlResponse.self, from: data),
              response.ok else {
            let message = version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return WSLServerInspection(health: .versionUnknown("not agterm-server"), detail: message)
        }
        let installed = response.result?.versions?.server ?? response.result?.app?.version ?? ""
        guard !installed.isEmpty else {
            return WSLServerInspection(health: .versionUnknown("version reply had no server number"), detail: version.stdout)
        }
        let active = runLine("systemctl --user is-active agterm-server 2>/dev/null").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if active == "active" {
            return WSLServerInspection(health: .ready(installedVersion: installed), detail: installed)
        }
        return WSLServerInspection(health: .serviceStopped(installedVersion: installed),
                                 detail: active.isEmpty ? "service not active" : "systemctl: \(active)")
    }

    /// startService asks systemd to start the user agterm-server unit and returns whether it became active.
    func startService() -> (ok: Bool, message: String) {
        let start = runLine("systemctl --user start agterm-server 2>&1")
        guard start.status == 0 else {
            let text = start.stdout.isEmpty ? start.stderr : start.stdout
            return (false, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for _ in 0..<25 {
            let active = runLine("systemctl --user is-active agterm-server 2>/dev/null")
            if active.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "active" { return (true, "") }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return (false, "agterm-server did not become active after start")
    }

    func tree() throws -> ControlRemoteTree {
        let result = try run(RemoteSession.treeCommand(host: name))
        guard result.status == 0 else { throw Failure.command("zmx tree", result.status, result.stderr) }
        let response = try JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8))
        guard response.ok, let tree = response.result?.remote else {
            throw Failure.reply("zmx tree refused: \(response.error ?? "no remote tree in the reply")")
        }
        return tree
    }

    /// attachCommandLine is the Windows command line that attaches a ConPTY to `daemon` for the pane's lifetime; the
    /// remote's command runs in that ConPTY, which is the pty the attach needs.
    func attachCommandLine(endpoint: ControlZmxEndpoint, daemon: String) throws -> String {
        Self.commandLine(try RemoteSession.attachCommand(host: name, endpoint: endpoint, daemon: daemon))
    }

    static func commandLine(_ argv: [String]) -> String { argv.map(WindowsCommandLine.quoted).joined(separator: " ") }

    /// start runs `argv`, with `input` on its stdin when given.
    func start(_ argv: [String], input: URL? = nil, captureErrors: Bool) throws -> HiddenProcess {
        try HiddenProcess(commandLine: Self.commandLine(argv), input: input, captureErrors: captureErrors)
    }

    /// runLine runs one shell line through the remote's command without throwing; probe steps use this so every failure
    /// carries stderr.
    func runLine(_ line: String) -> (status: Int32, stdout: String, stderr: String) {
        guard let prefix = RemoteCommands.current.command(for: name) else {
            return (-1, "", "\(name) is not defined in \(RemoteCommands.fileName)")
        }
        return (try? run(prefix + ["/bin/sh", "-c", line])) ?? (status: -1, stdout: "", stderr: "\(prefix[0]) did not start")
    }

    /// run runs `argv` to completion, with `input` on its stdin, and returns what it printed.
    func run(_ argv: [String], input: URL? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = try start(argv, input: input, captureErrors: true)
        process.closeInput()
        let data = process.readToEnd()
        let stderr = process.readErrorsToEnd()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), RemoteCommands.outputText(stderr))
    }
}
