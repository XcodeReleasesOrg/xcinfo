import Foundation
import Testing
import XCIFoundation
@testable import XCInfoTUI

struct TUISessionTests {
    private func next(_ iterator: inout AsyncStream<TUIInput>.Iterator) async -> TUIInput? {
        await iterator.next()
    }

    @Test
    func `output is passed to the screen as typed events`() async {
        let (inputs, input) = AsyncStream.makeStream(of: TUIInput.self)
        let session = TUISession(input: input, questions: TUIQuestionBox(input: input))
        var iterator = inputs.makeAsyncIterator()

        session.logger.log("Hello")

        guard case let .output(event) = await next(&iterator) else {
            Issue.record("Expected output")
            return
        }
        #expect(event == .message("Hello", .plain))
    }

    @Test
    func `a secret question opens a dialog and returns the typed answer`() async {
        let (inputs, input) = AsyncStream.makeStream(of: TUIInput.self)
        let box = TUIQuestionBox(input: input)
        let session = TUISession(input: input, questions: box)
        var iterator = inputs.makeAsyncIterator()

        async let password = session.prompt.readSecret("Apple ID password for user (not your Mac password):")
        guard case let .question(question) = await next(&iterator), case let .text(prompt, isSecret, _, _) = question else {
            Issue.record("Expected a text question")
            return
        }
        #expect(prompt == "Apple ID password for user (not your Mac password):")
        #expect(isSecret)
        await box.answer(.text("secret"))

        #expect(await password == "secret")
    }

    @Test
    func `choices and questions return the selected answer`() async {
        let (inputs, input) = AsyncStream.makeStream(of: TUIInput.self)
        let box = TUIQuestionBox(input: input)
        let session = TUISession(input: input, questions: box)
        var iterator = inputs.makeAsyncIterator()

        async let index = session.prompt.choose("Choose:", ["a", "b"])
        _ = await next(&iterator)
        await box.answer(.choice(1))
        #expect(await index == 1)

        async let agreed = session.prompt.agree("Sure?")
        _ = await next(&iterator)
        await box.answer(.confirm(true))
        #expect(await agreed)
    }

    @Test
    func `cancelling answers the open question and every later one without asking`() async {
        let (inputs, input) = AsyncStream.makeStream(of: TUIInput.self)
        let box = TUIQuestionBox(input: input)
        let session = TUISession(input: input, questions: box)
        var iterator = inputs.makeAsyncIterator()

        async let password = session.prompt.readSecret("Mac administrator password for user (sudo):")
        _ = await next(&iterator)
        await box.cancel()

        #expect(await password == "")
        #expect(await session.prompt.agree("Install from this archive anyway?") == false)
        #expect(await session.prompt.choose("Choose:", ["a"]) == 0)
    }

    @Test
    func `a flood of output events never makes the producer wait`() {
        let (inputs, input) = AsyncStream.makeStream(of: TUIInput.self)
        let session = TUISession(input: input, questions: TUIQuestionBox(input: input))
        let start = ContinuousClock.now

        for index in 0 ..< 100_000 {
            session.logger.verbose("Extracted: file \(index)")
        }

        #expect(start.duration(to: .now) < .seconds(2))
        _ = inputs
    }

    @Test
    func `hidden detail lines cost nothing in the activity`() {
        var activity = TUIActivity(title: "Installing", steps: ["Extract"])
        let start = ContinuousClock.now

        for index in 0 ..< 100_000 {
            activity.apply(.verbose("Extracted: file \(index)"))
        }

        #expect(activity.lines.isEmpty)
        #expect(start.duration(to: .now) < .seconds(2))
    }
}
