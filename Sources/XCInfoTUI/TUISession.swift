//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
import XCIFoundation

public enum TUIInput: Sendable {
    case keys([Key])
    case tick
    case output(OutputEvent)
    case question(TUIQuestion)
    case finished(TUIOutcome)
}

public struct TUIOutcome: Sendable, Equatable {
    public var succeeded: Bool
    public var message: String?

    public init(succeeded: Bool, message: String?) {
        self.succeeded = succeeded
        self.message = message
    }
}

actor TUIQuestionBox {
    private let input: AsyncStream<TUIInput>.Continuation
    private var pending: CheckedContinuation<TUIAnswer, Never>?
    private var isCancelled = false

    init(input: AsyncStream<TUIInput>.Continuation) {
        self.input = input
    }

    func ask(_ question: TUIQuestion) async -> TUIAnswer {
        guard !isCancelled, !Task.isCancelled else { return .cancelled }
        input.yield(.question(question))
        return await withCheckedContinuation { pending = $0 }
    }

    func answer(_ answer: TUIAnswer) {
        pending?.resume(returning: answer)
        pending = nil
    }

    func cancel() {
        isCancelled = true
        answer(.cancelled)
    }
}

public struct TUISession: Sendable {
    public let logger: Logger
    public let prompt: PromptClient

    init(input: AsyncStream<TUIInput>.Continuation, questions: TUIQuestionBox) {
        logger = Logger { input.yield(.output($0)) }
        prompt = PromptClient(
            ask: { message, invalidMessage, isInvalid in
                let answer = await questions.ask(.text(prompt: message, isSecret: false, invalidMessage: invalidMessage, isInvalid: isInvalid))
                guard case let .text(text) = answer else { return "" }
                return text
            },
            choose: { message, choices in
                guard case let .choice(index) = await questions.ask(.choice(prompt: message, choices: choices)) else { return 0 }
                return index
            },
            agree: { message in
                guard case let .confirm(agreed) = await questions.ask(.confirm(prompt: message)) else { return false }
                return agreed
            },
            readLine: { message in
                guard case let .text(text) = await questions.ask(.text(prompt: message, isSecret: false, invalidMessage: nil, isInvalid: { _ in false })) else { return "" }
                return text
            },
            readSecret: { message in
                guard case let .text(text) = await questions.ask(.text(prompt: message, isSecret: true, invalidMessage: nil, isInvalid: { _ in false })) else { return "" }
                return text
            }
        )
    }
}
