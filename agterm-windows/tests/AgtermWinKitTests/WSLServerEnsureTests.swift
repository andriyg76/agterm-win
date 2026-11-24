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
}