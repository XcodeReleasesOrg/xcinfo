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
    case releaseTerminal(TerminalRelease)
    case reacquireTerminal(TerminalRelease)
}

public struct TerminalRelease: Sendable {
    public let leavesFullScreen: Bool
    public let message: String
    let done: CheckedContinuation<String, Never>
}

actor KeyReaderGate {
    private(set) var isPaused = false

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }
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
    private let input: AsyncStream<TUIInput>.Continuation

    public func withTerminalReleased<Result: Sendable>(
        leavingFullScreen: Bool,
        message: String,
        _ operation: (_ terminalState: String) async throws -> Result
    ) async throws -> Result {
        let input = input
        let state = await withCheckedContinuation { done in
            input.yield(.releaseTerminal(TerminalRelease(leavesFullScreen: leavingFullScreen, message: message, done: done)))
        }
        let result = await Swift.Result { try await operation(state) }
        _ = await withCheckedContinuation { done in
            input.yield(.reacquireTerminal(TerminalRelease(leavesFullScreen: leavingFullScreen, message: message, done: done)))
        }
        return try result.get()
    }

    init(input: AsyncStream<TUIInput>.Continuation, questions: TUIQuestionBox) {
        self.input = input
        logger = Logger { input.yield(.output($0)) }
        prompt = PromptClient(
            ask: { message, invalidMessage, isInvalid in
                let answer = await questions.ask(.text(prompt: message, isSecret: false, invalidMessage: invalidMessage, isInvalid: isInvalid))
                guard case let .text(text) = answer else { throw CancellationError() }
                return text
            },
            choose: { message, choices in
                guard case let .choice(index) = await questions.ask(.choice(prompt: message, choices: choices)) else { throw CancellationError() }
                return index
            },
            agree: { message in
                guard case let .confirm(agreed) = await questions.ask(.confirm(prompt: message)) else { throw CancellationError() }
                return agreed
            },
            readLine: { message in
                let answer = await questions.ask(.text(prompt: message, isSecret: false, invalidMessage: nil, isInvalid: { _ in false }))
                guard case let .text(text) = answer else { throw CancellationError() }
                return text
            },
            readSecret: { message in
                let answer = await questions.ask(.text(prompt: message, isSecret: true, invalidMessage: nil, isInvalid: { _ in false }))
                guard case let .text(text) = answer else { throw CancellationError() }
                return text
            }
        )
    }
}
