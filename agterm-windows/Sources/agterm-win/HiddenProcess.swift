import Foundation
import WinSDK

/// A console program on pipes with no console window. Foundation's Process gives a console child of this GUI-subsystem
/// app a console of its own, which Windows shows as a separate terminal window (Windows Terminal when it is the default).
final class HiddenProcess {
    // ProcThreadAttributeValue(2, FALSE, TRUE, FALSE): PROC_THREAD_ATTRIBUTE_HANDLE_LIST
    private static let handleListAttribute = DWORD_PTR(0x0002_0002)

    private let process: HANDLE
    private var input: HANDLE?
    private let output: HANDLE
    private let errors: HANDLE?

    /// `input` is a file for the child's stdin, else a pipe `write` feeds. `captureErrors` false sends its stderr to NUL;
    /// true leaves it for `readErrorsToEnd`.
    init(commandLine: String, input file: URL? = nil, captureErrors: Bool) throws {
        var security = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
                                           lpSecurityDescriptor: nil, bInheritHandle: true)
        var parentEnds: [HANDLE] = [], childEnds: [HANDLE] = []
        defer { childEnds.forEach { CloseHandle($0) } }
        func pipe(childReads: Bool) throws -> HANDLE {
            var read: HANDLE?, write: HANDLE?
            guard CreatePipe(&read, &write, &security, 0), let read, let write else {
                parentEnds.forEach { CloseHandle($0) }
                throw PseudoConsole.Failure.win32("CreatePipe", GetLastError())
            }
            let parent = childReads ? write : read
            SetHandleInformation(parent, DWORD(HANDLE_FLAG_INHERIT), 0)
            parentEnds.append(parent)
            childEnds.append(childReads ? read : write)
            return parent
        }
        func open(_ path: String, access: DWORD) throws {
            let handle = path.withCString(encodedAs: UTF16.self) {
                CreateFileW($0, access, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), &security, DWORD(OPEN_EXISTING), 0, nil)
            }
            guard let handle, handle != INVALID_HANDLE_VALUE else {
                parentEnds.forEach { CloseHandle($0) }
                throw PseudoConsole.Failure.win32("CreateFileW(\(path))", GetLastError())
            }
            childEnds.append(handle)
        }
        var input: HANDLE?
        if let file { try open(file.path, access: DWORD(GENERIC_READ)) } else { input = try pipe(childReads: true) }
        let output = try pipe(childReads: false)
        let errors = captureErrors ? try pipe(childReads: false) : nil
        if !captureErrors { try open("NUL", access: DWORD(GENERIC_WRITE)) }

        // only these handles reach the child, so a pipe spawned on another thread never keeps this one's open
        var inherited = childEnds
        var listSize: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &listSize)
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(listSize), alignment: 16)
        defer { list.deallocate() }
        let attributes: LPPROC_THREAD_ATTRIBUTE_LIST = OpaquePointer(list)
        guard InitializeProcThreadAttributeList(attributes, 1, 0, &listSize) else {
            parentEnds.forEach { CloseHandle($0) }
            throw PseudoConsole.Failure.win32("InitializeProcThreadAttributeList", GetLastError())
        }
        defer { DeleteProcThreadAttributeList(attributes) }

        var info = PROCESS_INFORMATION()
        var line = Array(commandLine.utf16) + [0]
        let started = inherited.withUnsafeMutableBufferPointer { handles in
            guard UpdateProcThreadAttribute(attributes, 0, Self.handleListAttribute, handles.baseAddress,
                                            SIZE_T(handles.count * MemoryLayout<HANDLE>.size), nil, nil) else { return false }
            var startup = STARTUPINFOEXW()
            startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
            startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
            startup.StartupInfo.hStdInput = childEnds[0]
            startup.StartupInfo.hStdOutput = childEnds[1]
            startup.StartupInfo.hStdError = childEnds[2]
            startup.lpAttributeList = attributes
            return withUnsafeMutablePointer(to: &startup) { pointer in
                pointer.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { startupInfo in
                    CreateProcessW(nil, &line, nil, nil, true, DWORD(EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW),
                                   nil, nil, startupInfo, &info)
                }
            }
        }
        guard started else {
            let code = GetLastError()
            parentEnds.forEach { CloseHandle($0) }
            throw PseudoConsole.Failure.win32("CreateProcessW(\(commandLine))", code)
        }
        CloseHandle(info.hThread)
        process = info.hProcess
        self.input = input
        self.output = output
        self.errors = errors
    }

    deinit {
        closeInput()
        CloseHandle(output)
        if let errors { CloseHandle(errors) }
        CloseHandle(process)
    }

    /// read returns the next chunk of stdout, empty once the child's end is closed.
    func read() -> Data {
        Self.read(output)
    }

    func readToEnd() -> Data {
        Self.readToEnd(output)
    }

    func readErrorsToEnd() -> Data {
        errors.map(Self.readToEnd) ?? Data()
    }

    func write(_ data: Data) {
        guard let input else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                var written: DWORD = 0
                guard WriteFile(input, raw.baseAddress! + offset, DWORD(raw.count - offset), &written, nil), written > 0 else { return }
                offset += Int(written)
            }
        }
    }

    func closeInput() {
        if let input { CloseHandle(input) }
        input = nil
    }

    var isRunning: Bool {
        WaitForSingleObject(process, 0) == DWORD(WAIT_TIMEOUT)
    }

    func waitUntilExit() {
        WaitForSingleObject(process, INFINITE)
    }

    var terminationStatus: Int32 {
        var code: DWORD = 0
        GetExitCodeProcess(process, &code)
        return Int32(bitPattern: code)
    }

    func terminate() {
        TerminateProcess(process, 1)
    }

    private static func read(_ handle: HANDLE) -> Data {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var count: DWORD = 0
        guard ReadFile(handle, &buffer, DWORD(buffer.count), &count, nil), count > 0 else { return Data() }
        return Data(buffer[0..<Int(count)])
    }

    private static func readToEnd(_ handle: HANDLE) -> Data {
        var data = Data()
        while true {
            let chunk = read(handle)
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
    }
}
