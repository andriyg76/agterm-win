import AgtermWinKit
import agtermCore
import Testing

struct NativeOverlayTests {
    @Test func aWindowsSessionsOverlayRunsUnderCmdInTheGivenFolder() {
        let launch = NativeOverlay.launch("git log | more", sessionCommandLine: "powershell.exe -NoLogo", cwd: "C:\\src", directory: "D:\\")
        #expect(launch == .init(commandLine: "cmd.exe /d /s /c \"git log | more\"", directory: "C:\\src"))
        #expect(NativeOverlay.launch("dir", sessionCommandLine: "cmd.exe", cwd: nil, directory: "D:\\work").directory == "D:\\work")
    }

    @Test func aWSLSessionsOverlayRunsInItsDistributionAndFolder() {
        let launch = NativeOverlay.launch("echo 'hi there'", sessionCommandLine: "wsl.exe -d Ubuntu --cd ~", cwd: nil, directory: "/home/me/src")
        #expect(launch == .init(commandLine: "wsl.exe -d Ubuntu --cd /home/me/src --exec sh -c \"echo 'hi there'\"", directory: nil))
        #expect(NativeOverlay.launch("ls", sessionCommandLine: "wsl.exe", cwd: "C:\\Users\\me", directory: nil).commandLine
            == "wsl.exe --cd /mnt/c/Users/me --exec sh -c ls")
        #expect(NativeOverlay.launch("ls", sessionCommandLine: "\"C:\\Windows\\System32\\wsl.exe\" -d \"My Distro\"", cwd: nil, directory: nil)
            .commandLine == "wsl.exe -d \"My Distro\" --cd ~ --exec sh -c ls")
    }

    @Test func aFloatingPanelIsCenteredAtItsPercentAndAFullOneCoversTheArea() {
        let area = NativeOverlay.Rect(x: 240, y: 40, width: 1000, height: 600)
        #expect(NativeOverlay.panel(in: area, sizePercent: nil) == area)
        #expect(NativeOverlay.panel(in: area, sizePercent: 100) == area)
        #expect(NativeOverlay.panel(in: area, sizePercent: 50) == NativeOverlay.Rect(x: 490, y: 190, width: 500, height: 300))
    }

    @Test func colorReadsHexWithOrWithoutTheHash() {
        #expect(NativeOverlay.background("#1a2B3c") == 0x1A2B3C)
        #expect(NativeOverlay.background("1a2b3c") == 0x1A2B3C)
        #expect(NativeOverlay.background("red") == nil && NativeOverlay.background(nil) == nil)
    }

    @Test func aWindowsOverlayIgnoresALinuxFolder() {
        #expect(NativeOverlay.launch("dir", sessionCommandLine: "cmd.exe", cwd: nil, directory: "/home/me").directory == nil)
    }

    @Test func quotingRoundTripsThroughCommandLineToArgvRules() {
        #expect(WindowsCommandLine.quoted("plain") == "plain")
        #expect(WindowsCommandLine.quoted("") == "\"\"")
        #expect(WindowsCommandLine.quoted("two words") == "\"two words\"")
        #expect(WindowsCommandLine.quoted("say \"hi\"") == "\"say \\\"hi\\\"\"")
        #expect(WindowsCommandLine.quoted("C:\\dir with space\\") == "\"C:\\dir with space\\\\\"")
    }
}
