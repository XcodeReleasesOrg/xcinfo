import Foundation
import Testing
import XCIFoundation
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.
@testable import xcinfo
@testable import xcinfoCore

struct NonInteractiveTests {
    private let xcodes = [Xcode.fixture("15.0", build: "15A240d", release: .beta(1)), .fixture("15.0", build: "15A507", release: .beta(2))]

    @Test
    func `the flag is parsed for every command`() throws {
        #expect(try XCInfo.List.parse(["--non-interactive"]).globals.isNonInteractive)
        #expect(try XCInfo.Install.parse(["15.0", "--non-interactive"]).globals.isNonInteractive)
        #expect(try !XCInfo.Download.parse(["15.0"]).globals.isNonInteractive)
    }

    @Test
    func `an unanswerable question names the question and the choices and exits with 10`() {
        let error = PromptUnavailable(question: "Please choose the version you want to install: ", choices: ["15.0 (15A240d)", "15.0.1 (15A507)"])

        #expect(error.exitCode == 10)
        let description = error.localizedDescription
        #expect(description.contains("\"Please choose the version you want to install:\""))
        #expect(description.contains("  15.0 (15A240d)\n  15.0.1 (15A507)"))
        #expect(description.contains("--non-interactive"))
    }

    @Test
    func `every question fails at once`() async {
        let prompt = PromptClient.unavailable
        await #expect(throws: PromptUnavailable(question: "Continue?")) { try await prompt.agree("Continue?") }
        await #expect(throws: PromptUnavailable(question: "Pick:", choices: ["a"])) { try await prompt.choose("Pick:", ["a"]) }
        await #expect(throws: PromptUnavailable(question: "Code:")) { try await prompt.ask("Code:", "", { _ in false }) }
        await #expect(throws: PromptUnavailable(question: "Apple ID (email):")) { try await prompt.readLine("Apple ID (email):") }
        await #expect(throws: PromptUnavailable(question: "Password:")) { try await prompt.readSecret("Password:") }
    }

    @Test
    func `an ambiguous version fails instead of asking`() async throws {
        let caches = try TemporaryDirectory()
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { [xcodes] in xcodes },
            promptClient: .unavailable,
            applicationsDirectory: caches.url
        )

        await #expect(throws: PromptUnavailable(question: "Please choose the version you want to install: ", choices: ["15.0 Beta 1 (15A240d)", "15.0 Beta 2 (15A507)"])) {
            try await core.info(version: .version("15 beta"), shouldUpdate: true)
        }
    }

    @Test
    func `uninstall fails instead of asking and keeps the xcode`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let app = try applications.fakeXcode(named: "Xcode-15.app", build: "15A240d")
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { [xcodes] in xcodes },
            shell: .installedXcodes([app]),
            promptClient: .unavailable,
            applicationsDirectory: applications.url,
            trashItem: { _ in
                Issue.record("Must not move anything to the Trash")
                return nil
            }
        )

        await #expect(throws: PromptUnavailable.self) {
            try await core.uninstall("15.0 beta 1", updateVersionList: true)
        }
        #expect(FileManager.default.fileExists(atPath: app.path))
    }

    @Test
    func `as root the privileged steps run without asking for a password`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let app = try applications.fakeXcode(named: "Xcode-15.app", build: "15A240d")
        let shell = FakeShell(isRoot: true) { call in
            call.command == "mdfind" ? (0, app.path + "\n", "") : (0, "", "")
        }
        let logs = LogRecorder()
        let core = Core.test(
            logs: logs,
            isVerbose: true,
            cachesDirectory: caches.url,
            listXcodes: { [xcodes] in xcodes },
            shell: shell,
            promptClient: .unavailable,
            applicationsDirectory: applications.url
        )

        try await core.switchXcode(to: "15.0 beta 1", options: .init(skipSymlinkCreation: true), updateVersionList: true)

        #expect(shell.privilegedCalls.map(\.command) == ["xcode-select"])
        #expect(shell.privilegedCalls.allSatisfy { $0.password == "" })
        #expect(logs.messages.contains("Running as root, so the privileged steps run without sudo."))
        #expect(!logs.messages.contains { $0.contains("needs administrator rights") })
    }
}
