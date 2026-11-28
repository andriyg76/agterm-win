import Foundation

/// StateMigration moves what agterm-win 0.44.1.11 and earlier kept in `%LOCALAPPDATA%\agterm-win`, which an MSIX package
/// redirects into its own AppData, to the folders every install type now shares. It moves state only while the new state
/// directory holds none, and config only while the new config directory holds none of the old files: that directory
/// already exists for the agent status scripts. The old `zmx` folder stays for `ZmxClient.endLegacyDaemons`, which ends the
/// daemons whose sockets are in it.
public enum StateMigration {
    /// run answers one line per entry it moved or could not move, for the log.
    public static func run(from legacy: URL, state: URL, config: URL) -> [String] {
        guard legacy.standardizedFileURL != state.standardizedFileURL else { return [] }
        let legacyConfig = legacy.appendingPathComponent("config")
        var report: [String] = []
        let stateEntries = entries(of: legacy).filter { !["zmx", "config"].contains($0) && !$0.hasSuffix(".sock") && !$0.hasSuffix(".lock") }
        if !stateEntries.isEmpty, !["native.json", "windows"].contains(where: { exists(state.appendingPathComponent($0)) }) {
            report += move(stateEntries, from: legacy, to: state)
        }
        let configEntries = entries(of: legacyConfig)
        if !configEntries.isEmpty, !configEntries.contains(where: { exists(config.appendingPathComponent($0)) }) {
            report += move(configEntries, from: legacyConfig, to: config)
        }
        return report
    }

    private static func entries(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// move renames each entry, and copies one a rename cannot take, as out of a packaged app's redirected AppData.
    private static func move(_ names: [String], from source: URL, to destination: URL) -> [String] {
        let files = FileManager.default
        do {
            try files.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return ["state migration: could not create \(destination.path): \(error.localizedDescription)"]
        }
        return names.map { name in
            let from = source.appendingPathComponent(name), to = destination.appendingPathComponent(name)
            if (try? files.moveItem(at: from, to: to)) != nil { return "state migration: moved \(from.path) to \(to.path)" }
            do {
                try files.copyItem(at: from, to: to)
                return "state migration: copied \(from.path) to \(to.path)"
            } catch {
                return "state migration: could not move \(from.path): \(error.localizedDescription)"
            }
        }
    }
}
