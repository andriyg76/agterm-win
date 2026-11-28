import Foundation
import agtermCore

/// NativeAsk is the ask panel's host-free half: which slot holds the ask, what a key does, and the panel's width.
/// The rules are upstream's `AskDialogView` and `AskKeyCatcher` (umputun/agterm), driving agtermCore's `AskDraft` and
/// `AskNavigation`, so a Windows panel answers exactly as a Mac one does.
public enum NativeAsk {
    /// Slot is where the shown ask lives: the window modal slot (a GUI ask) or its session's own (a terminal ask, or
    /// a server's ask of either style mirrored into the catalog row).
    @MainActor
    public enum Slot {
        case window(PickController)
        case session(Session)

        public var ask: PendingAsk? {
            switch self {
            case .window(let controller): controller.pendingAsk
            case .session(let session): session.askPending
            }
        }

        public var draft: AskDraft? {
            switch self {
            case .window(let controller): controller.askDraft
            case .session(let session): session.askDraft
            }
        }

        public func updateDraft(_ change: (inout AskDraft) -> Void) {
            guard let id = ask?.id else { return }
            switch self {
            case .window(let controller): controller.updateAskDraft(id: id, change)
            case .session(let session): session.updateAskDraft(id: id, change)
            }
        }

        public func answer(_ index: Int) {
            guard let id = ask?.id else { return }
            switch self {
            case .window(let controller): controller.answerAsk(id: id, buttonAt: index)
            case .session(let session): session.answerAsk(id: id, buttonAt: index)
            }
        }

        /// escape is Esc or Ctrl+W: the user dismissed the ask, which is `escaped`, not `cancelled`.
        public func escape() {
            guard let id = ask?.id else { return }
            switch self {
            case .window(let controller): controller.escapeAsk()
            case .session(let session): session.resolveAsk(id: id, ControlAskResult(result: .escaped))
            }
        }
    }

    /// Key is what a key press asks of the panel, upstream's `AskKey`.
    public enum Key: Equatable, Sendable {
        case forward, backward, up, down, toggle, activate, cancel
        case hotkey(String)
    }

    /// Editor names the field that holds the keyboard: the `--input` field or the `--other` line of a list.
    public enum Editor: Equatable, Sendable {
        case input(ControlAskInputMode)
        case other
    }

    static let tab: Int32 = 0x09, enter: Int32 = 0x0D, escape: Int32 = 0x1B, space: Int32 = 0x20
    static let left: Int32 = 0x25, up: Int32 = 0x26, right: Int32 = 0x27, down: Int32 = 0x28, letterW: Int32 = 0x57

    /// key maps a key pressed with the panel itself focused. A letter is a hotkey by its virtual key, which a Latin
    /// layout gives the typed letter and any other layout the US-layout letter at that position, as upstream's
    /// `resolvedHotkey` resolves a Mac key. Ctrl+W dismisses like Esc; any other Ctrl or Alt chord is not the panel's.
    public static func key(virtualKey: Int32, shift: Bool, control: Bool, alt: Bool) -> Key? {
        if control, !alt, !shift, virtualKey == letterW { return .cancel }
        guard !control, !alt else { return nil }
        switch virtualKey {
        case tab: return shift ? .backward : .forward
        case right: return .forward
        case left: return .backward
        case down: return .down
        case up: return .up
        case space: return .toggle
        case enter: return .activate
        case escape: return .cancel
        case 0x41...0x5A: return .hotkey(String(UnicodeScalar(UInt8(virtualKey + 0x20))))
        default: return nil
        }
    }

    /// editorKey maps a key pressed in an editor; nil leaves it to the editor. Tab moves the button highlight, Return
    /// answers a one-line field and the other line, Ctrl+Return a multiline one, and on the other line Up returns to
    /// the item above while Down stays.
    public static func editorKey(_ editor: Editor, virtualKey: Int32, shift: Bool, control: Bool, alt: Bool) -> Key? {
        guard !alt else { return nil }
        switch virtualKey {
        case escape where !control: return .cancel
        case letterW where control && !shift: return .cancel
        case tab where !control: return shift ? .backward : .forward
        case enter where editor == .input(.multiline): return control ? .activate : nil
        case enter where !control: return .activate
        case up where editor == .other && !control: return .up
        case down where editor == .other && !control: return .down
        default: return nil
        }
    }

    /// apply runs `key` against the shown ask, upstream's `AskDialogView.handle`: a list moves its cursor with Up and
    /// Down and toggles with Space, any other ask moves the button highlight with them. It returns the button to
    /// answer with, or whether Esc dismissed it.
    @MainActor
    public static func apply(_ key: Key, to slot: Slot, navigation: inout AskNavigation) -> Outcome {
        guard let ask = slot.ask else { return .none }
        let list: Bool
        if case .choices = ask.form { list = true } else { list = false }
        switch key {
        case .forward: navigation.moveForward()
        case .backward: navigation.moveBackward()
        case .down:
            if list { slot.updateDraft { $0.moveCursor(by: 1) } } else { navigation.moveForward() }
        case .up:
            if list { slot.updateDraft { $0.moveCursor(by: -1) } } else { navigation.moveBackward() }
        case .toggle:
            if list { slot.updateDraft { $0.toggleCursor() } }
        case .activate:
            if let index = navigation.activate() { return .answer(index) }
        case .cancel:
            return .escape
        case .hotkey(let letter):
            if let index = navigation.hotkey(letter) { return .answer(index) }
        }
        return .none
    }

    public enum Outcome: Equatable, Sendable {
        case none
        case answer(Int)
        case escape
    }

    /// acceptsEdit is whether an editor may hold `text`: within 64 KiB and free of the controls its mode forbids, the
    /// check upstream makes before the change, so a refused edit or paste puts the field back and loses nothing.
    public static func acceptsEdit(_ text: String, editor: Editor) -> Bool {
        let mode: ControlAskInputMode
        if case .input(let input) = editor { mode = input } else { mode = .line }
        return text.utf8.count <= AskInputForm.maxTextBytes && !AskInputForm.hasForbiddenControls(text, mode: mode)
    }

    /// panelWidth is the widest the panel may be over an anchor `anchorWidth` wide: `--width` percent of it, else 90%
    /// of it up to 72 cells, which content narrower than that shrinks to.
    public static func panelWidth(anchorWidth: Int32, cell: Int32, width: Int?) -> Int32 {
        if let width { return max(anchorWidth, 0) * Int32(min(100, max(10, width))) / 100 }
        return min(max(anchorWidth, 0) * 9 / 10, 72 * cell)
    }

    /// buttonLabel is a button's text with its hotkey marked for `DrawText`'s `&` underline: the first matching letter,
    /// or a ` (X)` hint after the label; a destructive terminal button opens with `! `, as upstream's `buttonLabel`.
    public static func buttonLabel(_ button: ControlAskButton, destructive: Bool) -> String {
        var label = button.label.replacingOccurrences(of: "&", with: "&&")
        if let hotkey = button.hotkey {
            if let range = label.range(of: hotkey, options: .caseInsensitive) {
                label.insert("&", at: range.lowerBound)
            } else {
                label += " (&\(hotkey.uppercased()))"
            }
        }
        return destructive ? "! " + label : label
    }
}
