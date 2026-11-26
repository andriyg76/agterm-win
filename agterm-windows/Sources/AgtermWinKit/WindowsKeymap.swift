import Foundation
import agtermCore

/// WindowsKeymap is `keymap.conf` as agterm-win runs it: agtermCore's parser and matcher with the Windows defaults
/// (`BuiltinAction.windowsDefaultChord`), `cmd` meaning the Win key. A chord names the unshifted key on a US
/// layout's position, so Ctrl+Shift+= is `ctrl+shift+=`.
public struct WindowsKeymap: Sendable {
    /// actions are the built-ins agterm-win has, each behind the command it runs.
    public static let actions: [(command: NativeMenu.Command, action: BuiltinAction)] = [
        (.newSession, .newSession), (.newServerSession, .newRemoteSession), (.renameSession, .renameSession),
        (.closeSession, .closeSession), (.nextSession, .nextSession), (.previousSession, .previousSession),
        (.find, .toggleSearch), (.fontBigger, .increaseFontSize), (.fontSmaller, .decreaseFontSize), (.fontReset, .resetFontSize),
        (.sessionPalette, .sessionPalette), (.commandPalette, .commandPalette), (.toggleSplit, .toggleSplit),
        (.toggleHorizontalSplit, .toggleHorizontalSplit), (.focusLeftPane, .focusLeftPane), (.focusRightPane, .focusRightPane),
        (.toggleScratch, .toggleScratch), (.toggleOverlay, .toggleOverlay), (.quickTerminal, .quickTerminal), (.dashboard, .dashboard),
        (.newWorkspace, .newWorkspace), (.renameWorkspace, .renameWorkspace), (.deleteWorkspace, .deleteWorkspace), (.toggleFlag, .toggleFlag),
        (.toggleFlaggedView, .toggleFlaggedView), (.focusWorkspace, .focusWorkspace), (.toggleWorkspaceFilter, .toggleWorkspaceFilter),
        (.previousWorkspace, .previousWorkspace), (.nextWorkspace, .nextWorkspace), (.newCompanion, .newCompanion),
        (.convertCompanion, .convertCompanion),
    ]

    /// reserved are the fixed chords of commands with no built-in action; a binding on one never fires.
    public static let reserved: [Chord: NativeMenu.Command] = [
        Chord(mods: [.control, .shift], key: "c"): .copy, Chord(mods: [.control, .shift], key: "v"): .paste,
        Chord(mods: [.control, .shift], key: "a"): .selectAll, Chord(mods: [.control, .shift], key: "i"): .paste,
        Chord(mods: [.control], key: "insert"): .copy, Chord(mods: [.shift], key: "insert"): .paste,
        Chord(mods: [.option], key: "f4"): .quit, Chord(mods: [.control], key: ","): .settings,
        Chord(mods: [.control, .option], key: "s"): .settings,
    ]

    public static func fixedCommand(for chord: Chord, hasSelection: Bool) -> NativeMenu.Command? {
        if chord == Chord(mods: [.control], key: "c"), hasSelection { return .copy }
        return reserved[chord]
    }

    public let keymap: Keymap
    public let diagnostics: [KeymapDiagnostic]
    public let path: String
    private var matcher: KeybindMatcher
    private let binds: [(keybind: Keybind, action: BuiltinAction)]

    public init(text: String, path: String = "keymap.conf") {
        let (keymap, diagnostics) = parseKeymap(text)
        self.init(keymap: keymap, diagnostics: diagnostics, path: path)
    }

    public init(keymap: Keymap, diagnostics: [KeymapDiagnostic], path: String) {
        var notes = diagnostics
        var binds: [(keybind: Keybind, action: BuiltinAction)] = []
        for (_, action) in Self.actions {
            let all = (keymap.equivalent(for: action).map { [[$0]] } ?? []) + keymap.sequences(for: action)
            for keybind in all {
                if let first = keybind.first, let owner = Self.reserved[first] {
                    notes.append(KeymapDiagnostic(line: 0, message: "\(keybind.displayString) for '\(action.rawValue)' is \(owner.title)'s on Windows"))
                } else {
                    binds.append((keybind, action))
                }
            }
        }
        let available = Set(Self.actions.map(\.action))
        let mapped = Set(keymap.builtinOverrides.keys).union(keymap.builtinSequences.keys)
        for action in BuiltinAction.allCases where mapped.contains(action) && !available.contains(action) {
            notes.append(KeymapDiagnostic(line: 0, message: "'\(action.rawValue)' is not available on Windows"))
        }
        if !keymap.commands.isEmpty {
            notes.append(KeymapDiagnostic(line: 0, message: "custom commands are not supported on Windows yet; \(keymap.commands.count) skipped"))
        }
        self.keymap = keymap
        self.diagnostics = notes
        self.path = path
        self.binds = binds
        let repeating = Set(keymap.builtinRepeating.filter(available.contains).map(KeybindTarget.builtin))
        matcher = KeybindMatcher(binds.map { ($0.keybind, .builtin($0.action)) }, repeating: repeating)
    }

    /// load reads `<configDirectory>/keymap.conf`; a missing file is the defaults.
    public static func load(configDirectory: URL) -> WindowsKeymap {
        let store = KeymapStore(configDirectory: configDirectory)
        let (keymap, diagnostics) = store.load()
        return WindowsKeymap(keymap: keymap, diagnostics: diagnostics, path: store.path.path)
    }

    /// control is what `keymap.list` reads: the actions agterm-win has, and every problem the file holds, custom
    /// commands left out since they do not run here.
    public var control: ControlKeymap {
        var projected = ControlKeymap.project(keymap: keymap, diagnostics: diagnostics, path: path)
        let available = Set(Self.actions.map(\.action.rawValue))
        projected.actions.removeAll { !available.contains($0.action) }
        projected.commands = []
        return projected
    }

