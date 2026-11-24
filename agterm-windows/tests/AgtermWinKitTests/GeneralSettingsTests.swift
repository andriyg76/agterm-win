import AgtermWinKit
import Foundation
import Testing

struct GeneralSettingsTests {
    private let home = #"C:\Users\me"#

    @Test func aNewSessionStartsWhereSettingsSayWhileThatFolderExists() {
        var general = GeneralSettings()
        let all = { (_: String) in true }
        #expect(general.startDirectory(current: #"C:\dev"#, home: home, exists: all) == home)
        general.newSessionDirectory = "currentSession"
        #expect(general.startDirectory(current: #"C:\dev"#, home: home, exists: all) == #"C:\dev"#)
        #expect(general.startDirectory(current: nil, home: home, exists: all) == home)
        general.newSessionDirectory = "custom"
        general.newSessionCustomDirectory = #"D:\work"#
        #expect(general.startDirectory(current: nil, home: home, exists: all) == #"D:\work"#)
        #expect(general.startDirectory(current: nil, home: home, exists: { _ in false }) == home)
    }

    @Test func aNewSessionGoesLastOrAfterTheSelectedOne() {
        var general = GeneralSettings()
        #expect(general.insertionIndex(count: 3, selected: 0) == 3)
        general.newSessionPlacement = "afterCurrent"
        #expect(general.insertionIndex(count: 3, selected: 0) == 1)
        #expect(general.insertionIndex(count: 3, selected: nil) == 3)
        #expect(general.insertionIndex(count: 3, selected: 7) == 3)
    }

    @Test func anOlderFileGetsTheDefaultsAndABadScrollIsRefused() throws {
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: Data(#"{"scrollLines": 40, "newSessionDirectory": "sideways"}"#.utf8))
        #expect(decoded.scrollLines == GeneralSettings.defaultScrollLines && decoded.directory == .home && !decoded.rightClickPastes)
        var saved = GeneralSettings()
        saved.confirmCloseSession = true
        saved.scrollLines = 5
        #expect(try JSONDecoder().decode(GeneralSettings.self, from: JSONEncoder().encode(saved)) == saved)
    }
}
