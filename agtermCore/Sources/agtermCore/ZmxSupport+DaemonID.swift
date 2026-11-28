import Foundation

extension ZmxSupport {
    /// opaqueID is the first `length` base58 characters of `text`'s SHA-256. agterm-win names its sockets with it, since an
    /// AF_UNIX path stops at 107 bytes and the profile folder already spends part of them.
    static func opaqueID(_ text: String, length: Int) -> String {
        String(base58(sha256(Array(text.utf8))).prefix(length))
    }

    static let base58Alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

    static func base58(_ bytes: [UInt8]) -> String {
        var digits: [UInt8] = []
        for byte in bytes {
            var carry = Int(byte)
            for index in digits.indices {
                carry += Int(digits[index]) << 8
                digits[index] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }
        let zeros = bytes.prefix { $0 == 0 }.count
        return String(decoding: Array(repeating: base58Alphabet[0], count: zeros) + digits.reversed().map { base58Alphabet[Int($0)] },
                      as: UTF8.self)
    }

    /// sha256 is FIPS 180-4's; Foundation offers none on Windows and Linux.
    static func sha256(_ message: [UInt8]) -> [UInt8] {
        var hash: [UInt32] = [0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19]
        var padded = message + [0x80]
        padded += Array(repeating: 0, count: (56 - padded.count % 64 + 64) % 64)
        padded += (0..<8).map { UInt8(truncatingIfNeeded: (UInt64(message.count) * 8) >> (56 - 8 * $0)) }
        var words = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            for index in 0..<16 {
                words[index] = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(padded[chunk + 4 * index + $1]) }
            }
            for index in 16..<64 {
                let low = words[index - 15], high = words[index - 2]
                let sigma0 = low.rotatedRight(7) ^ low.rotatedRight(18) ^ (low >> 3)
                let sigma1 = high.rotatedRight(17) ^ high.rotatedRight(19) ^ (high >> 10)
                words[index] = words[index - 16] &+ sigma0 &+ words[index - 7] &+ sigma1
            }
            var state = hash
            for index in 0..<64 {
                let (a, b, c, d, e, f, g, h) = (state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7])
                let temp1 = h &+ (e.rotatedRight(6) ^ e.rotatedRight(11) ^ e.rotatedRight(25)) &+ ((e & f) ^ (~e & g))
                    &+ roundConstants[index] &+ words[index]
                let temp2 = (a.rotatedRight(2) ^ a.rotatedRight(13) ^ a.rotatedRight(22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                state = [temp1 &+ temp2, a, b, c, d &+ temp1, e, f, g]
            }
            hash = zip(hash, state).map { $0 &+ $1 }
        }
        return hash.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (24 - 8 * $0)) } }
    }

    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]
}

private extension UInt32 {
    func rotatedRight(_ count: UInt32) -> UInt32 { self >> count | self << (32 - count) }
}
