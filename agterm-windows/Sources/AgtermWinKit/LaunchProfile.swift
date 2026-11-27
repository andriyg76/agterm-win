import Foundation
import agtermCore

/// LaunchProfile is a program a new local session can start: a Windows shell, Git Bash, or a WSL distribution's login
/// shell. Upstream has no profiles, since macOS has one login shell; Windows has several, so agterm-win lists them.
public struct LaunchProfile: Equatable, Sendable {
    public let name: String
    public let commandLine: String

    public init(name: String, commandLine: String) {
        self.name = name
        self.commandLine = commandLine
    }
}

public enum LaunchProfiles {
    /// available lists what this machine can start, Windows PowerShell first as the default.
    /// `powerShell7` and `gitBash` are pwsh.exe's and Git for Windows' bash.exe's paths when installed.
    public static func available(wslDistributions: [String], powerShell7: String?, gitBash: String? = nil) -> [LaunchProfile] {
        var profiles = [LaunchProfile(name: "Windows PowerShell", commandLine: "powershell.exe -NoLogo")]
        if let powerShell7 { profiles.append(LaunchProfile(name: "PowerShell 7", commandLine: "\"\(powerShell7)\" -NoLogo")) }
        profiles.append(LaunchProfile(name: "Command Prompt", commandLine: "cmd.exe"))
        if let gitBash { profiles.append(LaunchProfile(name: "Git Bash", commandLine: "\"\(gitBash)\" --login -i")) }
        profiles += serverDistributions(wslDistributions).map {
            LaunchProfile(name: "WSL \($0)", commandLine: "wsl.exe -d \($0) --cd ~")
        }
        return profiles
    }

    /// serverDistributions are the distributions that can hold a shell and an agterm-server; Docker Desktop's hold neither.
    public static func serverDistributions(_ distributions: [String]) -> [String] {
        distributions.filter { !$0.hasPrefix("docker-desktop") }
    }

    /// named finds a profile by name, ignoring case, as `--profile` names one.
    public static func named(_ name: String, in profiles: [LaunchProfile]) -> LaunchProfile? {
        profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Override is a `profiles.properties` line: a command line for a profile, nil to hide a detected one.
    public struct Override: Equatable, Sendable {
        public let name: String
        public let commandLine: String?
    }

    public static let fileName = "profiles.properties"

    /// path is the file in a resolved config directory, beside `keymap.conf` and `remote.properties`.
    public static func path(configDirectory: URL) -> URL { configDirectory.appendingPathComponent(fileName) }

    /// overrides reads `profiles.properties`: `name = command line` lines, `#` and `!` comment lines. The name ends at the
    /// first `=`, so it may hold spaces, and the blanks around either side are the format's, not the value's. An empty
    /// command hides a detected profile; the first line for a name, matched ignoring case, wins.
    public static func overrides(fromProperties text: String) -> (overrides: [Override], diagnostics: [KeymapDiagnostic]) {
        var overrides: [Override] = []
        var diagnostics: [KeymapDiagnostic] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            guard let equals = line.firstIndex(of: "=") else {
                diagnostics.append(KeymapDiagnostic(line: index + 1, message: "line has no '='; skipped"))
                continue
            }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let command = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                diagnostics.append(KeymapDiagnostic(line: index + 1, message: "line has no name; skipped"))
                continue
            }
            guard !overrides.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                diagnostics.append(KeymapDiagnostic(line: index + 1, message: "profile '\(name)' is already defined; line skipped"))
                continue
            }
            overrides.append(Override(name: name, commandLine: command.isEmpty ? nil : command))
        }
        return (overrides, diagnostics)
    }

    /// applying puts the file over what this launch detected: a detected profile keeps its place with the file's command
    /// line or leaves when hidden, and the file's other profiles follow in its order.
    public static func applying(_ overrides: [Override], to detected: [LaunchProfile]) -> [LaunchProfile] {
        func override(_ name: String) -> Override? { overrides.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        let kept = detected.compactMap { profile in
            guard let override = override(profile.name) else { return profile }
            return override.commandLine.map { LaunchProfile(name: profile.name, commandLine: $0) }
        }
        let added = overrides.filter { added in !detected.contains { $0.name.caseInsensitiveCompare(added.name) == .orderedSame } }
            .compactMap { added in added.commandLine.map { LaunchProfile(name: added.name, commandLine: $0) } }
        return kept + added
    }

    /// template is a new file: the format, then what this launch detected, commented out.
    public static func template(detected: [LaunchProfile]) -> String {
        let header = """
        # profiles.properties: agterm-win's launch profiles, one `name = command line` per line.
        # agterm-win detects Windows PowerShell, PowerShell 7, Command Prompt, Git Bash and each WSL distribution at
        # every launch. A line here adds a profile, gives a detected one another command line, or hides it with an
        # empty command (`Command Prompt =`). Detected now:

        """
        return header + detected.map { "# \($0.name) = \($0.commandLine)\n" }.joined()
    }

    /// distributions reads `wsl.exe --list --quiet`, which writes UTF-16LE, one name a CRLF line.
    public static func distributions(fromWSLList data: Data) -> [String] {
        let units = stride(from: 0, to: data.count - data.count % 2, by: 2).map { UInt16(data[data.startIndex + $0]) | UInt16(data[data.startIndex + $0 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.filter { $0 != "\u{FEFF}" && $0 != "\0" } }
            .filter { !$0.isEmpty }
    }
}
