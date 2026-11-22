import Foundation
import agtermCore

/// The catalog stream and short commands of a remote window, carried by `wsl.exe` instead of ssh. agtermCore hands
/// over ssh argv; the remote line is its last element, run by `/bin/sh -c` inside the distribution.
@MainActor
final class WSLTransport: RemotePresentationTransport {
    let host: WSLHost

    init(host: WSLHost) {
        self.host = host
    }

    func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
              onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
        let link = WSLLink()
        do {
            try link.start(host.process(argv.last ?? ""), onLine: onLine, onClose: onClose)
        } catch {
            let reason = "wsl.exe did not start: \(error)"
            DispatchQueue.main.async { MainActor.assumeIsolated { onClose(reason) } }
        }
        return link
    }

    /// runner answers RemoteCatalogClient's short commands off the main thread.
    var runner: RemoteCatalogClient.Runner {
        let host = host
        return { argv in
            await withCheckedContinuation { continuation in
                Thread {
                    let result = (try? host.run(argv.last ?? "")) ?? (status: -1, stdout: "", stderr: "")
                    continuation.resume(returning: (result.status, result.stdout))
                }.start()
            }
        }
    }
}

final class WSLLink: RemotePresentationLink {
    private var process: Process?
    private var input: FileHandle?

    func start(_ process: Process, onLine: @escaping @MainActor (Data) -> Void,
               onClose: @escaping @MainActor (String) -> Void) throws {
        let output = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        let reader = output.fileHandleForReading
        Thread {
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    let copy = Data(line.last == 0x0D ? line.dropLast() : line)
                    DispatchQueue.main.async { MainActor.assumeIsolated { onLine(copy) } }
                }
            }
            process.waitUntilExit()
            let reason = "wsl.exe exited \(process.terminationStatus)"
            DispatchQueue.main.async { MainActor.assumeIsolated { onClose(reason) } }
        }.start()
    }

    /// send writes `line` as given: agtermCore's codecs end every frame with its newline.
    func send(_ line: Data) {
        input?.write(line)
    }

    func stop() {
        try? input?.close()
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}
