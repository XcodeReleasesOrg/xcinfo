import AppleArchive
import CryptoKit
import Foundation
import System
import Testing
import XCIFoundation
@testable import xcinfoCore

enum AEAFixture {
    static func url(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/AEA"))
    }

    static var trust: AEASigningTrust {
        get throws {
            let pem = try String(contentsOf: url("root.pem"), encoding: .utf8)
            let body = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----")[1].components(separatedBy: "-----END CERTIFICATE-----")[0]
            let der = try #require(Data(base64Encoded: body, options: .ignoreUnknownCharacters))
            return AEASigningTrust(
                anchors: [der],
                rootName: "XCInfo Test Root",
                rootSHA256: SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined(),
                intermediateCommonName: "XCInfo Test Signing CA"
            )
        }
    }
}

struct ArchiveFormatTests {
    @Test(arguments: [
        ("xar!rest", ArchiveFormat?.some(.xip)),
        ("AEA1rest", .some(.aea)),
        ("PK\u{3}\u{4}", nil),
        ("xar", nil),
        ("", nil),
    ])
    func `the format is detected from the first bytes`(contents: String, format: ArchiveFormat?) throws {
        let directory = try TemporaryDirectory()
        let file = try directory.file("archive.xip", contents: Data(contents.utf8))

        #expect(ArchiveFormat(contentsOf: file) == format)
    }

    @Test
    func `a real fixture archive is detected as aea whatever its name`() throws {
        let directory = try TemporaryDirectory()
        let renamed = directory.url.appendingPathComponent("Xcode.xip")
        try FileManager.default.copyItem(at: AEAFixture.url("signed.aea"), to: renamed)

        #expect(ArchiveFormat(contentsOf: renamed) == .aea)
    }
}

struct AEAAuthDataTests {
    @Test
    func `key value entries are read`() throws {
        func entry(_ key: String, _ value: String) -> Data {
            let body = Data(key.utf8) + Data([0]) + Data(value.utf8)
            let size = UInt32(body.count + 4)
            return withUnsafeBytes(of: size.littleEndian) { Data($0) } + body
        }

        let authData = try AEAAuthData(entry("a", "one") + entry("b", "two"))

        #expect(authData.entries == ["a": Data("one".utf8), "b": Data("two".utf8)])
    }

    @Test(arguments: [Data([1, 2]), Data([200, 0, 0, 0, 65])])
    func `malformed auth data is rejected`(data: Data) {
        #expect(throws: AEAError.malformedAuthData) { try AEAAuthData(data) }
    }
}

struct AEAExtractionTests {
    private struct Fixture {
        let directory: TemporaryDirectory
        let destination: URL
        let logs = LogRecorder()

        init() throws {
            directory = try TemporaryDirectory()
            destination = directory.url.appendingPathComponent("Applications")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        func extractor(_ name: String) throws -> Extractor {
            let source = directory.url.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: AEAFixture.url(name), to: source)
            }
            return Extractor(
                forReadingFromContainerAt: source,
                destination: destination,
                appFilename: "Xcode_99.0.app",
                temporaryDirectory: directory.url.appendingPathComponent("tmp"),
                logger: logs.logger()
            )
        }

