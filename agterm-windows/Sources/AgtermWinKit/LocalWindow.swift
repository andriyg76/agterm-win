import Foundation
import agtermCore

/// LocalWindow is agterm-win's own window as agtermCore models a Mac window: a store whose root and named workspaces
/// hold the local sessions, saved in `windows/<id>.json`. A session's `initialCommand` is the program its pane runs.
@MainActor
public enum LocalWindow {
    public nonisolated static let id = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    public static func persistence(stateDirectory: URL) -> PersistenceStore {
        PersistenceStore(directory: stateDirectory.appendingPathComponent("windows"), fileName: "\(id.uuidString).json")
    }

    public static func file(stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("windows").appendingPathComponent("\(id.uuidString).json")
    }

    /// load reads the window's saved tree. Without one it imports `legacy`, the sessions a build before workspaces kept
    /// in `native.json`, into the root, selecting `legacySelected` as that build did. `paneIdentities` are the panes the
    /// saved tree claims, each given an identity a file from before Live sessions lacked, as a Mac window's are; nil
    /// when the file could not be read, so a Live launch reaps nothing.
    public static func load(stateDirectory: URL, legacy: [NativeSettings.LocalSession], legacySelected: Int?,
                            paneFinalizer: (([UUID]) -> Void)? = nil) -> (store: AppStore, paneIdentities: Set<UUID>?) {
        let persistence = persistence(stateDirectory: stateDirectory)
        let store = AppStore(persistence: persistence, paneFinalizer: paneFinalizer)
        guard FileManager.default.fileExists(atPath: file(stateDirectory: stateDirectory).path) else {
            store.ensureRoot()
            importLegacy(legacy, selected: legacySelected, into: store)
            return (store, [])
        }
        guard var snapshot = try? persistence.loadChecked() else {
            store.restore(from: persistence.load())
            store.ensureRoot()
            return (store, nil)
        }
        let upgrade = PaneIdentityInventory.upgrade(&snapshot)
        store.restore(from: snapshot)
        store.ensureRoot()
        if upgrade.changed { store.save() }
        return (store, upgrade.identities)
    }

    static func importLegacy(_ legacy: [NativeSettings.LocalSession], selected: Int?, into store: AppStore) {
        guard let root = store.rootWorkspace?.id else { return }
        var imported: [UUID] = []
        for saved in legacy {
            guard let session = store.addSession(toWorkspace: root, cwd: saved.directory ?? "", command: saved.commandLine,
                                                 name: saved.customName, select: false) else { continue }
            if let split = saved.split {
                session.hasSplit = true
                session.isSplit = split.shown
                session.splitAxis = split.axis
                session.splitRatio = split.ratio
                session.splitFocused = split.focused
                session.splitCwd = split.directory
            }
            imported.append(session.id)
        }
        if let selected, imported.indices.contains(selected) { store.selectSession(imported[selected]) }
        store.save()
    }

    /// fallbackName is what a local session is called before its program reports a title or folder: the launch
    /// profile running its command, numbered after the first of the same profile in `earlier`.
    public nonisolated static func fallbackName(commandLine: String, profiles: [LaunchProfile], earlier: [String]) -> String {
        let base = profiles.first { $0.commandLine == commandLine }?.name ?? "Session"
        let siblings = earlier.filter { $0.hasPrefix(base) }.count
        return siblings == 0 ? base : "\(base) \(siblings + 1)"
    }
}
