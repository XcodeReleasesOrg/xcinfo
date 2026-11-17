import Foundation
import os
import Testing
import XCIFoundation

final class CapturedOutput: Sendable {
    private let standardOutput = OSAllocatedUnfairLock<String>(initialState: "")
    private let standardError = OSAllocatedUnfairLock<String>(initialState: "")

    func renderer(_ options: OutputOptions) -> TerminalRenderer {
        TerminalRenderer(
            options: options,
            standardOutput: { [standardOutput] text in standardOutput.withLock { $0 += text } },
            standardError: { [standardError] text in standardError.withLock { $0 += text } }
        )
    }

    var output: String {
        standardOutput.withLock { $0 }
    }

    var error: String {
        standardError.withLock { $0 }
    }
}

struct TerminalRendererTests {
    private let piped = OutputOptions()
    private let terminal = OutputOptions(isTerminal: true)

    @Test
    func `status goes to standard output and problems to standard error`() {
        let captured = CapturedOutput()
        let renderer = captured.renderer(piped)

        renderer.render(.section("Downloading"))
        renderer.render(.message("Source: https://example.invalid", .plain))
        renderer.render(.message("Careful", .warning))
        renderer.render(.message("Broken", .error))

        #expect(captured.output == "\nDownloading\nSource: https://example.invalid\n")
        #expect(captured.error == "Careful\nBroken\n")
    }

    @Test
    func `verbose messages need verbose output`() {
        let quiet = CapturedOutput()
        quiet.renderer(piped).render(.verbose("details"))
        #expect(quiet.output.isEmpty)

        let verbose = CapturedOutput()
        verbose.renderer(OutputOptions(isVerbose: true)).render(.verbose("details"))
        #expect(verbose.output == "details\n")
    }

    @Test
    func `quiet output keeps results, warnings and errors`() {
        let captured = CapturedOutput()
        let renderer = captured.renderer(OutputOptions(isQuiet: true))

        renderer.render(.section("Installing"))
        renderer.render(.message("Installed", .success))
        renderer.render(.check("Selecting Xcode", .passed))
        renderer.render(.progress(OutputProgress(title: "Downloading", fraction: 0.5, isMilestone: true)))
        renderer.render(.message("Careful", .warning))
        renderer.render(.check("Approving License", .failed))
        renderer.print("result")

        #expect(captured.output == "result\n")
        #expect(captured.error == "Careful\nApproving License ✗\n")
    }

    @Test
    func `json output only keeps errors and the result`() {
        let captured = CapturedOutput()
        let renderer = captured.renderer(OutputOptions(isJSON: true))

        renderer.render(.section("Installing"))
        renderer.render(.message("Careful", .warning))
        renderer.render(.check("Approving License", .failed))
        renderer.render(.message("Broken", .error))
        renderer.print("{}")

        #expect(captured.output == "{}\n")
        #expect(captured.error == "Broken\n")
    }

    @Test
    func `checks print their result when piped`() {
        let captured = CapturedOutput()
        let renderer = captured.renderer(piped)

        renderer.render(.check("Selecting Xcode", .running))
        renderer.render(.check("Selecting Xcode", .passed))

        #expect(captured.output == "Selecting Xcode ✓\n")
    }

    @Test
    func `checks update one line on a terminal`() {
        let captured = CapturedOutput()
        let renderer = captured.renderer(terminal)

        renderer.render(.check("Selecting Xcode", .running))
        renderer.render(.check("Selecting Xcode", .passed))

        #expect(captured.output == "\r\u{1B}[KSelecting Xcode...\r\u{1B}[KSelecting Xcode ✓\n")
    }

    @Test
    func `progress is one updating line on a terminal`() {
        let captured = CapturedOutput()
        let renderer = captured.renderer(terminal)

        renderer.render(.progress(OutputProgress(title: "Downloading", fraction: 0.5, detail: "1 GB remaining")))
        renderer.render(.progress(OutputProgress(title: "Downloading", fraction: 1, detail: "0 bytes remaining")))
        renderer.render(.progress(OutputProgress(title: "Downloading", fraction: 1, detail: "done", isFinished: true)))

        #expect(captured.output == "\r\u{1B}[KDownloading: [██████████          ] 50.0% 1 GB remaining"
            + "\r\u{1B}[KDownloading: [████████████████████] 100.0% 0 bytes remaining"
            + "\r\u{1B}[KDownloading: [████████████████████] 100.0% done\n")
    }

    @Test
    func `progress prints milestones when piped`() {
        let captured = CapturedOutput()
        let renderer = captured.renderer(piped)

        renderer.render(.progress(OutputProgress(title: "Extracting", fraction: 0.05)))
        renderer.render(.progress(OutputProgress(title: "Extracting", fraction: 0.1, isMilestone: true)))
        renderer.render(.progress(OutputProgress(title: "Extracting", fraction: 0.15)))
        renderer.render(.progress(OutputProgress(title: "Extracting", fraction: 1, detail: "done", isFinished: true)))

        #expect(captured.output == "Extracting: 10 %\nExtracting: 100 %, done\n")
    }

    @Test
    func `colors are only used when enabled`() {
        let plain = CapturedOutput()
        plain.renderer(piped).render(.message("Broken", .error))
        #expect(plain.error == "Broken\n")
    }

    @Test(arguments: [
        (true, [String: String](), true, true),
        (true, ["NO_COLOR": "1"], true, false),
        (true, ["TERM": "dumb"], true, false),
        (false, [:], true, false),
        (true, [:], false, false),
    ])
    func `colors follow the terminal, NO_COLOR and the ansi flag`(isTerminal: Bool, environment: [String: String], allowsColors: Bool, expected: Bool) {
        let options = OutputOptions.detect(
            isVerbose: false,
            isQuiet: false,
            isJSON: false,
            allowsColors: allowsColors,
            environment: environment,
            isTerminal: isTerminal
        )

        #expect(options.usesColors == expected)
        #expect(options.isTerminal == isTerminal)
    }

    @Test
    func `json output never uses colors`() {
        let options = OutputOptions.detect(isVerbose: false, isQuiet: false, isJSON: true, allowsColors: true, environment: [:], isTerminal: true)

        #expect(!options.usesColors)
    }
}
