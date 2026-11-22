import Foundation
import agtermCore

/// SessionSidebar is what a remote window's native sidebar shows and does, kept off Win32 so it can be tested:
/// the root workspace's sessions at the top level, named workspaces holding theirs, companions under their session.
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
        workspaces.flatMap { workspace in
            let sessions = sessionItems(workspace.sessions)
            return workspace.isRoot ? sessions
                : [Item(id: workspace.id, title: workspace.name, isWorkspace: true, ended: false, children: sessions)]
        }
    }

    private static func sessionItems(_ sessions: [Session]) -> [Item] {
        let ids = Set(sessions.map(\.id))
        return sessions.filter { $0.parentID.map { !ids.contains($0) } ?? true }.map { parent in
            item(parent, children: sessions.filter { $0.parentID == parent.id }.map { item($0, children: []) })
        }
    }

    private static func item(_ session: Session, children: [Item]) -> Item {
        Item(id: session.id, title: session.ended ? "\(session.displayName) (ended)" : session.displayName, isWorkspace: false,
             ended: session.ended, children: children)
    }

    /// selection keeps `current` while the catalog still has it, else falls to the first live session, else the first
    /// one at all, so the terminal says why there is nothing to show rather than staying blank.
    public static func selection(current: UUID?, in workspaces: [Workspace]) -> UUID? {
        let sessions = workspaces.lazy.flatMap(\.sessions)
        if let current, sessions.contains(where: { $0.id == current }) { return current }
        return (sessions.first { !$0.ended } ?? sessions.first)?.id
    }

    /// launch is what selecting `session` runs: its attach command, or a notice where there is nothing to attach.
    /// agtermCore's placeholder for an ended or held pane is a POSIX line, with no /bin/sh to run it on Windows.
    public static func launch(for session: Session, hostLabel: String) -> Launch {
        let placeholder = session.remoteHost.map(RemoteSession.endedCommand(host:))
        guard let command = session.initialCommand else { return .notice("no pane to attach") }
        return command == placeholder ? .notice("Ended on \(hostLabel)") : .command(command)
    }
}
