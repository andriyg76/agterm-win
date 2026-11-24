import Foundation
import AgtermWinKit
import NativeShim
import agtermCore

/// An agterm-server inside a WSL distribution, reached through `wsl.exe` where the Mac reaches a host through ssh. The
/// remote command lines are agtermCore's own: `wsl.exe -e /bin/sh -c LINE` stands in for sshd running the account
/// shell with LINE, so the last argument of `RemoteSession`'s ssh argv is all this needs.
struct WSLHost {
    let distribution: String

    private static let system32 = (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows") + "\\System32\\"
    private static let wsl = system32 + "wsl.exe"
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

    /// installServer installs agterm-server `version` in the distribution as `agtermctl server install` does over ssh:
    /// the distribution's architecture, that release's tarball from GitHub checked against `checksums` (the sha256 this
    /// build recorded), unpacked in place of the live one, then its install.sh. It returns install.sh's exit code.
    func installServer(version: String, checksums: String, progress: (String) -> Void) throws -> Int32 {
        let probe = try run("uname -m")
        guard probe.status == 0 else { throw Failure.command("uname -m", probe.status, probe.stderr) }
        let architecture = try ServerInstall.architecture(probeOutput: Data(probe.stdout.utf8))
        let asset = ServerInstall.assetName(version: version, architecture: architecture)
        let expected = try ServerInstall.checksum(for: asset, in: checksums)
        let url = ServerInstall.downloadURL(version: version, architecture: architecture)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(asset)")
        defer { try? FileManager.default.removeItem(at: file) }
        progress("downloading \(url.absoluteString)")
        try Self.download(url, to: file)
        guard try Self.sha256(of: file) == expected else {
            throw Failure.reply("\(asset) does not match the sha256 this build recorded; nothing was installed")
        }
        progress("unpacking \(asset) in \(distribution)")
        let connection = TerminfoInstall.Connection(destination: Self.placeholderHost)
        let unpacked = try run(ServerInstall.unpackCommand(connection).last!, input: file)
        guard unpacked.status == 0 else { throw Failure.command("unpack", unpacked.status, unpacked.stderr) }
        // one stream, so a chatty install.sh cannot fill the stderr pipe while stdout is read
        let installed = try run(ServerInstall.installerCommand(connection).last! + " 2>&1")
        progress(installed.stdout)
        return installed.status
    }

    /// download fetches a release asset with the system curl.exe, over HTTPS only and within ServerInstall's limit.
    private static func download(_ url: URL, to file: URL) throws {
        let arguments = [system32 + "curl.exe", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
                         "--proto-redir", "=https", "--max-filesize", String(ServerInstall.downloadLimit), "--output", file.path,
                         url.absoluteString]
        let curl = try HiddenProcess(commandLine: arguments.map(windowsQuoted).joined(separator: " "), captureErrors: true)
        curl.closeInput()
        _ = curl.readToEnd()
        let stderr = curl.readErrorsToEnd()
        curl.waitUntilExit()
        guard curl.terminationStatus == 0 else {
            throw Failure.command("downloading \(url.absoluteString)", curl.terminationStatus, String(decoding: stderr, as: UTF8.self))
        }
    }

    private static func sha256(of file: URL) throws -> String {
        var digest = [UInt8](repeating: 0, count: 32)
        let status = nt_sha256_file(Array(file.path.utf16) + [0], &digest)
        guard status == 0 else { throw Failure.reply("hashing \(file.path) failed: \(String(UInt32(bitPattern: status), radix: 16))") }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// attachCommandLine is the Windows command line that attaches a ConPTY to `daemon` for the pane's lifetime.
    func attachCommandLine(endpoint: ControlZmxEndpoint, daemon: String) throws -> String {
        commandLine(try RemoteSession.attachCommand(host: Self.placeholderHost, endpoint: endpoint, daemon: daemon).last!)
    }

    /// commandLine is the Windows command line that runs `remoteShellLine` under `/bin/sh -c` in the distribution.
    func commandLine(_ remoteShellLine: String) -> String {
        [Self.wsl, "-d", distribution, "-e", "/bin/sh", "-c", remoteShellLine].map(Self.windowsQuoted).joined(separator: " ")
    }

    /// start runs `line` under `/bin/sh -c` in the distribution, with `input` on its stdin when given.
    func start(_ line: String, input: URL? = nil, captureErrors: Bool) throws -> HiddenProcess {
        try HiddenProcess(commandLine: commandLine(line), input: input, captureErrors: captureErrors)
    }

    /// run runs `line` to completion, with `input` on its stdin, and returns what it printed.
    func run(_ line: String, input: URL? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = try start(line, input: input, captureErrors: true)
        process.closeInput()
        let data = process.readToEnd()
        let stderr = process.readErrorsToEnd()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }

    private func run(_ line: String, what: String) throws -> Data {
        let result = try run(line)
        guard result.status == 0 else { throw Failure.command(what, result.status, result.stderr) }
        return Data(result.stdout.utf8)
    }

    static func windowsQuoted(_ argument: String) -> String { WindowsCommandLine.quoted(argument) }
}
