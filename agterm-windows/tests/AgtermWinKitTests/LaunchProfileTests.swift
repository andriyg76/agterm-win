import AgtermWinKit
import Foundation
import Testing

struct LaunchProfileTests {
    @Test func windowsShellsComeFirstThenEachDistribution() {
        let profiles = LaunchProfiles.available(wslDistributions: ["Ubuntu", "Debian"], powerShell7: #"C:\Program Files\PowerShell\7\pwsh.exe"#)
        #expect(profiles.map(\.name) == ["Windows PowerShell", "PowerShell 7", "Command Prompt", "WSL Ubuntu", "WSL Debian"])
        #expect(profiles[1].commandLine == #""C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo"#)
        #expect(profiles[3].commandLine == "wsl.exe -d Ubuntu --cd ~")
    }

    @Test func withoutPowerShell7OrWSLOnlyTheBuiltInShells() {
        #expect(LaunchProfiles.available(wslDistributions: [], powerShell7: nil).map(\.name) == ["Windows PowerShell", "Command Prompt"])
    }

    @Test func dockerDesktopDistributionsAreLeftOut() {
        let names = LaunchProfiles.available(wslDistributions: ["docker-desktop", "docker-desktop-data", "Ubuntu"], powerShell7: nil).map(\.name)
        #expect(names.last == "WSL Ubuntu" && !names.contains { $0.contains("docker") })
        #expect(LaunchProfiles.serverDistributions(["docker-desktop", "Ubuntu", "Debian"]) == ["Ubuntu", "Debian"])
    }

    @Test func wslListIsUTF16WithCRLFLines() {
        var data = Data([0xFF, 0xFE])
        for unit in "Ubuntu\r\nDebian-12\r\n\r\n".utf16 { data.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
        #expect(LaunchProfiles.distributions(fromWSLList: data) == ["Ubuntu", "Debian-12"])
        #expect(LaunchProfiles.distributions(fromWSLList: Data()).isEmpty)
    }

    @Test func profilesAreNamedIgnoringCase() {
        let profiles = LaunchProfiles.available(wslDistributions: ["Ubuntu"], powerShell7: nil)
        #expect(LaunchProfiles.named("wsl ubuntu", in: profiles)?.commandLine == "wsl.exe -d Ubuntu --cd ~")
        #expect(LaunchProfiles.named("Bash", in: profiles) == nil)
    }
}
