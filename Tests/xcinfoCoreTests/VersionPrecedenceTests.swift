import Foundation
import Testing
@testable import xcinfoCore
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has immutable value types without Sendable annotations.

struct VersionPrecedenceTests {
    private let xcodes = [
        Xcode.fixture("26.7", build: "17G5", release: .beta(1)),
        .fixture("26.6.1", build: "17F200"),
        .fixture("26.6", build: "17F113"),
        .fixture("26.6", build: "17F113", release: .rc(2)),
        .fixture("26.6", build: "17F109", release: .rc(1)),
        .fixture("26.5", build: "17F42"),
        .fixture("27.0", build: "27A5", release: .beta(3)),
        .fixture("27.0", build: "27A4", release: .beta(2))
    ]

    private func identify(_ version: String, prompt: FakePrompt = FakePrompt()) async throws -> (Xcode, LogRecorder) {
        let caches = try TemporaryDirectory()
        let logs = LogRecorder()
        let core = Core.test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { [xcodes] in xcodes },
            prompt: prompt,
            applicationsDirectory: caches.url
        )
        return try await (core.info(version: .version(version), shouldUpdate: true), logs)
    }

    @Test(arguments: [
        ("26.6", "26.6 (17F113)", "Using Xcode 26.6 (17F113), the final release. Use '26.6 RC 2' for a release candidate."),
        ("26", "26.6.1 (17F200)", "Using Xcode 26.6.1 (17F200), the newest final release of Xcode 26."),
        ("26.6 RC 2", "26.6 RC 2 (17F113)", nil),
        ("26.6 rc2", "26.6 RC 2 (17F113)", nil),
        ("26.6 rc 1", "26.6 RC 1 (17F109)", nil),
        ("17F109", "26.6 RC 1 (17F109)", nil),
        ("27", "27.0 Beta 3 (27A5)", "Using Xcode 27.0 Beta 3 (27A5), the newest pre-release of 27; there is no final release yet."),
        ("27.0 beta 2", "27.0 Beta 2 (27A4)", nil)
    ] as [(String, String, String?)])
    func `a version without a qualifier means the final release`(version: String, expected: String, message: String?) async throws {
        let prompt = FakePrompt()
        let (xcode, logs) = try await identify(version, prompt: prompt)

        #expect(xcode.displayName == expected)
        #expect(prompt.chosen.values.isEmpty)
        if let message {
            #expect(logs.messages.contains(message))
        }
    }

    @Test
    func `a qualifier without a number still asks`() async throws {
        let prompt = FakePrompt(choices: [1])
        let (xcode, _) = try await identify("27 beta", prompt: prompt)

        #expect(prompt.chosen.values == [["27.0 Beta 3 (27A5)", "27.0 Beta 2 (27A4)"]])
        #expect(xcode.displayName == "27.0 Beta 2 (27A4)")
    }
}
