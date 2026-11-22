import Foundation
import WebView2Shim
import WinSDK
import agtermCore

// One window: a sidebar and one xterm.js terminal, its program under ConPTY. Usage:
//   agterm-win.exe [--wsl <distribution>]   agterm-server's sessions there; the default distribution is Ubuntu
//   agterm-win.exe --local [<name>]         local zmx session <name> (default agterm), kept when the window closes
//   agterm-win.exe -- <command line>        one local program instead, no sidebar

private let stateDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? ".")
    .appendingPathComponent("agterm-win")
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
    var window: HWND?
    private var console: PseudoConsole?
    private var generation = 0
    private var size = (columns: 80, rows: 24)
    private var pageReady = false
    private var selected: Foundation.UUID?
    private let pendingLock = NSLock()
    nonisolated(unsafe) private var pending = Data()
    nonisolated(unsafe) private var exitCode: (generation: Int, code: DWORD)?

    init(remote: RemoteWindow?, localCommand: String?) {
        self.remote = remote
        self.localCommand = localCommand
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
    }

    func received(_ text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let kind = object["t"] as? String else { return }
        switch kind {
        case "ready":
            size = (object["cols"] as? Int ?? 80, object["rows"] as? Int ?? 24)
            pageReady = true
            if let localCommand {
                start(localCommand)
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

    private func catalogChanged() {
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
        guard let command = session.initialCommand else {
            write("\u{1b}[2m\(session.ended ? "session ended" : "no pane to attach")\u{1b}[0m\r\n")
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

    private func write(_ text: String) {
        post(["t": "out", "d": Data(text.utf8).base64EncodedString()])
    }
}

/// localZmx is the zmx.exe beside agterm-win.exe, else the one scripts/fetch-zmx.ps1 built into vendor/zmx.
private func localZmx() -> String {
    let beside = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("zmx.exe")
    if FileManager.default.fileExists(atPath: beside.path) { return beside.path }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("vendor/zmx/zmx.exe").path
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
    log("agterm-win starting on \(UpdateCheck.hostName)")
    let arguments = CommandLine.arguments
    if let flag = arguments.firstIndex(of: "--local") {
        let name = flag + 1 < arguments.count ? arguments[flag + 1] : "agterm"
        app = App(remote: nil, localCommand: "\"\(localZmx())\" attach \(name)")
    } else if let separator = arguments.firstIndex(of: "--"), separator + 1 < arguments.count {
        app = App(remote: nil, localCommand: arguments[(separator + 1)...].joined(separator: " "))
    } else {
        let flag = arguments.firstIndex(of: "--wsl")
        let distribution = flag.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "Ubuntu"
        app = App(remote: RemoteWindow(host: WSLHost(distribution: distribution), stateDirectory: stateDirectory), localCommand: nil)
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

    let created = wv_create(UnsafeMutableRawPointer(window), stateDirectory.appendingPathComponent("WebView2").path.wide,
                            TerminalPage.html.wide,
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
