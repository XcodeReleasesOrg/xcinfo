import Foundation
import os
import Testing
import XCIFoundation

final class ScriptedConsole: Sendable {
    private let input: OSAllocatedUnfairLock<[String]>
    private let output = OSAllocatedUnfairLock<String>(initialState: "")

    init(_ lines: [String]) {
        input = OSAllocatedUnfairLock(initialState: lines)
    }

    var console: ConsolePrompt {
        ConsolePrompt(
            read: { [input] in input.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
            write: { [output] text, terminator in output.withLock { $0 += text + terminator } }
        )
    }

    var written: String {
        output.withLock { $0 }
    }
}

struct PromptTests {
    @Test
    func `ask repeats until the answer is valid`() {
        let script = ScriptedConsole(["123", "123456"])

        let answer = script.console.ask("Code:", invalidMessage: "Invalid code length") { $0.count != 6 }

        #expect(answer == "123456")
        #expect(script.written == "Code:\nInvalid code length\n?  ")
    }

    @Test
    func `choose lists numbered choices and accepts a number`() {
        let script = ScriptedConsole(["2"])

        let index = script.console.choose("Pick one: ", choices: ["first", "second"])

        #expect(index == 1)
        #expect(script.written == "1. first\n2. second\nPick one: ")
    }

    @Test
    func `choose accepts the text of a choice`() {
        let script = ScriptedConsole(["second"])

        #expect(script.console.choose("Pick one: ", choices: ["first", "second"]) == 1)
    }

    @Test
    func `choose repeats on an invalid choice`() {
        let script = ScriptedConsole(["3", "1"])

        let index = script.console.choose("Pick one: ", choices: ["first", "second"])

        #expect(index == 0)
        #expect(script.written.contains("You must choose one of [1, 2, first, second].\n?  "))
    }

    @Test(arguments: [
        (["y"], true),
        (["Yes"], true),
        (["n"], false),
        (["No"], false),
        (["maybe", "yes"], true),
    ])
    func `agree accepts yes and no`(input: [String], expected: Bool) {
        let script = ScriptedConsole(input)

        #expect(script.console.agree("Continue?") == expected)
        #expect(script.written.hasPrefix("Continue?  "))
    }

    @Test
    func `agree asks again on an invalid answer`() {
        let script = ScriptedConsole(["maybe", "n"])

        _ = script.console.agree("Continue?")

        #expect(script.written == "Continue?  Please enter \"yes\" or \"no\".\nContinue?  ")
    }

    @Test
    func `the end of the input stops asking`() {
        let script = ScriptedConsole([])

        #expect(!script.console.agree("Continue?"))
        #expect(script.console.ask("Code:", invalidMessage: "Invalid") { $0.isEmpty } == "")
    }

    @Test
    func `read line shows the prompt on the same line`() {
        let script = ScriptedConsole(["user@example.invalid"])

        #expect(script.console.readLine("Username:") == "user@example.invalid")
        #expect(script.written == "Username: ")
    }
}
