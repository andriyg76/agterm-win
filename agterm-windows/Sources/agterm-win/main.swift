import Foundation
import WebView2Shim
import WinSDK
import agtermCore

// One window: a sidebar and one xterm.js terminal, its program under ConPTY. Usage:
//   agterm-win.exe [--wsl <distribution>]   agterm-server's sessions there; the default distribution is Ubuntu
//                  [--install-server]       first install or upgrade agterm-server there to the release AGTERM_VERSION names
//   agterm-win.exe --local [<name>]         local zmx session <name> (default agterm), kept when the window closes
//   agterm-win.exe -- <command line>        one local program instead, no sidebar
//   agterm-win.exe --native [--wsl <distribution>] [--profile <name>]...
//                                                    spike: the sidebar and terminals drawn natively, no WebView2;
//                                                    each --profile starts a local session ("Command Prompt", "WSL Ubuntu")
//   agterm-win.exe --native -- <command>             spike: one program drawn natively by agwinterm's core

// AGTERM_WIN_STATE_DIR isolates a test or second instance; AGTERM_WIN_TEST_SCREEN makes the window write the
// terminal's text there when its program exits, then close.
private let environment = ProcessInfo.processInfo.environment
private let stateDirectory = environment["AGTERM_WIN_STATE_DIR"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: environment["LOCALAPPDATA"] ?? ".").appendingPathComponent("agterm-win")
private let testScreen = environment["AGTERM_WIN_TEST_SCREEN"]
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

private extension String {
    var wide: [UInt16] { Array(utf16) + [0] }
}

private func post(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    wv_post_string(String(decoding: data, as: UTF8.self).wide)
}

private let outputMessage = UINT(WM_APP + 1)
private let exitMessage = UINT(WM_APP + 2)

/// App owns the window's one terminal: the program under ConPTY, the output queued for the UI thread, and, for a
/// remote window, which session the terminal shows.
@MainActor
final class App {
    let remote: RemoteWindow?
    let localCommand: String?
    let installServer: Bool
    var window: HWND?
    private var console: PseudoConsole?
    private var generation = 0
    private var size = (columns: 80, rows: 24)
    private var pageReady = false
    private var selected: Foundation.UUID?
    private let pendingLock = NSLock()
    nonisolated(unsafe) private var pending = Data()
    nonisolated(unsafe) private var exitCode: (generation: Int, code: DWORD)?

    init(remote: RemoteWindow?, localCommand: String?, installServer: Bool = false) {
        self.remote = remote
        self.localCommand = localCommand
        self.installServer = installServer
        remote?.changed = { [weak self] in self?.catalogChanged() }
    }

    // reader thread: queue, and wake the UI thread only when the queue was empty
    nonisolated func enqueue(_ data: Data, window: HWND?) {
        pendingLock.lock()
        let wasEmpty = pending.isEmpty
        pending.append(data)
        pendingLock.unlock()
        if wasEmpty, let window { PostMessageW(window, outputMessage, 0, 0) }
    }

    func flush() {
        pendingLock.lock()
        let chunk = pending
        pending = Data()
        pendingLock.unlock()
        guard !chunk.isEmpty else { return }
        post(["t": "out", "d": chunk.base64EncodedString()])
    }

    nonisolated func exited(_ code: DWORD, generation: Int, window: HWND?) {
        pendingLock.lock()
        exitCode = (generation, code)
        pendingLock.unlock()
        if let window { PostMessageW(window, exitMessage, 0, 0) }
    }

    func showExit() {
        pendingLock.lock()
        let exit = exitCode
        pendingLock.unlock()
        guard let exit, exit.generation == generation else { return }
        flush()
        log("program exited with \(exit.code)")
        write("\r\n\u{1b}[2m[process exited with code \(exit.code)]\u{1b}[0m\r\n")
        console?.close()
        console = nil
        if testScreen != nil { post(["t": "dump"]) }
    }

