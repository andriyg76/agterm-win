#if os(Windows)
import ArgumentParser
import Foundation
import agtermCore

/// Server is `server install` on agterm-win, where a host is a `remote.properties` remote, such as a WSL distribution.
struct Server: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "agterm-server on remote.properties remotes.", subcommands: [Install.self])

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install or upgrade agterm-server on a remote.properties remote.",
            discussion: """
            Installs the agterm-server release this agterm-win is locked to on a remote that remote.properties names, \
            as agterm-win does when one needs it: asks the remote for its architecture, downloads that release tarball \
            from GitHub, checks it against the sha256 agterm-win was built with, unpacks it into \
            ~/.local/lib/agterm-server and runs its installer, each through the remote's command. --from FILE uses a \
            tarball already on this PC instead. Exits 0 when installed, 3 when installed but the agent hooks are \
            incomplete, and 1 on failure, with the reason on stderr.
            """)
        @Argument(help: "The remote's name in remote.properties.") var destination: String
        @Option(name: .customLong("from"),
                help: ArgumentHelp("Use a tarball already on this PC instead of downloading one; it must still match the sha256.",
                                   valueName: "file"))
        var source: String?

        func run() throws {
            RemoteCommands.useConfigured()
            let code = try RemoteServerInstaller.install(destination: destination, source: source)
            if code != 0 { throw ExitCode(code) }
        }
    }
}

