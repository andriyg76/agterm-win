import Foundation
import agtermCore

/// AgentHooksSetup installs agterm-win's PowerShell status adapters, the twins of a Mac's hook scripts, into the same
/// `~/.config/agterm/agent-status`, and wires Claude Code's and Codex's hooks to them with the events a Mac's
/// `AgentHooksInstall` uses. The merges are idempotent, keep everything else in the file, refresh an entry whose script
/// path changed, and leave a file they cannot read as JSON, or a Codex config with hooks of its own, alone.
public enum AgentHooksSetup {
    public struct Refusal: Error, Equatable {
        public let message: String
    }

    public static let claudeScript = "agterm-claude-status.ps1"
    public static let codexScript = "agterm-codex-status.ps1"
    public static let libraryScript = "agterm-status-lib.ps1"
    static let scripts = ["agterm-agent-status.ps1", claudeScript, codexScript, libraryScript]
    // the line in the library whose path the install replaces with this build's agtermctl
    static let toolLine = "$AgtermCtl = 'agtermctl' # agterm-win installs its agtermctl path here"

    /// command runs one adapter. Forward slashes, and `powershell.exe` first so the quoted path reads the same in Git
    /// Bash, cmd and PowerShell, where a leading quoted path would need `&`.
    public static func command(folder: String, script: String, arguments: String) -> String {
        let base = folder.replacingOccurrences(of: "\\", with: "/")
        let path = base.hasSuffix("/") ? base + script : base + "/" + script
        return "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"\(path)\" \(arguments)"
    }

    /// stamp is what `installed` records, so a new version or a moved agtermctl installs again.
    public static func stamp(version: String, tool: String) -> String { "\(version)\n\(tool)\n" }

    /// library is the bundled library with `tool` written in, as a Mac's installer bakes its agtermctl path.
    public static func library(_ text: String, tool: String) -> String {
        text.replacingOccurrences(of: toolLine, with: "$AgtermCtl = '\(tool.replacingOccurrences(of: "'", with: "''"))'")
    }

    /// claudeSettings merges the hooks into `~/.claude/settings.json`'s text, nil for no file.
    public static func claudeSettings(existing: String?, folder: String) -> Result<(text: String, changed: Bool), Refusal> {
        var root: [String: Any] = [:]
        if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let data = existing.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .failure(Refusal(message: "settings.json is not a JSON object"))
            }
            root = object
        }
        let refusal = Refusal(message: "settings.json has a hooks value agterm does not understand")
        var hooks: [String: Any] = [:]
        if let value = root["hooks"] {
            guard let object = value as? [String: Any] else { return .failure(refusal) }
            hooks = object
        }
        var changed = false
        for hook in AgentHooksInstall.claudeHookStates {
            let wanted = command(folder: folder, script: claudeScript, arguments: hook.state)
            var entries: [[String: Any]] = []
            if let value = hooks[hook.event] {
                guard let list = value as? [[String: Any]] else { return .failure(refusal) }
                entries = list
            }
            var found = false
            for index in entries.indices where (entries[index]["matcher"] as? String) == hook.matcher {
                guard var commands = entries[index]["hooks"] as? [[String: Any]] else { continue }
                for slot in commands.indices {
                    guard let line = commands[slot]["command"] as? String, line.contains(claudeScript) else { continue }
                    found = true
                    if line != wanted {
                        commands[slot]["command"] = wanted
                        changed = true
                    }
                }
                entries[index]["hooks"] = commands
            }
            if !found {
                var entry: [String: Any] = ["hooks": [["type": "command", "command": wanted]]]
                if let matcher = hook.matcher { entry["matcher"] = matcher }
                entries.append(entry)
                changed = true
            }
            hooks[hook.event] = entries
        }
        guard changed else { return .success((existing ?? "", false)) }
        root["hooks"] = hooks
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return .failure(Refusal(message: "settings.json could not be written")) }
        return .success((text + "\n", true))
    }

    public static let codexBegin = "# >>> agterm-win agent-status >>>"
    public static let codexEnd = "# <<< agterm-win agent-status <<<"

    /// codexConfig merges the hooks into `config.toml`'s text, empty for no file. Codex records hook trust under
    /// `[hooks.state…]` tables it appends, which can land inside the block, so a refresh keeps everything from the
    /// first of those on.
    public static func codexConfig(existing: String, folder: String) -> Result<(text: String, changed: Bool), Refusal> {
        let block = codexBlock(folder: folder)
        var lines = existing.components(separatedBy: "\n")
        if let begin = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == codexBegin }),
           let end = lines.indices.dropFirst(begin + 1).first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == codexEnd }) {
            let body = lines[(begin + 1)..<end]
            let state = body.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[hooks.state") } ?? end
            lines.replaceSubrange((begin + 1)..<state, with: block + [""])
            let text = lines.joined(separator: "\n")
            return .success((text, text != existing))
        }
        guard let definesHooks = try? AgentHooksInstall.codexConfigDefinesHooks(existing) else {
            return .failure(Refusal(message: "config.toml is invalid TOML, left alone"))
        }
        if definesHooks {
            return .failure(Refusal(message: "config.toml already defines hooks; add agterm's by hand"))
        }
        var text = existing
        if !text.isEmpty {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n"
        }
        text += ([codexBegin] + block + ["", codexEnd]).joined(separator: "\n") + "\n"
        guard (try? AgentHooksInstall.codexConfigDefinesHooks(text)) == true else {
            return .failure(Refusal(message: "config.toml cannot be extended with agterm hooks; add agterm's by hand"))
        }
        return .success((text, true))
    }

    private static func codexBlock(folder: String) -> [String] {
        Array(AgentHooksInstall.codexHookActions.flatMap { hook in
            let line = command(folder: folder, script: codexScript, arguments: hook.action)
                .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return ["[[hooks.\(hook.event)]]", "[[hooks.\(hook.event).hooks]]", "type = \"command\"", "command = \"\(line)\"", ""]
        }.dropLast())
    }
}

