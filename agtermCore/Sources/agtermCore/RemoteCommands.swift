import Foundation

/// RemoteCommands is `remote.properties`: each name is a remote reached by its own command in place of `ssh <host>`.
/// Every remote invocation runs that command followed by `/bin/sh -c SCRIPT` as three more arguments, so the command
/// must run its arguments as one program (`wsl.exe -d NAME -e`, `docker exec -i NAME`). A name the file does not
/// define is an ssh destination.
public struct RemoteCommands: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let name: String
        /// argv is the command split into words: whitespace separates them, and double or single quotes keep one.
        public let argv: [String]
        public let line: Int
    }

    public static let fileName = "remote.properties"
    public let entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public func command(for name: String) -> [String]? {
        entries.first { $0.name == name }?.argv
    }

    public var names: [String] { entries.map(\.name) }

    /// outputText decodes what a remote's command printed: a Windows launcher's own messages (wsl.exe's) are UTF-16LE,
    /// the remote's output UTF-8.
    public static func outputText(_ data: Data) -> String {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes.count % 2 == 0, bytes[1] == 0 || bytes.starts(with: [0xFF, 0xFE]) else {
            return String(decoding: bytes, as: UTF8.self)
        }
        let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        return String(decoding: units.first == 0xFEFF ? Array(units.dropFirst()) : units, as: UTF16.self)
    }

    /// path is the file in a resolved config directory, beside `keymap.conf`.
    public static func path(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent(fileName)
    }

    /// load parses the file at `url`. A missing file defines nothing; one that exists and cannot be read is a
    /// diagnostic, never read as empty without one.
    public static func load(at url: URL) -> (commands: RemoteCommands, diagnostics: [KeymapDiagnostic]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (RemoteCommands(), []) }
        do {
            return parse(try String(contentsOf: url, encoding: .utf8))
        } catch {
            return (RemoteCommands(), [KeymapDiagnostic(line: 0, message: "could not read \(fileName): \(error.localizedDescription)")])
        }
    }

    /// template is a new file: the format in a comment header, then one `name = command` line per entry.
    public static func template(_ entries: [(name: String, command: String)]) -> String {
        let header = """
        # remote.properties: remotes agterm reaches by a command of their own instead of ssh.
        # One `name = command` per line; `#` and `!` start a comment line. A name used as a host
        # (window remote open NAME, session new --remote NAME, server install NAME) runs the command
        # followed by `/bin/sh -c SCRIPT`, so the command must run its arguments as a program.
        # Words split at whitespace; quote a word holding spaces. Write a backslash as \\\\.
        # Any other host is an ssh destination. agterm never rewrites this file.

        """
        return header + entries.map { "\($0.name) = \($0.command)\n" }.joined()
    }

    /// parse reads the properties format: logical lines joined at a trailing backslash, `#`/`!` comment lines, the
    /// key ending at the first unescaped `=`, `:` or whitespace, and `\t`, `\n`, `\r`, `\f`, `\uXXXX` and `\x` escapes.
    /// A bad line is diagnosed and skipped; the first definition of a name wins.
    public static func parse(_ text: String) -> (commands: RemoteCommands, diagnostics: [KeymapDiagnostic]) {
        var entries: [Entry] = []
        var diagnostics: [KeymapDiagnostic] = []
        for (number, line) in logicalLines(text) {
            let (rawKey, rawValue) = split(line)
            guard let key = unescape(rawKey), let value = unescape(rawValue) else {
                diagnostics.append(KeymapDiagnostic(line: number, message: "malformed \\u escape; line skipped"))
                continue
            }
            guard !key.isEmpty else {
                diagnostics.append(KeymapDiagnostic(line: number, message: "line has no name; skipped"))
                continue
            }
            guard RemoteSession.isHost(key) else {
                diagnostics.append(KeymapDiagnostic(line: number, message: "'\(key)' is not a usable remote name; skipped"))
                continue
            }
            guard let argv = words(value) else {
                diagnostics.append(KeymapDiagnostic(line: number, message: "command for '\(key)' has an unclosed quote; skipped"))
                continue
            }
            guard !argv.isEmpty else {
                diagnostics.append(KeymapDiagnostic(line: number, message: "'\(key)' has no command; skipped"))
                continue
            }
            guard !entries.contains(where: { $0.name == key }) else {
                diagnostics.append(KeymapDiagnostic(line: number, message: "remote '\(key)' is already defined; line skipped"))
                continue
            }
            entries.append(Entry(name: key, argv: argv, line: number))
        }
        return (RemoteCommands(entries: entries), diagnostics)
    }

    /// logicalLines are the non-blank, non-comment lines, a continuation joined to its line with its leading
    /// whitespace dropped, each with the number of its first physical line.
    private static func logicalLines(_ text: String) -> [(Int, Substring)] {
        let physical = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var lines: [(Int, Substring)] = []
        var index = 0
        while index < physical.count {
            let start = index
            var line = physical[index].drop { $0 == " " || $0 == "\t" || $0 == "\u{0C}" }
            index += 1
            if line.isEmpty || line.first == "#" || line.first == "!" { continue }
            var joined = ""
            while line.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1 {
                joined += line.dropLast()
                guard index < physical.count else { line = ""; break }
                line = physical[index].drop { $0 == " " || $0 == "\t" || $0 == "\u{0C}" }
                index += 1
            }
            lines.append((start + 1, Substring(joined + line)))
        }
        return lines
    }

    /// split ends the key at the first unescaped separator and skips whitespace and one `=` or `:` after it.
    private static func split(_ line: Substring) -> (Substring, Substring) {
        var escaped = false
        var end = line.endIndex
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "=" || character == ":" || character == " " || character == "\t" || character == "\u{0C}" {
                end = index
                break
            }
        }
        var rest = line[end...].drop { $0 == " " || $0 == "\t" || $0 == "\u{0C}" }
        if rest.first == "=" || rest.first == ":" { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" || $0 == "\u{0C}" } }
        return (line[..<end], rest)
    }

    private static func unescape(_ text: Substring) -> String? {
        var result = ""
        var characters = text.makeIterator()
        while let character = characters.next() {
            guard character == "\\" else { result.append(character); continue }
            guard let escaped = characters.next() else { break }
            switch escaped {
            case "t": result.append("\t")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "f": result.append("\u{0C}")
            case "u":
                var hex = ""
                for _ in 0..<4 { if let digit = characters.next() { hex.append(digit) } }
                guard hex.count == 4, let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
                result.unicodeScalars.append(scalar)
            default: result.append(escaped)
            }
        }
        return result
    }

    /// words splits a command at unquoted whitespace; nil for an unclosed quote.
    static func words(_ text: String) -> [String]? {
        var words: [String] = []
        var word: String?
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { word?.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                word = word ?? ""
            } else if character.isWhitespace {
                if let finished = word { words.append(finished) }
                word = nil
            } else {
                word = (word ?? "") + String(character)
            }
        }
        guard quote == nil else { return nil }
        if let word { words.append(word) }
        return words
    }
}