        var leftovers: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: directory.url.appendingPathComponent("tmp").path)) ?? []
        }
    }

    @Test
    func `a signed archive with a trusted chain is extracted with progress`() async throws {
        let fixture = try Fixture()

        let app = try await fixture.extractor("signed.aea").extractAEA(trust: AEAFixture.trust, archiveUtility: { _, _ in
            Issue.record("archiveutil must not run for a signed archive")
            return ProcessResult(exitStatus: 1)
        })

        #expect(app.path == fixture.destination.appendingPathComponent("Xcode_99.0.app").path)
        #expect(Bundle(url: app)?.bundleIdentifier == "com.apple.dt.Xcode")
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/payload.txt"), encoding: .utf8) == "payload\n")
        #expect(fixture.logs.progress.last == OutputProgress(title: "Extracting", fraction: 1, isFinished: true))
        #expect(fixture.leftovers.isEmpty)
        #expect(fixture.logs.messages.contains("The archive is signed by a certificate that leads to XCInfo Test Root."))
        #expect(fixture.logs.messages.contains { $0.hasPrefix("Extracting the .aea archive into a temporary folder: ") })
        let source = fixture.directory.url.appendingPathComponent("signed.aea")
        #expect(try Data(contentsOf: source) == Data(contentsOf: AEAFixture.url("signed.aea")))
    }

    @Test
    func `a chain that does not lead to the trusted root fails closed`() async throws {
        let fixture = try Fixture()

        await #expect {
            try await fixture.extractor("signed.aea").extractAEA(trust: .apple, archiveUtility: { _, _ in
                Issue.record("archiveutil must not run after a failed trust check")
                return ProcessResult(exitStatus: 0)
            })
        } throws: { error in
            guard case AEAError.untrusted = error else { return false }
            return true
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
        #expect(fixture.leftovers.isEmpty)
    }

    @Test
    func `an archive signed by another key than its certificate fails closed`() async throws {
        let fixture = try Fixture()

        await #expect(throws: AEAError.invalidSignature) {
            try await fixture.extractor("wrong-signer.aea").extractAEA(trust: AEAFixture.trust, archiveUtility: { _, _ in
                Issue.record("archiveutil must not run after a failed signature check")
                return ProcessResult(exitStatus: 0)
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    }

    @Test
    func `another profile without archiveutil fails with a clear message`() async throws {
        let fixture = try Fixture()

        await #expect {
            try await fixture.extractor("symmetric.aea").extractAEA(trust: AEAFixture.trust, archiveUtility: nil)
        } throws: { error in
            guard case let AEAError.archiveUtilityUnavailable(profile) = error else { return false }
            return profile.contains("symmetric") && error.localizedDescription.contains("macOS 15")
        }
    }

    @Test
    func `another profile is extracted with archiveutil in the private working folder`() async throws {
        let fixture = try Fixture()
        let calls = Recorder<String>()
        let source = fixture.directory.url.appendingPathComponent("symmetric.aea")

        let app = try await fixture.extractor("symmetric.aea").extractAEA(trust: AEAFixture.trust) { archive, workingDirectory in
            calls.append(archive.path)
            let contents = workingDirectory.appendingPathComponent("Xcode.app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.dt.Xcode"], format: .xml, options: 0)
            try info.write(to: contents.appendingPathComponent("Info.plist"))
            return ProcessResult(exitStatus: 0, stdout: "Extraction completed to: \(workingDirectory.path)\n")
        }

        #expect(calls.values == [source.path])
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(app.path == fixture.destination.appendingPathComponent("Xcode_99.0.app").path)
        #expect(fixture.logs.messages.contains("Extracting with archiveutil ✓"))
        #expect(fixture.leftovers.isEmpty)
    }

    @Test
    func `an archiveutil failure is reported with its output`() async throws {
        let fixture = try Fixture()

        await #expect(throws: AEAError.archiveUtilityFailed("Inappropriate file type or format")) {
            try await fixture.extractor("symmetric.aea").extractAEA(trust: AEAFixture.trust) { _, _ in
                ProcessResult(exitStatus: 1, stderr: "Inappropriate file type or format\n")
            }
        }
    }

    @Test
    func `an archive without exactly one xcode app is rejected`() async throws {
        let fixture = try Fixture()

        await #expect {
            try await fixture.extractor("symmetric.aea").extractAEA(trust: AEAFixture.trust) { _, workingDirectory in
                try FileManager.default.createDirectory(at: workingDirectory.appendingPathComponent("Other.app"), withIntermediateDirectories: true)
                return ProcessResult(exitStatus: 0)
            }
        } throws: { error in
            guard case AEAError.unexpectedContents = error else { return false }
            return true
        }
    }
}

struct AEAProgressTests {
    @Test
    func `progress follows the read position through a large file`() throws {
        let directory = try TemporaryDirectory()
        let file = try directory.file("large.bin", contents: Data(repeating: 7, count: 4 * 1024 * 1024))
        let reports = Recorder<Double>()
        let inner = try #require(ArchiveByteStream.fileStream(path: FilePath(file.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)))
        let stream = ProgressReportingStream(inner: inner, size: 4 * 1024 * 1024) { reports.append($0) }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 1)
        defer { buffer.deallocate() }

        while try stream.read(into: buffer) > 0 {}
        try inner.close()

        #expect(reports.values.count >= 64)
        #expect(reports.values == reports.values.sorted())
        #expect(reports.values.last == 1)
    }
}
