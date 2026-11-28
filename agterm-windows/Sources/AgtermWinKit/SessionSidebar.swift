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
        /// status and info are what an agent reported: the glyph at the row's edge and the line under its title.
        public let status: AgentIndicator
        public let info: String?
        /// expanded is whether the row shows its children: a folded workspace or companion group does not.
        public var expanded = true
        public var tint: SidebarTint?

        public init(id: UUID, title: String, isWorkspace: Bool, ended: Bool, children: [Item], status: AgentIndicator = AgentIndicator(),
                    info: String? = nil, expanded: Bool = true, tint: SidebarTint? = nil) {
            self.id = id
            self.title = title
            self.isWorkspace = isWorkspace
            self.ended = ended
            self.children = children
            self.status = status
            self.info = info
            self.expanded = expanded
            self.tint = tint
        }
    }

    /// Label is how a row reads: its title, whether its program ended, and its agent's status and info line.
    public typealias Label = (title: String, ended: Bool, status: AgentIndicator, info: String?)

    /// items lays out `store` as a Mac's sidebar does: in the tree, the root's sessions at the top level and each
    /// workspace the focus filter shows as a row, companions under their session, folds kept; in the flagged view,
    /// the flagged sessions alone, in their saved order. `label` names a session, the server catalog's way when nil.
    public static func items(_ store: AppStore, unseen: [UUID: Int] = [:], label: ((Session) -> Label)? = nil) -> [Item] {
        let name = label ?? { session in
            (catalogTitle(session, unseen: unseen), session.ended, session.agentIndicator, StatusGlyph.infoText(session.effectiveInfo))
        }
        if store.sidebarMode == .flagged {
            switch store.flaggedLayout {
            case .tree:
                return store.displayWorkspaces.flatMap { workspace -> [Item] in
                    let sessions = workspace.sessions.filter(\.flagged).map { row($0, name($0), children: []) }
                    guard !sessions.isEmpty else { return [] }
                    return workspace.isRoot ? sessions
                        : [Item(id: workspace.id, title: workspace.name, isWorkspace: true, ended: false, children: sessions,
                                expanded: workspace.isExpanded, tint: workspace.tint)]
                }
            case .flat, .plain:
                return store.orderedFlaggedSessions.map { session in
                    var label = name(session)
                    if store.flaggedLayout == .flat, let workspace = store.workspace(forSession: session.id)?.name, !workspace.isEmpty {
                        label.title += " : \(workspace)"
                    }
                    return row(session, label, children: [])
                }
            }
        }
        // the Mac fills a flagged row's icon; these rows have no icon, so the flag follows the name
        let marked: (Session) -> Label = { session in
            var label = name(session)
            if session.flagged { label.title += " ⚑" }
            return label
        }
        return store.visibleWorkspaces.flatMap { workspace in
            let sessions = groupedItems(workspace.sessions, name: marked)
            return workspace.isRoot ? sessions
                : [Item(id: workspace.id, title: workspace.name, isWorkspace: true, ended: false, children: sessions, expanded: workspace.isExpanded,
                        tint: workspace.tint)]
        }
    }

    private static func groupedItems(_ sessions: [Session], name: (Session) -> Label) -> [Item] {
        let ids = Set(sessions.map(\.id))
        return sessions.filter { $0.parentID.map { !ids.contains($0) } ?? true }.map { parent in
            let companions = sessions.filter { $0.parentID == parent.id }.map { row($0, name($0), children: []) }
            return row(parent, name(parent), children: companions)
        }
    }

    private static func row(_ session: Session, _ label: Label, children: [Item]) -> Item {
        Item(id: session.id, title: label.title, isWorkspace: false, ended: label.ended, children: children, status: label.status,
             info: label.info, expanded: session.isExpanded, tint: session.tint)
    }

    private static func catalogTitle(_ session: Session, unseen: [UUID: Int]) -> String {
        let count = unseen[session.id] ?? 0
        let marker = count > 0 ? "● \(NotificationRules.countLabel(count)) " : ""
        return marker + (session.ended ? "\(session.displayName) (ended)" : session.displayName)
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
                : [Item(id: workspace.id, title: workspace.name, isWorkspace: true, ended: false, children: sessions, tint: workspace.tint)]
        }
    }

    /// server is one agterm-server's group: its label over its tree, so every server's sessions read the same way.
    public static func server(id: UUID, label: String, workspaces: [Workspace], unseen: [UUID: Int] = [:]) -> Item {
        Item(id: id, title: label, isWorkspace: true, ended: false, children: items(workspaces, unseen: unseen))
    }

    /// server is a remote window's section: its label over the server's tree as this window shows it.
    public static func server(id: UUID, label: String, store: AppStore, unseen: [UUID: Int] = [:]) -> Item {
        Item(id: id, title: label, isWorkspace: true, ended: false, children: items(store, unseen: unseen))
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
                    isWorkspace: false, ended: session.ended, children: children, status: session.agentIndicator,
                    info: StatusGlyph.infoText(session.effectiveInfo), tint: session.tint)
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