    func received(_ text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let kind = object["t"] as? String else { return }
        if kind != "in" && kind != "screen" { log("page: \(text)") }
        switch kind {
        case "ready":
            size = (object["cols"] as? Int ?? 80, object["rows"] as? Int ?? 24)
            pageReady = true
            if let localCommand {
                start(localCommand)
            } else if installServer, let remote {
                install(remote)
            } else {
                catalogChanged()
                remote?.start()
            }
        case "in":
            if let typed = object["d"] as? String { console?.write(Data(typed.utf8)) }
        case "resize":
            if let columns = object["cols"] as? Int, let rows = object["rows"] as? Int {
                size = (columns, rows)
                console?.resize(columns: Int16(clamping: columns), rows: Int16(clamping: rows))
            }
        case "title":
            if let title = object["title"] as? String, let window {
                SetWindowTextW(window, (title.isEmpty ? "agterm" : title + " — agterm").wide)
            }
        case "screen":
            if let path = testScreen, let text = object["text"] as? String {
                try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
                if let window { DestroyWindow(window) }
            }
        case "select":
            if let id = (object["id"] as? String).flatMap(Foundation.UUID.init(uuidString:)) { select(id) }
        default:
            break
        }
    }

    func stop() {
        console?.close()
        console = nil
    }

