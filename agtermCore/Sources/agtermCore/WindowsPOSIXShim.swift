#if os(Windows)
import Foundation
import ucrt

// Windows probe: the POSIX spellings agtermCore uses, mapped onto the UCRT. Ownership and 0700 modes have no
// meaning here (ACLs decide), so callers that check them need their own Windows branch.
let O_CLOEXEC: Int32 = _O_NOINHERIT
let O_NOFOLLOW: Int32 = 0

func mkdir(_ path: String, _ mode: Int32) -> Int32 {
    path.withCString { _mkdir($0) }
}

func mkdtemp(_ template: UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    guard _mktemp_s(template, strlen(template) + 1) == 0, _mkdir(template) == 0 else { return nil }
    return template
}
#endif
