import Foundation

/// LaunchProfile is a program a new local session can start: a Windows shell, or a WSL distribution's login shell.
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
    /// `powerShell7` is pwsh.exe's path when installed.
    public static func available(wslDistributions: [String], powerShell7: String?) -> [LaunchProfile] {
        var profiles = [LaunchProfile(name: "Windows PowerShell", commandLine: "powershell.exe -NoLogo")]
        if let powerShell7 { profiles.append(LaunchProfile(name: "PowerShell 7", commandLine: "\"\(powerShell7)\" -NoLogo")) }
        profiles.append(LaunchProfile(name: "Command Prompt", commandLine: "cmd.exe"))
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

    /// distributions reads `wsl.exe --list --quiet`, which writes UTF-16LE, one name a CRLF line.
    public static func distributions(fromWSLList data: Data) -> [String] {
        let units = stride(from: 0, to: data.count - data.count % 2, by: 2).map { UInt16(data[data.startIndex + $0]) | UInt16(data[data.startIndex + $0 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.filter { $0 != "\u{FEFF}" && $0 != "\0" } }
            .filter { !$0.isEmpty }
    }
}