extension RemoteCommands {
    /// current is the file in the directory `use` named, read again whenever its modification date or size changes,
    /// so an edit applies to the next remote command without a reload. Empty until `use` is called.
    public static var current: RemoteCommands { registry.current() }

    /// use names the config directory `current` reads; `diagnostics` hears each read that found problems.
    public static func use(configDirectory: URL?, diagnostics: (@Sendable ([KeymapDiagnostic]) -> Void)? = nil) {
        registry.use(configDirectory.map(path(configDirectory:)), diagnostics: diagnostics)
    }

    /// useConfigured points `current` at the config directory a CLI shares with its app: Settings' choice, else
    /// `<AGTERM_STATE_DIR>/config`, else `~/.config/agterm`. agterm-win has no such setting and exports its state
    /// directory to its sessions, so only a non-default one isolates the config there.
    public static func useConfigured(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let stateDir = environment["AGTERM_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(Windows)
        let isolated = ControlResolve.isCustomStateDirectory(environment: environment) ? stateDir : nil
        use(configDirectory: ConfigPaths.configDirectory(setting: nil, stateDir: isolated, home: home))
        #else
        let settings = SettingsStore(directory: stateDir.map { URL(fileURLWithPath: $0) } ?? PersistenceStore.defaultDirectory).load()
        use(configDirectory: ConfigPaths.configDirectory(setting: settings.configDirectory, stateDir: stateDir, home: home))
        #endif
    }

    private static let registry = Registry()

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var url: URL?
        private var stamp: [FileAttributeKey: AnyHashable]?
        private var commands = RemoteCommands()
        private var diagnostics: (@Sendable ([KeymapDiagnostic]) -> Void)?

        func use(_ url: URL?, diagnostics: (@Sendable ([KeymapDiagnostic]) -> Void)?) {
            lock.lock()
            defer { lock.unlock() }
            self.url = url
            self.diagnostics = diagnostics
            stamp = nil
            commands = RemoteCommands()
        }

        func current() -> RemoteCommands {
            lock.lock()
            guard let url else { lock.unlock(); return RemoteCommands() }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let now: [FileAttributeKey: AnyHashable] = [.modificationDate: attributes?[.modificationDate] as? Date ?? .distantPast,
                                                        .size: attributes?[.size] as? Int ?? -1]
            guard now != stamp else { lock.unlock(); return commands }
            let loaded = RemoteCommands.load(at: url)
            stamp = now
            commands = loaded.commands
            let report = diagnostics
            lock.unlock()
            if !loaded.diagnostics.isEmpty { report?(loaded.diagnostics) }
            return loaded.commands
        }
    }
}
