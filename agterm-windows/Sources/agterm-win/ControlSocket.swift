import AgtermWinKit
import Foundation
import WinSDK
import agtermCore

/// ControlSocket serves agtermctl on `ControlResolve.socketPath`, an AF_UNIX socket as on a Mac: one JSON request line and one
/// response line per connection. Accepting and reading run on a thread of their own; each request runs on the main
/// actor, so a slow server operation holds the next connection, never the window.
final class ControlSocket: @unchecked Sendable {
    let path: String
    private let listener: Int32

    private init(path: String, listener: Int32) {
        self.path = path
        self.listener = listener
    }

    /// start listens at `path` and serves `host`; nil, logged, when the socket cannot be bound.
    static func start(path: String, host: NativeControlHost, version: String) -> ControlSocket? {
        let listener: Int32
        do {
            listener = try UnixSocket.listening(path: path)
        } catch {
            log("control: cannot listen at \(path): \(error)")
            return nil
        }
        log("control: listening at \(path)")
        let socket = ControlSocket(path: path, listener: listener)
        let box = HostBox(host: host)
        Thread.detachNewThread { socket.serve(box, version: version) }
        return socket
    }

    private struct HostBox: @unchecked Sendable {
        let host: NativeControlHost
    }

    private final class ReplyBox: @unchecked Sendable {
        var response = ControlResponse(ok: false, error: "no response")
    }

    private func serve(_ box: HostBox, version: String) {
        while true {
            let client = Int32(bitPattern: UInt32(truncatingIfNeeded: accept(SOCKET(UInt32(bitPattern: listener)), nil, nil)))
            guard client != -1 else {
                log("control: accept failed: WSA error \(WSAGetLastError())")
                return
            }
            // a client that connects and sends nothing would hold every later one
            var timeout: DWORD = 5000
            setsockopt(SOCKET(UInt32(bitPattern: client)), SOL_SOCKET, SO_RCVTIMEO, withUnsafeBytes(of: &timeout) { $0.baseAddress!.assumingMemoryBound(to: CChar.self) },
                       Int32(MemoryLayout<DWORD>.size))
            handle(client, box: box, version: version)
            UnixSocket.closeSocket(client)
        }
    }

    private func handle(_ client: Int32, box: HostBox, version: String) {
        guard let line = Self.readLine(client) else { return }
        let reply = ReplyBox()
        do {
            let request = try JSONDecoder().decode(ControlRequest.self, from: line)
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                reply.response = await NativeControl.handle(request, host: box.host, version: version)
                log("control: \(request.cmd.rawValue) \(reply.response.ok ? "ok" : reply.response.error ?? "failed")")
                done.signal()
            }
            done.wait()
        } catch let error as DecodingError {
            reply.response = ControlResponse(ok: false, error: "invalid request: \(Self.context(of: error))")
        } catch {
            reply.response = ControlResponse(ok: false, error: "invalid request: \(error)")
        }
        guard var data = try? JSONEncoder().encode(reply.response) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = UnixSocket.write(client, raw.baseAddress! + offset, raw.count - offset)
                if sent <= 0 { return }
                offset += sent
            }
        }
    }

    private static func context(of error: DecodingError) -> String {
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context), .dataCorrupted(let context):
            context.debugDescription
        @unknown default:
            "\(error)"
        }
    }

    /// readLine reads the request up to its newline, nil past the shared request cap or when the client hangs up first.
    private static func readLine(_ client: Int32) -> Data? {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { UnixSocket.read(client, $0.baseAddress!, $0.count) }
            guard count > 0 else { return nil }
            if let end = chunk[0..<count].firstIndex(of: UInt8(ascii: "\n")) {
                line.append(contentsOf: chunk[0..<end])
                return line
            }
            line.append(contentsOf: chunk[0..<count])
            if line.count > ControlWire.maxRequestLineBytes { return nil }
        }
    }
}
