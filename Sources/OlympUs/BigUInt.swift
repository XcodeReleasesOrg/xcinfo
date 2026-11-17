//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see LICENSE.md
//

import Foundation

struct BigUInt: Sendable, Hashable, Comparable, CustomStringConvertible {
    private(set) var limbs: [UInt32]

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    init(_ value: UInt64) {
        self.init(limbs: [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)])
    }

    init(bigEndian bytes: some Collection<UInt8>) {
        var limbs: [UInt32] = []
        limbs.reserveCapacity(bytes.count / 4 + 1)
        var current: UInt32 = 0
        var shift: UInt32 = 0
        for byte in bytes.reversed() {
            current |= UInt32(byte) << shift
            shift += 8
            if shift == 32 {
                limbs.append(current)
                current = 0
                shift = 0
            }
        }
        if shift > 0 {
            limbs.append(current)
        }
        self.init(limbs: limbs)
    }

    init?(hex: String) {
        let digits = hex.filter { !$0.isWhitespace }
        guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit) else { return nil }
        let padded = digits.count.isMultiple(of: 2) ? digits : "0" + digits
        var bytes: [UInt8] = []
        bytes.reserveCapacity(padded.count / 2)
        var index = padded.startIndex
        while index < padded.endIndex {
            let next = padded.index(index, offsetBy: 2)
            bytes.append(UInt8(padded[index ..< next], radix: 16)!)
            index = next
        }
        self.init(bigEndian: bytes)
    }

    static let zero = BigUInt(limbs: [])
    static let one = BigUInt(1)

    var isZero: Bool {
        limbs.isEmpty
    }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 32 - top.leadingZeroBitCount
    }

    var byteCount: Int {
        (bitWidth + 7) / 8
    }

    func bit(at index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return limbs[limb] & (1 << UInt32(index % 32)) != 0
    }

    func bytes(paddedTo length: Int = 0) -> [UInt8] {
        let count = max(byteCount, length)
        var bytes = [UInt8](repeating: 0, count: count)
        for (limbIndex, limb) in limbs.enumerated() {
            for byteIndex in 0 ..< 4 {
                let position = count - 1 - (limbIndex * 4 + byteIndex)
                guard position >= 0 else { break }
                bytes[position] = UInt8(truncatingIfNeeded: limb >> UInt32(byteIndex * 8))
            }
        }
        return bytes
    }

    var hex: String {
        bytes().map { String(format: "%02x", $0) }.joined()
    }

    var description: String {
        isZero ? "0" : hex
    }

    private mutating func normalize() {
        while limbs.last == 0 {
            limbs.removeLast()
        }
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result: [UInt32] = []
        result.reserveCapacity(max(lhs.limbs.count, rhs.limbs.count) + 1)
        var carry: UInt64 = 0
        for index in 0 ..< max(lhs.limbs.count, rhs.limbs.count) {
            let sum = UInt64(lhs.limbs[safe: index]) + UInt64(rhs.limbs[safe: index]) + carry
            result.append(UInt32(truncatingIfNeeded: sum))
            carry = sum >> 32
        }
        if carry > 0 {
            result.append(UInt32(carry))
        }
        return BigUInt(limbs: result)
    }

    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(lhs >= rhs, "BigUInt subtraction would underflow")
        var result = lhs.limbs
        var borrow: Int64 = 0
        for index in 0 ..< result.count {
            var difference = Int64(result[index]) - Int64(rhs.limbs[safe: index]) - borrow
            if difference < 0 {
                difference += 1 << 32
                borrow = 1
            } else {
                borrow = 0
            }
            result[index] = UInt32(difference)
        }
        return BigUInt(limbs: result)
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        guard !lhs.isZero, !rhs.isZero else { return .zero }
        var result = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for (i, left) in lhs.limbs.enumerated() {
            var carry: UInt64 = 0
            let left = UInt64(left)
            for (j, right) in rhs.limbs.enumerated() {
                let product = left * UInt64(right) + UInt64(result[i + j]) + carry
                result[i + j] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
            result[i + rhs.limbs.count] = UInt32(carry)
        }
        return BigUInt(limbs: result)
    }

    static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.quotientAndRemainder(dividingBy: rhs).remainder
    }

    static func / (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.quotientAndRemainder(dividingBy: rhs).quotient
    }

    func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "Division by zero")
        if self < divisor {
            return (.zero, self)
        }
        if divisor.limbs.count == 1 {
            let d = UInt64(divisor.limbs[0])
            var quotient = [UInt32](repeating: 0, count: limbs.count)
            var remainder: UInt64 = 0
            for index in stride(from: limbs.count - 1, through: 0, by: -1) {
                let current = (remainder << 32) | UInt64(limbs[index])
                quotient[index] = UInt32(current / d)
                remainder = current % d
            }
            return (BigUInt(limbs: quotient), BigUInt(remainder))
        }

        let shift = divisor.limbs.last!.leadingZeroBitCount
        let v = divisor.shiftedLeft(by: shift).limbs
        var u = shiftedLeft(by: shift).limbs
        if u.count == limbs.count {
            u.append(0)
        }
        let n = v.count
        let m = u.count - n - 1
        var quotient = [UInt32](repeating: 0, count: m + 1)
        let base: UInt64 = 1 << 32

        for j in stride(from: m, through: 0, by: -1) {
            let numerator = (UInt64(u[j + n]) << 32) | UInt64(u[j + n - 1])
            var qhat = numerator / UInt64(v[n - 1])
            var rhat = numerator % UInt64(v[n - 1])
            while qhat >= base || qhat * UInt64(v[n - 2]) > (rhat << 32) + UInt64(u[j + n - 2]) {
                qhat -= 1
                rhat += UInt64(v[n - 1])
                if rhat >= base { break }
            }

            var borrow: Int64 = 0
            var carry: UInt64 = 0
            for i in 0 ..< n {
                let product = qhat * UInt64(v[i]) + carry
                carry = product >> 32
                let difference = Int64(u[i + j]) - Int64(product & 0xFFFF_FFFF) - borrow
                u[i + j] = UInt32(truncatingIfNeeded: difference)
                borrow = difference < 0 ? 1 : 0
            }
            let last = Int64(u[j + n]) - Int64(carry) - borrow
            u[j + n] = UInt32(truncatingIfNeeded: last)

            if last < 0 {
                qhat -= 1
                var addCarry: UInt64 = 0
                for i in 0 ..< n {
                    let sum = UInt64(u[i + j]) + UInt64(v[i]) + addCarry
                    u[i + j] = UInt32(truncatingIfNeeded: sum)
                    addCarry = sum >> 32
                }
                u[j + n] = UInt32(truncatingIfNeeded: UInt64(u[j + n]) + addCarry)
            }
            quotient[j] = UInt32(qhat)
        }

        let remainder = BigUInt(limbs: Array(u[0 ..< n])).shiftedRight(by: shift)
        return (BigUInt(limbs: quotient), remainder)
    }

    func shiftedLeft(by bits: Int) -> BigUInt {
        guard bits > 0, !isZero else { return self }
        var result = [UInt32](repeating: 0, count: limbs.count + 1)
        for (index, limb) in limbs.enumerated() {
            result[index] |= limb << UInt32(bits)
            result[index + 1] = limb >> UInt32(32 - bits)
        }
        return BigUInt(limbs: result)
    }

    func shiftedRight(by bits: Int) -> BigUInt {
        guard bits > 0, !isZero else { return self }
        var result = [UInt32](repeating: 0, count: limbs.count)
        for index in 0 ..< limbs.count {
            result[index] = limbs[index] >> UInt32(bits)
            if index + 1 < limbs.count {
                result[index] |= limbs[index + 1] << UInt32(32 - bits)
            }
        }
        return BigUInt(limbs: result)
    }

    func power(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        precondition(!modulus.isZero, "Modulus must not be zero")
        if let montgomery = Montgomery(modulus: modulus) {
            return montgomery.power(self, exponent)
        }
        var result = BigUInt.one % modulus
        var base = self % modulus
        for index in 0 ..< exponent.bitWidth {
            if exponent.bit(at: index) {
                result = (result * base) % modulus
            }
            base = (base * base) % modulus
        }
        return result
    }
}

private extension Array where Element == UInt32 {
    subscript(safe index: Int) -> UInt32 {
        index < count ? self[index] : 0
    }
}
