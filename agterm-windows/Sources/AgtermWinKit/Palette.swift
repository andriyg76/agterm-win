import Foundation
import agtermCore

/// Palette is what the two palettes list and how a query narrows them, as on a Mac: Ctrl+P the sessions, Ctrl+Shift+P
/// the ☰ menu's commands. Rows match their title and subtitle; an empty query keeps the source order.
public enum Palette {
    public enum Mode: Equatable, Sendable {
        case sessions, commands

        public var cue: String { self == .sessions ? "Go to session" : "Run a command" }
    }

    public enum Target: Equatable, Sendable {
        case session(UUID)
        case pick(NativeMenu.Pick)
    }

    public struct Row: Equatable, Sendable {
        public let title: String
        /// subtitle is the session's workspace, or the submenu a command sits in; searched with the title.
        public let subtitle: String
        /// detail is drawn at the trailing edge: a command's chord, a session's state.
        public let detail: String
        public let enabled: Bool
        public let target: Target

        public init(title: String, subtitle: String = "", detail: String = "", enabled: Bool = true, target: Target) {
            self.title = title
            self.subtitle = subtitle
            self.detail = detail
            self.enabled = enabled
            self.target = target
        }
    }

    /// Local is a local session as the session palette reads it.
    public struct Local: Sendable {
        public let id: UUID
        public let name: String
        public let exited: Bool
        public let attention: Bool
        public let unseen: Int

        public init(id: UUID, name: String, exited: Bool, attention: Bool, unseen: Int = 0) {
            self.id = id
            self.name = name
            self.exited = exited
            self.attention = attention
            self.unseen = unseen
        }
    }

    /// sessionRows lists every session in the window A→Z by label, local and the server's alike, each server session
    /// followed by its companions, titled `parent › companion`.
    @MainActor
    public static func sessionRows(locals: [Local], server: [Workspace], serverLabel: String, unseen: [UUID: Int] = [:]) -> [Row] {
        var groups: [[Row]] = locals.map { local in
            [Row(title: local.name, subtitle: "Local", detail: state(exited: local.exited, ended: false, attention: local.attention, unseen: local.unseen),
                 target: .session(local.id))]
        }
        for workspace in server {
            let subtitle = workspace.isRoot || workspace.name.isEmpty ? serverLabel : "\(serverLabel) · \(workspace.name)"
            let ids = Set(workspace.sessions.map(\.id))
            func row(_ session: Session, title: String) -> Row {
                Row(title: title, subtitle: subtitle, detail: state(exited: false, ended: session.ended, attention: false, unseen: unseen[session.id] ?? 0),
                    target: .session(session.id))
            }
            for parent in workspace.sessions where parent.parentID.map(ids.contains) != true {
                let companions = workspace.sessions.filter { $0.parentID == parent.id }
                groups.append([row(parent, title: parent.displayName)]
                    + companions.map { row($0, title: "\(parent.displayName) › \($0.displayName)") })
            }
        }
        return groups.sorted { $0[0].title.localizedCaseInsensitiveCompare($1[0].title) == .orderedAscending }.flatMap { $0 }
    }

    private static func state(exited: Bool, ended: Bool, attention: Bool, unseen: Int) -> String {
        if unseen > 0 { return "● \(NotificationRules.countLabel(unseen))" }
        if attention { return "●" }
        return exited ? "exited" : ended ? "ended" : ""
    }

    /// commandRows is the ☰ menu flattened A→Z: a submenu's entries titled `submenu › entry`, disabled entries kept
    /// so a search still finds them, and the command palette's own entry left out.
    public static func commandRows(_ entries: [NativeMenu.Entry]) -> [Row] {
        func flatten(_ entries: [NativeMenu.Entry], under parent: String?) -> [Row] {
            entries.flatMap { entry -> [Row] in
                if !entry.children.isEmpty { return flatten(entry.children, under: entry.title) }
                guard let pick = entry.pick, pick != .command(.commandPalette) else { return [] }
                return [Row(title: parent.map { "\($0) › \(entry.title)" } ?? entry.title, detail: entry.shortcut, enabled: entry.enabled,
                            target: .pick(pick))]
            }
        }
        return flatten(entries, under: nil).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// filter narrows `rows` to `query`, best match first; a blank query keeps them as they are.
    public static func filter(_ rows: [Row], query: String) -> [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rows }
        return fuzzyRank(query: trimmed, items: rows) { paletteSearchKeys(title: $0.title, subtitle: $0.subtitle, callerSupplied: false) }
    }

    /// step moves the highlight by `delta`, stopping at either end; nil when there is nothing to highlight.
    public static func step(_ index: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max((index ?? 0) + delta, 0), count - 1)
    }
}
