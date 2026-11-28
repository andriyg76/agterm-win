import AgtermWinKit
import Foundation
import Testing

struct AppBuildInfoTests {
    @Test func packagedReleaseShowsItsVersionUpstreamAndBuildDate() throws {
        let data = Data(#"{"version":"0.44.2","agtermVersion":"0.44.1","buildDate":"2026-11-26T14:00:00Z"}"#.utf8)
        let info = try JSONDecoder().decode(AppBuildInfo.self, from: data)
        #expect(info.aboutText == "agterm for Windows\nVersion 0.44.2 (agterm 0.44.1)\nBuilt 2026-11-26T14:00:00Z")
    }

    @Test func identityFromBeforeTheUpstreamFieldStillDecodes() throws {
        let data = Data(#"{"version":"0.44.1.7","buildDate":"2026-11-26T14:00:00Z"}"#.utf8)
        let info = try JSONDecoder().decode(AppBuildInfo.self, from: data)
        #expect(info.aboutText == "agterm for Windows\nVersion 0.44.1.7\nBuilt 2026-11-26T14:00:00Z")
    }

    @Test func ciIdentityShowsTheHeadBranchAndPullRequest() throws {
        let data = Data(#"{"version":"0.44.1","agtermVersion":"0.44.1","buildDate":"2026-11-26T14:00:00Z","branch":"fix/menu","pullRequest":123}"#.utf8)
        let info = try JSONDecoder().decode(AppBuildInfo.self, from: data)
        #expect(info.aboutText.contains("Branch fix/menu\nPR #123"))
    }

    @Test func sourceBuildShowsTheUpstreamVersionWithoutInventingCiIdentity() {
        let info = AppBuildInfo(version: "0.44.1", agtermVersion: "0.44.1", buildDate: nil)
        #expect(info.aboutText == "agterm for Windows\nVersion 0.44.1 (agterm 0.44.1)")
    }

    @Test func sidebarVisibilitySurvivesSaveAndOldSettingsRemainVisible() throws {
        #expect(try JSONDecoder().decode(NativeSettings.self, from: Data("{}".utf8)).sidebarVisible)
        var settings = NativeSettings()
        settings.sidebarVisible = false
        settings.sidebarWidthPoints = 300
        let restored = try JSONDecoder().decode(NativeSettings.self, from: JSONEncoder().encode(settings))
        #expect(!restored.sidebarVisible)
        #expect(restored.sidebarWidthPoints == 300)
    }
}
