import Foundation
import Testing
import XCIFoundation
@testable import xcinfoCore

struct ProgressDisplayTests {
    @Test(arguments: [
        (0.0, "[                    ] 0.0%"),
        (0.5, "[██████████          ] 50.0%"),
        (0.25, "[█████               ] 25.0%"),
        (0.123, "[██▍                 ] 12.3%"),
        (0.999, "[███████████████████▉] 99.9%"),
    ])
    func `progress is drawn as a bar with a percentage`(ratio: Double, expected: String) {
        let display = ProgressDisplay(ratio: ratio, width: 20)

        #expect(display.representation.strippingANSI == expected)
    }

    @Test(arguments: [1.0, 1.5])
    func `complete progress shows a full bar`(ratio: Double) {
        #expect(ProgressDisplay(ratio: ratio, width: 10).representation == "[██████████] 100.0%")
    }

    @Test
    func `negative progress shows an empty bar`() {
        let representation = ProgressDisplay(ratio: -0.5, width: 4).representation.strippingANSI

        #expect(representation.hasPrefix("[    ]"))
    }
}

struct SpeedMeasurementsTests {
    @Test
    func `speed is unknown with fewer than two measurements`() {
        var measurements = SpeedMeasurements()
        #expect(measurements.averageSpeed() == -1)

        measurements.append(100)
        #expect(measurements.averageSpeed() == -1)
    }

    @Test
    func `speed is the sum of the bytes over the elapsed time`() async throws {
        var measurements = SpeedMeasurements()
        measurements.append(1000)
        try await Task.sleep(nanoseconds: 50_000_000)
        measurements.append(1000)

        let speed = measurements.averageSpeed()
        #expect(speed > 0)
        #expect(speed < 2000 / 0.05)
    }
}

struct ShellTests {
    @Test
    func `execute captures standard output and the exit status`() {
        let result = Shell.execute("echo", args: "hello", "world")

        #expect(result.exitStatus == 0)
        #expect(result.stdout == "hello world\n")
        #expect(result.stderr.isEmpty)
    }

    @Test
    func `execute reports a failing exit status`() {
        #expect(Shell.execute("false").exitStatus == 1)
    }

    @Test
    func `execute captures standard error`() {
        let result = Shell.execute("ls", args: ["/nonexistent-xcinfo-test-path"])

        #expect(result.exitStatus != 0)
        #expect(result.stderr.contains("nonexistent-xcinfo-test-path"))
    }

    @Test
    func `live shell client forwards to the shell`() {
        let result = ShellClient.live.execute("printf", ["%s", "xcinfo"])

        #expect(result.stdout == "xcinfo")
    }
}

struct LoggerTests {
    @Test
    func `log levels write their message`() {
        let logs = LogRecorder()
        let logger = logs.logger()

        logger.log("plain")
        logger.success("success")
        logger.error("error")
        logger.warn("warning")
        logger.emphasized("emphasized")

        #expect(logs.messages == ["plain", "success", "error", "warning", "emphasized"])
    }

    @Test
    func `sections and paragraphs start on a new line`() {
        let logs = LogRecorder()
        let logger = logs.logger()

        logger.beginSection("Section")
        logger.beginParagraph("Paragraph")

        #expect(logs.messages == ["\nSection", "\nParagraph"])
    }

    @Test
    func `verbose messages are written only when verbose`() {
        let quiet = LogRecorder()
        quiet.logger(isVerbose: false).verbose("details")
        #expect(quiet.messages.isEmpty)

        let verbose = LogRecorder()
        verbose.logger(isVerbose: true).verbose("details")
        #expect(verbose.messages == ["details"])
    }

    @Test
    func `same line messages move the cursor up and clear the line`() {
        let logs = LogRecorder()
        let logger = logs.logger(isVerbose: true)

        logger.log("progress", onSameLine: true)
        logger.verbose("detail", onSameLine: true)
        logger.error("failure", onSameLine: true)
        logger.warn("warning", onSameLine: true)
        logger.log("next line")

        let prefix = "\u{1B}[1A\u{1B}[K"
        #expect(logs.rawMessages[0] == prefix + "progress")
        #expect(logs.rawMessages[1] == prefix + "detail")
        #expect(logs.rawMessages[2].hasPrefix(prefix))
        #expect(logs.rawMessages[3].hasPrefix(prefix))
        #expect(logs.rawMessages[4] == "next line")
    }

    @Test
    func `success ignores the same line flag`() {
        let logs = LogRecorder()

        logs.logger().success("done", onSameLine: true)

        #expect(!logs.rawMessages[0].hasPrefix("\u{1B}[1A"))
    }
}

struct ExtensionTests {
    @Test(arguments: [
        ("abc", 5, "abc  "),
        ("abc", 3, "abc"),
        ("abcdef", 3, "abcdef"),
        ("", 2, "  "),
    ])
    func `strings are padded with spaces`(string: String, length: Int, expected: String) {
        #expect(string.paddedWithSpaces(to: length) == expected)
    }

    @Test
    func `safe subscript returns nil outside the bounds`() {
        let array = [1, 2, 3]

        #expect(array[safe: 0] == 1)
        #expect(array[safe: 2] == 3)
        #expect(array[safe: 3] == nil)
        #expect(array[safe: -1] == nil)
    }

    @Test
    func `symbolic links are detected`() throws {
        let directory = try TemporaryDirectory()
        let target = try directory.file("target")
        let link = directory.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(FileManager.default.isSymbolicLink(atPath: link.path))
        #expect(!FileManager.default.isSymbolicLink(atPath: target.path))
        #expect(!FileManager.default.isSymbolicLink(atPath: directory.url.appendingPathComponent("missing").path))
    }

    @Test
    func `missing folders are created`() throws {
        let directory = try TemporaryDirectory()
        let nested = directory.url.appendingPathComponent("a/b/c")

        try FileManager.default.ensureFolderExists(nested)
        try FileManager.default.ensureFolderExists(nested)

        #expect(nested.isReachable)
        #expect(!directory.url.appendingPathComponent("missing").isReachable)
    }
}
