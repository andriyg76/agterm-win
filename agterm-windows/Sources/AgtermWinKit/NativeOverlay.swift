import Foundation
import agtermCore

/// NativeOverlay is a local session's program overlay: one program in its own terminal over the session, full or a
/// floating panel, as `session.overlay.open` runs one on a Mac. The session's own program keeps running under it.
public struct NativeOverlay: Equatable, Sendable {
    /// sizePercent is the floating panel's share of the session's area on both axes; nil covers all of it.
    public var sizePercent: Int?
    /// hidden keeps the overlay running with the session in view; it gives the keyboard back to the session.
    public var hidden = false
    /// wait keeps an exited program's last screen until a key closes it.
    public let wait: Bool

    public init(sizePercent: Int?, wait: Bool) {
        self.sizePercent = sizePercent
        self.wait = wait
    }

    public struct Open: Equatable, Sendable {
        public let command: String
        public let cwd: String?
        public let wait: Bool
        public let sizePercent: Int?
        /// background is the overlay's own `--color` as 0xRRGGBB, the theme's when nil.
        public let background: UInt32?

        public init(command: String, cwd: String?, wait: Bool, sizePercent: Int?, background: UInt32?) {
            self.command = command
            self.cwd = cwd
            self.wait = wait
            self.sizePercent = sizePercent
            self.background = background
        }
    }

    public static let serverRefusal = "overlays on agterm-server sessions are not shown on Windows yet"
    public static let paneRefusal = "--pane is not supported on Windows: its sessions have no split panes"
    public static let pointsRefusal = "--width/--height are not supported on Windows"
    public static let pageRefusal = "session.overlay.open: pages (--html, --url, --image, --markdown, --text) are not supported on Windows"

    /// Launch is how the overlay's program starts: under cmd.exe for a Windows session, under the distribution's sh
    /// for a WSL one, so the command means what it would typed into that session.
    public struct Launch: Equatable, Sendable {
        public let commandLine: String
        /// directory is the Windows folder the process starts in; a WSL launch passes its folder to wsl.exe instead.
        public let directory: String?

        public init(commandLine: String, directory: String?) {
            self.commandLine = commandLine
            self.directory = directory
        }
    }

    /// launch runs `command` beside a session started with `sessionCommandLine`, in `cwd` when given, else in the
    /// session's last reported `directory`.
    public static func launch(_ command: String, sessionCommandLine: String, cwd: String?, directory: String?) -> Launch {
        let folder = cwd ?? directory
        guard TerminalInput.runsInWSL(sessionCommandLine) else {
            // /s takes the outer quotes off and runs what is between them as typed
            return Launch(commandLine: "cmd.exe /d /s /c \"\(command)\"", directory: folder.flatMap { $0.hasPrefix("/") ? nil : $0 })
        }
        var line = "wsl.exe"
        if let distribution = distribution(of: sessionCommandLine) { line += " -d " + WindowsCommandLine.quoted(distribution) }
        line += " --cd " + WindowsCommandLine.quoted(folder.map(linuxPath) ?? "~")
        return Launch(commandLine: line + " --exec sh -c " + WindowsCommandLine.quoted(command), directory: nil)
    }

    /// distribution is the `-d`/`--distribution` a wsl.exe command line names, nil for the default one.
    static func distribution(of commandLine: String) -> String? {
        let words = WindowsCommandLine.split(commandLine)
        guard let flag = words.firstIndex(where: { $0 == "-d" || $0 == "--distribution" }), flag + 1 < words.count else { return nil }
        return words[flag + 1]
    }

    /// linuxPath maps a drive path to its /mnt mount; a Linux path or `~` stays as it is.
    static func linuxPath(_ path: String) -> String {
        guard path.count >= 2, path.dropFirst().first == ":", let drive = path.first, drive.isLetter else { return path }
        return "/mnt/\(drive.lowercased())" + path.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
    }

    /// background reads `--color`'s `#rrggbb`, nil for anything else.
    public static func background(_ hex: String?) -> UInt32? {
        guard let hex, WatermarkConfig.isValidColorHex(hex) else { return nil }
        return UInt32(hex.hasPrefix("#") ? String(hex.dropFirst()) : hex, radix: 16)
    }

    public struct Rect: Equatable, Sendable {
        public let x: Int32, y: Int32, width: Int32, height: Int32

        public init(x: Int32, y: Int32, width: Int32, height: Int32) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// panel is where the overlay sits in the session's `area`: all of it when full, else its percent of each axis,
    /// centered.
    public static func panel(in area: Rect, sizePercent: Int?) -> Rect {
        guard let percent = sizePercent, percent < 100 else { return area }
        let width = max(area.width * Int32(percent) / 100, 1), height = max(area.height * Int32(percent) / 100, 1)
        return Rect(x: area.x + (area.width - width) / 2, y: area.y + (area.height - height) / 2, width: width, height: height)
    }
}

/// WindowsCommandLine quotes and splits arguments the way CommandLineToArgvW reads them.
public enum WindowsCommandLine {
    public static func quoted(_ argument: String) -> String {
        if !argument.isEmpty, !argument.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) { return argument }
        var quoted = "\""
        var backslashes = 0
        for character in argument {
            switch character {
            case "\\":
                backslashes += 1
            case "\"":
                quoted += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
                backslashes = 0
            default:
                quoted += String(repeating: "\\", count: backslashes) + String(character)
                backslashes = 0
            }
        }
        return quoted + String(repeating: "\\", count: backslashes * 2) + "\""
    }

    /// split reads whitespace-separated words, double quotes grouping one; enough for a profile's command line.
    static func split(_ line: String) -> [String] {
        var words: [String] = [], word = "", quoted = false, started = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
                started = true
            } else if !quoted, character == " " || character == "\t" {
                if started { words.append(word) }
                word = ""
                started = false
            } else {
                word.append(character)
                started = true
            }
        }
        if started { words.append(word) }
        return words
    }
}
