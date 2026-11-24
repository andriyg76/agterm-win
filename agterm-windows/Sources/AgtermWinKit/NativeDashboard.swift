import Foundation
import agtermCore

/// NativeDashboard lays out the dashboard: up to nine panes' terminals in a view-only grid over the terminal area, as
/// agtermCore's DashboardLayout sizes it on a Mac, each cell captioned with its session's name.
public enum NativeDashboard {
    public typealias Rect = NativeOverlay.Rect

    public struct Cell: Equatable, Sendable {
        /// frame is the whole cell, caption its name strip along the top, terminal what is left under it.
        public let frame: Rect
        public let caption: Rect
        public let terminal: Rect
    }

    /// cells splits `area` into the grid for `count` members, row by row, `gap` pixels apart.
    public static func cells(in area: Rect, count: Int, gap: Int32, caption: Int32) -> [Cell] {
        guard count > 0 else { return [] }
        let (columns, rows) = DashboardLayout.grid(count: count)
        let width = max((area.width - gap * Int32(columns + 1)) / Int32(columns), 1)
        let height = max((area.height - gap * Int32(rows + 1)) / Int32(rows), 1)
        return (0..<min(count, DashboardLayout.maxCells)).map { index in
            let (column, row) = DashboardLayout.cell(index: index, cols: columns)
            let frame = Rect(x: area.x + gap + Int32(column) * (width + gap), y: area.y + gap + Int32(row) * (height + gap),
                             width: width, height: height)
            let strip = min(caption, max(height - 1, 0))
            return Cell(frame: frame, caption: Rect(x: frame.x, y: frame.y, width: width, height: strip),
                        terminal: Rect(x: frame.x, y: frame.y + strip, width: width, height: max(height - strip, 1)))
        }
    }

    /// cell is the index of the cell holding a point, nil between cells.
    public static func cell(at x: Int32, _ y: Int32, in cells: [Cell]) -> Int? {
        cells.firstIndex { x >= $0.frame.x && x < $0.frame.x + $0.frame.width && y >= $0.frame.y && y < $0.frame.y + $0.frame.height }
    }

    /// Target is a resolved `dashboard` argument: a session, and the pane its `:left`/`:right` names, nil for both.
    public struct Target: Equatable, Sendable {
        public let session: UUID
        public let pane: TerminalZoomSurface?

        public init(session: UUID, pane: TerminalZoomSurface?) {
            self.session = session
            self.pane = pane
        }
    }

    /// members expands targets into cells as AppStore.dashboardPaneCells does: a bare session is its primary pane and,
    /// with a split, its split pane; a repeat is dropped, and so is everything past `limit`, which `dropped` counts.
    public static func members(for targets: [Target], hasSplit: (UUID) -> Bool,
                               limit: Int = DashboardLayout.maxCells) -> (members: [DashboardMember], dropped: Int) {
        var expanded: [DashboardMember] = []
        var seen = Set<DashboardMember>()
        for target in targets {
            var cells = [DashboardMember(session: target.session, surface: target.pane ?? .primary)]
            if target.pane == nil, hasSplit(target.session) { cells.append(DashboardMember(session: target.session, surface: .split)) }
            for cell in cells where seen.insert(cell).inserted { expanded.append(cell) }
        }
        let capped = Array(expanded.prefix(limit))
        return (capped, expanded.count - capped.count)
    }

    /// fontModeName is `tree`'s `dashboardFontMode`.
    public static func fontModeName(_ mode: DashboardFontMode) -> String {
        switch mode {
        case .untouched: "untouched"
        case .fixed: "fixed"
        case .auto: "auto"
        }
    }

    /// caption is a cell's name strip: the session's name, and which pane of a split session it shows.
    public static func caption(name: String, member: DashboardMember, split: SplitAxis?) -> String {
        guard let split else { return name }
        let primary = member.surface == .primary
        let side = split == .leftRight ? (primary ? "left" : "right") : (primary ? "top" : "bottom")
        return "\(name) · \(side)"
    }
}

/// QuickPanel places the quick terminal: QuickTerminalMetrics' size on the monitor under the pointer, centred across
/// it and a little below its top.
public enum QuickPanel {
    public static func frame(work: NativeOverlay.Rect, dpi: UInt32, sizePercent: Int? = nil) -> NativeOverlay.Rect {
        let scale = Double(max(dpi, 1)) / 96
        let visible = WindowGeometry.Size(width: Double(work.width) / scale, height: Double(work.height) / scale)
        let size = QuickTerminalMetrics.panelSize(visible: visible, sizePercent: sizePercent)
        let width = min(Int32((size.width * scale).rounded()), work.width), height = min(Int32((size.height * scale).rounded()), work.height)
        let top = work.y + min((work.height - height) / 2, Int32((48 * scale).rounded()))
        return NativeOverlay.Rect(x: work.x + (work.width - width) / 2, y: top, width: width, height: height)
    }
}
