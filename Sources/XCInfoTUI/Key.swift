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
    case wordLeft
    case wordRight
    case pageUp
    case pageDown
    case home
    case end
    case enter
    case escape
    case tab
    case interrupt
    case backspace
    case delete
    case deleteWord
    case deleteToStart
    case deleteToEnd
    case paste(String)
    case character(Character)

    static let pasteStart: [UInt8] = Array("\u{1B}[200~".utf8)
    static let pasteEnd: [UInt8] = Array("\u{1B}[201~".utf8)

    static func isIncomplete(_ bytes: [UInt8]) -> Bool {
        guard let start = bytes.lastIndex(of: 0x1b) else { return false }
        let tail = Array(bytes[start...])
        if let pasteStart = bytes.firstRange(of: Key.pasteStart),
           bytes[pasteStart.upperBound...].firstRange(of: pasteEnd) == nil
        {
            return true
        }
        if tail.count == 1 {
            return true
        }
        guard tail[1] == UInt8(ascii: "[") || tail[1] == UInt8(ascii: "O") else { return false }
        return !tail.dropFirst(2).contains { (0x40 ... 0x7e).contains($0) }
    }

    public static func parse(_ bytes: [UInt8]) -> [Key] {
        var keys: [Key] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x1b:
                let (key, length) = escape(Array(bytes[index...]))
                if let key {
                    keys.append(key)
                }
                index += length
                continue
            case 0x01:
                keys.append(.home)
            case 0x03:
                keys.append(.interrupt)
            case 0x04:
                keys.append(.delete)
            case 0x05:
                keys.append(.end)
            case 0x0b:
                keys.append(.deleteToEnd)
            case 0x0d, 0x0a:
                keys.append(.enter)
            case 0x09:
                keys.append(.tab)
            case 0x15:
                keys.append(.deleteToStart)
            case 0x17:
                keys.append(.deleteWord)
            case 0x7f, 0x08:
                keys.append(.backspace)
            case 0x20 ... 0x7e:
                keys.append(.character(Character(UnicodeScalar(byte))))
            case 0xc0 ... 0xf7:
                let length = byte >= 0xf0 ? 4 : byte >= 0xe0 ? 3 : 2
                let end = min(bytes.count, index + length)
                if let text = String(bytes: bytes[index ..< end], encoding: .utf8), let character = text.first {
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

    private static func escape(_ bytes: [UInt8]) -> (Key?, Int) {
        guard bytes.count > 1 else { return (.escape, 1) }
        if bytes.starts(with: pasteStart) {
            let body = Array(bytes.dropFirst(pasteStart.count))
            let end = body.indices.first { body[$0...].starts(with: pasteEnd) } ?? body.count
            let text = String(decoding: body[..<end], as: UTF8.self)
                .filter { !$0.unicodeScalars.contains { $0.properties.generalCategory == .control } }
            return (.paste(text), pasteStart.count + min(body.count, end + pasteEnd.count))
        }
        switch bytes[1] {
        case 0x7f, 0x08:
            return (.deleteWord, 2)
        case UInt8(ascii: "b"):
            return (.wordLeft, 2)
        case UInt8(ascii: "f"):
            return (.wordRight, 2)
        case UInt8(ascii: "d"):
            return (.deleteToEnd, 2)
        case UInt8(ascii: "["), UInt8(ascii: "O"):
            return controlSequence(bytes)
        case 0x1b:
            return (.escape, 1)
        default:
            return (nil, 2)
        }
    }

    private static func controlSequence(_ bytes: [UInt8]) -> (Key?, Int) {
        let body = bytes.dropFirst(2)
        guard let finalIndex = body.firstIndex(where: { (0x40 ... 0x7e).contains($0) }) else {
            return (nil, bytes.count)
        }
        let parameters = String(decoding: body[body.startIndex ..< finalIndex], as: UTF8.self)
        let length = finalIndex + 1
        let isAlt = parameters.hasSuffix(";3") || parameters.hasSuffix(";9")
        let key: Key? = switch bytes[finalIndex] {
        case UInt8(ascii: "A"): .up
        case UInt8(ascii: "B"): .down
        case UInt8(ascii: "C"): isAlt ? .wordRight : .right
        case UInt8(ascii: "D"): isAlt ? .wordLeft : .left
        case UInt8(ascii: "H"): .home
        case UInt8(ascii: "F"): .end
        case UInt8(ascii: "~"):
            switch parameters {
            case "1", "7": .home
            case "4", "8": .end
            case "3": .delete
            case "5": .pageUp
            case "6": .pageDown
            default: nil
            }
        default: nil
        }
        return (key, length)
    }
}
