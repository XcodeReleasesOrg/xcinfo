//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import CryptoKit
import Foundation

struct Hashcash: Sendable, Equatable {
    let bits: Int
    let challenge: String

    func stamp(date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMddHHmmss"
        let prefix = "1:\(bits):\(formatter.string(from: date)):\(challenge)::"
        var counter = 0
        while !Self.hasLeadingZeroBits(bits, in: Array(Insecure.SHA1.hash(data: Data((prefix + String(counter)).utf8)))) {
            counter += 1
        }
        return prefix + String(counter)
    }

    static func hasLeadingZeroBits(_ count: Int, in digest: [UInt8]) -> Bool {
        var remaining = count
        for byte in digest {
            guard remaining > 0 else { return true }
            if remaining >= 8 {
                guard byte == 0 else { return false }
                remaining -= 8
            } else {
                return byte >> UInt8(8 - remaining) == 0
            }
        }
        return remaining <= 0
    }
}
