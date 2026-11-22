import Foundation
#if os(Windows)
import WinSDK
#endif

/// StateDirectoryLock marks one process as the owner of a state directory for as long as it lives. Every
/// store save rewrites its whole file from memory, so a second process loaded from the same directory
/// overwrites the owner's later changes with its own stale copy (#741).
public final class StateDirectoryLock: Sendable {
    /// Outcome is what `acquire` found. Only `owned` grants the directory; `unavailable` proves nothing
    /// about whether another process owns it.
    public enum Outcome: Sendable {
        case owned(StateDirectoryLock)
        case heldByAnother
        case unavailable(String)
    }

    static let filename = "agterm.lock"

    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    // a child spawned on another thread holds a copy of the descriptor until its exec,
    // and close alone leaves the lock held through that copy
    deinit {
        #if os(Windows)
        var overlapped = OVERLAPPED()
        _ = UnlockFileEx(HANDLE(bitPattern: _get_osfhandle(fd)), 0, 1, 0, &overlapped)
        #else
        flock(fd, LOCK_UN)
        #endif
        close(fd)
    }

    /// acquire creates a missing directory and takes the exclusive lock without waiting. The lock file is
    /// never removed: the next process would lock a fresh inode and exclude nobody.
    public static func acquire(directory: URL) -> Outcome {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .unavailable("cannot create \(directory.path): \(error.localizedDescription)")
        }
        let path = directory.appendingPathComponent(filename).path
        #if os(Windows)
        let fd = open(path, O_CREAT | O_RDWR | _O_BINARY | _O_NOINHERIT, 0o600)
        guard fd >= 0 else {
            return .unavailable("cannot open \(path): \(String(cString: strerror(errno)))")
        }
        var overlapped = OVERLAPPED()
        guard LockFileEx(HANDLE(bitPattern: _get_osfhandle(fd)), DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY),
                         0, 1, 0, &overlapped) else {
            let code = GetLastError()
            close(fd)
            if code == DWORD(ERROR_LOCK_VIOLATION) { return .heldByAnother }
            return .unavailable("cannot lock \(path): Win32 error \(code)")
        }
        #else
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            return .unavailable("cannot open \(path): \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return .heldByAnother }
            return .unavailable("cannot lock \(path): \(String(cString: strerror(code)))")
        }
        #endif
        return .owned(StateDirectoryLock(fd: fd))
    }
}
