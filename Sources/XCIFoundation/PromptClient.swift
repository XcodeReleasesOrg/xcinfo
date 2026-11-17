//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation

public struct PromptClient: Sendable {
    public var ask: @Sendable (_ message: String, _ invalidMessage: String, _ isInvalid: @escaping @Sendable (String) -> Bool) -> String
    public var choose: @Sendable (_ message: String, _ choices: [String]) -> Int
    public var agree: @Sendable (_ message: String) -> Bool
    public var readLine: @Sendable (_ prompt: String) -> String
    public var readSecret: @Sendable (_ prompt: String) -> String

    public init(
        ask: @escaping @Sendable (String, String, @escaping @Sendable (String) -> Bool) -> String,
        choose: @escaping @Sendable (String, [String]) -> Int,
        agree: @escaping @Sendable (String) -> Bool,
        readLine: @escaping @Sendable (String) -> String,
        readSecret: @escaping @Sendable (String) -> String
    ) {
        self.ask = ask
        self.choose = choose
        self.agree = agree
        self.readLine = readLine
        self.readSecret = readSecret
    }
}

public struct ConsolePrompt: Sendable {
    public var read: @Sendable () -> String?
    public var write: @Sendable (_ text: String, _ terminator: String) -> Void

    public init(
        read: @escaping @Sendable () -> String?,
        write: @escaping @Sendable (String, String) -> Void
    ) {
        self.read = read
        self.write = write
    }

    public static let standard = ConsolePrompt(
        read: { Swift.readLine() },
        write: { text, terminator in
            print(text, terminator: terminator)
            fflush(nil)
        }
    )

    public func ask(_ message: String, invalidMessage: String, isInvalid: (String) -> Bool) -> String {
        write(message, "\n")
        return validated(read() ?? "", newPrompt: "?  ") { value in
            isInvalid(value) ? invalidMessage : nil
        }
    }

    public func choose(_ message: String, choices: [String]) -> Int {
        for (index, choice) in choices.enumerated() {
            write("\(index + 1). \(choice)", "\n")
        }
        write(message, "")
        let input = validated(read() ?? "", newPrompt: "?  ") { value in
            choiceIndex(for: value, in: choices) == nil
                ? "You must choose one of [\((Array(1 ... max(1, choices.count)).map(String.init) + choices).joined(separator: ", "))]."
                : nil
        }
        return choiceIndex(for: input, in: choices) ?? 0
    }

    public func agree(_ message: String) -> Bool {
        let positive = ["Yes", "yes", "Y", "y"]
        let negative = ["No", "no", "N", "n"]
        write(message, "  ")
        let input = validated(read() ?? "", newPrompt: "\(message)  ") { value in
            positive.contains(value) || negative.contains(value) ? nil : "Please enter \"yes\" or \"no\"."
        }
        return positive.contains(input)
    }

    public func readLine(_ prompt: String) -> String {
        write("\(prompt) ", "")
        return read() ?? ""
    }

    private func choiceIndex(for input: String, in choices: [String]) -> Int? {
        if let number = Int(input) {
            return choices.indices.contains(number - 1) ? number - 1 : nil
        }
        return choices.firstIndex(of: input)
    }

    private func validated(_ initialValue: String, newPrompt: String, invalidMessage: (String) -> String?) -> String {
        var value = initialValue
        while let message = invalidMessage(value) {
            write(message, "\n")
            write(newPrompt, "")
            guard let next = read() else { return value }
            value = next
        }
        return value
    }
}

public extension PromptClient {
    static func console(_ console: ConsolePrompt) -> PromptClient {
        PromptClient(
            ask: { message, invalidMessage, isInvalid in
                console.ask(message, invalidMessage: invalidMessage, isInvalid: isInvalid)
            },
            choose: { message, choices in
                console.choose(message, choices: choices)
            },
            agree: { message in
                console.agree(message)
            },
            readLine: { prompt in
                console.readLine(prompt)
            },
            readSecret: { prompt in
                String(cString: getpass("\(prompt) "))
            }
        )
    }

    static let live = PromptClient.console(.standard)
}
