import AgtermWinKit
import Testing

struct ServerLaunchTests {
    @Test func onlyTheChoiceToStartAtLaunchStartsIt() {
        #expect(!ServerLaunch.startsAtLaunch(nil))
        #expect(!ServerLaunch.startsAtLaunch(.manual))
        #expect(ServerLaunch.startsAtLaunch(.atLaunch))
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

    @Test func clearingStartAtLaunchIsAChoice() {
        #expect(ServerLaunch.toggled(nil) == .atLaunch)
        #expect(ServerLaunch.toggled(.manual) == .atLaunch)
        #expect(ServerLaunch.toggled(.atLaunch) == .manual)
    }
}
