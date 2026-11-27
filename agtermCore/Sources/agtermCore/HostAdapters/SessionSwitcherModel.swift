import Foundation

/// The Ctrl-Tab cycle over recent sessions, as macOS `SessionSwitcher` runs it.
public struct SessionSwitcherModel: Equatable, Sendable {
    /// Cap on cycle rows, shared with the recent-sessions list (macOS `SessionSwitcher.maxCandidates`).
    public static let maxCandidates = 10

    private var candidates: [UUID] = []
    private var index = 0

    public init() {}

    public var isActive: Bool { !candidates.isEmpty }
    public var current: UUID? { candidates.indices.contains(index) ? candidates[index] : nil }
    public var ordered: [UUID] { candidates }

    /// begin starts on the second most recent session; fewer than two leave nothing to switch to.
    public mutating func begin(_ mru: [UUID]) {
        guard mru.count >= 2 else {
            end()
            return
        }
        candidates = mru
        index = 1
    }

    public mutating func advance(reverse: Bool = false) {
        guard !candidates.isEmpty else { return }
        let delta = reverse ? -1 : 1
        index = ((index + delta) % candidates.count + candidates.count) % candidates.count
    }

    /// commitTarget is the highlighted session while it still exists; one closed mid-hold commits nothing, as on macOS.
    public func commitTarget(liveIDs: Set<UUID>) -> UUID? {
        guard let current, liveIDs.contains(current) else { return nil }
        return current
    }

    public mutating func end() {
        candidates = []
        index = 0
    }

    /// canSwitch is macOS's `canSwitch`: each of these owns the keyboard, so a cycle neither begins nor commits under one.
    public static func canSwitch(zoomed: Bool, dashboardOpen: Bool, modalPending: Bool, dialogVisible: Bool,
                                 popoverOpen: Bool) -> Bool {
        !(zoomed || dashboardOpen || modalPending || dialogVisible || popoverOpen)
    }
}
