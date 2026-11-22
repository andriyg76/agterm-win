import AgtermWinKit
import Foundation
import Testing

struct NativeSettingsTests {
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-settings-\(UUID().uuidString).json")

    @Test func savedSettingsLoadBack() throws {
        var settings = NativeSettings()
        settings.fontPoints = 14
        settings.frame = .init(left: 10, top: 20, right: 1210, bottom: 820)
        settings.maximized = true
        try settings.save(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(NativeSettings.load(from: url) == settings)
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
}
