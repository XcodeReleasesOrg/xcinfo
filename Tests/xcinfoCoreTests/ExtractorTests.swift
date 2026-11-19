import Foundation
import Testing
@testable import xcinfoCore

@Suite(.timeLimit(.minutes(1)))
struct ExtractorTests {
    @Test
    func `a broken archive fails without changing the working directory`() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.file("Broken.xip", contents: Data("not a xip archive".utf8))
        let output = try directory.directory("Output")
        let workingDirectory = FileManager.default.currentDirectoryPath

        await #expect(throws: (any Error).self) {
            try await Unxip(input: source, output: output, logger: LogRecorder().logger()).extract(progress: nil)
        }

        #expect(FileManager.default.currentDirectoryPath == workingDirectory)
    }

    @Test
    func `a failed extraction removes its temporary folder`() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.file("Broken.xip", contents: Data("not a xip archive".utf8))
        let temporary = try directory.directory("Temporary")
        let extractor = Extractor(
            forReadingFromContainerAt: source,
            destination: directory.url,
            appFilename: nil,
            temporaryDirectory: temporary,
            logger: LogRecorder().logger()
        )

        await #expect(throws: (any Error).self) {
            try await extractor.extractXIP()
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
    }

    @Test
    func `reading an archive reports its progress`() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.file("Data.bin", contents: Data(repeating: 7, count: 100_000))
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let progress = Recorder<Double>()

        var chunks = FileChunks(handle: handle, total: 100_000, progress: { progress.append($0) })
        chunks.chunkSize = 30_000
        var bytes = 0
        for try await chunk in chunks {
            bytes += chunk.count
        }

        #expect(bytes == 100_000)
        #expect(progress.values == [0.3, 0.6, 0.9, 1.0])
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
}
