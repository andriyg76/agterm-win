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

        public init(id: UUID, title: String, isWorkspace: Bool, ended: Bool, children: [Item]) {
            self.id = id
            self.title = title
            self.isWorkspace = isWorkspace
            self.ended = ended
            self.children = children
        }
    }

    public enum Launch: Equatable, Sendable {
        case command(String)
        case notice(String)
    }

    /// items lays out the server's tree; `unseen` counts the notifications each server session had out of view.
    public static func items(_ workspaces: [Workspace], unseen: [UUID: Int] = [:]) -> [Item] {
        workspaces.flatMap { workspace in
            let sessions = sessionItems(workspace.sessions, unseen: unseen)
            return workspace.isRoot ? sessions
                : [Item(id: workspace.id, title: workspace.name, isWorkspace: true, ended: false, children: sessions)]
        }
    }

    /// server is one agterm-server's group: its label over its tree, so every server's sessions read the same way.
    public static func server(id: UUID, label: String, workspaces: [Workspace], unseen: [UUID: Int] = [:]) -> Item {
        Item(id: id, title: label, isWorkspace: true, ended: false, children: items(workspaces, unseen: unseen))
    }

    private static func sessionItems(_ sessions: [Session], unseen: [UUID: Int]) -> [Item] {
        let ids = Set(sessions.map(\.id))
        return sessions.filter { $0.parentID.map { !ids.contains($0) } ?? true }.map { parent in
            item(parent, unseen: unseen, children: sessions.filter { $0.parentID == parent.id }.map { item($0, unseen: unseen, children: []) })
        }
    }

    private static func item(_ session: Session, unseen: [UUID: Int], children: [Item]) -> Item {
        let count = unseen[session.id] ?? 0
        let marker = count > 0 ? "● \(NotificationRules.countLabel(count)) " : ""
        return Item(id: session.id, title: marker + (session.ended ? "\(session.displayName) (ended)" : session.displayName),
                    isWorkspace: false, ended: session.ended, children: children)
    }

    /// localTitle is a local session's sidebar label: ● while it wants attention (a bell or notification since it was
    /// last shown), with how many notifications when `unseen` counts them, and marked once its program exits.
    public nonisolated static func localTitle(_ name: String, exited: Bool, attention: Bool, unseen: Int = 0) -> String {
        let marker = unseen > 0 ? "● \(NotificationRules.countLabel(unseen)) " : attention ? "● " : ""
        return marker + name + (exited ? " (exited)" : "")
    }

    /// selection keeps `current` while the catalog still has it, else falls to the first live session, else the first
    /// one at all, so the terminal says why there is nothing to show rather than staying blank.
    public static func selection(current: UUID?, in workspaces: [Workspace]) -> UUID? {
        let sessions = workspaces.lazy.flatMap(\.sessions)
        if let current, sessions.contains(where: { $0.id == current }) { return current }
        return (sessions.first { !$0.ended } ?? sessions.first)?.id
    }

    /// neighbor is the session after (or before) `current` in sidebar order, wrapping around; the first one when
    /// `current` is not among them.
    public nonisolated static func neighbor(of current: UUID?, in order: [UUID], forward: Bool) -> UUID? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else { return forward ? order.first : order.last }
        return order[(index + (forward ? 1 : order.count - 1)) % order.count]
    }

    /// launch is what selecting `session` runs: its attach command, or a notice where there is nothing to attach.
    /// agtermCore's placeholder for an ended or held pane is a POSIX line, with no /bin/sh to run it on Windows.
    public static func launch(for session: Session, hostLabel: String) -> Launch {
        let placeholder = session.remoteHost.map(RemoteSession.endedCommand(host:))
        guard let command = session.initialCommand else { return .notice("no pane to attach") }
        return command == placeholder ? .notice("Ended on \(hostLabel)") : .command(command)
    }
}
