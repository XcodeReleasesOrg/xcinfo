import Foundation
import Testing
@testable import xcinfoCore

struct ExtractorTests {
    @Test(.disabled("Hangs: libunxip reads the archive through DispatchIO on the main queue, which the test runner does not service. Known issue to check once runnable: the working directory is not restored when extraction fails"))
    func `a broken archive fails and the working directory is restored`() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.file("Broken.xip", contents: Data("not a xip archive".utf8))
        let output = try directory.directory("Output")
        let workingDirectory = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(workingDirectory) }

        await #expect(throws: (any Error).self) {
            try await Unxip(input: source, output: output, logger: LogRecorder().logger()).extract(progress: nil)
        }

        let directoryAfterFailure = FileManager.default.currentDirectoryPath
        withKnownIssue("The working directory is not restored when extraction fails") {
            #expect(directoryAfterFailure == workingDirectory)
        }
    }

    @Test
    func `an output folder that does not exist is rejected`() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.file("Broken.xip", contents: Data("not a xip archive".utf8))
        let missing = directory.url.appendingPathComponent("missing")

        await #expect {
            try await Unxip(input: source, output: missing, logger: LogRecorder().logger()).extract(progress: nil)
        } throws: { error in
            guard case let CoreError.invalidExtractionOutputURL(url) = error else { return false }
            return url == missing
        }
    }

    @Test(.disabled("Crashes the process: the legacy extractor force-unwraps the container after PKSignedContainer fails to open the archive"))
    func `the legacy extractor rejects a broken archive`() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.file("Broken.xip", contents: Data("not a xip archive".utf8))
        let extractor = Extractor(forReadingFromContainerAt: source, destination: directory.url, appFilename: nil, logger: LogRecorder().logger())

        await #expect(throws: (any Error).self) {
            try await extractor.extract()
        }
    }
}
