import Foundation
import agtermCore

/// SessionNaming names a local session in `Session.displayName`'s order: a name of the user's own, else the
/// program's title, else its working directory's last folder, else the profile it started from.
public enum SessionNaming {
    public static func displayName(customName: String?, title: String?, directory: String?, fallback: String) -> String {
        if let name = trimmed(customName) { return name }
        if let title = programTitle(title) { return title }
        if let folder = directory.flatMap(folderName) { return folder }
        return fallback
    }

    /// customName is what a rename keeps: the name without control characters, nil for a blank one, which restores
    /// the automatic name.
    public static func customName(_ name: String) -> String? { trimmed(TerminalText.sanitized(name)) }

    /// programTitle drops the console title ConPTY reports for a program that set none, its executable's path.
    public static func programTitle(_ title: String?) -> String? {
        guard let title = trimmed(title.map(TerminalText.sanitized)) else { return nil }
        return title.lowercased().hasSuffix(".exe") ? nil : title
    }

    /// directory is the path a shell reported (an OSC 7 `file://` URI, or a bare and possibly quoted path for
    /// OSC 9;9 and 1337), nil for an empty one.
    public static func directory(fromReported value: String) -> String? {
        var path = value.trimmingCharacters(in: .whitespaces)
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
        if path.lowercased().hasPrefix("file://") {
            let rest = path.dropFirst("file://".count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            path = String(rest[slash...]).removingPercentEncoding ?? String(rest[slash...])
            if isDrivePath(path.dropFirst()) { path.removeFirst() }
        }
        return path.isEmpty ? nil : path
    }

    /// folderName is the last folder of a Windows or Linux path; a root names itself, `C:` for a drive's.
    public static func folderName(_ path: String) -> String? {
        let parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" })
        guard let last = parts.last else { return path.isEmpty ? nil : "/" }
        return String(last)
    }

    private static func isDrivePath(_ path: Substring) -> Bool {
        let characters = Array(path.prefix(2))
        return characters.count == 2 && characters[0].isLetter && characters[1] == ":"
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// ShellIntegration makes a profile's shell report its working directory with OSC 9;9, the sequence ConPTY passes
/// through. Only a bare shell line is changed: one already given a command runs as written.
public enum ShellIntegration {
    public static func commandLine(_ commandLine: String) -> String {
        let (program, arguments) = split(commandLine)
        let name = program.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map { $0.lowercased() } ?? ""
        switch name {
        case "powershell.exe", "powershell", "pwsh.exe", "pwsh":
            let plain = Set(["-nologo", "-noprofile"])
            guard arguments.allSatisfy({ plain.contains($0.lowercased()) }) else { return commandLine }
            return commandLine + " -NoExit -EncodedCommand " + encoded(powerShellPrompt)
        case "cmd.exe", "cmd":
            // replaces a PROMPT of the user's own, which cmd offers no way to wrap
            return arguments.isEmpty ? commandLine + #" /k prompt $e]9;9;$P$e\$P$G"# : commandLine
        default:
            return commandLine
        }
    }

    /// powerShellPrompt wraps whatever prompt the profile left, so a prompt theme keeps working; Windows PowerShell 5.1
    /// has no `e escape, hence [char]27.
    static let powerShellPrompt = #"""
    $global:__agtermPrompt = $function:prompt
    function global:prompt {
        $location = $executionContext.SessionState.Path.CurrentLocation
        if ($location.Provider.Name -eq 'FileSystem') { [Console]::Write("$([char]27)]9;9;$($location.ProviderPath)$([char]27)\") }
        if ($global:__agtermPrompt) { & $global:__agtermPrompt } else { "PS $location> " }
    }
    """#

    /// environment is `environment` with what a bash profile needs to report its folder, which bash takes from the
    /// environment, not its command line: Git Bash's PROMPT_COMMAND with CHERE_INVOKING, which keeps its login profile from
    /// changing to HOME, and a WSL login shell's PROMPT_COMMAND, carried across by WSLENV. A shell of another kind, or one
    /// given a program to run, starts with `environment` unchanged.
    public static func environment(for commandLine: String, merging environment: [String: String]) -> [String: String] {
        let (program, arguments) = split(commandLine)
        let lowered = program.lowercased().replacingOccurrences(of: "/", with: "\\")
        let name = lowered.split(separator: "\\").last.map(String.init) ?? ""
        var result = environment
        // System32's bash.exe is WSL's launcher, not a bash of its own
        if ["bash.exe", "bash"].contains(name), !lowered.contains("\\system32\\"), !arguments.contains("-c") {
            result["PROMPT_COMMAND"] = folderReport("cygpath")
            result["CHERE_INVOKING"] = "1"
        } else if ["wsl.exe", "wsl"].contains(name), !arguments.contains(where: { ["-e", "--exec", "--"].contains($0) }) {
            result["PROMPT_COMMAND"] = folderReport("wslpath")
            let key = environment.keys.first { $0.uppercased() == "WSLENV" } ?? "WSLENV"
            result[key] = ([environment[key]].compactMap { $0 }.filter { !$0.isEmpty } + ["PROMPT_COMMAND/u"]).joined(separator: ":")
        }
        return result
    }

    /// folderReport prints the folder as OSC 9;9 in its Windows form, which `converter -w` gives.
    static func folderReport(_ converter: String) -> String {
        #"printf '\033]9;9;%s\033\\' "$(\#(converter) -w "$PWD")""#
    }

    /// encoded is `-EncodedCommand`'s form: base64 of the UTF-16LE script, which no quoting can break.
    static func encoded(_ script: String) -> String {
        Data(script.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).base64EncodedString()
    }

    private static func split(_ commandLine: String) -> (program: String, arguments: [String]) {
        if commandLine.hasPrefix("\"") {
            let body = commandLine.dropFirst()
            let program = body.prefix { $0 != "\"" }
            let rest = body.dropFirst(program.count + 1)
            return (String(program), rest.split(separator: " ").map(String.init))
        }
        let words = commandLine.split(separator: " ").map(String.init)
        return (words.first ?? "", Array(words.dropFirst()))
    }
}
