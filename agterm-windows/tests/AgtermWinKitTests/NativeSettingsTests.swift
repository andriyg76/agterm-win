import AgtermWinKit
import Foundation
import Testing

struct NativeSettingsTests {
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-settings-\(UUID().uuidString).json")

    @Test func savedSettingsLoadBack() throws {
        var settings = NativeSettings()
        settings.fontPoints = 14
        settings.sidebarWidthPoints = 280
        settings.sidebarTint = 12
        settings.noticeBarPosition = .bottom
        settings.frame = .init(left: 10, top: 20, right: 1210, bottom: 820)
        settings.maximized = true
        settings.defaultProfile = "WSL Ubuntu"
        settings.serverLaunch = ["Ubuntu": .atLaunch, "Debian": .manual]
        try settings.save(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(NativeSettings.load(from: url) == settings)
    }

    @Test func legacyLocalSessionsLoadButAreNeverSavedAgain() throws {
        try Data(#"{"localSessions": [{"title": "build", "commandLine": "cmd.exe"}], "selectedLocal": 0}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = NativeSettings.load(from: url)
        #expect(settings.localSessions.count == 1 && settings.selectedLocal == 0)
        try settings.save(to: url)
        settings = NativeSettings.load(from: url)
        #expect(settings.localSessions.isEmpty && settings.selectedLocal == nil)
    }

    @Test func aLocalSessionFromAnOlderBuildLoadsWithoutANameOrFolder() throws {
        try Data(#"{"localSessions": [{"title": "Windows PowerShell", "commandLine": "powershell.exe -NoLogo"}]}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(NativeSettings.load(from: url).localSessions == [.init(title: "Windows PowerShell", commandLine: "powershell.exe -NoLogo")])
    }

    @Test func anUnknownNoticeBarPositionFallsBackToTheTop() throws {
        try Data(#"{"fontPoints": 13, "noticeBarPosition": "left"}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = NativeSettings.load(from: url)
        #expect(settings.noticeBarPosition == .top && settings.fontPoints == 13)
    }

    @Test func missingOrBrokenFilesGiveTheDefaults() throws {
        #expect(NativeSettings.load(from: url) == NativeSettings())
        try Data("{not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(NativeSettings.load(from: url) == NativeSettings())
    }

    @Test func outOfRangeValuesFallBack() throws {
        try Data(#"{"fontPoints": 300, "frame": {"left": 50, "top": 50, "right": 10, "bottom": 900}}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = NativeSettings.load(from: url)
        #expect(settings.fontPoints == NativeMenu.defaultPoints)
        #expect(settings.frame == nil)
    }

    @Test func fieldsAFileLacksKeepTheirDefaults() throws {
        try Data(#"{"fontPoints": 13}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = NativeSettings.load(from: url)
        #expect(settings.fontPoints == 13 && settings.frame == nil && !settings.maximized)
    }

    @Test func localSessionsDropBlankCommandsAndAStaleSelection() throws {
        try Data(#"{"localSessions": [{"title": "a", "commandLine": ""}, {"title": "b", "commandLine": "cmd.exe"}], "selectedLocal": 1}"#.utf8)
            .write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = NativeSettings.load(from: url)
        #expect(settings.localSessions == [.init(title: "b", commandLine: "cmd.exe")])
        #expect(settings.selectedLocal == nil)
    }

    @Test func framesFitTheWorkArea() {
        let area = NativeSettings.Frame(left: 0, top: 0, right: 984, bottom: 1013)
        #expect(NativeSettings.Frame(left: 100, top: 50, right: 700, bottom: 550).fitted(in: area) == .init(left: 100, top: 50, right: 700, bottom: 550))
        #expect(NativeSettings.Frame(left: 8, top: 120, right: 1308, bottom: 880).fitted(in: area) == .init(left: 0, top: 120, right: 984, bottom: 880))
        #expect(NativeSettings.Frame(left: 600, top: 900, right: 1000, bottom: 1200).fitted(in: area) == .init(left: 584, top: 713, right: 984, bottom: 1013))
        #expect(NativeSettings.Frame(left: -3000, top: 0, right: -2000, bottom: 400).fitted(in: area) == .init(left: 0, top: 0, right: 1000 - 16, bottom: 400))
    }
}
