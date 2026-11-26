import Foundation
import agtermCore

/// The catalog stream and short commands of a remote window. agtermCore hands over each invocation whole, the remote's
/// own command first, and this runs it as a hidden Windows process.
@MainActor
final class RemoteTransport: RemotePresentationTransport {
    let host: RemoteHost

    init(host: RemoteHost) {
        self.host = host
    }

    func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
              onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
        let link = RemoteLink()
        do {
            try link.start(host.start(argv, captureErrors: false), onLine: onLine, onClose: onClose)
        } catch {
            let reason = "\(argv.first ?? "the remote command") did not start: \(error)"
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
                    let result = (try? host.run(argv)) ?? (status: -1, stdout: "", stderr: "")
                    continuation.resume(returning: (result.status, result.stdout))
                }.start()
            }
        }
    }
}

final class RemoteLink: RemotePresentationLink {
    private var process: HiddenProcess?

    func start(_ process: HiddenProcess, onLine: @escaping @MainActor (Data) -> Void,
               onClose: @escaping @MainActor (String) -> Void) {
        self.process = process
        Thread {
            var buffer = Data()
            while true {
                let chunk = process.read()
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
            let reason = "the remote command exited \(process.terminationStatus)"
            DispatchQueue.main.async { MainActor.assumeIsolated { onClose(reason) } }
        }.start()
    }

    /// send writes `line` as given: agtermCore's codecs end every frame with its newline.
    func send(_ line: Data) {
        process?.write(line)
    }

    func stop() {
        process?.closeInput()
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}
