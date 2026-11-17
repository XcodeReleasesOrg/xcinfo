//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import Foundation

public struct TextField: Sendable, Equatable {
    public private(set) var text: String
    public private(set) var cursor: Int

    public init(_ text: String = "") {
        self.text = text
        cursor = text.count
    }

    public mutating func clear() {
        text = ""
        cursor = 0
    }

    @discardableResult
    public mutating func handle(_ key: Key) -> Bool {
        switch key {
        case let .character(character):
            insert(String(character))
        case let .paste(pasted):
            insert(pasted)
        case .backspace:
            guard cursor > 0 else { return true }
            remove(cursor - 1 ..< cursor)
        case .delete:
            guard cursor < text.count else { return true }
            remove(cursor ..< cursor + 1)
        case .left:
            cursor = max(0, cursor - 1)
        case .right:
            cursor = min(text.count, cursor + 1)
        case .home:
            cursor = 0
        case .end:
            cursor = text.count
        case .wordLeft:
            cursor = previousWordStart()
        case .wordRight:
            cursor = nextWordEnd()
        case .deleteWord:
            remove(previousWordStart() ..< cursor)
        case .deleteToStart:
            remove(0 ..< cursor)
        case .deleteToEnd:
            remove(cursor ..< text.count)
        default:
            return false
        }
        return true
    }

    public func display(width: Int, masked: Bool = false) -> String {
        let characters = masked ? Array(repeating: Character("•"), count: text.count) : Array(text)
        let visible = max(1, width - 1)
        let start = max(0, min(cursor - visible, characters.count - visible))
        let window = Array(characters.dropFirst(start).prefix(visible))
        let position = cursor - start
        return String(window.prefix(position)) + "▏" + String(window.dropFirst(position))
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character == " " || character == "/"
    }

    private func previousWordStart() -> Int {
        let characters = Array(text)
        var index = cursor
        while index > 0, Self.isBoundary(characters[index - 1]) {
            index -= 1
        }
        while index > 0, !Self.isBoundary(characters[index - 1]) {
            index -= 1
        }
        return index
    }

    private func nextWordEnd() -> Int {
        let characters = Array(text)
        var index = cursor
        while index < characters.count, Self.isBoundary(characters[index]) {
            index += 1
        }
        while index < characters.count, !Self.isBoundary(characters[index]) {
            index += 1
        }
        return index
    }

    private mutating func insert(_ inserted: String) {
        var characters = Array(text)
        characters.insert(contentsOf: inserted, at: cursor)
        text = String(characters)
        cursor += inserted.count
    }

    private mutating func remove(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        var characters = Array(text)
        characters.removeSubrange(range)
        text = String(characters)
        cursor = range.lowerBound
    }
}
