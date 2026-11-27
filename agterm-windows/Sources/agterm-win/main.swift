import AgtermWinKit
import Foundation
import NativeShim
import WinSDK
import agtermCore

// The native Win32 implementation is the only application path:
//   agterm-win.exe [--wsl <remote>] [--profile <name>]...
//   agterm-win.exe [--install-server] [--wsl <remote>]
//   agterm-win.exe --local [<name>]
//   agterm-win.exe -- <command line>
//
// A remote.properties remote's agterm-server starts only on `--wsl`, `--install-server`, the menu, or the choice to start it at launch.
// Unless `--install-server` is set, agterm-win probes the remote first and installs or starts agterm-server when needed.
// `--native` is accepted as a compatibility no-op for commands written while the implementation was introduced.
// AGTERM_WIN_STATE_DIR isolates a test or second instance; AGTERM_WIN_TEST_SCREEN makes a command window write its
// terminal text there when the program exits, then close.
private let environment = ProcessInfo.processInfo.environment
private let stateDirectory = environment["AGTERM_WIN_STATE_DIR"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: environment["LOCALAPPDATA"] ?? ".").appendingPathComponent("agterm-win")
private let logURL = stateDirectory.appendingPathComponent("agterm-win.log")
private let logLock = NSLock()

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    logLock.lock()
    defer { logLock.unlock() }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: logURL)
    }
}

// the module's own path: launched through an MSIX App Execution Alias, argv[0] is the alias in WindowsApps
private let executableFolder = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent()

/// bundled is `name` beside agterm-win.exe, as stage.ps1 lays a package out, else `source` in the source tree.
private func bundled(_ name: String, source: String) -> URL {
    let beside = executableFolder.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: beside.path) { return beside }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(source)
}

/// Packaged identity comes from stage.ps1; source builds use the executable's actual modification date.
func appBuildInfo(serverVersion: String) -> AppBuildInfo {
    let metadata = executableFolder.appendingPathComponent("build-info.json")
    if let data = try? Data(contentsOf: metadata), let info = try? JSONDecoder().decode(AppBuildInfo.self, from: data) {
        return info
    }
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path)
    let date = (attributes?[.modificationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) }
    return AppBuildInfo(version: serverVersion, buildDate: date)
}

/// localZmx is the zmx.exe stage.ps1 put in zmx\<rev>, the folder zmx\current names, else the source tree's.
func localZmx() -> String {
    let packaged = executableFolder.appendingPathComponent("zmx")
    if let current = try? String(contentsOf: packaged.appendingPathComponent("current"), encoding: .utf8),
       let rev = current.split(whereSeparator: \.isNewline).first {
        return packaged.appendingPathComponent(String(rev)).appendingPathComponent("zmx.exe").path
    }
    return bundled("zmx.exe", source: "vendor/zmx/zmx.exe").path
}

/// The agterm release this build is locked to and the sha256 scripts/fetch-server.ps1 recorded for its server tarballs.
func serverRelease() throws -> (version: String, checksums: String) {
    let version = try String(contentsOf: bundled("AGTERM_VERSION", source: "AGTERM_VERSION"), encoding: .utf8)
    let checksums = try String(contentsOf: bundled(ServerInstall.checksumFile,
                                                    source: "vendor/server/\(ServerInstall.checksumFile)"), encoding: .utf8)
    return (version.split(whereSeparator: \.isNewline).first.map(String.init) ?? "", checksums)
}

/// installAgentHooks puts the Claude Code and Codex status adapters in place on the first run and on each new version
/// or agtermctl path. An isolated instance never writes the user's agent config, as a Mac's Debug build must not.
private func installAgentHooks(version: String) {
    guard environment["AGTERM_WIN_STATE_DIR"] == nil else { return }
    let home = FileManager.default.homeDirectoryForCurrentUser
    // a packaged install's own folder is not on PATH and not readable by the agents' shells; its alias is
    let alias = URL(fileURLWithPath: environment["LOCALAPPDATA"] ?? "").appendingPathComponent("Microsoft/WindowsApps/agtermctl.exe")
    let tool = executableFolder.path.contains("WindowsApps") ? alias.path : executableFolder.appendingPathComponent("agtermctl.exe").path
    guard AgentHooksSetup.needsInstall(home: home, version: version, tool: tool) else { return }
    let source = bundled("agent-status", source: "Resources/agent-status")
    let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
    DispatchQueue.global(qos: .utility).async {
        let report = AgentHooksSetup.install(home: home, codexHome: codexHome, source: source, version: version, tool: tool)
        log("agent hooks: \(report.installed ? "installed" : "incomplete") for \(version) with \(tool): \(report.lines.joined(separator: " "))")
    }
}

