import AgtermWinKit
import Foundation
import Testing

struct StateMigrationTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("state-migration-\(UUID().uuidString)")
    private var legacy: URL { root.appendingPathComponent("legacy") }
    private var state: URL { root.appendingPathComponent("state") }
    private var config: URL { root.appendingPathComponent("config") }

    private func write(_ url: URL, _ text: String = "x") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ url: URL, _ path: String) -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path) }

    private func seedLegacy() throws {
        for path in ["native.json", "windows/a.json", "agterm-win.log", "zmx/0123/agterm-abc", "config/keymap.conf", "config/themes/Dark"] {
            try write(legacy.appendingPathComponent(path))
        }
    }

    @Test func movesStateAndConfigIntoFoldersThatHoldNoneAndLeavesTheDaemonFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacy()
        try write(state.appendingPathComponent("agterm-0123.sock"))
        try write(config.appendingPathComponent("agent-status/agterm-agent-status.sh"))
        let report = StateMigration.run(from: legacy, state: state, config: config)
        #expect(["native.json", "windows/a.json", "agterm-win.log"].allSatisfy { exists(state, $0) && !exists(legacy, $0) })
        #expect(exists(config, "keymap.conf") && exists(config, "themes/Dark") && !exists(state, "config"))
        #expect(exists(legacy, "zmx/0123/agterm-abc") && !exists(state, "zmx"))
        #expect(report.count == 5)
    }

    @Test func leavesStateAndConfigAloneWhereTheNewFoldersAlreadyHoldThem() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacy()
        try write(state.appendingPathComponent("native.json"), "new")
        try write(config.appendingPathComponent("themes/Light"))
        #expect(StateMigration.run(from: legacy, state: state, config: config).isEmpty)
        #expect(exists(legacy, "native.json") && exists(legacy, "config/keymap.conf") && !exists(state, "agterm-win.log"))
        #expect(try String(contentsOf: state.appendingPathComponent("native.json"), encoding: .utf8) == "new")
    }

    @Test func anIsolatedInstanceMovesNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacy()
        #expect(StateMigration.run(from: legacy, state: legacy, config: legacy.appendingPathComponent("config")).isEmpty)
    }
}
