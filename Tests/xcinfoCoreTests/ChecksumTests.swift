import Foundation
import Testing
import XCIFoundation
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.
@testable import xcinfoCore

struct ChecksumTests {
    private let content = Data("xar!xip-content".utf8)
    private let sha1 = "8e4a6d65179ce1b5a3ad04a1c6472a744c410621"
    private let wrongSHA1 = "0000000000000000000000000000000000000000"

    private func downloadingCore(logs: LogRecorder, caches: TemporaryDirectory, archive: URL, sha1: String?) -> Core {
        let xcodes = [Xcode.fixture("15.0", build: "15A240d", sha1: sha1)]
        return .test(
            logs: logs,
            isVerbose: true,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            accountName: { "user" },
            authenticate: { _, _ in },
            download: { _, _, _ in archive },
            applicationsDirectory: caches.url
        )
    }

    @Test
    func `the checksum is computed from the file in chunks with progress`() async throws {
        let directory = try TemporaryDirectory()
        let archive = try directory.file("Xcode.xip", contents: content)
        let logs = LogRecorder()

        let checksum = try await ArchiveChecksum(url: archive).sha1(logger: logs.logger())

        #expect(checksum == sha1)
        #expect(logs.progress.last == OutputProgress(title: "Verifying", fraction: 1, detail: "SHA-1 checked", isFinished: true))
    }

    @Test(arguments: [true, false])
    func `a download with the listed checksum succeeds`(isUppercase: Bool) async throws {
        let caches = try TemporaryDirectory()
        let archive = try caches.file("Xcode.xip", contents: content)
        let logs = LogRecorder()
        let core = downloadingCore(logs: logs, caches: caches, archive: archive, sha1: isUppercase ? sha1.uppercased() : sha1)

        let (_, url) = try await core.download(version: .latest, options: .init(destination: caches.url.appendingPathComponent("Downloads"), disableSleep: false), updateVersionList: true)

        #expect(url == archive)
        #expect(logs.messages.contains("SHA-1 \(sha1) matches xcodereleases.com."))
    }

    @Test
    func `a download with another checksum fails as a download error and keeps the file`() async throws {
        let caches = try TemporaryDirectory()
        let archive = try caches.file("Xcode.xip", contents: content)
        let core = downloadingCore(logs: LogRecorder(), caches: caches, archive: archive, sha1: wrongSHA1)

        await #expect {
            try await core.download(version: .latest, options: .init(destination: caches.url.appendingPathComponent("Downloads"), disableSleep: false), updateVersionList: true)
        } throws: { error in
            guard case let CoreError.checksumMismatch(file, expected, actual) = error else { return false }
            return file == archive && expected == wrongSHA1 && actual == sha1
        }
        #expect(FileManager.default.fileExists(atPath: archive.path))
        let error = CoreError.checksumMismatch(file: archive, expected: wrongSHA1, actual: sha1)
        #expect(error.localizedDescription.contains("is corrupt"))
        #expect(error.localizedDescription.contains("--no-verify"))
    }

    @Test
    func `a version without a checksum is not verified`() async throws {
        let caches = try TemporaryDirectory()
        let archive = try caches.file("Xcode.xip", contents: content)
        let logs = LogRecorder()
        let core = downloadingCore(logs: logs, caches: caches, archive: archive, sha1: nil)

        _ = try await core.download(version: .latest, options: .init(destination: caches.url.appendingPathComponent("Downloads"), disableSleep: false), updateVersionList: true)

        #expect(logs.messages.contains("xcodereleases.com has no checksum for Xcode 15.0; skipping the SHA-1 check."))
        #expect(logs.progress.isEmpty)
    }

    @Test
    func `an aea archive is never compared with the xip checksum`() async throws {
        let caches = try TemporaryDirectory()
        let archive = try caches.file("Xcode.aea", contents: Data("AEA1signed".utf8))
        let logs = LogRecorder()
        let core = downloadingCore(logs: logs, caches: caches, archive: archive, sha1: sha1)

        let (_, url) = try await core.download(version: .latest, options: .init(destination: caches.url.appendingPathComponent("Downloads"), disableSleep: false), updateVersionList: true)

        #expect(url == archive)
        #expect(logs.progress.isEmpty)
        #expect(logs.messages.contains("xcodereleases.com lists no SHA-1 for the .aea archive. Its Apple signature is checked during extraction instead."))
    }

    @Test
    func `no verify skips the check`() async throws {
        let caches = try TemporaryDirectory()
        let archive = try caches.file("Xcode.xip", contents: content)
        let logs = LogRecorder()
        let core = downloadingCore(logs: logs, caches: caches, archive: archive, sha1: wrongSHA1)

        _ = try await core.download(
            version: .latest,
            options: .init(destination: caches.url.appendingPathComponent("Downloads"), disableSleep: false, verifiesChecksum: false),
            updateVersionList: true
        )

        #expect(logs.progress.isEmpty)
    }

    @Test(arguments: [true, false])
    func `a supplied archive with another checksum asks before installing`(agrees: Bool) async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let archive = try caches.file("Xcode_15.xip", contents: content)
        let prompt = FakePrompt(agree: agrees, passwords: ["sudo-password"])
        let extractions = Recorder<String>()
        let logs = LogRecorder()
        let xcodes = [Xcode.fixture("15.0", build: "15A240d", sha1: wrongSHA1)]
        let core = Core.test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            extract: { source, destination, filename, _ in
                extractions.append(source.lastPathComponent)
                return destination.appendingPathComponent(filename ?? "Xcode.app")
            },
            shell: FakeShell(),
            prompt: prompt,
            applicationsDirectory: applications.url,
            revealInFinder: { _ in }
        )
        let options = Core.InstallationOptions(
            version: .version("15.0"),
            archiveFile: archive,
            downloadOptions: .init(destination: caches.url.appendingPathComponent("Downloads"), disableSleep: false),
            extractionOptions: .init(destination: applications.url),
            skipSymlinkCreation: true,
            skipXcodeSelection: true,
            shouldPreserveArchive: true
        )

        if agrees {
            try await core.install(options: options, updateVersionList: true)
            #expect(extractions.values == ["Xcode_15.xip"])
        } else {
            await #expect(throws: CoreError.self) {
                try await core.install(options: options, updateVersionList: true)
            }
            #expect(extractions.values.isEmpty)
        }
        #expect(prompt.agreed.values == ["Install from this archive anyway?"])
        #expect(logs.messages.contains { $0.contains("is corrupt") })
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }
}
