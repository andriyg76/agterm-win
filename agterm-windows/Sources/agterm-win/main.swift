import Foundation
import WebView2Shim
import WinSDK
import agtermCore

// First milestone: one window, one xterm.js terminal, one program under ConPTY. Usage:
//   agterm-win.exe [-- <command line>]      default: wsl.exe --cd ~

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

private let outputMessage = UINT(WM_APP + 1)
private let exitMessage = UINT(WM_APP + 2)

/// App owns the window's one terminal: the page, the program, and the output queued for the UI thread.
final class App {
    let commandLine: String
    var window: HWND?
    var console: PseudoConsole?
    private let pendingLock = NSLock()
    private var pending = Data()
    private var exitCode: DWORD?

    init(commandLine: String) {
        self.commandLine = commandLine
    }

    // reader thread: queue, and wake the UI thread only when the queue was empty
    func enqueue(_ data: Data) {
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
        wv_post_string(chunk.base64EncodedString().wide)
    }

    func exited(_ code: DWORD) {
        pendingLock.lock()
        exitCode = code
        pendingLock.unlock()
        if let window { PostMessageW(window, exitMessage, 0, 0) }
    }

    func showExit() {
        flush()
        let code = exitCode ?? 0
        log("program exited with \(code)")
        wv_post_string(Data("\r\n\u{1b}[2m[process exited with code \(code)]\u{1b}[0m\r\n".utf8).base64EncodedString().wide)
        console?.close()
        console = nil
    }

    func received(_ text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let kind = object["t"] as? String else { return }
        switch kind {
        case "ready":
            start(columns: object["cols"] as? Int ?? 80, rows: object["rows"] as? Int ?? 24)
        case "in":
            if let typed = object["d"] as? String { console?.write(Data(typed.utf8)) }
        case "resize":
            if let columns = object["cols"] as? Int, let rows = object["rows"] as? Int {
                console?.resize(columns: Int16(clamping: columns), rows: Int16(clamping: rows))
            }
        case "title":
            if let title = object["title"] as? String, let window {
                SetWindowTextW(window, (title.isEmpty ? "agterm" : title + " — agterm").wide)
            }
        default:
            break
        }
    }

    private func start(columns: Int, rows: Int) {
        guard console == nil else { return }
        do {
            console = try PseudoConsole(commandLine: commandLine, columns: Int16(clamping: columns), rows: Int16(clamping: rows),
                                        onOutput: { [unowned self] in enqueue($0) },
                                        onExit: { [unowned self] in exited($0) })
            log("started pid \(console!.processID) at \(columns)x\(rows): \(commandLine)")
        } catch {
            log("start failed: \(error)")
            wv_post_string(Data("\u{1b}[31m\(error)\u{1b}[0m\r\n".utf8).base64EncodedString().wide)
        }
    }
}

private func commandLineFromArguments() -> String {
    let arguments = CommandLine.arguments
    if let separator = arguments.firstIndex(of: "--"), separator + 1 < arguments.count {
        return arguments[(separator + 1)...].joined(separator: " ")
    }
    return "wsl.exe --cd ~"
}

private var app: App!

private let windowProcedure: WNDPROC = { window, message, wParam, lParam in
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
        app.console?.close()
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(window, message, wParam, lParam)
    }
}

try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
log("agterm-win starting on \(UpdateCheck.hostName); agtermCore linked")
app = App(commandLine: commandLineFromArguments())

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
let window = CreateWindowExW(0, className, "agterm".wide, DWORD(WS_OVERLAPPEDWINDOW),
                             CW_USEDEFAULT, CW_USEDEFAULT, 1100, 700, nil, nil, instance, nil)
guard let window else {
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
                            app.received(String(decodingCString: message, as: UTF16.self))
                        },
                        nil)
if created != 0 { log("CreateCoreWebView2EnvironmentWithOptions failed: \(String(UInt32(bitPattern: created), radix: 16))") }

var message = MSG()
while GetMessageW(&message, nil, 0, 0) {
    TranslateMessage(&message)
    DispatchMessageW(&message)
}
log("agterm-win exiting")
