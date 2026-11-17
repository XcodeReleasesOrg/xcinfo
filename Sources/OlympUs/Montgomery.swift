//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

struct Montgomery: Sendable {
    let modulus: BigUInt
    private let limbs: [UInt64]
    private let inverse: UInt64
    private let rSquared: [UInt64]

    init?(modulus: BigUInt) {
        guard modulus.bit(at: 0), modulus.bitWidth > 64 else { return nil }
        self.modulus = modulus
        limbs = modulus.wideLimbs
        var inverse: UInt64 = 1
        for _ in 0 ..< 6 {
            inverse = inverse &* (2 &- limbs[0] &* inverse)
        }
        self.inverse = 0 &- inverse
        let r = BigUInt(limbs: [UInt32](repeating: 0, count: limbs.count * 4) + [1])
        rSquared = (r % modulus).wideLimbs(count: limbs.count)
    }

    func power(_ base: BigUInt, _ exponent: BigUInt) -> BigUInt {
        let count = limbs.count
        var scratch = [UInt64](repeating: 0, count: count + 2)
        var one = [UInt64](repeating: 0, count: count)
        one[0] = 1

        let reduced = (base % modulus).wideLimbs(count: count)
        var table = [[UInt64]](repeating: [], count: 16)
        table[0] = multiply(one, rSquared, scratch: &scratch)
        table[1] = multiply(reduced, rSquared, scratch: &scratch)
        for index in 2 ..< 16 {
            table[index] = multiply(table[index - 1], table[1], scratch: &scratch)
        }

        var result = table[0]
        let windows = (exponent.bitWidth + 3) / 4
        for window in stride(from: windows - 1, through: 0, by: -1) {
            for _ in 0 ..< 4 {
                result = multiply(result, result, scratch: &scratch)
            }
            var digit = 0
            for bit in 0 ..< 4 where exponent.bit(at: window * 4 + bit) {
                digit |= 1 << bit
            }
            if digit != 0 {
                result = multiply(result, table[digit], scratch: &scratch)
            }
        }
        return BigUInt(wideLimbs: multiply(result, one, scratch: &scratch))
    }

    private func multiply(_ a: [UInt64], _ b: [UInt64], scratch: inout [UInt64]) -> [UInt64] {
        let count = limbs.count
        var result = [UInt64](repeating: 0, count: count)
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                limbs.withUnsafeBufferPointer { m in
                    scratch.withUnsafeMutableBufferPointer { t in
                        for index in 0 ..< count + 2 {
                            t[index] = 0
                        }
                        for i in 0 ..< count {
                            var carry: UInt64 = 0
                            let ai = a[i]
                            for j in 0 ..< count {
                                let (high, low) = ai.multipliedFullWidth(by: b[j])
                                let (sum, overflow1) = t[j].addingReportingOverflow(low)
                                let (total, overflow2) = sum.addingReportingOverflow(carry)
                                t[j] = total
                                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
                            }
                            let (top, overflow) = t[count].addingReportingOverflow(carry)
                            t[count] = top
                            t[count + 1] = overflow ? 1 : 0

                            let factor = t[0] &* inverse
                            let (high0, low0) = factor.multipliedFullWidth(by: m[0])
                            let (_, overflow0) = t[0].addingReportingOverflow(low0)
                            carry = high0 &+ (overflow0 ? 1 : 0)
                            for j in 1 ..< count {
                                let (high, low) = factor.multipliedFullWidth(by: m[j])
                                let (sum, overflow1) = t[j].addingReportingOverflow(low)
                                let (total, overflow2) = sum.addingReportingOverflow(carry)
                                t[j - 1] = total
                                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
                            }
                            let (shifted, overflowTop) = t[count].addingReportingOverflow(carry)
                            t[count - 1] = shifted
                            t[count] = t[count + 1] &+ (overflowTop ? 1 : 0)
                        }

                        var isAtLeastModulus = t[count] != 0
                        if !isAtLeastModulus {
                            isAtLeastModulus = true
                            for index in stride(from: count - 1, through: 0, by: -1) where t[index] != m[index] {
                                isAtLeastModulus = t[index] > m[index]
                                break
                            }
                        }
                        result.withUnsafeMutableBufferPointer { result in
                            if isAtLeastModulus {
                                var borrow: UInt64 = 0
                                for index in 0 ..< count {
                                    let (difference, overflow1) = t[index].subtractingReportingOverflow(m[index])
                                    let (final, overflow2) = difference.subtractingReportingOverflow(borrow)
                                    result[index] = final
                                    borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
                                }
                            } else {
                                for index in 0 ..< count {
                                    result[index] = t[index]
                                }
                            }
                        }
                    }
                }
            }
        }
        return result
    }
}

extension BigUInt {
    init(wideLimbs: [UInt64]) {
        self.init(limbs: wideLimbs.flatMap { [UInt32(truncatingIfNeeded: $0), UInt32(truncatingIfNeeded: $0 >> 32)] })
    }

    var wideLimbs: [UInt64] {
        wideLimbs(count: (limbs.count + 1) / 2)
    }

    func wideLimbs(count: Int) -> [UInt64] {
        (0 ..< count).map { index in
            let low = 2 * index < limbs.count ? UInt64(limbs[2 * index]) : 0
            let high = 2 * index + 1 < limbs.count ? UInt64(limbs[2 * index + 1]) : 0
            return low | high << 32
        }
    }
}
