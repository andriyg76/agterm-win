import AgtermWinKit
import Foundation
import Testing
import agtermCore

struct ZmxLaunchTests {
    private let zmx = (ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#) + #"\System32\cmd.exe"#

    @Test func aLiveLaunchWrapsAProfileInItsPanesDaemonAndLeavesWSLPlain() throws {
        let launch = ZmxLaunch(executablePath: zmx, stateDirectory: #"C:\state"#, requested: .live)
        #expect(launch.decision.active == .live)
        let identity = UUID()
        let start = try #require(launch.start("powershell.exe -NoLogo", paneIdentity: identity, environment: ["A": "1"]))
        #expect(start.daemonName == ZmxSupport.daemonName(for: identity))
        // agtermCore standardizes the executable's path, which Foundation spells with forward slashes
        let line = start.commandLine.replacingOccurrences(of: "/", with: #"\"#)
        #expect(line.lowercased().hasPrefix("\(zmx) attach \(start.daemonName) ".lowercased()))
        #expect(start.commandLine.contains("powershell.exe"))
        #expect(start.environment["A"] == "1" && start.environment["ZMX_DIR"] == launch.socketDirectory)
        #expect(launch.start("wsl.exe -d Ubuntu", paneIdentity: identity, environment: [:]) == nil)
    }

    @Test func freshShellsAndAMissingZmxStartPlain() {
        let fresh = ZmxLaunch(executablePath: zmx, stateDirectory: #"C:\state"#, requested: .none)
        #expect(fresh.start("cmd.exe", paneIdentity: UUID(), environment: [:]) == nil)
        let missing = ZmxLaunch(executablePath: #"C:\nowhere\zmx.exe"#, stateDirectory: #"C:\state"#, requested: .live)
        #expect(missing.decision.active == .none && missing.decision.liveUnavailableReason != nil)
        #expect(missing.start("cmd.exe", paneIdentity: UUID(), environment: [:]) == nil)
    }

    @Test func theSocketDirectoryIsShortAndPerStateDirectory() {
        let one = ZmxLaunch(executablePath: zmx, stateDirectory: #"C:\a"#, requested: .live).socketDirectory
        let other = ZmxLaunch(executablePath: zmx, stateDirectory: #"C:\b"#, requested: .live).socketDirectory
        #expect(one != other && one.contains(#"\agterm-win\zmx\"#))
    }
}
