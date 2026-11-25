import Foundation
import AgtermWinKit
import Testing

struct WSLServerEnsureTests {
    @Test func missingInstallTriggersInstall() {
        #expect(WSLServerEnsure.plan(health: .missingInstall, expectedVersion: "0.44.1")
            == .install(reason: "agterm-server is not installed in this distribution"))
    }

    @Test func matchingReadyConnects() {
        #expect(WSLServerEnsure.plan(health: .ready(installedVersion: "0.44.1"), expectedVersion: "0.44.1") == .connect)
    }

    @Test func stoppedMatchingVersionStartsService() {
        #expect(WSLServerEnsure.plan(health: .serviceStopped(installedVersion: "0.44.1"), expectedVersion: "0.44.1")
            == .startServiceThenConnect)
    }

    @Test func versionMismatchUpgrades() {
        let action = WSLServerEnsure.plan(health: .ready(installedVersion: "0.43.0"), expectedVersion: "0.44.1")
        #expect(action == .install(reason: "agterm-server 0.43.0 is installed; this app needs 0.44.1"))
    }

    @Test func unreachableRefuses() {
        #expect(WSLServerEnsure.plan(health: .distributionUnreachable("wsl.exe exited 1"), expectedVersion: "0.44.1")
            == .refuse("WSL distribution is not reachable: wsl.exe exited 1"))
    }

    @Test func aFailedInstallIsAnErrorOfferingInstallAndTheLog() {
        let failed = WSLServerEnsure.installNotice(exitCode: 1, error: nil, label: "WSL Ubuntu", source: "Ubuntu")
        #expect(failed == NoticeBar.Message(source: "Ubuntu", text: "WSL Ubuntu: install exited 1. See agterm-win.log.", severity: .error,
                                            actions: [.install, .openLog]))
        #expect(WSLServerEnsure.installNotice(exitCode: 0, error: "no network", label: "WSL Ubuntu", source: "Ubuntu").severity == .error)
        #expect(WSLServerEnsure.installNotice(exitCode: 3, error: nil, label: "WSL Ubuntu", source: "Ubuntu").severity == .info)
        #expect(WSLServerEnsure.installNotice(exitCode: 0, error: nil, label: "WSL Ubuntu", source: "Ubuntu").actions.isEmpty)
    }

    @Test func wslExeMessagesDecodeFromUTF16AndDistributionOutputFromUTF8() {
        let message = "The Windows Subsystem for Linux is not installed.\r\n"
        #expect(WSLServerEnsure.wslText(Data(message.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })) == message)
        #expect(WSLServerEnsure.wslText(Data([0xFF, 0xFE, 0x41, 0x00])) == "A")
        #expect(WSLServerEnsure.wslText(Data("sh: агент: not found\n".utf8)) == "sh: агент: not found\n")
    }
}
