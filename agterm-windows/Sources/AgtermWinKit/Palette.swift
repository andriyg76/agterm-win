import Foundation
import agtermCore

/// Palette is what the two palettes list and how a query narrows them, as on a Mac: Ctrl+P the sessions, Ctrl+Shift+P
/// the ☰ menu's commands. Rows match their title and subtitle; an empty query keeps the source order.
public enum Palette {
    public enum Mode: Equatable, Sendable {
        case sessions, commands, attention, flagEditor, focusEditor

        public var cue: String {
            switch self {
            case .sessions: "Go to session"
            case .commands: "Run a command"
            case .attention: "Go to attention"
            case .flagEditor: "Flag or unflag sessions"
            case .focusEditor: "Focus or unfocus workspaces"
            }
        }
    }

    public enum Target: Equatable, Sendable {
        case session(UUID)
        /// flag toggles a session's flag in Edit Flagged Sessions, which stays open.
        case flag(UUID)
        /// focus adds a workspace to the focused set or removes it, in Edit Focused Workspaces, which stays open.
        case focus(UUID)
        case pick(NativeMenu.Pick)
        /// pickChoice is one item of a pick, by its id.
        case pickChoice(String)
        /// pickCustom is a pick's free-text row, carrying the trimmed query it answers with.
        case pickCustom(String)
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

    /// Local is a local session as the session palette reads it: `workspace` is its named workspace's name, empty at
    /// the top level, and `parent` the session it is a companion of.
    public struct Local: Sendable {
        public let id: UUID
        public let name: String
        public let exited: Bool
        public let attention: Bool
        public let unseen: Int
        public var workspace = ""
        public var parent: UUID?

        public init(id: UUID, name: String, exited: Bool, attention: Bool, unseen: Int = 0, workspace: String = "", parent: UUID? = nil) {
            self.id = id
            self.name = name
            self.exited = exited
            self.attention = attention
            self.unseen = unseen
            self.workspace = workspace
            self.parent = parent
        }
    }

    /// sessionRows lists every session in the window A→Z by label, local and every server's alike, each session
    /// followed by its companions, titled `parent › companion`.
    @MainActor
    public static func sessionRows(locals: [Local], servers: [(label: String, workspaces: [Workspace])], unseen: [UUID: Int] = [:]) -> [Row] {
        let ids = Set(locals.map(\.id))
        func row(_ local: Local, title: String) -> Row {
            Row(title: title, subtitle: local.workspace,
                detail: state(exited: local.exited, ended: false, attention: local.attention, unseen: local.unseen), target: .session(local.id))
        }
        var groups: [[Row]] = locals.filter { $0.parent.map(ids.contains) != true }.map { parent in
            [row(parent, title: parent.name)] + locals.filter { $0.parent == parent.id }.map { row($0, title: "\(parent.name) › \($0.name)") }
        }
        for (serverLabel, server) in servers {
            groups += serverGroups(server, serverLabel: serverLabel, unseen: unseen)
        }
        return groups.sorted { $0[0].title.localizedCaseInsensitiveCompare($1[0].title) == .orderedAscending }.flatMap { $0 }
    }

    @MainActor
    private static func serverGroups(_ server: [Workspace], serverLabel: String, unseen: [UUID: Int]) -> [[Row]] {
        var groups: [[Row]] = []
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
        return groups
    }

    private static func state(exited: Bool, ended: Bool, attention: Bool, unseen: Int) -> String {
        if unseen > 0 { return "● \(NotificationRules.countLabel(unseen))" }
        if attention { return "●" }
        return exited ? "exited" : ended ? "ended" : ""
    }

    /// Match macOS Attention order across the supplied local and server sessions.
    public static func attentionRows(_ sessions: [(id: UUID, title: String, subtitle: String, status: AgentStatus, changedAt: Date?)]) -> [Row] {
        sessions.filter { $0.status != .idle }.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status.attentionRank < rhs.status.attentionRank }
            return (lhs.changedAt ?? .distantPast) > (rhs.changedAt ?? .distantPast)
        }.map { session in
            Row(title: session.title, subtitle: session.subtitle, detail: session.status.rawValue.capitalized, target: .session(session.id))
        }
    }

    /// FlagGroup is one tree Edit Flagged Sessions lists: the local window's, unlabelled, or a server's under its label;
    /// `editable` is false while that tree's flags cannot be written.
    public typealias FlagGroup = (label: String?, store: AppStore, editable: Bool)

    /// flagRows are Edit Flagged Sessions' rows, the Mac's flagged editor: every session in sidebar order, a companion
    /// titled `parent › companion`, ⚑ while flagged; a pick toggles the flag and keeps the palette open.
    @MainActor
    public static func flagRows(_ groups: [FlagGroup]) -> [Row] {
        groups.flatMap { group in
            group.store.displayWorkspaces.flatMap { workspace in
                let place = [group.label, workspace.isRoot ? nil : workspace.name].compactMap { $0 }.joined(separator: " · ")
                return workspace.sessions.map { session in
                    Row(title: group.store.listLabel(for: session), subtitle: place, detail: session.flagged ? "\u{2691}" : "", enabled: group.editable,
                        target: .flag(session.id))
                }
            }
        }
    }

    /// commandRows is the ☰ menu flattened A→Z: a submenu's entries titled `submenu › entry`, disabled entries kept
    /// so a search still finds them, and the command palette's own entry left out.
    /// focusRows are Edit Focused Workspaces' rows, the Mac's focus editor: every workspace in sidebar order with its
    /// session count, ✓ while a member of the focused set.
    @MainActor
    public static func focusRows(_ groups: [FlagGroup]) -> [Row] {
        groups.flatMap { group in
            group.store.displayWorkspaces.map { workspace in
                let count = workspace.sessions.count
                let subtitle = [group.label, count == 1 ? "1 session" : "\(count) sessions"].compactMap { $0 }.joined(separator: " · ")
                return Row(title: workspace.label, subtitle: subtitle, detail: group.store.focusedWorkspaceIDs.contains(workspace.id) ? "\u{2713}" : "",
                           enabled: group.editable, target: .focus(workspace.id))
            }
        }
    }

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

    /// pickRows is what a pick lists for `query`, upstream `Palette.updateFiltered`: its items matched on their labels
    /// only, in caller order while the query is blank, and with `allowCustom` a `Use "…"` row when nothing matches.
    public static func pickRows(_ pick: PendingPick, query: String) -> [Row] {
        let rows = pick.items.map { Row(title: $0.label, subtitle: $0.subtitle ?? "", target: .pickChoice($0.id)) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = trimmed.isEmpty ? rows
            : fuzzyRank(query: trimmed, items: rows) { paletteSearchKeys(title: $0.title, subtitle: $0.subtitle, callerSupplied: true) }
        if let label = pickCustomRowLabel(query: trimmed, filteredCount: matched.count, allowCustom: pick.allowCustom) {
            return [Row(title: label, target: .pickCustom(trimmed))]
        }
        return matched
    }

    /// pickSeed is the row a pick opens highlighted on: its `--select` item while the first list shows it, else the first.
    public static func pickSeed(_ pick: PendingPick, rows: [Row]) -> Int {
        guard let selection = pick.selection else { return 0 }
        return rows.firstIndex { $0.target == .pickChoice(selection) } ?? 0
    }

    /// step moves the highlight by `delta`, stopping at either end; nil when there is nothing to highlight.
    public static func step(_ index: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max((index ?? 0) + delta, 0), count - 1)
    }
}
