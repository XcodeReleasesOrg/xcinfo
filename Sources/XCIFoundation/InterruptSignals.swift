//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Darwin
import Foundation

public struct Interrupted: Error, Sendable, Equatable {
    public let signal: Int32

    public init(signal: Int32) {
        self.signal = signal
    }
}

public struct InterruptSignals: Sendable {
    public let signals: [Int32]

    public init(_ signals: [Int32] = [SIGINT, SIGTERM]) {
        self.signals = signals
    }

    public func run<Result: Sendable>(
        onInterrupt: @escaping @Sendable (Int32) -> Void,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let pipe = SignalPipe.shared
        let token = UInt8.random(in: SignalPipe.firstToken ... UInt8.max)
        let previousHandlers = signals.map { SignalHandler(signal: $0).replace(with: writeSignalToPipe) }
        let outcome = await Swift.Result { try await watch(pipe: pipe, token: token, onInterrupt: onInterrupt, operation: operation) }
        for previous in previousHandlers {
            previous.restore()
        }
        return try outcome.get()
    }

    private func watch<Result: Sendable>(
        pipe: SignalPipe,
        token: UInt8,
        onInterrupt: @escaping @Sendable (Int32) -> Void,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Outcome<Result>.self) { group in
            group.addTask {
                defer { pipe.write(token) }
                do {
                    return try .finished(.success(await operation()))
                } catch {
                    return .finished(.failure(error))
                }
            }
            group.addTask {
                await .signal(pipe.nextSignal(until: token))
            }

            var interruption: Int32?
            var result: Swift.Result<Result, any Error>?
            while let outcome = try await group.next() {
                switch outcome {
                case let .signal(signal?):
                    interruption = signal
                    for signal in signals {
                        var action = sigaction()
                        action.__sigaction_u.__sa_handler = SIG_DFL
                        sigaction(signal, &action, nil)
                    }
                    onInterrupt(signal)
                    group.cancelAll()
                case .signal(nil):
                    break
                case let .finished(finished):
                    result = finished
                }
            }
            if let interruption {
                throw Interrupted(signal: interruption)
            }
            guard let result else { throw CancellationError() }
            return try result.get()
        }
    }
}

private struct SignalHandler {
    let signal: Int32
    var action = sigaction()

    func replace(with handler: @escaping @convention(c) (Int32) -> Void) -> SignalHandler {
        var replacement = sigaction()
        replacement.__sigaction_u.__sa_handler = handler
        var previous = self
        sigaction(signal, &replacement, &previous.action)
        return previous
    }

    func restore() {
        var action = action
        sigaction(signal, &action, nil)
    }
}

private enum Outcome<Result: Sendable>: Sendable {
    case finished(Swift.Result<Result, any Error>)
    case signal(Int32?)
}

private func writeSignalToPipe(_ signal: Int32) {
    SignalPipe.shared.write(UInt8(truncatingIfNeeded: signal))
}

final class SignalPipe: Sendable {
    static let shared = SignalPipe()
    static let firstToken: UInt8 = 64

    let readEnd: Int32
    let writeEnd: Int32

    private init() {
        var descriptors: [Int32] = [-1, -1]
        Darwin.pipe(&descriptors)
        readEnd = descriptors[0]
        writeEnd = descriptors[1]
    }

    func write(_ byte: UInt8) {
        var byte = byte
        _ = Darwin.write(writeEnd, &byte, 1)
    }

    func nextSignal(until token: UInt8) async -> Int32? {
        do {
            for try await byte in FileHandle(fileDescriptor: readEnd, closeOnDealloc: false).bytes {
                if byte == token {
                    return nil
                }
                if byte > 0, byte < Self.firstToken {
                    return Int32(byte)
                }
            }
        } catch {}
        return nil
    }
}
