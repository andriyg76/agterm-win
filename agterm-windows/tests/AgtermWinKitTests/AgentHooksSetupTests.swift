import AgtermWinKit
import Foundation
import Testing

struct AgentHooksSetupTests {
    private let folder = #"C:\Users\me\.config\agterm\agent-status"#
    private let prefix = #"powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""#

    @Test func commandRunsTheAdapterThroughPowerShell() {
        #expect(AgentHooksSetup.command(folder: folder, script: AgentHooksSetup.claudeScript, arguments: "active --blink")
            == prefix + #"C:/Users/me/.config/agterm/agent-status/agterm-claude-status.ps1" active --blink"#)
    }

    @Test func libraryBakesTheToolPath() {
        let text = "x\n$AgtermCtl = 'agtermctl' # agterm-win installs its agtermctl path here\ny"
        #expect(AgentHooksSetup.library(text, tool: #"C:\O'Neil\agtermctl.exe"#) == "x\n$AgtermCtl = 'C:\\O''Neil\\agtermctl.exe'\ny")
    }

    @Test func claudeMergeKeepsOtherHooksAndIsIdempotent() throws {
        let existing = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        let merged = try AgentHooksSetup.claudeSettings(existing: existing, folder: folder).get()
        #expect(merged.changed)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(merged.text.utf8)) as? [String: Any])
        #expect(root["model"] as? String == "opus")
        let hooks = try #require(root["hooks"] as? [String: [[String: Any]]])
        #expect(hooks["Stop"]?.count == 2)
        #expect(hooks["Notification"]?.first?["matcher"] as? String == "permission_prompt")
        #expect(merged.text.contains(#"agterm-claude-status.ps1\" completed --auto-reset"#))
        #expect(try AgentHooksSetup.claudeSettings(existing: merged.text, folder: folder).get().changed == false)
    }

    @Test func claudeMergeRepointsAMovedFolder() throws {
        let first = try AgentHooksSetup.claudeSettings(existing: nil, folder: folder).get().text
        let moved = try AgentHooksSetup.claudeSettings(existing: first, folder: #"D:\home\.config\agterm\agent-status"#).get()
        #expect(moved.changed && !moved.text.contains("C:/Users/me") && moved.text.contains("D:/home/.config/agterm/agent-status/"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(moved.text.utf8)) as? [String: [String: [[String: Any]]]])
        #expect(root["hooks"]?["Stop"]?.count == 1)
    }

    @Test func claudeMergeRefusesWhatItCannotRead() {
        #expect(throws: AgentHooksSetup.Refusal.self) { try AgentHooksSetup.claudeSettings(existing: "{oops", folder: folder).get() }
        #expect(throws: AgentHooksSetup.Refusal.self) { try AgentHooksSetup.claudeSettings(existing: #"{"hooks":[]}"#, folder: folder).get() }
    }

    @Test func codexBlockAppendsRefreshesAndKeepsTrustState() throws {
        let first = try AgentHooksSetup.codexConfig(existing: "model = \"o3\"\n", folder: folder).get()
        #expect(first.changed && first.text.hasPrefix("model = \"o3\"\n\n" + AgentHooksSetup.codexBegin))
        #expect(first.text.contains(#"agterm-codex-status.ps1\" permission-request""#))
        #expect(try AgentHooksSetup.codexConfig(existing: first.text, folder: folder).get().changed == false)
        let trusted = first.text.replacingOccurrences(of: AgentHooksSetup.codexEnd, with: "[hooks.state.abc]\ntrusted = true\n" + AgentHooksSetup.codexEnd)
        let moved = try AgentHooksSetup.codexConfig(existing: trusted, folder: #"D:\status"#).get().text
        #expect(moved.contains(#"D:/status/agterm-codex-status.ps1\" stop""#) && !moved.contains("C:/Users/me"))
        #expect(moved.contains("[hooks.state.abc]\ntrusted = true\n" + AgentHooksSetup.codexEnd))
    }

    @Test func codexLeavesItsOwnHooksAlone() {
        #expect(throws: AgentHooksSetup.Refusal.self) {
            try AgentHooksSetup.codexConfig(existing: "[[hooks.Stop]]\ncommand = \"x\"\n", folder: folder).get()
        }
    }

    @Test func codexAppendsHooksAlongsideExistingTrustState() throws {
        let existing = "[hooks.state.abc]\ntrusted = true\n"
        let merged = try AgentHooksSetup.codexConfig(existing: existing, folder: folder).get().text
        #expect(merged.hasPrefix(existing))
        #expect(merged.contains("[[hooks.UserPromptSubmit]]"))
        #expect(try AgentHooksSetup.codexConfig(existing: merged, folder: folder).get().changed == false)
    }

    @Test func installCopiesAdaptersStampsOnceAndSkipsAMissingCodex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["agterm-agent-status.ps1", AgentHooksSetup.claudeScript, AgentHooksSetup.codexScript] {
            try "# \(name)\n".write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "$AgtermCtl = 'agtermctl' # agterm-win installs its agtermctl path here\n"
            .write(to: source.appendingPathComponent(AgentHooksSetup.libraryScript), atomically: true, encoding: .utf8)
        let home = root.appendingPathComponent("home")
        let tool = #"C:\agterm\agtermctl.exe"#
        #expect(AgentHooksSetup.needsInstall(home: home, version: "1.0", tool: tool))
        let report = AgentHooksSetup.install(home: home, codexHome: nil, source: source, version: "1.0", tool: tool)
        #expect(report.installed && report.lines.last?.hasPrefix("Codex: not installed") == true)
        let library = try String(contentsOf: AgentHooksSetup.folder(home: home).appendingPathComponent(AgentHooksSetup.libraryScript), encoding: .utf8)
        #expect(library == "$AgtermCtl = 'C:\\agterm\\agtermctl.exe'\n")
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
        #expect(!AgentHooksSetup.needsInstall(home: home, version: "1.0", tool: tool))
        #expect(AgentHooksSetup.needsInstall(home: home, version: "1.1", tool: tool))
    }
}
