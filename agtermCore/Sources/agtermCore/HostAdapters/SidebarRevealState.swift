import Foundation

/// Positive-only overlay over persisted `Workspace.isExpanded`: selecting a session inside a collapsed workspace shows
/// its rows without a store write. The gate reveals once per selection change, so a status or title resync never
/// reopens a workspace the user collapsed while its session stayed selected. Flagged mode follows macOS's flat
/// outline: a listed selection advances the gate with no owner to reveal and an unlisted one clears it, so a fold
/// survives a flagged round trip.
public struct SidebarRevealState: Sendable {
    public private(set) var transientlyExpandedWorkspaceIDs: Set<UUID> = []
    public private(set) var lastRevealedSelection: UUID?

    public init() {}

    /// syncedExpansion is the one derivation of what the sidebar shows expanded, run once per sync pass. Every step
    /// is idempotent, so a second call in the same pass changes nothing.
    @MainActor
    public mutating func syncedExpansion(store: AppStore) -> Set<UUID> {
        if !transientlyExpandedWorkspaceIDs.isEmpty {
            transientlyExpandedWorkspaceIDs.formIntersection(store.workspaces.map(\.id))
        }
        let selected = store.selectedSessionID
        switch store.sidebarMode {
        case .tree:
            revealIfSelectionChanged(selected: selected, owner: selected.flatMap { store.workspace(forSession: $0)?.id })
        case .flagged:
            lastRevealedSelection = selected.flatMap { id in store.flaggedSessions.contains { $0.id == id } ? id : nil }
        }
        return effectiveExpandedIDs(workspaces: store.workspaces)
    }

    public mutating func revealIfSelectionChanged(selected: UUID?, owner: UUID?) {
        guard let selected else {
            lastRevealedSelection = nil
            return
        }
        guard let owner, selected != lastRevealedSelection else { return }
        transientlyExpandedWorkspaceIDs.insert(owner)
        lastRevealedSelection = selected
    }

    public mutating func clearTransient(_ id: UUID) {
        transientlyExpandedWorkspaceIDs.remove(id)
    }

    public mutating func clearAllTransient() {
        transientlyExpandedWorkspaceIDs.removeAll()
    }

    @MainActor
    public func effectiveExpandedIDs(workspaces: [Workspace]) -> Set<UUID> {
        Set(workspaces.lazy.filter { $0.isExpanded || transientlyExpandedWorkspaceIDs.contains($0.id) }.map(\.id))
    }
}
