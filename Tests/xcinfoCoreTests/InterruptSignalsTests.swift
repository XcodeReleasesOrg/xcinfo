import Darwin
import Foundation
import Testing
@testable import XCIFoundation

@Suite(.serialized, .timeLimit(.minutes(1)))
struct InterruptSignalsTests {
    private let signals = InterruptSignals([SIGUSR1])

    @Test
    func `an operation without a signal returns its result and restores the handler`() async throws {
        let previous = signal(SIGUSR1, SIG_IGN)
        defer { signal(SIGUSR1, previous) }

        let result = try await signals.run { _ in
            Issue.record("No signal was sent")
        } operation: {
            42
        }

        #expect(result == 42)
        let current = signal(SIGUSR1, SIG_IGN)
        #expect(unsafeBitCast(current, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self))
    }

    @Test
    func `an operation error is passed on`() async throws {
        struct Failure: Error {}

        await #expect(throws: Failure.self) {
            try await signals.run { _ in } operation: { () async throws -> Int in throw Failure() }
        }
    }

    @Test
    func `a signal cancels the operation, waits for it and reports the interruption`() async throws {
        let interrupts = Recorder<Int32>()
        let cleanups = Recorder<Bool>()

        await #expect(throws: Interrupted(signal: SIGUSR1)) {
            try await signals.run { signal in
                interrupts.append(signal)
            } operation: {
                raise(SIGUSR1)
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cleanups.append(Task.isCancelled)
                    throw error
                }
            }
        }

        #expect(interrupts.values == [SIGUSR1])
        #expect(cleanups.values == [true])
    }

    @Test
    func `runs one after another do not see each other's wake-up`() async throws {
        for value in 1 ... 3 {
            let result = try await signals.run { _ in Issue.record("No signal was sent") } operation: { value }
            #expect(result == value)
        }
    }

    @Test
    func `a nested watch finishes and leaves signals to the outer one`() async throws {
        let interrupts = Recorder<Int32>()
        let nested = Recorder<Int>()

        await #expect(throws: Interrupted(signal: SIGUSR1)) {
            try await signals.run { interrupts.append($0) } operation: {
                let value = try await signals.run { _ in Issue.record("The nested watch must not see the signal") } operation: { 7 }
                nested.append(value)
                raise(SIGUSR1)
                try await Task.sleep(for: .seconds(30))
            }
        }

        #expect(nested.values == [7])
        #expect(interrupts.values == [SIGUSR1])
    }
}
