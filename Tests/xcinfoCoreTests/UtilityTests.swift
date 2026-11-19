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
        (0.999, "[███████████████████▉] 99.9%")
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
        measurements.append(1_000)
        try await Task.sleep(nanoseconds: 50_000_000)
        measurements.append(1_000)

        let speed = measurements.averageSpeed()
        #expect(speed > 0)
        #expect(speed < 2_000 / 0.05)
    }
}

struct ProcessRunnerTests {
    @Test
    func `run captures standard output and the exit status`() async throws {
        let result = try await ProcessRunner.run("echo", arguments: ["hello", "world"])

        #expect(result.exitStatus == 0)
        #expect(result.stdout == "hello world\n")
        #expect(result.stderr.isEmpty)
    }

    @Test
    func `run reports a failing exit status`() async throws {
        #expect(try await ProcessRunner.run("false", arguments: []).exitStatus == 1)
    }

    @Test
    func `run captures standard error`() async throws {
        let result = try await ProcessRunner.run("ls", arguments: ["/nonexistent-xcinfo-test-path"])

        #expect(result.exitStatus != 0)
        #expect(result.stderr.contains("nonexistent-xcinfo-test-path"))
    }

    @Test
    func `run reads large output without blocking`() async throws {
        let result = try await ProcessRunner.run("sh", arguments: ["-c", "yes | head -n 200000; yes error | head -n 100000 >&2"])

        #expect(result.exitStatus == 0)
        #expect(result.stdout.count == 400_000)
        #expect(result.stderr.count == 600_000)
    }

    @Test
    func `live process client forwards to the runner`() async throws {
        let result = try await ProcessClient.liveValue.run("printf", ["%s", "xcinfo"])

        #expect(result.stdout == "xcinfo")
    }
}

struct LoggerTests {
    @Test
    func `log levels emit typed events`() {
        let logs = LogRecorder()
        let logger = logs.logger()

        logger.log("plain")
        logger.success("success")
        logger.error("error")
        logger.warn("warning")
        logger.emphasized("emphasized")
        logger.verbose("details")
        logger.beginSection("Section")
        logger.beginParagraph("Paragraph")
        logger.check("Step", .passed)
        logger.progress(OutputProgress(title: "Downloading", fraction: 0.5))

        #expect(logs.events == [
            .message("plain", .plain),
            .message("success", .success),
            .message("error", .error),
            .message("warning", .warning),
            .message("emphasized", .emphasized),
            .verbose("details"),
            .section("Section"),
            .paragraph("Paragraph"),
            .check("Step", .passed),
            .progress(OutputProgress(title: "Downloading", fraction: 0.5))
        ])
    }
}

struct ExtensionTests {
    @Test(arguments: [
        ("abc", 5, "abc  "),
        ("abc", 3, "abc"),
        ("abcdef", 3, "abcdef"),
        ("", 2, "  ")
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
