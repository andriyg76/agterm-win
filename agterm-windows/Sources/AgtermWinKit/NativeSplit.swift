import Foundation
import agtermCore

/// NativeSplit is a local session's second pane as a Mac session holds one: its axis, the primary pane's share of the
/// session's area, whether both panes are shown, and which one has the keyboard. A hidden split keeps both shells and
/// shows the focused pane alone.
public struct NativeSplit: Equatable, Sendable {
    public var axis: SplitAxis
    /// ratio is the primary pane's share along the axis, within `ratioRange`.
    public var ratio: Double
    public var shown: Bool
    /// focused is whether the split pane, not the primary, has the keyboard.
    public var focused: Bool

    public static let defaultRatio = 0.5
    /// ratioRange mirrors AppStore's clamp, so a ratio read back on Windows means what it does on a Mac.
    public static let ratioRange: ClosedRange<Double> = 0.05...0.95

    public init(axis: SplitAxis = .leftRight, ratio: Double = NativeSplit.defaultRatio, shown: Bool = true, focused: Bool = true) {
        self.axis = axis
        self.ratio = Self.clamp(ratio)
        self.shown = shown
        self.focused = focused
    }

    public static func clamp(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return defaultRatio }
        return min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }

    /// next is the split after `session.split`'s `mode` or a split key, as AppStore.toggleSplit decides it: a toggle with
    /// an axis shows the split on that axis unless it is already shown on it, which hides it; a new split focuses its own
    /// pane. nil while there is no split and none is asked for.
    public static func next(_ current: NativeSplit?, mode: ControlToggleMode, axis: SplitAxis?) -> NativeSplit? {
        let isShown = current?.shown ?? false
        let show: Bool
        switch mode {
        case .on: show = true
        case .off: show = false
        case .toggle: show = axis.map { !isShown || current?.axis != $0 } ?? !isShown
        }
        guard var split = current else { return show ? NativeSplit(axis: axis ?? .leftRight) : nil }
        if show, let axis { split.axis = axis }
        split.shown = show
        return split
    }

    /// axisName is `tree`'s `splitAxis`, the wire spelling.
    public var axisName: String { axis.rawValue }
}

/// PaneLayout is where a session's panes sit in its area: both with a divider between them while a split is shown,
/// else the one in view across all of it.
public struct PaneLayout: Equatable, Sendable {
    public typealias Rect = NativeOverlay.Rect

    public let primary: Rect?
    public let split: Rect?
    public let divider: Rect?

    public init(area: Rect, split: NativeSplit?, divider thickness: Int32) {
        guard let split else {
            self.init(primary: area, split: nil, divider: nil)
            return
        }
        guard split.shown else {
            self.init(primary: split.focused ? nil : area, split: split.focused ? area : nil, divider: nil)
            return
        }
        let vertical = split.axis == .leftRight
        let extent = vertical ? area.width : area.height
        let available = max(extent - thickness, 2)
        let first = min(max(Int32((Double(available) * split.ratio).rounded()), 1), available - 1)
        let second = available - first
        if vertical {
            self.init(primary: Rect(x: area.x, y: area.y, width: first, height: area.height),
                      split: Rect(x: area.x + first + thickness, y: area.y, width: second, height: area.height),
                      divider: Rect(x: area.x + first, y: area.y, width: thickness, height: area.height))
        } else {
            self.init(primary: Rect(x: area.x, y: area.y, width: area.width, height: first),
                      split: Rect(x: area.x, y: area.y + first + thickness, width: area.width, height: second),
                      divider: Rect(x: area.x, y: area.y + first, width: area.width, height: thickness))
        }
    }

    init(primary: Rect?, split: Rect?, divider: Rect?) {
        self.primary = primary
        self.split = split
        self.divider = divider
    }

    /// onDivider is whether a point is on the divider or within `slop` pixels of it, where a drag moves it.
    public func onDivider(x: Int32, y: Int32, slop: Int32 = 0) -> Bool {
        guard let divider else { return false }
        return x >= divider.x - slop && x < divider.x + divider.width + slop && y >= divider.y - slop && y < divider.y + divider.height + slop
    }

    /// ratio is the primary pane's share that puts the divider's middle at the point a drag reached, clamped.
    public static func ratio(at x: Int32, _ y: Int32, area: Rect, axis: SplitAxis, divider thickness: Int32) -> Double {
        let vertical = axis == .leftRight
        let offset = Double((vertical ? x - area.x : y - area.y) - thickness / 2)
        let available = Double(max((vertical ? area.width : area.height) - thickness, 2))
        return NativeSplit.clamp(offset / available)
    }
}

/// NativePane names one of a local session's terminals, as `--pane` does on a Mac.
public enum NativePane: String, Equatable, Sendable {
    case primary = "left"
    case split = "right"
    case scratch

    /// parse reads `--pane`: `primary|left|top`, `split|right|bottom` or `scratch`; nil for anything else.
    public init?(controlName: String) {
        if controlName == "scratch" {
            self = .scratch
            return
        }
        switch TerminalZoomSurface(controlName: controlName) {
        case .primary?: self = .primary
        case .split?: self = .split
        default: return nil
        }
    }

    /// onScreen is the pane a command without `--pane` reaches, as `onScreenSurface` picks it: a shown scratch, else the
    /// focused pane.
    public static func onScreen(split: NativeSplit?, scratchShown: Bool) -> NativePane {
        if scratchShown { return .scratch }
        return split?.focused == true ? .split : .primary
    }
}