    /// install installs agterm-server in the window's distribution off the UI thread, its progress shown in the
    /// terminal, and opens the catalog afterwards whatever the outcome: a server that is still missing or older shows
    /// as the window's notice, as it does without the flag.
    private func install(_ remote: RemoteWindow) {
        let host = remote.host
        let report: @Sendable (String) -> Void = { text in
            log("server install: \(text)")
            DispatchQueue.main.async { MainActor.assumeIsolated { app.write(text.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n") } }
        }
        DispatchQueue.global().async {
            do {
                let release = try serverRelease()
                let code = try host.installServer(version: release.version, checksums: release.checksums, progress: report)
                switch code {
                case 0: report("installed agterm-server \(release.version) in WSL \(host.distribution)")
                case 3: report("installed agterm-server \(release.version) in WSL \(host.distribution); the agent hooks are incomplete")
                default: report("\u{1b}[31magterm-server's install.sh exited \(code)\u{1b}[0m")
                }
            } catch {
                report("\u{1b}[31mserver install failed: \(error)\u{1b}[0m")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { app.catalogChanged(); remote.start() } }
        }
    }

    func catalogChanged() {
        guard pageReady, let remote else { return }
        if selected == nil || remote.session(selected!) == nil,
           let first = remote.store.workspaces.lazy.flatMap(\.sessions).first(where: { !$0.ended }) {
            select(first.id)
            return
        }
        publishTree()
    }

    private func publishTree() {
        guard let remote else { return }
        let workspaces: [[String: Any]] = remote.store.workspaces.map { workspace in
            ["name": workspace.name,
             "sessions": workspace.sessions.map { ["id": $0.id.uuidString, "name": $0.displayName, "ended": $0.ended] }]
        }
        let notice = remote.mirror.state.windowNotice(host: "WSL \(remote.host.distribution)") ?? ""
        post(["t": "tree", "workspaces": workspaces, "selected": selected?.uuidString ?? "", "notice": notice])
    }

    private func select(_ id: Foundation.UUID) {
        guard let session = remote?.session(id) else { return }
        guard id != selected || console == nil else { return }
        selected = id
        remote?.store.selectedSessionID = id
        publishTree()
        stop()
        post(["t": "reset"])
        // agtermCore's placeholder for an ended or held pane is a POSIX line, with no /bin/sh to run it here
        let placeholder = session.remoteHost.map(RemoteSession.endedCommand(host:))
        guard let command = session.initialCommand, command != placeholder else {
            let notice = session.initialCommand == nil ? "no pane to attach" : "Ended on WSL \(remote?.host.distribution ?? "")"
            write("\u{1b}[2m\(notice)\u{1b}[0m\r\n")
            return
        }
        log("showing \(session.displayName) [\(id)]")
        start(command)
    }

    private func start(_ commandLine: String) {
        generation += 1
        let generation = generation, window = window
        do {
            console = try PseudoConsole(commandLine: commandLine, columns: Int16(clamping: size.columns), rows: Int16(clamping: size.rows),
                                        onOutput: { [unowned self] in enqueue($0, window: window) },
                                        onExit: { [unowned self] in exited($0, generation: generation, window: window) })
            log("started pid \(console!.processID) at \(size.columns)x\(size.rows)")
        } catch {
            log("start failed: \(error)")
            write("\u{1b}[31m\(error)\u{1b}[0m\r\n")
        }
    }

    func write(_ text: String) {
        post(["t": "out", "d": Data(text.utf8).base64EncodedString()])
    }
}

/// bundled is `name` beside agterm-win.exe, as stage.ps1 lays a package out, else `source` in the agterm-windows tree.
private func bundled(_ name: String, source: String) -> URL {
    let beside = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: beside.path) { return beside }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(source)
}

/// localZmx is the zmx.exe stage.ps1 put in zmx\<rev>, the folder zmx\current names, else the source tree's.
private func localZmx() -> String {
    let packaged = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("zmx")
    if let current = try? String(contentsOf: packaged.appendingPathComponent("current"), encoding: .utf8),
       let rev = current.split(whereSeparator: \.isNewline).first {
        return packaged.appendingPathComponent(String(rev)).appendingPathComponent("zmx.exe").path
    }
    return bundled("zmx.exe", source: "vendor/zmx/zmx.exe").path
}

private func xtermAssets() -> URL { bundled("xterm", source: "vendor/xterm") }

/// serverRelease is the agterm release this build is locked to and the sha256 scripts/fetch-server.ps1 recorded for
/// its server tarballs.
private func serverRelease() throws -> (version: String, checksums: String) {
    let version = try String(contentsOf: bundled("AGTERM_VERSION", source: "AGTERM_VERSION"), encoding: .utf8)
    let checksums = try String(contentsOf: bundled(ServerInstall.checksumFile, source: "vendor/server/\(ServerInstall.checksumFile)"),
                               encoding: .utf8)
    // a checkout with core.autocrlf gives AGTERM_VERSION a CRLF, which is one newline Character
    return (version.split(whereSeparator: \.isNewline).first.map(String.init) ?? "", checksums)
}

// Swift's main actor is the main dispatch queue, which nothing drains while a Win32 message loop blocks; these are
// the hooks CoreFoundation's run loop uses for the same purpose on Windows.
@_silgen_name("_dispatch_get_main_queue_handle_4CF") private func mainQueueHandle() -> HANDLE?
@_silgen_name("_dispatch_main_queue_callback_4CF") private func drainMainQueue(_ message: UnsafeMutableRawPointer?)

private nonisolated(unsafe) var app: App!

private let windowProcedure: WNDPROC = { window, message, wParam, lParam in
    MainActor.assumeIsolated {
        switch message {
        case UINT(WM_SIZE):
            let size = UInt32(truncatingIfNeeded: lParam)
            wv_resize(Int32(size & 0xFFFF), Int32(size >> 16))
            return 0
        case UINT(WM_SETFOCUS):
            wv_focus()
            return 0
        case outputMessage:
            app.flush()
            return 0
        case exitMessage:
            app.showExit()
            return 0
        case UINT(WM_DESTROY):
            app.stop()
            PostQuitMessage(0)
            return 0
        default:
            return DefWindowProcW(window, message, wParam, lParam)
        }
    }
}

MainActor.assumeIsolated {
    try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    crash_log_install(stateDirectory.appendingPathComponent("crash.log").path.wide)
    log("agterm-win starting on \(UpdateCheck.hostName)")
    let arguments = CommandLine.arguments
    if arguments.contains("--native") {
        let core = bundled(NativeTerminal.coreFile, source: "vendor/agwcore/\(NativeTerminal.coreFile)")
        if let separator = arguments.firstIndex(of: "--") {
            let command = arguments[(separator + 1)...].joined(separator: " ")
            NativeTerminal.open(commandLine: command.isEmpty ? "powershell.exe" : command, core: core)
        } else {
            let flag = arguments.firstIndex(of: "--wsl")
            let distribution = flag.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "Ubuntu"
            let profiles = arguments.indices.filter { arguments[$0] == "--profile" && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
            NativeShell.open(remote: RemoteWindow(host: WSLHost(distribution: distribution), stateDirectory: stateDirectory), core: core,
                             settings: stateDirectory.appendingPathComponent("native.json"), profiles: profiles)
        }
        return
    }
    if let flag = arguments.firstIndex(of: "--local") {
        let name = flag + 1 < arguments.count ? arguments[flag + 1] : "agterm"
        app = App(remote: nil, localCommand: "\"\(localZmx())\" attach \(name)")
    } else if let separator = arguments.firstIndex(of: "--"), separator + 1 < arguments.count {
        app = App(remote: nil, localCommand: arguments[(separator + 1)...].joined(separator: " "))
    } else {
        let flag = arguments.firstIndex(of: "--wsl")
        let distribution = flag.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "Ubuntu"
        app = App(remote: RemoteWindow(host: WSLHost(distribution: distribution), stateDirectory: stateDirectory), localCommand: nil,
                  installServer: arguments.contains("--install-server"))
    }

    wv_init_process()
    _ = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue))

    let instance = GetModuleHandleW(nil)
    let className = "agterm-win".wide
    className.withUnsafeBufferPointer { name in
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.lpfnWndProc = windowProcedure
        windowClass.hInstance = instance
        windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512)) // IDC_ARROW
        // icon group 1 of Resources/agterm.res, linked into the exe
        let icon = UnsafePointer<WCHAR>(bitPattern: 1)
        windowClass.hIcon = LoadIconW(instance, icon)
        windowClass.hIconSm = LoadImageW(instance, icon, UINT(IMAGE_ICON), GetSystemMetrics(SM_CXSMICON),
                                         GetSystemMetrics(SM_CYSMICON), 0)?.assumingMemoryBound(to: HICON__.self)
        windowClass.lpszClassName = name.baseAddress
        RegisterClassExW(&windowClass)
    }
    guard let window = CreateWindowExW(0, className, "agterm".wide, DWORD(WS_OVERLAPPEDWINDOW),
                                       CW_USEDEFAULT, CW_USEDEFAULT, 1300, 760, nil, nil, instance, nil) else {
        log("CreateWindowExW failed: \(GetLastError())")
        exit(1)
    }
    app.window = window
    ShowWindow(window, SW_SHOW)

    // a fixed-version runtime for a machine without WebView2, such as Windows Sandbox
    let runtime = environment["AGTERM_WIN_WEBVIEW2_RUNTIME"]?.wide
    let created = wv_create(UnsafeMutableRawPointer(window), runtime, stateDirectory.appendingPathComponent("WebView2").path.wide,
                            TerminalPage.html(assets: xtermAssets()).wide,
                            { _, result in log(result == 0 ? "webview ready" : "webview failed: HRESULT \(String(UInt32(bitPattern: result), radix: 16))") },
                            { _, message in
                                guard let message else { return }
                                let text = String(decodingCString: message, as: UTF16.self)
                                MainActor.assumeIsolated { app.received(text) }
                            },
                            nil)
    if created != 0 { log("CreateCoreWebView2EnvironmentWithOptions failed: \(String(UInt32(bitPattern: created), radix: 16))") }
}

var queueHandle = mainQueueHandle()
var message = MSG()
loop: while true {
    let woke = MsgWaitForMultipleObjectsEx(queueHandle == nil ? 0 : 1, &queueHandle, INFINITE, DWORD(QS_ALLINPUT), DWORD(MWMO_INPUTAVAILABLE))
    if queueHandle != nil, woke == WAIT_OBJECT_0 { drainMainQueue(nil) }
    while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
        if message.message == UINT(WM_QUIT) { break loop }
        TranslateMessage(&message)
        DispatchMessageW(&message)
    }
}
log("agterm-win exiting")