// Swift's main actor is the main dispatch queue, which nothing drains while a Win32 message loop blocks; these are
// the hooks CoreFoundation's run loop uses for the same purpose on Windows.
@_silgen_name("_dispatch_get_main_queue_handle_4CF") private func mainQueueHandle() -> HANDLE?
@_silgen_name("_dispatch_main_queue_callback_4CF") private func drainMainQueue(_ message: UnsafeMutableRawPointer?)

MainActor.assumeIsolated {
    try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    nt_install_crash_log(Array(stateDirectory.appendingPathComponent("crash.log").path.utf16) + [0])
    log("agterm-win starting on \(UpdateCheck.hostName)")
    let configDirectory = ConfigPaths.configDirectory(setting: nil, stateDir: stateDirectory.path,
                                                      home: FileManager.default.homeDirectoryForCurrentUser)
    Keys.load(configDirectory: configDirectory)
    RemoteCommands.use(configDirectory: configDirectory) { diagnostics in
        for diagnostic in diagnostics { log("remote.properties line \(diagnostic.line): \(diagnostic.message)") }
    }
    // the agtermctl this app runs (server install) resolves the same state directory, and with it remote.properties
    _ = SetEnvironmentVariableW(Array("AGTERM_STATE_DIR".utf16) + [0], Array(stateDirectory.path.utf16) + [0])
    TerminalAppearance.themes = TerminalThemes(userDirectory: configDirectory.appendingPathComponent("themes"),
                                               bundledDirectory: bundled("themes", source: "Resources/themes"))
    // a window without the sidebar draws and takes the mouse as Settings say too
    let saved = NativeSettings.load(from: stateDirectory.appendingPathComponent("native.json"))
    TerminalAppearance.use(saved.appearance)
    NativeTerminal.rightClickPastes = saved.general.rightClickPastes
    NativeTerminal.scrollLines = saved.general.scrollLines

    let arguments = CommandLine.arguments
    if let flag = arguments.firstIndex(of: "--local") {
        let name = flag + 1 < arguments.count ? arguments[flag + 1] : "agterm"
        NativeTerminal.open(commandLine: "\"\(localZmx())\" attach \(name)")
    } else if let separator = arguments.firstIndex(of: "--") {
        let command = arguments[(separator + 1)...].joined(separator: " ")
        NativeTerminal.open(commandLine: command.isEmpty ? "powershell.exe" : command)
    } else {
        let flag = arguments.firstIndex(of: "--wsl")
        let installServer = arguments.contains("--install-server")
        // --install-server names its distribution with --wsl, Ubuntu when it does not
        let server = flag.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? (installServer ? "Ubuntu" : nil)
        let profiles = arguments.indices
            .filter { arguments[$0] == "--profile" && $0 + 1 < arguments.count }
            .map { arguments[$0 + 1] }
        let version = (try? serverRelease().version) ?? "dev"
        installAgentHooks(version: version)
        NativeShell.open(settings: stateDirectory.appendingPathComponent("native.json"), profiles: profiles,
                         version: version, server: server, installServer: installServer)
    }
}

var queueHandle = mainQueueHandle()
var message = MSG()
loop: while true {
    let woke = MsgWaitForMultipleObjectsEx(queueHandle == nil ? 0 : 1, &queueHandle, INFINITE, DWORD(QS_ALLINPUT),
                                           DWORD(MWMO_INPUTAVAILABLE))
    if queueHandle != nil, woke == WAIT_OBJECT_0 { drainMainQueue(nil) }
    while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
        if message.message == UINT(WM_QUIT) { break loop }
        // Tab, Enter and Esc move through Settings' controls as in a dialog
        if let settings = MainActor.assumeIsolated({ SettingsWindow.current?.handle }), IsDialogMessageW(settings, &message) { continue }
        if MainActor.assumeIsolated({ NativeShell.handleSidebarShortcut(message) }) { continue }
        TranslateMessage(&message)
        DispatchMessageW(&message)
    }
}
log("agterm-win exiting")
