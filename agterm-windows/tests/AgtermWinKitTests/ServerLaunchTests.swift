import AgtermWinKit
import Testing

struct ServerLaunchTests {
    @Test func onlyTheChoiceToStartAtLaunchStartsIt() {
        #expect(ServerLaunch.atLaunch(["Ubuntu": .atLaunch, "Debian": .manual, "alpine": .atLaunch]) == ["alpine", "Ubuntu"])
        #expect(ServerLaunch.atLaunch([:]).isEmpty)
    }

    @Test func startingAsksUntilSomethingIsChosen() {
        #expect(ServerLaunch.asks(nil))
        #expect(!ServerLaunch.asks(.manual))
        #expect(!ServerLaunch.asks(.atLaunch))
    }

    @Test func noAsksAgainAndDontAskAgainDoesNot() {
        #expect(ServerLaunch.choice(after: .atLaunch) == .atLaunch)
        #expect(ServerLaunch.asks(ServerLaunch.choice(after: .notNow)))
        #expect(ServerLaunch.choice(after: .neverAsk) == .manual)
        #expect(ServerLaunch.Answer.allCases.map(\.title) == ["Yes, start it at launch", "No", "No, and don't ask again"])
    }

    @Test func settingsTickStartsAtLaunchAndUntickNeverAsks() {
        let before: [String: ServerLaunch] = ["Ubuntu": .atLaunch, "Debian": .manual]
        let after = ServerLaunch.choices(before, checked: ["Debian", "Arch"], listed: ["Ubuntu", "Debian", "Arch", "Fedora"])
        #expect(after == ["Ubuntu": .manual, "Debian": .atLaunch, "Arch": .atLaunch])
        #expect(ServerLaunch.asks(after["Fedora"]))
    }

    @Test func settingsListAStartAtLaunchDistributionWSLNoLongerHas() {
        #expect(ServerLaunch.listed(available: ["Ubuntu"], choices: ["Old": .atLaunch, "Gone": .manual]) == ["Ubuntu", "Old"])
        #expect(ServerLaunch.listed(available: ["Ubuntu"], choices: ["Ubuntu": .atLaunch]) == ["Ubuntu"])
    }
}
