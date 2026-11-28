import AgtermWinKit
import Foundation
import Testing
import agtermCore

struct ZmxLaunchTests {
    private let zmx = (ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#) + #"\System32\cmd.exe"#

    @Test func aLiveLaunchWrapsAProfileInItsPanesDaemon() throws {
        let launch = ZmxLaunch(executablePath: zmx, stateDirectory: #"C:\state"#, requested: .live)
        #expect(launch.decision.active == .live)
        let identity = UUID()
        let start = try #require(launch.start("powershell.exe -NoLogo", paneIdentity: identity, environment: ["A": "1"]))
        #expect(start.daemonName == ZmxSupport.localDaemonName(for: identity))
        // agtermCore standardizes the executable's path, which Foundation spells with forward slashes
        let line = start.commandLine.replacingOccurrences(of: "/", with: #"\"#)
        #expect(line.lowercased().hasPrefix("\(zmx) attach \(start.daemonName) ".lowercased()))
        #expect(start.commandLine.contains("powershell.exe"))
        #expect(start.environment["A"] == "1" && start.environment["ZMX_DIR"] == launch.socketDirectory)
        let wsl = try #require(launch.start("wsl.exe -d Ubuntu", paneIdentity: identity, environment: [:]))
        #expect(wsl.commandLine.contains("wsl.exe -d Ubuntu") && wsl.daemonName == start.daemonName)
    }

    @Test func freshShellsAndAMissingZmxStartPlain() {
        let fresh = ZmxLaunch(executablePath: zmx, stateDirectory: #"C:\state"#, requested: .none)
        #expect(fresh.start("cmd.exe", paneIdentity: UUID(), environment: [:]) == nil)
        let missing = ZmxLaunch(executablePath: #"C:\nowhere\zmx.exe"#, stateDirectory: #"C:\state"#, requested: .live)
        #expect(missing.decision.active == .none && missing.decision.liveUnavailableReason != nil)
        #expect(missing.start("cmd.exe", paneIdentity: UUID(), environment: [:]) == nil)
    }

    @Test func aDaemonSocketFitsAProfileFolderOf46Characters() {
        let profile = #"C:\Users\"# + String(repeating: "u", count: 46)
        let root = ControlResolve.windowsSocketRoot.replacingOccurrences(of: ProcessInfo.processInfo.environment["USERPROFILE"] ?? "", with: profile)
        let one = ZmxLaunch(executablePath: zmx, stateDirectory: #"C:\a"#, requested: .live).socketDirectory
        let other = ZmxLaunch(executablePath: zmx, stateDirectory: #"C:\b"#, requested: .live).socketDirectory
        #expect(one != other && one.hasPrefix(ControlResolve.windowsSocketRoot + #"\z\"#))
        let socket = one.replacingOccurrences(of: ControlResolve.windowsSocketRoot, with: root) + #"\"# + ZmxSupport.localDaemonName(for: UUID())
        #expect(socket.utf8.count == 107)
    }

    @Test func aLocalDaemonNameIsOpaqueAndServerDaemonsKeepTheirs() {
        let identity = UUID()
        let local = ZmxSupport.localDaemonName(for: identity)
        #expect(local.utf8.count == 16 && local == ZmxSupport.localDaemonName(for: identity) && local != ZmxSupport.localDaemonName(for: UUID()))
        #expect(ZmxSupport.isDaemonName(local) && !ZmxSupport.isDaemonName(local + "x") && !ZmxSupport.isDaemonName("0" + local.dropFirst()))
        #expect(ZmxSupport.paneIdentity(fromDaemonName: ZmxSupport.daemonName(for: identity)) == identity)
    }

    @MainActor @Test func theDaemonsAnOlderVersionStartedAreEndedAndTheirFolderRemoved() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("zmx-legacy-\(UUID().uuidString)")
        let legacy = parent.appendingPathComponent("0123456789abcdef").path
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(atPath: legacy, withIntermediateDirectories: true)
        let old = ZmxSupport.daemonName(for: UUID())
        var calls: [(arguments: [String], directory: String?)] = []
        let client = ZmxClient(executablePath: zmx, socketDirectory: #"C:\new"#) { _, invocation in
            calls.append((invocation.arguments, invocation.environment["ZMX_DIR"]))
            return invocation.arguments == ["list"] ? (0, "name=\(old)\tpid=1\tclients=0\n") : (0, "killed \(old)\n")
        }
        client.endLegacyDaemons(in: legacy)
        #expect(calls.map(\.arguments) == [["list"], ["kill", old, "--force"]] && calls.allSatisfy { $0.directory == legacy })
        #expect(!FileManager.default.fileExists(atPath: parent.path))
        client.endLegacyDaemons(in: legacy)
        #expect(calls.count == 2)
    }
}
