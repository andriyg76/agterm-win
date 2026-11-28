#if os(Windows)
import Foundation
import ucrt
import WinSDK

// Windows probe: the POSIX spellings agtermCore uses, mapped onto the UCRT. Ownership and 0700 modes have no
// meaning here (ACLs decide), so callers that check them need their own Windows branch.
typealias pid_t = Int32

let O_CLOEXEC: Int32 = _O_NOINHERIT
let O_NOFOLLOW: Int32 = 0
let O_NONBLOCK: Int32 = 0

// st_mode is an unsigned short here and the UCRT's file-type masks are Int32
let S_IFMT = UInt16(ucrt.S_IFMT)
let S_IFREG = UInt16(ucrt.S_IFREG)
let S_IFDIR = UInt16(ucrt.S_IFDIR)

// WinSock takes the buffer length as an Int32
func gethostname(_ name: UnsafeMutablePointer<CChar>, _ length: Int) -> Int32 {
    WinSDK.gethostname(name, Int32(clamping: length))
}

// not atomic like POSIX pread: the descriptor's offset moves, which is safe only for a descriptor one thread owns
func pread(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int, _ offset: off_t) -> Int {
    guard _lseeki64(fd, Int64(offset), SEEK_SET) >= 0 else { return -1 }
    return Int(_read(fd, buffer, UInt32(clamping: count)))
}

func mkdir(_ path: String, _ mode: Int32) -> Int32 {
    path.withCString { _mkdir($0) }
}

func mkdtemp(_ template: UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    guard _mktemp_s(template, strlen(template) + 1) == 0, _mkdir(template) == 0 else { return nil }
    return template
}
#endif
