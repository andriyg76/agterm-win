import Foundation
import agtermCore

/// AgentActivity is a local session's agent status, kept by `AppStore+Status`'s rules: the indicator the row shows,
/// each pane's last `active`, and when a status was last set. A block holds against another pane's other writes, and a
/// pane's completed or idle shows another pane's retained `active`, so one agent's turn end cannot idle a row while
/// another still works. Ephemeral, as on a Mac.
public struct AgentActivity: Equatable, Sendable {
    public private(set) var indicator = AgentIndicator()
    public private(set) var paneActivity: [StatusPane: AgentIndicator] = [:]
    public private(set) var changedAt: Date?

    public init() {}

    /// keystroke is what typed `text` means to the glyph: Escape or Ctrl-C interrupts, a line ending submits; nil for
    /// nothing typed, which clears nothing, as an empty `session.type` does not on a Mac.
    public static func keystroke(_ text: String) -> StatusKeystroke? {
        if text.isEmpty { return nil }
        if text == "\u{1B}" || text == "\u{03}" { return .interrupt }
        return text.contains(where: \.isNewline) ? .submit : .other
    }

    /// apply records a `session.status` write; false only for an `ifIdle` write on a non-idle row, which changes nothing.
    @discardableResult
    public mutating func apply(_ update: ControlSessionStatusUpdate, hasSplit: Bool, now: Date = Date()) -> Bool {
        if update.ifIdle, indicator.status != .idle { return false }
        let written = AgentIndicator(status: update.status, blink: update.blink ?? false, autoReset: update.autoReset ?? false,
                                     color: update.color, shape: update.shape, statusPane: Self.normalized(update.pane, hasSplit: hasSplit))
        let writer = written.statusPane ?? .left
        paneActivity[writer] = written.status == .active ? written : nil
        if indicator.status == .blocked, written.status != .blocked, (indicator.statusPane ?? .left) != writer { return true }
        let ending = written.status == .completed || written.status == .idle
        show(ending ? remainingActivity ?? written : written, now: now)
        return true
    }

    /// clear applies typing in `pane`: an interrupt ends that pane's activity whatever the row shows, and the shown
    /// status clears when `pane` owns it and `reset` allows.
    public mutating func clear(by keystroke: StatusKeystroke, pane: StatusPane, reset: StatusReset, now: Date = Date()) {
        if keystroke == .interrupt { paneActivity[pane] = nil }
        if indicator.clearedBy(pane: pane, keystroke: keystroke, reset: reset) { show(remainingActivity ?? AgentIndicator(), now: now) }
    }

    /// visited ends an `--auto-reset` status as the session is entered or left.
    public mutating func visited(now: Date = Date()) {
        guard indicator.autoReset, indicator.status != .idle else { return }
        let pane = indicator.statusPane ?? .left
        paneActivity[pane] = nil
        show(remainingActivity ?? AgentIndicator(), now: now)
    }

    /// paneEnded drops what a closed pane reported, so a block it owned cannot outlive the only surface that clears it.
    public mutating func paneEnded(_ pane: StatusPane, now: Date = Date()) {
        paneActivity[pane] = nil
        if indicator.status != .idle, (indicator.statusPane ?? .left) == pane { show(remainingActivity ?? AgentIndicator(), now: now) }
    }

    /// swapped follows a pane swap: what each terminal reported moves with it, as status ownership does on a Mac.
    public mutating func swapped() {
        let flip: (StatusPane) -> StatusPane = { $0 == .left ? .right : $0 == .right ? .left : $0 }
        paneActivity = Dictionary(uniqueKeysWithValues: paneActivity.map { (flip($0.key), $0.value) })
        if indicator.status != .idle { indicator.statusPane = flip(indicator.statusPane ?? .left) }
    }

    /// activePanes is the tree's `activePanes`: the panes still reporting work.
    public var activePanes: [String] { StatusPane.allCases.filter { paneActivity[$0] != nil }.map(\.rawValue) }

    private var remainingActivity: AgentIndicator? {
        for pane in StatusPane.allCases {
            guard var activity = paneActivity[pane] else { continue }
            activity.statusPane = pane
            return activity
        }
        return nil
    }

    private mutating func show(_ next: AgentIndicator, now: Date) {
        indicator = next
        if next.status == .idle { paneActivity.removeAll() }
        changedAt = now
    }

    // a promoted survivor keeps its spawn-time `right`, which only the sole pane could ever clear
    private static func normalized(_ pane: StatusPane?, hasSplit: Bool) -> StatusPane? {
        pane == .right && !hasSplit ? .left : pane
    }
}

/// StatusGlyph is how the sidebar and title bar draw a status: a character for its shape and an RGB tint.
public enum StatusGlyph {
    /// character draws each `StatusShape` with a glyph Segoe UI's fallback fonts carry.
    public static func character(_ shape: StatusShape) -> String {
        switch shape {
        case .circle: "●"
        case .square: "■"
        case .triangle: "▲"
        case .triangleDown: "▼"
        case .play: "▶"
        case .diamond: "◆"
        case .capsule: "⬬"
        case .seal: "✹"
        case .star: "★"
        case .bolt: "ϟ"
        case .bell: "🔔"
        case .checkmark: "✔"
        }
    }

    /// rgb is the per-call color, else the Mac app's default tint for the status; nil for idle, which draws nothing.
    public static func rgb(_ indicator: AgentIndicator) -> UInt32? {
        if let color = indicator.color, let value = UInt32(color.dropFirst(), radix: 16) { return value }
        switch indicator.status {
        case .idle: return nil
        case .active: return 0xDBD9E6
        case .blocked: return 0xFF9F0A
        case .completed: return 0x30D158
        }
    }

    /// macSoundNames are the system sounds a Mac's `session.status --sound` names in its refusal; Windows has none of
    /// them, so each plays the system alert, as `default` and `beep` do.
    public static let macSoundNames = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Hero", "Morse",
                                       "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink", "Glass"]

    public static func acceptsSound(_ name: String) -> Bool { name == "default" || name == "beep" || macSoundNames.contains(name) }

    /// infoText is an info line as plain text, the spans' styling dropped.
    public static func infoText(_ info: SessionInfo?) -> String? {
        info.map { $0.spans.map(\.text).joined() }
    }
}
