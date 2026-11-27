import Foundation
import WinSDK

/// One program under a Windows pseudoconsole: bytes in through `write`, bytes out through `onOutput` on a reader
/// thread, `onExit` once the program ends.
final class PseudoConsole {
    // ProcThreadAttributeValue(22, FALSE, TRUE, FALSE): a function-like macro the importer does not bring over
    private static let pseudoConsoleAttribute = DWORD_PTR(0x0002_0016)

    private let console: HPCON
    private let input: HANDLE
    private let output: HANDLE
    private let process: HANDLE
    let processID: DWORD

    /// `directory` is where the program starts, the caller's current directory when nil.
    init(commandLine: String, directory: String? = nil, environment: [String: String]? = nil, columns: Int16, rows: Int16,
         onOutput: @escaping (Data) -> Void, onExit: @escaping (DWORD) -> Void) throws {
        var inputRead: HANDLE?, inputWrite: HANDLE?, outputRead: HANDLE?, outputWrite: HANDLE?
        guard CreatePipe(&inputRead, &inputWrite, nil, 0), CreatePipe(&outputRead, &outputWrite, nil, 0) else {
            throw Failure.win32("CreatePipe", GetLastError())
        }
        var console: HPCON?
        let created = CreatePseudoConsole(COORD(X: columns, Y: rows), inputRead, outputWrite, 0, &console)
        CloseHandle(inputRead)
        CloseHandle(outputWrite)
        guard created == S_OK, let console else { throw Failure.hresult("CreatePseudoConsole", created) }

        var listSize: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &listSize)
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(listSize), alignment: 16)
        defer { list.deallocate() }
        let attributes: LPPROC_THREAD_ATTRIBUTE_LIST = OpaquePointer(list)
        guard InitializeProcThreadAttributeList(attributes, 1, 0, &listSize),
              UpdateProcThreadAttribute(attributes, 0, Self.pseudoConsoleAttribute, console,
                                        SIZE_T(MemoryLayout<HPCON>.size), nil, nil) else {
            ClosePseudoConsole(console)
            throw Failure.win32("UpdateProcThreadAttribute", GetLastError())
        }
        defer { DeleteProcThreadAttributeList(attributes) }

        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        startup.lpAttributeList = attributes
        var info = PROCESS_INFORMATION()
        var line = Array(commandLine.utf16) + [0]
        let folder = directory.map { Array($0.utf16) + [0] }
        var block = environment.map(Self.environmentBlock) ?? []
        let flags = DWORD(EXTENDED_STARTUPINFO_PRESENT) | (block.isEmpty ? 0 : DWORD(CREATE_UNICODE_ENVIRONMENT))
        let started = withUnsafeMutablePointer(to: &startup) { pointer in
            pointer.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { startupInfo in
                block.withUnsafeMutableBufferPointer { variables in
                    CreateProcessW(nil, &line, nil, nil, false, flags, variables.isEmpty ? nil : UnsafeMutableRawPointer(variables.baseAddress),
                                   folder, startupInfo, &info)
                }
            }
        }
        guard started else {
            let code = GetLastError()
            ClosePseudoConsole(console)
            throw Failure.win32("CreateProcessW(\(commandLine))", code)
        }
        CloseHandle(info.hThread)

        self.console = console
        input = inputWrite!
        output = outputRead!
        process = info.hProcess
        processID = info.dwProcessId

        let output = self.output, process = self.process
        Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var count: DWORD = 0
            while ReadFile(output, &buffer, DWORD(buffer.count), &count, nil), count > 0 {
                onOutput(Data(buffer[0..<Int(count)]))
            }
        }.start()
        Thread {
            WaitForSingleObject(process, INFINITE)
            var code: DWORD = 0
            GetExitCodeProcess(process, &code)
            onExit(code)
        }.start()
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                var written: DWORD = 0
                guard WriteFile(input, raw.baseAddress! + offset, DWORD(raw.count - offset), &written, nil), written > 0 else { return }
                offset += Int(written)
            }
        }
    }

    func resize(columns: Int16, rows: Int16) {
        _ = ResizePseudoConsole(console, COORD(X: columns, Y: rows))
    }

    /// close ends the pseudoconsole, which ends the program's console and with it the reader thread.
    func close() {
        ClosePseudoConsole(console)
        CloseHandle(input)
    }

    /// environmentBlock is CreateProcessW's Unicode block: NAME=value strings, each NUL-ended, the block ending in one more NUL.
    static func environmentBlock(_ variables: [String: String]) -> [UInt16] {
        variables.sorted { $0.key.uppercased() < $1.key.uppercased() }.flatMap { Array("\($0.key)=\($0.value)".utf16) + [0] } + [0]
    }

    enum Failure: Error, CustomStringConvertible {
        case win32(String, DWORD)
        case hresult(String, HRESULT)

        var description: String {
            switch self {
            case .win32(let call, let code): "\(call) failed: Win32 error \(code)"
            case .hresult(let call, let code): "\(call) failed: HRESULT 0x\(String(UInt32(bitPattern: code), radix: 16))"
            }
        }
    }
}
