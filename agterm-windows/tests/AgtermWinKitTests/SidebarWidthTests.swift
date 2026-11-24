import AgtermWinKit
import Testing
import agtermCore

struct SidebarWidthTests {
    @Test func clampMatchesAppStore() {
        #expect(NativeSettings().sidebarWidthPoints == AppStore.sidebarWidthDefault)
        var settings = NativeSettings()
        settings.sidebarWidthPoints = AppStore.sidebarWidthMin
        #expect(settings.sidebarWidthPoints == AppStore.sidebarWidthMin)
        settings.sidebarWidthPoints = 9000
        #expect(settings.sidebarWidthPoints == AppStore.sidebarWidthMax)
    }

    @Test func loadClampsOutOfRange() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-sidebar-\(UUID().uuidString).json")
        let json = #"{"sidebarWidthPoints":50}"#
        try! json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = NativeSettings.load(from: url)
        #expect(settings.sidebarWidthPoints == AppStore.sidebarWidthMin)
    }
}