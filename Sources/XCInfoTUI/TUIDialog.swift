//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation

public enum TUIQuestion: Sendable {
    case text(prompt: String, isSecret: Bool, invalidMessage: String?, isInvalid: @Sendable (String) -> Bool)
    case choice(prompt: String, choices: [String])
    case confirm(prompt: String)
}

public enum TUIAnswer: Sendable, Equatable {
    case text(String)
    case choice(Int)
    case confirm(Bool)
    case cancelled
}

public struct TUIDialog: Sendable {
    public let question: TUIQuestion
    public private(set) var input = ""
    public private(set) var selection = 0
    public private(set) var error: String?

    public init(_ question: TUIQuestion) {
        self.question = question
    }

    public mutating func handle(_ key: Key) -> TUIAnswer? {
        if key == .escape || key == .interrupt {
            return .cancelled
        }
        switch question {
        case let .text(_, _, invalidMessage, isInvalid):
            switch key {
            case .enter:
                guard !isInvalid(input) else {
                    error = invalidMessage
                    return nil
                }
                defer { input = "" }
                return .text(input)
            case .backspace:
                if !input.isEmpty {
                    input.removeLast()
                }
            case let .character(character):
                input.append(character)
                error = nil
            default:
                break
            }
        case let .choice(_, choices):
            switch key {
            case .up, .character("k"):
                selection = max(0, selection - 1)
            case .down, .character("j"):
                selection = min(max(0, choices.count - 1), selection + 1)
            case .enter:
                return choices.isEmpty ? .cancelled : .choice(selection)
            case let .character(character):
                if let number = character.wholeNumberValue, choices.indices.contains(number - 1) {
                    return .choice(number - 1)
                }
            default:
                break
            }
        case .confirm:
            switch key {
            case .character("y"), .character("Y"):
                return .confirm(true)
            case .character("n"), .character("N"):
                return .confirm(false)
            case .left, .right, .tab:
                selection = selection == 0 ? 1 : 0
            case .enter:
                return .confirm(selection == 0)
            default:
                break
            }
        }
        return nil
    }

    var prompt: String {
        switch question {
        case let .text(prompt, _, _, _), let .choice(prompt, _), let .confirm(prompt):
            prompt
        }
    }

    var lines: [String] {
        switch question {
        case let .text(_, isSecret, _, _):
            let shown = isSecret ? String(repeating: "•", count: input.count) : input
            return ["> " + shown + "▏", error ?? "", isSecret ? "Return to confirm · Esc to cancel · typing is hidden" : "Return to confirm · Esc to cancel"]
        case let .choice(_, choices):
            return choices.enumerated().map { (selection == $0.offset ? "› " : "  ") + "\($0.offset + 1). \($0.element)" } + ["", "↑↓ choose · Return to confirm · Esc to cancel"]
        case .confirm:
            return [selection == 0 ? "[ Yes ]   No  " : "  Yes   [ No ]", "", "y yes · n no · Esc to cancel"]
        }
    }
}

extension TUIDialog: Equatable {
    public static func == (lhs: TUIDialog, rhs: TUIDialog) -> Bool {
        lhs.prompt == rhs.prompt && lhs.input == rhs.input && lhs.selection == rhs.selection && lhs.error == rhs.error
    }
}
