import AgtermWinKit
import Foundation
import Testing

struct SessionNamingTests {
    @Test func aCustomNameWinsThenTheTitleThenTheFolderThenTheProfile() {
        #expect(SessionNaming.displayName(customName: "build", title: "vim", directory: #"C:\dev\agterm"#, fallback: "PowerShell") == "build")
        #expect(SessionNaming.displayName(customName: "  ", title: "vim", directory: #"C:\dev\agterm"#, fallback: "PowerShell") == "vim")
        #expect(SessionNaming.displayName(customName: nil, title: nil, directory: #"C:\dev\agterm"#, fallback: "PowerShell") == "agterm")
        #expect(SessionNaming.displayName(customName: nil, title: "", directory: nil, fallback: "PowerShell") == "PowerShell")
    }

    @Test func conPTYsExecutableTitleIsNotAName() {
        #expect(SessionNaming.programTitle(#"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe"#) == nil)
        #expect(SessionNaming.programTitle(#"Administrator: C:\Windows\system32\cmd.exe"#) == nil)
        #expect(SessionNaming.programTitle("✳ Claude Code") == "✳ Claude Code")
        #expect(SessionNaming.programTitle("a\u{7}b") == "ab")
    }

    @Test func reportedDirectoriesDecode() {
        #expect(SessionNaming.directory(fromReported: "file://host/C:/Users/me/My%20Projects") == "C:/Users/me/My Projects")
        #expect(SessionNaming.directory(fromReported: "file:///home/me/dev") == "/home/me/dev")
        #expect(SessionNaming.directory(fromReported: #""C:\dev\agterm""#) == #"C:\dev\agterm"#)
        #expect(SessionNaming.directory(fromReported: "") == nil)
    }

    @Test func folderNamesKeepRoots() {
        #expect(SessionNaming.folderName(#"C:\dev\agterm\"#) == "agterm")
        #expect(SessionNaming.folderName(#"C:\"#) == "C:")
        #expect(SessionNaming.folderName("/") == "/")
        #expect(SessionNaming.folderName(#"\\server\share\logs"#) == "logs")
    }

    @Test func aBlankRenameRestoresTheAutomaticName() {
        #expect(SessionNaming.customName("  ") == nil)
        #expect(SessionNaming.customName(" logs\n") == "logs")
    }

    @Test func bareShellsGetTheDirectoryReport() {
        let powerShell = ShellIntegration.commandLine("powershell.exe -NoLogo")
        #expect(powerShell.hasPrefix("powershell.exe -NoLogo -NoExit -EncodedCommand "))
        let script = try! #require(Data(base64Encoded: String(powerShell.split(separator: " ").last!)))
        let units = stride(from: 0, to: script.count, by: 2).map { UInt16(script[$0]) | UInt16(script[$0 + 1]) << 8 }
        #expect(String(decoding: units, as: UTF16.self).contains("]9;9;"))
        #expect(ShellIntegration.commandLine(#""C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo"#).contains("-EncodedCommand"))
        #expect(ShellIntegration.commandLine("cmd.exe") == #"cmd.exe /k prompt $e]9;9;$P$e\$P$G"#)
    }

    @Test func linesWithTheirOwnCommandRunAsWritten() {
        #expect(ShellIntegration.commandLine("powershell.exe -File build.ps1") == "powershell.exe -File build.ps1")
        #expect(ShellIntegration.commandLine("cmd.exe /k") == "cmd.exe /k")
        #expect(ShellIntegration.commandLine("wsl.exe -d Ubuntu --cd ~") == "wsl.exe -d Ubuntu --cd ~")
    }
}
