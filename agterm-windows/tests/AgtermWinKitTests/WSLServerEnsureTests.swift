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

    @Test func anInstallLeftForTheUserManagerOffersARestart() {
        let notice = WSLServerEnsure.installNotice(exitCode: 4, error: nil, label: "WSL Ubuntu", source: "Ubuntu")
        #expect(notice.severity == .error && notice.actions == [.restartDistribution, .openLog])
        #expect(WSLServerEnsure.installNotice(exitCode: 4, error: "no network", label: "WSL Ubuntu", source: "Ubuntu").actions == [.install, .openLog])
    }

    @Test func aColdDistributionIsWaitedForButAHiddenBusIsNot() {
        #expect(WSLServerEnsure.waitsForUserManager(.notRunning, elapsed: 29, hiddenFor: 0))
        #expect(!WSLServerEnsure.waitsForUserManager(.notRunning, elapsed: 30, hiddenFor: 0))
        #expect(WSLServerEnsure.waitsForUserManager(.busHidden, elapsed: 3, hiddenFor: 3))
        #expect(!WSLServerEnsure.waitsForUserManager(.busHidden, elapsed: 8, hiddenFor: 5))
        #expect(!WSLServerEnsure.waitsForUserManager(.ready, elapsed: 0, hiddenFor: 0))
        #expect(!WSLServerEnsure.waitsForUserManager(.unreachable, elapsed: 0, hiddenFor: 0))
    }

    @Test func onlyAFailedInstallIsRetried() {
        #expect(WSLServerEnsure.retriesInstall(WSLServerEnsure.installNotice(exitCode: 1, error: nil, label: "WSL Ubuntu", source: "Ubuntu"), manager: .ready))
        #expect(!WSLServerEnsure.retriesInstall(WSLServerEnsure.installNotice(exitCode: 4, error: nil, label: "WSL Ubuntu", source: "Ubuntu"), manager: .ready))
        #expect(!WSLServerEnsure.retriesInstall(WSLServerEnsure.installNotice(exitCode: 0, error: nil, label: "WSL Ubuntu", source: "Ubuntu"), manager: .ready))
        #expect(!WSLServerEnsure.retriesInstall(WSLServerEnsure.installNotice(exitCode: 1, error: nil, label: "WSL Ubuntu", source: "Ubuntu"), manager: .unreachable))
    }
}