    public static func command(for action: BuiltinAction) -> NativeMenu.Command? {
        actions.first { $0.action == action }?.command
    }

    /// shortcuts are the menu labels: each action's chord, and its first sequence when it has no chord.
    public var shortcuts: NativeMenu.Shortcuts {
        var labels: NativeMenu.Shortcuts = [:]
        for (command, action) in Self.actions {
            let keybind = binds.first { $0.action == action }?.keybind
            labels[command] = keybind.map { $0.map(Self.label).joined(separator: ", ") } ?? ""
        }
        return labels
    }

    /// globalHotkey is `global-hotkey`'s chord as RegisterHotKey takes it, which summons the quick terminal from any app.
    public var globalHotkey: Hotkey? { keymap.globalHotkey.flatMap(Self.hotkey) }

    /// usesWinKey is whether a binding starts with the Win key, which only a low-level hook sees.
    public var usesWinKey: Bool { binds.contains { $0.keybind.first?.mods.contains(.command) == true } }

    public enum Press: Equatable, Sendable {
        case command(NativeMenu.Command)
        /// consumed is a chord the keymap took without a command to run: a leader, or the key that abandoned one.
        case consumed
        case pass
    }

    /// press feeds one chord; Esc abandons a pending leader.
    public mutating func press(_ chord: Chord) -> Press {
        let pending = matcher.isArmed
        if pending, chord.mods.isEmpty, chord.key == "esc" {
            matcher.reset()
            return .consumed
        }
        switch matcher.advance(chord) {
        case .fired(.builtin(let action)): return Self.command(for: action).map(Press.command) ?? .consumed
        case .fired(.command): return .consumed
        case .armed: return .consumed
        case .unmatched: return pending ? .consumed : .pass
        }
    }

    public mutating func cancel() { matcher.reset() }

    /// chord is the keymap's name for a key press; nil for a key the grammar has no name for, modifiers included.
    public static func chord(virtualKey key: Int32, control: Bool, alt: Bool, shift: Bool, win: Bool) -> Chord? {
        guard let name = keyName(key) else { return nil }
        var mods: Modifier = []
        if control { mods.insert(.control) }
        if alt { mods.insert(.option) }
        if shift { mods.insert(.shift) }
        if win { mods.insert(.command) }
        return Chord(mods: mods, key: name)
    }

    static func keyName(_ key: Int32) -> String? {
        switch key {
        case 0x41...0x5A: String(UnicodeScalar(UInt8(key + 0x20)))
        case 0x30...0x39: String(UnicodeScalar(UInt8(key)))
        case 0x70...0x83: "f\(key - 0x6F)"
        case 0x08: "delete"
        case 0x09: "tab"
        case 0x0D: "return"
        case 0x1B: "esc"
        case 0x20: "space"
        case 0x25: "left"
        case 0x26: "up"
        case 0x27: "right"
        case 0x28: "down"
        case 0x2D: "insert"
        case 0xBA: ";"
        case 0xBB: "="
        case 0xBC: ","
        case 0xBD: "-"
        case 0xBE: "."
        case 0xBF: "/"
        case 0xC0: "`"
        case 0xDB: "["
        case 0xDC: "\\"
        case 0xDD: "]"
        case 0xDE: "'"
        default: nil
        }
    }

    /// virtualKey is the Windows virtual-key code of a key the grammar names, the inverse of `keyName`.
    public static func virtualKey(_ name: String) -> Int32? {
        (0x08...0xDE).first { keyName(Int32($0)) == name }.map(Int32.init)
    }

    /// Hotkey is a chord as RegisterHotKey takes it: MOD_ALT, MOD_CONTROL, MOD_SHIFT and MOD_WIN, and the virtual key.
    public struct Hotkey: Equatable, Sendable {
        public let modifiers: UInt32
        public let key: UInt32

        public init(modifiers: UInt32, key: UInt32) {
            self.modifiers = modifiers
            self.key = key
        }
    }

    /// hotkey is `global-hotkey`'s chord for RegisterHotKey; nil for a key Windows has no code for here or a chord with no
    /// modifier, which would take the key from every application.
    public static func hotkey(_ chord: Chord) -> Hotkey? {
        guard !chord.mods.isEmpty, let key = virtualKey(chord.key) else { return nil }
        var modifiers: UInt32 = 0x4000  // MOD_NOREPEAT
        if chord.mods.contains(.option) { modifiers |= 0x1 }
        if chord.mods.contains(.control) { modifiers |= 0x2 }
        if chord.mods.contains(.shift) { modifiers |= 0x4 }
        if chord.mods.contains(.command) { modifiers |= 0x8 }
        return Hotkey(modifiers: modifiers, key: UInt32(key))
    }

    /// label is a chord as Windows menus write one: Ctrl+Shift+T, Win+Left, F2.
    public static func label(_ chord: Chord) -> String {
        var parts: [String] = []
        if chord.mods.contains(.control) { parts.append("Ctrl") }
        if chord.mods.contains(.command) { parts.append("Win") }
        if chord.mods.contains(.option) { parts.append("Alt") }
        if chord.mods.contains(.shift) { parts.append("Shift") }
        let names = ["tab": "Tab", "space": "Space", "return": "Enter", "delete": "Backspace", "left": "Left", "right": "Right",
                     "up": "Up", "down": "Down", "insert": "Insert"]
        parts.append(names[chord.key] ?? chord.key.uppercased())
        return parts.joined(separator: "+")
    }
}