/// RemoteServerInstaller runs the steps `ServerInstaller` runs over ssh on a Mac through a remote's own command.
/// agterm-win's own install runs this command, so it is the one implementation.
enum RemoteServerInstaller {
    private static let system32 = (ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#) + #"\System32\"#

    static func install(destination: String, source: String?) throws -> Int32 {
        guard RemoteCommands.current.command(for: destination) != nil else {
            throw SocketClientError("'\(destination)' is not defined in \(RemoteCommands.fileName); agtermctl on Windows "
                + "installs agterm-server only on a remote defined there")
        }
        let connection = TerminfoInstall.Connection(destination: destination)
        let release = try self.release()

        let probe = try run(ServerInstall.probeCommand(connection))
        guard probe.status == 0 else {
            throw SocketClientError("exit \(probe.status) asking \(destination) for its architecture: \(probe.errors)")
        }
        let architecture: String
        do {
            architecture = try ServerInstall.architecture(probeOutput: probe.output)
        } catch ServerInstall.Failure.unsupportedArchitecture(let name) {
            throw SocketClientError("unsupported architecture '\(name)' on \(destination); agterm-server is built for "
                + ServerInstall.architectures.joined(separator: " and "))
        }
        let asset = ServerInstall.assetName(version: release.version, architecture: architecture)
        let expected: String
        do {
            expected = try ServerInstall.checksum(for: asset, in: release.checksums)
        } catch {
            throw SocketClientError("this agterm-win's \(ServerInstall.checksumFile) has no usable entry for \(asset): \(error)")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(asset)
        if let source {
            try snapshot(source, to: file)
        } else {
            let url = ServerInstall.downloadURL(version: release.version, architecture: architecture)
            say("downloading \(url.absoluteString)")
            let curl = try run([system32 + "curl.exe", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
                                "--proto-redir", "=https", "--max-filesize", String(ServerInstall.downloadLimit), "--output",
                                file.path, url.absoluteString])
            guard curl.status == 0 else { throw SocketClientError("could not download \(url.absoluteString): \(curl.errors)") }
        }
        guard try sha256(of: file) == expected else {
            throw SocketClientError("\(asset) does not match the sha256 this agterm-win was built with; nothing was installed")
        }

        say("unpacking \(asset) on \(destination)")
        let unpacked = try run(ServerInstall.unpackCommand(connection), input: file)
        guard unpacked.status == 0 else { throw SocketClientError("unpacking on \(destination) failed: exit \(unpacked.status): \(unpacked.errors)") }
        let installed = try run(ServerInstall.installerCommand(connection), passthrough: true)
        switch installed.status {
        case 0: say("installed agterm-server \(release.version) on \(destination)")
        case 3: say("installed agterm-server \(release.version) on \(destination); the agent hooks are incomplete")
        default: throw SocketClientError("the installer on \(destination) exited \(installed.status)")
        }
        return installed.status
    }

    /// release is the version and checksums agterm-win was built with: stage.ps1 puts both beside agtermctl.exe, and a
    /// build run from the source tree reads agterm-windows' own.
    private static func release() throws -> (version: String, checksums: String) {
        let beside = URL(fileURLWithPath: Bundle.main.executablePath ?? "").deletingLastPathComponent()
        let tree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("agterm-windows")
        func file(_ name: String, source: String) -> URL {
            let packaged = beside.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: packaged.path) ? packaged : tree.appendingPathComponent(source)
        }
        do {
            let version = try String(contentsOf: file("AGTERM_VERSION", source: "AGTERM_VERSION"), encoding: .utf8)
            let checksums = try String(contentsOf: file(ServerInstall.checksumFile, source: "vendor/server/\(ServerInstall.checksumFile)"),
                                       encoding: .utf8)
            return (version.split(whereSeparator: \.isNewline).first.map(String.init) ?? "", checksums)
        } catch {
            throw SocketClientError("no AGTERM_VERSION and \(ServerInstall.checksumFile) beside agtermctl: \(error)")
        }
    }

    // agterm-win reads these lines from a pipe as they come
    private static func say(_ line: String) {
        print(line)
        fflush(stdout)
    }

    private static func snapshot(_ source: String, to file: URL) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: source)[.size] as? Int) ?? nil
        guard let size else { throw SocketClientError("could not read \(source) as a regular file") }
        guard size <= ServerInstall.downloadLimit else { throw SocketClientError("\(source) is larger than \(ServerInstall.downloadLimit) bytes") }
        try Data(contentsOf: URL(fileURLWithPath: source)).write(to: file)
    }

    /// sha256 asks certutil, which every Windows has, for the file's digest: the one line of 64 hex digits it prints.
    private static func sha256(of file: URL) throws -> String {
        let hashed = try run([system32 + "certutil.exe", "-hashfile", file.path, "SHA256"])
        let digest = String(decoding: hashed.output, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.filter { !$0.isWhitespace }.lowercased() }
            .first { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }
        guard hashed.status == 0, let digest else { throw SocketClientError("certutil could not hash \(file.path): \(hashed.errors)") }
        return digest
    }

    /// executable is `name` as Process needs it: a path as given, else the first PATH directory holding it, `.exe` added
    /// when the name has no extension.
    private static func executable(_ name: String) -> URL {
        guard !name.contains("\\"), !name.contains("/") else { return URL(fileURLWithPath: name) }
        let file = name.contains(".") ? name : name + ".exe"
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ProcessInfo.processInfo.environment["Path"] ?? ""
        for directory in path.split(separator: ";") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(file)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return URL(fileURLWithPath: system32 + file)
    }

    /// run starts `argv`, with `input` on its stdin, and returns what it printed; `passthrough` sends its output to this
    /// command's stdout instead, stderr included, so a reader of one pipe sees every line in order.
    private static func run(_ argv: [String], input: URL? = nil, passthrough: Bool = false) throws
        -> (status: Int32, output: Data, errors: String) {
        let process = Process()
        process.executableURL = executable(argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardInput = try input.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        if passthrough {
            process.standardError = FileHandle.standardOutput
        } else {
            process.standardOutput = output
            process.standardError = errors
        }
        do {
            try process.run()
        } catch {
            throw SocketClientError("could not start \(argv[0]): \(error)")
        }
        guard !passthrough else {
            process.waitUntilExit()
            return (process.terminationStatus, Data(), "")
        }
        // both pipes drain at once, so a chatty child cannot block on the one not being read
        nonisolated(unsafe) var errorData = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        let text = RemoteCommands.outputText(errorData).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, data, text.isEmpty ? "exit \(process.terminationStatus)" : text)
    }
}
#endif
