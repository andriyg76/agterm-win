import Foundation
import NativeShim
import WinSDK
import agtermCore

// The native Win32 implementation is the only application path:
//   agterm-win.exe [--wsl <distribution>] [--profile <name>]...
//   agterm-win.exe [--install-server] [--wsl <distribution>]
//   agterm-win.exe --local [<name>]
//   agterm-win.exe -- <command line>
//
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

/// localZmx is the zmx.exe stage.ps1 put in zmx\<rev>, the folder zmx\current names, else the source tree's.
private func localZmx() -> String {
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

// Swift's main actor is the main dispatch queue, which nothing drains while a Win32 message loop blocks; these are
// the hooks CoreFoundation's run loop uses for the same purpose on Windows.
@_silgen_name("_dispatch_get_main_queue_handle_4CF") private func mainQueueHandle() -> HANDLE?
@_silgen_name("_dispatch_main_queue_callback_4CF") private func drainMainQueue(_ message: UnsafeMutableRawPointer?)

MainActor.assumeIsolated {
    try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    nt_install_crash_log(Array(stateDirectory.appendingPathComponent("crash.log").path.utf16) + [0])
    log("agterm-win starting on \(UpdateCheck.hostName)")

    let arguments = CommandLine.arguments
    if let flag = arguments.firstIndex(of: "--local") {
        let name = flag + 1 < arguments.count ? arguments[flag + 1] : "agterm"
        NativeTerminal.open(commandLine: "\"\(localZmx())\" attach \(name)")
    } else if let separator = arguments.firstIndex(of: "--") {
        let command = arguments[(separator + 1)...].joined(separator: " ")
        NativeTerminal.open(commandLine: command.isEmpty ? "powershell.exe" : command)
    } else {
        let flag = arguments.firstIndex(of: "--wsl")
        let distribution = flag.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "Ubuntu"
        let profiles = arguments.indices
            .filter { arguments[$0] == "--profile" && $0 + 1 < arguments.count }
            .map { arguments[$0 + 1] }
        NativeShell.open(remote: RemoteWindow(host: WSLHost(distribution: distribution), stateDirectory: stateDirectory),
                         settings: stateDirectory.appendingPathComponent("native.json"), profiles: profiles,
                         version: (try? serverRelease().version) ?? "dev", installServer: arguments.contains("--install-server"))
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
        TranslateMessage(&message)
        DispatchMessageW(&message)
    }
}
log("agterm-win exiting")
