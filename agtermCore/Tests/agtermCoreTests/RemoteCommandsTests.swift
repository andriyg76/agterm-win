import Foundation
import Testing
@testable import agtermCore

struct RemoteCommandsTests {
    @Test func aLineDefinesANameAndItsCommandWords() {
        let (commands, diagnostics) = RemoteCommands.parse("Ubuntu = wsl.exe -d Ubuntu -e\n")
        #expect(diagnostics.isEmpty)
        #expect(commands.entries == [RemoteCommands.Entry(name: "Ubuntu", argv: ["wsl.exe", "-d", "Ubuntu", "-e"], line: 1)])
    }

    @Test(arguments: ["box=docker exec -i box", "box:docker exec -i box", "box docker exec -i box", "  box \t =   docker exec -i box"])
    func everyPropertiesSeparatorWorks(line: String) {
        #expect(RemoteCommands.parse(line).commands.command(for: "box") == ["docker", "exec", "-i", "box"])
    }

    @Test func commentsBlankLinesAndCRLFAreSkippedAndLinesKeepTheirNumbers() {
        let text = "# header\r\n! bang comment\r\n\r\n   # indented\r\na = one\r\n\r\nb = two\r\n"
        let (commands, diagnostics) = RemoteCommands.parse(text)
        #expect(diagnostics.isEmpty)
        #expect(commands.names == ["a", "b"])
        #expect(commands.entries.map(\.line) == [5, 7])
    }

    @Test func aTrailingBackslashContinuesTheLineAndEscapesDecode() {
        let text = "box = docker exec \\\n    -i box\npath = C:\\\\Windows\\\\wsl.exe -e\nuni = \\u0041b\n"
        let (commands, diagnostics) = RemoteCommands.parse(text)
        #expect(diagnostics.isEmpty)
        #expect(commands.command(for: "box") == ["docker", "exec", "-i", "box"])
        #expect(commands.command(for: "path") == [#"C:\Windows\wsl.exe"#, "-e"])
        #expect(commands.command(for: "uni") == ["Ab"])
    }

    @Test func quotesKeepAWordWithSpaces() {
        let commands = RemoteCommands.parse(#"dev = "/opt/my tools/enter" 'a b' c"#).commands
        #expect(commands.command(for: "dev") == ["/opt/my tools/enter", "a b", "c"])
    }

    @Test func badLinesAreDiagnosedWithTheirLineAndSkipped() {
        let text = "good = ssh-free run\nempty =\n-bad = x\nopen = \"unclosed\ngood = later\nuni = \\u12\n"
        let (commands, diagnostics) = RemoteCommands.parse(text)
        #expect(commands.names == ["good"])
        #expect(commands.command(for: "good") == ["ssh-free", "run"])
        #expect(diagnostics.map(\.line) == [2, 3, 4, 5, 6])
    }

    @Test func aMissingFileDefinesNothingWithoutADiagnostic() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("remote.properties")
        let loaded = RemoteCommands.load(at: url)
        #expect(loaded.commands.entries.isEmpty)
        #expect(loaded.diagnostics.isEmpty)
    }

    @Test func theTemplateParsesBackToItsEntries() {
        let text = RemoteCommands.template([(name: "Ubuntu", command: "wsl.exe -d Ubuntu -e"), (name: "Debian", command: "wsl.exe -d Debian -e")])
        let (commands, diagnostics) = RemoteCommands.parse(text)
        #expect(diagnostics.isEmpty)
        #expect(commands.names == ["Ubuntu", "Debian"])
        #expect(commands.command(for: "Debian") == ["wsl.exe", "-d", "Debian", "-e"])
    }

    @Test func outputTextDecodesWslExesUTF16AndTheRemotesUTF8() {
        let message = "There is no distribution with the supplied name.\r\n"
        #expect(RemoteCommands.outputText(Data(message.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })) == message)
        #expect(RemoteCommands.outputText(Data([0xFF, 0xFE, 0x41, 0x00])) == "A")
        #expect(RemoteCommands.outputText(Data("sh: агент: not found\n".utf8)) == "sh: агент: not found\n")
    }

    private let wsl =RemoteCommands.parse("Ubuntu = wsl.exe -d Ubuntu -e\n").commands

    @Test func aDefinedNameRunsItsCommandWithTheSameShellScript() throws {
        let ssh = try RemoteSession.catalogCommand(host: "studio", controlPath: "/tmp/p", remotes: wsl)
        let defined = try RemoteSession.catalogCommand(host: "Ubuntu", controlPath: "/tmp/p", remotes: wsl)
        #expect(ssh.first == "ssh")
        #expect(Array(defined.prefix(4)) == ["wsl.exe", "-d", "Ubuntu", "-e"])
        #expect(Array(defined.dropFirst(4).prefix(2)) == ["/bin/sh", "-c"])
        #expect(defined.count == 7)
        #expect(ssh.last == CommandRestore.shellQuotedLine(Array(defined.suffix(3))))
        #expect(!defined.contains { $0.contains("ControlPath") || $0.contains("BatchMode") })
    }

    @Test func aDefinedControlCommandCarriesTheChainUnquoted() throws {
        let argv = try RemoteSession.controlCommand(host: "Ubuntu", arguments: ["window", "list"], remotes: wsl)
        #expect(Array(argv.prefix(6)) == ["wsl.exe", "-d", "Ubuntu", "-e", "/bin/sh", "-c"])
        #expect(argv.last?.hasSuffix("agtermctl window list --json") == true)
    }

    @Test func aDefinedAttachHasNoSshKeepaliveOrMasterWait() throws {
        let endpoint = ControlZmxEndpoint(executable: "/usr/local/bin/zmx", socketDirectory: "/run/zmx")
        let line = try RemoteSession.attachPaneCommand(host: "Ubuntu", endpoint: endpoint, daemon: "d1", session: "s", pane: .left,
                                                       controlPath: "/tmp/p", remotes: wsl)
        #expect(line.contains("wsl.exe"))
        #expect(!line.contains("ServerAliveInterval"))
        #expect(!line.contains("agterm_connection_wait"))
    }

    @Test func aDefinedNameRefusesSshForwards() {
        #expect(throws: RemoteSession.InvocationError.definedRemote) {
            try RemoteSession.forwardCommand(host: "Ubuntu", spec: "127.0.0.1:1:127.0.0.1:2", remotes: wsl)
        }
        #expect(throws: RemoteSession.InvocationError.definedRemote) {
            try RemoteSession.forwardControlCommand("check", host: "Ubuntu", controlPath: "/tmp/p", remotes: wsl)
        }
    }

    @Test func serverInstallRunsItsStepsThroughTheDefinedCommand() throws {
        let connection = TerminfoInstall.Connection(destination: "Ubuntu")
        #expect(try ServerInstall.probeCommand(connection, remotes: wsl) == ["wsl.exe", "-d", "Ubuntu", "-e", "/bin/sh", "-c", "uname -m"])
        #expect(try ServerInstall.unpackCommand(connection, remotes: wsl).last == ServerInstall.unpackScript)
        #expect(try ServerInstall.installerCommand(connection, remotes: wsl).last == ServerInstall.installerCommand)
        #expect(throws: ServerInstall.Failure.sshOptionsForDefinedRemote("Ubuntu")) {
            try ServerInstall.probeCommand(TerminfoInstall.Connection(destination: "Ubuntu", port: 22), remotes: wsl)
        }
        #expect(try ServerInstall.probeCommand(TerminfoInstall.Connection(destination: "studio"), remotes: wsl).first == "ssh")
    }
}
