import Foundation
import agtermCore

/// ReplicaPageServeClient holds one page-serve helper over WSL and fetches a single file path from the origin.
@MainActor
final class ReplicaPageServeClient {
    private let process: HiddenProcess
    private var finished = false

    private init(process: HiddenProcess) {
        self.process = process
    }

    static func start(host: WSLHost, token: String) throws -> ReplicaPageServeClient {
        let remote = try RemoteSession.pageServeCommand(host: "wsl", token: token).last!
        return ReplicaPageServeClient(process: try host.start(remote, captureErrors: true))
    }

    func close() {
        guard !finished else { return }
        finished = true
        process.closeInput()
        if process.isRunning { process.terminate() }
    }

    /// fetch reads `path` on the origin through the page channel and returns the assembled bytes.
    func fetch(path: String) throws -> (mime: String, data: Data) {
        let requestID = 1
        try process.write(try PageServeCodec.encode(.resource(id: requestID, path: path)))
        process.closeInput()
        var buffer = Data()
        var mime = "text/html"
        while true {
            guard let line = try readLine() else { break }
            let frame = try PageServeCodec.decode(line)
            switch frame {
            case .head(let id, let mimeType) where id == requestID:
                mime = mimeType
            case .chunk(let id, let chunk) where id == requestID:
                buffer.append(chunk)
            case .end(let id) where id == requestID:
                return (mime, buffer)
            case .failure(let id, let error) where id == requestID:
                throw WSLHost.Failure.reply(error)
            case .failure, .end, .chunk, .head:
                continue
            default:
                continue
            }
        }
        if buffer.isEmpty { throw WSLHost.Failure.reply("page channel ended before the file arrived") }
        return (mime, buffer)
    }

    private func readLine() throws -> Data? {
        var buffer = Data()
        while true {
            let chunk = process.read()
            if chunk.isEmpty {
                return buffer.isEmpty ? nil : buffer
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line.last == 0x0D ? line.dropLast() : line)
            }
        }
    }
}