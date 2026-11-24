import AgtermWinKit
import Foundation
import Testing
import agtermCore

struct SidebarWidthTests {
    @Test func clampMatchesAppStore() {
        #expect(NativeSettings().sidebarWidthPoints == SidebarWidthLimits.defaultPoints)
        var settings = NativeSettings()
        settings.sidebarWidthPoints = SidebarWidthLimits.minPoints
        #expect(settings.sidebarWidthPoints == SidebarWidthLimits.minPoints)
        settings.sidebarWidthPoints = 9000
        #expect(settings.sidebarWidthPoints == SidebarWidthLimits.maxPoints)
    }

    @Test func loadClampsOutOfRange() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-sidebar-\(UUID().uuidString).json")
        let json = #"{"sidebarWidthPoints":50}"#
        try! json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = NativeSettings.load(from: url)
        #expect(settings.sidebarWidthPoints == SidebarWidthLimits.minPoints)
    }
}