import AgtermWinKit
import Foundation
import Testing

struct NotificationRulesTests {
    @Test func theSessionInViewDropsOnlyItsOwnProgramsNotifications() {
        #expect(!NotificationRules.delivers(.terminal, sessionInView: true, windowInFront: true))
        #expect(NotificationRules.delivers(.terminal, sessionInView: true, windowInFront: false))
        #expect(NotificationRules.delivers(.terminal, sessionInView: false, windowInFront: true))
        #expect(NotificationRules.delivers(.control, sessionInView: true, windowInFront: true))
        #expect(NotificationRules.tag(.terminal) != NotificationRules.tag(.control))
    }

    @Test func aToastNamesItsSessionAndEscapesText() {
        let toast = NotificationRules.toast(title: "Build <done>", body: "a & b", session: "api", sound: false)
        #expect(toast.contains("<text>Build &lt;done&gt;</text><text>a &amp; b</text><text placement=\"attribution\">api</text>"))
        #expect(toast.contains("<audio silent=\"true\"/>"))
        let untitled = NotificationRules.toast(title: "", body: "ready", session: "api", sound: true)
        #expect(untitled.contains("<text>api</text><text>ready</text></binding>") && !untitled.contains("audio"))
    }

    @Test func settingsSurviveAndAnOlderFileGetsTheDefaults() throws {
        let saved = NotificationSettings(banners: false, sound: false, flash: .once, unseenCount: false)
        #expect(try JSONDecoder().decode(NotificationSettings.self, from: JSONEncoder().encode(saved)) == saved)
        #expect(try JSONDecoder().decode(NotificationSettings.self, from: Data(#"{"flash": "sideways"}"#.utf8)) == NotificationSettings())
    }
}
