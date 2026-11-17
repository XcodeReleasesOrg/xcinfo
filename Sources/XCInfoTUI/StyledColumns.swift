//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation

extension Character {
    var cellWidth: Int {
        guard let scalar = unicodeScalars.first else { return 0 }
        if scalar.properties.isEmojiPresentation || unicodeScalars.contains(where: { $0.value == 0xfe0f }) {
            return 2
        }
        return switch scalar.value {
        case 0x1100 ... 0x115f, 0x2e80 ... 0x303e, 0x3041 ... 0x33ff, 0x3400 ... 0x4dbf, 0x4e00 ... 0x9fff,
             0xa000 ... 0xa4cf, 0xac00 ... 0xd7a3, 0xf900 ... 0xfaff, 0xfe30 ... 0xfe4f, 0xff00 ... 0xff60,
             0xffe0 ... 0xffe6, 0x20000 ... 0x3fffd:
            2
        default:
            1
        }
    }
}

private enum StyledToken {
    case escape(String)
    case character(Character, width: Int)
}

extension String {
    private var styledTokens: [StyledToken] {
        var tokens: [StyledToken] = []
        var index = startIndex
        while index < endIndex {
            let character = self[index]
            if character == "\u{1B}" {
                var end = self.index(after: index)
                if end < endIndex, self[end] == "[" {
                    end = self.index(after: end)
                    while end < endIndex, !self[end].isLetter, self[end] != "~" {
                        end = self.index(after: end)
                    }
                    end = end < endIndex ? self.index(after: end) : end
                }
                tokens.append(.escape(String(self[index ..< end])))
                index = end
            } else {
                tokens.append(.character(character, width: character.cellWidth))
                index = self.index(after: index)
            }
        }
        return tokens
    }

    func columns(before column: Int) -> String {
        var result = ""
        var position = 0
        var isStyled = false
        for token in styledTokens {
            switch token {
            case let .escape(sequence):
                result += sequence
                isStyled = true
            case let .character(character, width):
                guard position < column else { break }
                if position + width > column {
                    result += String(repeating: " ", count: column - position)
                } else {
                    result.append(character)
                }
                position += width
            }
        }
        return result + (isStyled ? "\u{1B}[0m" : "")
    }

    func columns(from column: Int) -> String {
        var result = ""
        var position = 0
        for token in styledTokens {
            switch token {
            case let .escape(sequence):
                result += sequence
            case let .character(character, width):
                if position >= column {
                    result.append(character)
                } else if position + width > column {
                    result += String(repeating: " ", count: position + width - column)
                }
                position += width
            }
        }
        return result
    }
}
