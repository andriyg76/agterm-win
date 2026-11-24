import Foundation

/// TerminalInput encodes keys, pastes and mouse events as the VT sequences a program under ConPTY reads.
public enum TerminalInput {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let alt = Modifiers(rawValue: 2)
        public static let control = Modifiers(rawValue: 4)

        /// parameter is the CSI modifier parameter: 1 plus shift 1, alt 2, control 4.
        var parameter: Int { 1 + rawValue }
    }

    public enum Key: Equatable, Sendable {
        case up, down, right, left, home, end, insert, delete, pageUp, pageDown
        case function(Int)
    }

    /// sequence is what `key` types; cursor keys are SS3 while the program has set DECCKM and no modifier is held.
    public static func sequence(for key: Key, modifiers: Modifiers = [], applicationCursor: Bool = false) -> String? {
        let parameter = modifiers.parameter
        func cursor(_ final: Character) -> String {
            parameter > 1 ? "\u{1b}[1;\(parameter)\(final)" : applicationCursor ? "\u{1b}O\(final)" : "\u{1b}[\(final)"
        }
        func tilde(_ code: Int) -> String { parameter > 1 ? "\u{1b}[\(code);\(parameter)~" : "\u{1b}[\(code)~" }
        func ss3(_ final: Character) -> String { parameter > 1 ? "\u{1b}[1;\(parameter)\(final)" : "\u{1b}O\(final)" }
        switch key {
        case .up: return cursor("A")
        case .down: return cursor("B")
        case .right: return cursor("C")
        case .left: return cursor("D")
        case .home: return cursor("H")
        case .end: return cursor("F")
        case .insert: return tilde(2)
        case .delete: return tilde(3)
        case .pageUp: return tilde(5)
        case .pageDown: return tilde(6)
        case .function(let number):
            let codes = [1: "P", 2: "Q", 3: "R", 4: "S"]
            if let final = codes[number]?.first { return ss3(final) }
            let tildes = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
            return tildes[number].map(tilde)
        }
    }

    /// character is typed text: Backspace sends DEL as terminals do, and Alt prefixes ESC.
    public static func character(_ text: String, alt: Bool = false) -> String {
        (alt ? "\u{1b}" : "") + (text == "\u{08}" ? "\u{7f}" : text)
    }

    /// typed is text as keys: line breaks become the carriage returns Enter types, control bytes pass through.
    public static func typed(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
    }

    /// pasteStripped are the bytes libghostty's paste encoder replaces with spaces, so pasted text cannot close the
    /// bracket with ESC[201~ or act as Ctrl-C, Ctrl-Z, Ctrl-U or Ctrl-W.
    static let pasteStripped: Set<Unicode.Scalar> = ["\u{00}", "\u{03}", "\u{04}", "\u{05}", "\u{08}", "\u{15}", "\u{17}",
                                                     "\u{1a}", "\u{1b}", "\u{7f}"]

    /// paste is `typed` with `pasteStripped` replaced by spaces, bracketed when the program set ?2004.
    public static func paste(_ text: String, bracketed: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.map { pasteStripped.contains($0) ? " " : $0 })
        let pasted = typed(String(scalars))
        return bracketed ? "\u{1b}[200~\(pasted)\u{1b}[201~" : pasted
    }

    /// mouse is one report for a 1-based cell: `button` 0 left, 1 middle, 2 right, 3 none (motion), 64/65 wheel.
    /// SGR when the program set ?1006, else the X10 bytes, which cap the cell at 223.
    public static func mouse(button: Int, column: Int, row: Int, release: Bool, motion: Bool = false,
                             modifiers: Modifiers = [], sgr: Bool) -> [UInt8] {
        var code = button + (motion ? 32 : 0)
        if modifiers.contains(.shift) { code += 4 }
        if modifiers.contains(.alt) { code += 8 }
        if modifiers.contains(.control) { code += 16 }
        if sgr { return Array("\u{1b}[<\(code);\(column);\(row)\(release ? "m" : "M")".utf8) }
        if release { code = (code & ~3) | 3 }
        let byte = { (value: Int) in UInt8(min(value + 32, 255)) }
        return [0x1B, 0x5B, 0x4D, byte(code), byte(column), byte(row)]
    }

    /// wheel is what a wheel turn sends to an alternate screen without mouse reporting: `lines` cursor keys a notch.
    public static func wheel(up: Bool, notches: Int, applicationCursor: Bool, lines: Int = 3) -> String {
        let key = sequence(for: up ? .up : .down, applicationCursor: applicationCursor) ?? ""
        return String(repeating: key, count: max(notches, 1) * max(lines, 1))
    }

    /// autoscrollLines is how far a selection drag held `y` pixels down a view `height` pixels tall scrolls a tick:
    /// positive back into the scrollback above the top, negative toward the live screen below the bottom, faster
    /// the further out, a line per `step` pixels up to 10.
    public static func autoscrollLines(y: Int, height: Int, step: Int) -> Int {
        let step = max(step, 1)
        if y < 0 { return min(1 + -y / step, 10) }
        if y >= height { return -min(1 + (y - height) / step, 10) }
        return 0
    }

    /// runsInWSL is whether a command line starts wsl.exe, whose programs read Linux paths.
    public static func runsInWSL(_ commandLine: String) -> Bool {
        let program = commandLine.hasPrefix("\"") ? commandLine.dropFirst().prefix { $0 != "\"" } : commandLine.prefix { $0 != " " }
        let name = program.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
        return name.caseInsensitiveCompare("wsl.exe") == .orderedSame || name.caseInsensitiveCompare("wsl") == .orderedSame
    }

    /// droppedPaths is what dropping files types: each path quoted when it needs it and followed by a space; under WSL a
    /// drive path becomes its /mnt mount, single-quoted for the Linux shell.
    public static func droppedPaths(_ paths: [String], wsl: Bool) -> String {
        paths.map { path in
            guard wsl else { return path.contains(where: { " &()[]{}^=;!'+,`~%$@#".contains($0) }) ? "\"\(path)\"" : path }
            var linux = path.replacingOccurrences(of: "\\", with: "/")
            if linux.count >= 2, linux.dropFirst().first == ":", let drive = linux.first, drive.isLetter {
                linux = "/mnt/\(drive.lowercased())" + linux.dropFirst(2)
            }
            let plain = linux.allSatisfy { $0.isLetter || $0.isNumber || "/._-+,:@%".contains($0) }
            return plain ? linux : "'" + linux.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.map { $0 + " " }.joined()
    }
}
