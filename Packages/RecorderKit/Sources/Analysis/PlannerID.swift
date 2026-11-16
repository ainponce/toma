// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// The ids of what the planners make (plan decision 10): a prefix and the first 4 bytes, in lowercase hex, of SHA-256
/// of the UTF-8 of the fields joined by `|` (the planner and its version first). The same fields always give the same
/// id, so planning again without changes gives the same ids.
enum PlannerID {
    static func make(prefix: String, _ fields: [String]) -> String {
        let digest = SHA256.hash(data: Data(fields.joined(separator: "|").utf8))
        let digits = Array("0123456789abcdef")
        return prefix + String(digest.prefix(4).flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]] })
    }
}