extension AgentHooksSetup {
    /// Report is one install's outcome, one line per step for the log.
    public struct Report: Equatable, Sendable {
        public var lines: [String]
        /// installed is whether the stamp now names this version and agtermctl.
        public var installed: Bool
    }

    /// folder is where the adapters go, a Mac's `~/.config/agterm/agent-status`.
    public static func folder(home: URL) -> URL { home.appendingPathComponent(".config/agterm/agent-status") }

    /// stampPath is where the installed version and agtermctl path are recorded, beside the adapters.
    public static func stampPath(home: URL) -> URL { folder(home: home).appendingPathComponent("agterm-win-installed") }

    /// needsInstall is whether `home` lacks this version's hooks: a first run, a new version or a moved agtermctl.
    public static func needsInstall(home: URL, version: String, tool: String) -> Bool {
        (try? String(contentsOf: stampPath(home: home), encoding: .utf8)) != stamp(version: version, tool: tool)
    }

    /// install copies the bundled adapters from `source`, merges both agents' hooks into `home` and records the stamp
    /// once nothing refused, so a refusal is retried at the next launch. Claude's file is written whether or not
    /// Claude is installed yet, as a Mac's is; Codex's only where its home exists.
    public static func install(home: URL, codexHome: URL?, source: URL, version: String, tool: String) -> Report {
        var lines: [String] = []
        var complete = true
        let target = folder(home: home)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for name in scripts {
                var text = try String(contentsOf: source.appendingPathComponent(name), encoding: .utf8)
                if name == libraryScript { text = library(text, tool: tool) }
                try text.write(to: target.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            lines.append("adapters installed in \(target.path).")
        } catch {
            return Report(lines: ["adapters: could not install from \(source.path): \(error.localizedDescription)"], installed: false)
        }
        let scriptFolder = target.path
        let claude = home.appendingPathComponent(".claude/settings.json")
        let existing = try? String(contentsOf: claude, encoding: .utf8)
        if existing == nil, FileManager.default.fileExists(atPath: claude.path) {
            lines.append("Claude Code: settings.json is unreadable, left alone.")
            complete = false
        } else {
            switch claudeSettings(existing: existing, folder: scriptFolder) {
            case .failure(let refusal):
                lines.append("Claude Code: \(refusal.message), left alone.")
                complete = false
            case .success(let merged):
                lines.append(write(merged, existing: existing, to: claude, name: "Claude Code", complete: &complete))
            }
        }
        let codexRoot = codexHome ?? home.appendingPathComponent(".codex")
        if FileManager.default.fileExists(atPath: codexRoot.path) {
            let config = codexRoot.appendingPathComponent("config.toml")
            let text = try? String(contentsOf: config, encoding: .utf8)
            if text == nil, FileManager.default.fileExists(atPath: config.path) {
                lines.append("Codex: config.toml is unreadable, left alone.")
                complete = false
            } else {
                switch codexConfig(existing: text ?? "", folder: scriptFolder) {
                case .failure(let refusal):
                    lines.append("Codex: \(refusal.message).")
                    complete = false
                case .success(let merged):
                    lines.append(write(merged, existing: text, to: config, name: "Codex", complete: &complete))
                }
            }
        } else {
            lines.append("Codex: not installed (\(codexRoot.path)).")
        }
        if complete {
            complete = (try? stamp(version: version, tool: tool).write(to: stampPath(home: home), atomically: true, encoding: .utf8)) != nil
        }
        return Report(lines: lines, installed: complete)
    }

    // the .bak keeps the file as it was before this write, as a Mac's installer does
    private static func write(_ merged: (text: String, changed: Bool), existing: String?, to url: URL, name: String,
                              complete: inout Bool) -> String {
        guard merged.changed else { return "\(name): hooks already installed." }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let existing { try existing.write(to: url.appendingPathExtension("bak"), atomically: true, encoding: .utf8) }
            try merged.text.write(to: url, atomically: true, encoding: .utf8)
            return "\(name): hooks installed in \(url.path)."
        } catch {
            complete = false
            return "\(name): could not write \(url.path): \(error.localizedDescription)"
        }
    }
}
