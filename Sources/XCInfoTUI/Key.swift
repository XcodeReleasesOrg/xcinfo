//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation

public enum Key: Sendable, Equatable {
    case up
    case down
    case left
    case right
    case pageUp
    case pageDown
    case home
    case end
    case enter
    case escape
    case tab
    case interrupt
    case backspace
    case character(Character)

    public static func parse(_ bytes: [UInt8]) -> [Key] {
        var keys: [Key] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x1B:
                if index + 2 < bytes.count, bytes[index + 1] == UInt8(ascii: "[") || bytes[index + 1] == UInt8(ascii: "O") {
                    let (key, length) = escapeSequence(Array(bytes[(index + 2)...]))
                    if let key {
                        keys.append(key)
                    }
                    index += 2 + length
                } else {
                    keys.append(.escape)
                    index += 1
                }
                continue
            case 0x03:
                keys.append(.interrupt)
            case 0x0D, 0x0A:
                keys.append(.enter)
            case 0x09:
                keys.append(.tab)
            case 0x7F, 0x08:
                keys.append(.backspace)
            case 0x20 ... 0x7E:
                keys.append(.character(Character(UnicodeScalar(byte))))
            case 0xC0 ... 0xF7:
                let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
                let end = min(bytes.count, index + length)
                if let scalar = String(bytes: bytes[index ..< end], encoding: .utf8), let character = scalar.first {
                    keys.append(.character(character))
                }
                index = end
                continue
            default:
                break
            }
            index += 1
        }
        return keys
    }

    private static func escapeSequence(_ bytes: [UInt8]) -> (Key?, Int) {
        guard let first = bytes.first else { return (nil, 0) }
        switch first {
        case UInt8(ascii: "A"):
            return (.up, 1)
        case UInt8(ascii: "B"):
            return (.down, 1)
        case UInt8(ascii: "C"):
            return (.right, 1)
        case UInt8(ascii: "D"):
            return (.left, 1)
        case UInt8(ascii: "H"):
            return (.home, 1)
        case UInt8(ascii: "F"):
            return (.end, 1)
        case UInt8(ascii: "0") ... UInt8(ascii: "9"):
            guard let terminator = bytes.firstIndex(of: UInt8(ascii: "~")) else { return (nil, bytes.count) }
            let number = String(decoding: bytes[..<terminator], as: UTF8.self)
            let key: Key? = switch number {
            case "1", "7":
                .home
            case "4", "8":
                .end
            case "5":
                .pageUp
            case "6":
                .pageDown
            default:
                nil
            }
            return (key, terminator + 1)
        default:
            return (nil, 1)
        }
    }
}
