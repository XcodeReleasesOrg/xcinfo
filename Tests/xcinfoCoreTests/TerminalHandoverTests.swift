import Foundation
import Testing
import XCIFoundation
@testable import xcinfo
@testable import xcinfoCore
@testable import XCInfoTUI

private final class FakeTerminal: TerminalControl, Sendable {
    let calls = Recorder<String>()
    func enter() {
        calls.append("enter")
    }

    func leave() {
        calls.append("leave")
    }

    func enterRawMode() {
        calls.append("raw")
    }

    func leaveRawMode() {
        calls.append("cooked")
    }

    func discardInput() {
        calls.append("discard")
    }

    var modeDescription: String {
        "fake terminal"
    }
}

struct TerminalHandoverTests {
    @Test
    func `the terminal goes to cooked mode for the read and comes back raw with input discarded`() async throws {
        let terminal = FakeTerminal()
        let gate = KeyReaderGate()
        let (inputs, input) = AsyncStream.makeStream(of: TUIInput.self)
        let session = TUISession(input: input, questions: TUIQuestionBox(input: input))

        async let result = session.withTerminalReleased(leavingFullScreen: false, message: "Waiting") { state in
            terminal.calls.append("read with \(state)")
            return 42
        }
        var iterator = inputs.makeAsyncIterator()
        guard case let .releaseTerminal(release) = await iterator.next() else { Issue.record("Expected a release")
            return
        }
        await terminal.handOver(release, gate: gate)
        #expect(await gate.isPaused)
        guard case let .reacquireTerminal(back) = await iterator.next() else { Issue.record("Expected a reacquire")
            return
        }
        await terminal.takeBack(back, gate: gate)

        #expect(try await result == 42)
        #expect(terminal.calls.values == ["cooked", "read with fake terminal", "raw", "discard"])
        #expect(await !gate.isPaused)
    }

    @Test
    func `the keychain is read once with a handover, cached afterwards, and a retry leaves full screen`() async throws {
        let (inputs, input) = AsyncStream.makeStream(of: TUIInput.self)
        let session = TUISession(input: input, questions: TUIQuestionBox(input: input))
        let terminal = FakeTerminal()
        let gate = KeyReaderGate()
        let events = Recorder<String>()
        let loads = Recorder<Bool>()
        let live = KeychainClient(
            load: { await loads.append(gate.isPaused)
                return VaultContents(accountName: "user")
            },
            reload: { await loads.append(gate.isPaused)
                return VaultContents(accountName: "user")
            },
            stage: { _ in },
            commit: { _ in }
        )
        let client = live.handingOverTerminal(to: session, logsState: false, firstUse: FirstUse())

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in inputs {
                    switch event {
                    case let .releaseTerminal(release):
                        events.append(release.leavesFullScreen ? "leave full screen" : "cooked")
                        await terminal.handOver(release, gate: gate)
                    case let .reacquireTerminal(release):
                        await terminal.takeBack(release, gate: gate)
                        events.append("back")
                    default:
                        break
                    }
                }
            }
            _ = try await client.load()
            _ = try await client.load()
            _ = try await client.reload()
            input.finish()
            try await group.waitForAll()
        }

        #expect(loads.values == [true, false, true])
        #expect(events.values == ["cooked", "back", "leave full screen", "back"])
        #expect(terminal.calls.values == ["cooked", "raw", "discard", "leave", "enter", "discard"])
    }
}
