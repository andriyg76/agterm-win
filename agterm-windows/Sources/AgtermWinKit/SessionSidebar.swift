import Foundation
import agtermCore

/// SessionSidebar is what a remote window's native sidebar shows and does, kept off Win32 so it can be tested:
/// workspaces holding sessions, companions under the session they belong to.
@MainActor
public enum SessionSidebar {
    public struct Item: Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let isWorkspace: Bool
        public let ended: Bool
        public let children: [Item]
    }

    public enum Launch: Equatable, Sendable {
        case command(String)
        case notice(String)
    }

    public static func items(_ workspaces: [Workspace]) -> [Item] {
        workspaces.map { workspace in
            let ids = Set(workspace.sessions.map(\.id))
            let roots = workspace.sessions.filter { $0.parentID.map { !ids.contains($0) } ?? true }
            return Item(id: workspace.id, title: workspace.name, isWorkspace: true, ended: false,
                        children: roots.map { root in
                            item(root, children: workspace.sessions.filter { $0.parentID == root.id }.map { item($0, children: []) })
                        })
        }
    }

    private static func item(_ session: Session, children: [Item]) -> Item {
        Item(id: session.id, title: session.ended ? "\(session.displayName) (ended)" : session.displayName, isWorkspace: false,
             ended: session.ended, children: children)
    }

    /// selection keeps `current` while the catalog still has it, else falls to the first live session.
    public static func selection(current: UUID?, in workspaces: [Workspace]) -> UUID? {
        let sessions = workspaces.lazy.flatMap(\.sessions)
        if let current, sessions.contains(where: { $0.id == current }) { return current }
        return sessions.first { !$0.ended }?.id
    }

    /// launch is what selecting `session` runs: its attach command, or a notice where there is nothing to attach.
    /// agtermCore's placeholder for an ended or held pane is a POSIX line, with no /bin/sh to run it on Windows.
    public static func launch(for session: Session, hostLabel: String) -> Launch {
        let placeholder = session.remoteHost.map(RemoteSession.endedCommand(host:))
        guard let command = session.initialCommand else { return .notice("no pane to attach") }
        return command == placeholder ? .notice("Ended on \(hostLabel)") : .command(command)
    }
}
