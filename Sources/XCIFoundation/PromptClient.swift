//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import Foundation

public struct PromptClient: Sendable {
    public var ask: @Sendable (_ message: String, _ invalidMessage: String, _ isInvalid: @escaping @Sendable (String) -> Bool) async throws -> String
    public var choose: @Sendable (_ message: String, _ choices: [String]) async throws -> Int
    public var agree: @Sendable (_ message: String) async throws -> Bool
    public var readLine: @Sendable (_ prompt: String) async throws -> String
    public var readSecret: @Sendable (_ prompt: String) async throws -> String

    public init(
        ask: @escaping @Sendable (String, String, @escaping @Sendable (String) -> Bool) async throws -> String,
        choose: @escaping @Sendable (String, [String]) async throws -> Int,
        agree: @escaping @Sendable (String) async throws -> Bool,
        readLine: @escaping @Sendable (String) async throws -> String,
        readSecret: @escaping @Sendable (String) async throws -> String
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
            FileHandle.standardError.write(Data((text + terminator).utf8))
        }
    )

    public func ask(_ message: String, invalidMessage: String, isInvalid: (String) -> Bool) throws -> String {
        write(message, "\n")
        return try validated(next(for: message), question: message, newPrompt: "?  ") { value in
            isInvalid(value) ? invalidMessage : nil
        }
    }

    public func choose(_ message: String, choices: [String]) throws -> Int {
        for (index, choice) in choices.enumerated() {
            write("\(index + 1). \(choice)", "\n")
        }
        write(message, "")
        let input = try validated(next(for: message, choices: choices), question: message, choices: choices, newPrompt: "?  ") { value in
            choiceIndex(for: value, in: choices) == nil
                ? "You must choose one of [\((Array(1 ... max(1, choices.count)).map(String.init) + choices).joined(separator: ", "))]."
                : nil
        }
        return choiceIndex(for: input, in: choices) ?? 0
    }

    public func agree(_ message: String) throws -> Bool {
        let positive = ["Yes", "yes", "Y", "y"]
        let negative = ["No", "no", "N", "n"]
        write(message, "  ")
        let input = try validated(next(for: message), question: message, newPrompt: "\(message)  ") { value in
            positive.contains(value) || negative.contains(value) ? nil : "Please enter \"yes\" or \"no\"."
        }
        return positive.contains(input)
    }

    public func readLine(_ prompt: String) throws -> String {
        write("\(prompt) ", "")
        return try next(for: prompt)
    }

    private func next(for question: String, choices: [String] = []) throws -> String {
        guard let line = read() else { throw PromptUnavailable(question: question, choices: choices) }
        return line
    }

    private func choiceIndex(for input: String, in choices: [String]) -> Int? {
        if let number = Int(input) {
            return choices.indices.contains(number - 1) ? number - 1 : nil
        }
        return choices.firstIndex(of: input)
    }

    private func validated(
        _ initialValue: String,
        question: String,
        choices: [String] = [],
        newPrompt: String,
        invalidMessage: (String) -> String?
    ) throws -> String {
        var value = initialValue
        while let message = invalidMessage(value) {
            write(message, "\n")
            write(newPrompt, "")
            value = try next(for: question, choices: choices)
        }
        return value
    }
}

public extension PromptClient {
    static func console(_ console: ConsolePrompt) -> PromptClient {
        PromptClient(
            ask: { message, invalidMessage, isInvalid in
                try console.ask(message, invalidMessage: invalidMessage, isInvalid: isInvalid)
            },
            choose: { message, choices in
                try console.choose(message, choices: choices)
            },
            agree: { message in
                try console.agree(message)
            },
            readLine: { prompt in
                try console.readLine(prompt)
            },
            readSecret: { prompt in
                readPassphrase(prompt: "\(prompt) ")
            }
        )
    }

    static let live = PromptClient.console(.standard)

    static let unavailable = PromptClient(
        ask: { message, _, _ in throw PromptUnavailable(question: message) },
        choose: { message, choices in throw PromptUnavailable(question: message, choices: choices) },
        agree: { message in throw PromptUnavailable(question: message) },
        readLine: { message in throw PromptUnavailable(question: message) },
        readSecret: { message in throw PromptUnavailable(question: message) }
    )
}

public struct PromptUnavailable: LocalizedError, Sendable, Equatable {
    public var question: String
    public var choices: [String]

    public init(question: String, choices: [String] = []) {
        self.question = question
        self.choices = choices
    }

    public var errorDescription: String? {
        let options = choices.isEmpty ? "" : "\nThe choices are:\n" + choices.map { "  \($0)" }.joined(separator: "\n")
        return """
        xcinfo would have to ask "\(question.trimmingCharacters(in: .whitespaces))", but it runs with --non-interactive or without a terminal.\(options)
        Give the answer up front: an exact version or build number, --overwrite, --no-verify, or XCINFO_APPLE_ID and XCINFO_APPLE_PASSWORD.
        """
    }
}

private func readPassphrase(prompt: String) -> String {
    var buffer = [CChar](repeating: 0, count: 1024)
    return buffer.withUnsafeMutableBufferPointer { buffer in
        defer { memset_s(buffer.baseAddress, buffer.count, 0, buffer.count) }
        guard let passphrase = readpassphrase(prompt, buffer.baseAddress, buffer.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) else {
            return ""
        }
        return String(cString: passphrase)
    }
}
