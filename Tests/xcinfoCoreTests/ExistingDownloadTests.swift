import Foundation
import Testing
import XCIFoundation
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.
@testable import xcinfo
@testable import xcinfoCore

struct ExistingDownloadTests {
    private let content = Data("xar!xip-content".utf8)
    private let sha1 = "8e4a6d65179ce1b5a3ad04a1c6472a744c410621"

    private struct Fixture {
        let caches: TemporaryDirectory
        let downloads: URL
        let logs = LogRecorder()
        let requested = Recorder<URL>()
        var core: Core

        init(name: String, sha1: String?, trust: AEASigningTrust = .apple) throws {
            caches = try TemporaryDirectory()
            downloads = caches.url.appendingPathComponent("Downloads")
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let xcodes = [Xcode.fixture("15.0", build: "15A240d", download: "https://download.example.invalid/\(name)", sha1: sha1)]
            let requested = requested
            let downloads = downloads
            core = Core.test(
                logs: logs,
                cachesDirectory: caches.url,
                listXcodes: { xcodes },
                accountName: { "user" },
                authenticate: { _, _ in },
                download: { url, _, _ in
                    requested.append(url)
                    let fresh = downloads.appendingPathComponent(url.lastPathComponent)
                    try Data("xar!fresh".utf8).write(to: fresh)
                    return fresh
                },
                applicationsDirectory: caches.url
            )
            core.signingTrust = trust
        }

        func existing(_ name: String, contents: Data) throws -> URL {
            let url = downloads.appendingPathComponent(name)
            try contents.write(to: url)
            return url
        }

        func download(overwrite: Bool = false) async throws -> URL {
            try await core.download(
                version: .latest,
                options: .init(destination: downloads, disableSleep: false, overwritesExistingFile: overwrite),
                updateVersionList: true
            ).1
        }
    }

    @Test
    func `an existing xip with the listed checksum is reused without downloading`() async throws {
        let fixture = try Fixture(name: "Xcode.xip", sha1: sha1)
        let existing = try fixture.existing("Xcode.xip", contents: content)

        let url = try await fixture.download()

        #expect(url == existing)
        #expect(fixture.requested.values.isEmpty)
        #expect(fixture.logs.messages.contains("Using the existing \(existing.path) (SHA-1 matches xcodereleases.com)."))
    }

    @Test(arguments: [("0000000000000000000000000000000000000000", "its SHA-1 does not match xcodereleases.com"), (nil, "xcodereleases.com has no checksum to check it against")] as [(String?, String)])
    func `an existing file that cannot be confirmed is kept and the download refused without overwrite`(sha1: String?, reason: String) async throws {
        let fixture = try Fixture(name: "Xcode.xip", sha1: sha1)
        let existing = try fixture.existing("Xcode.xip", contents: content)

        await #expect {
            try await fixture.download()
        } throws: { error in
            guard case let CoreError.destinationExists(url, actualReason) = error else { return false }
            return url == existing && actualReason == reason && error.localizedDescription.contains("--overwrite") && error.exitCode == 5
        }
        #expect(try Data(contentsOf: existing) == content)
        #expect(fixture.requested.values.isEmpty)
    }

    @Test
    func `overwrite moves the existing file to the trash and downloads anew`() async throws {
        let fixture = try Fixture(name: "Xcode.xip", sha1: "0000000000000000000000000000000000000000")
        _ = try fixture.existing("Xcode.xip", contents: content)

        await #expect(throws: CoreError.self) { try await fixture.download(overwrite: true) }

        #expect(fixture.requested.values.map(\.lastPathComponent) == ["Xcode.xip"])
        let trashed = fixture.caches.url.appendingPathComponent("Trash/Xcode.xip")
        #expect(try Data(contentsOf: trashed) == content)
        #expect(fixture.logs.messages.contains("Moved the existing file to the Trash: \(trashed.path)"))
    }

    @Test
    func `an existing aea with a trusted signature is reused`() async throws {
        let fixture = try Fixture(name: "Xcode.aea", sha1: nil, trust: AEAFixture.trust)
        let existing = try fixture.existing("Xcode.aea", contents: Data(contentsOf: AEAFixture.url("signed.aea")))

        let url = try await fixture.download()

        #expect(url == existing)
        #expect(fixture.requested.values.isEmpty)
        #expect(fixture.logs.messages.contains("Using the existing \(existing.path) (Apple signature checked)."))
        #expect(fixture.logs.progress.last == OutputProgress(title: "Verifying", fraction: 1, detail: "signature checked", isFinished: true))
    }

    @Test(arguments: ["wrong-signer.aea", "signed.aea"])
    func `an existing aea whose signature does not check out is not reused`(fixtureName: String) async throws {
        let trust: AEASigningTrust = fixtureName == "signed.aea" ? .apple : try AEAFixture.trust
        let fixture = try Fixture(name: "Xcode.aea", sha1: nil, trust: trust)
        _ = try fixture.existing("Xcode.aea", contents: Data(contentsOf: AEAFixture.url(fixtureName)))

        await #expect {
            try await fixture.download()
        } throws: { error in
            guard case let CoreError.destinationExists(_, reason) = error else { return false }
            return reason.hasPrefix("its signature could not be checked")
        }
        #expect(fixture.requested.values.isEmpty)
    }

    @Test
    func `overwrite is parsed for download and install`() throws {
        #expect(try XCInfo.Download.parse(["15.0", "--overwrite"]).downloadOptions.options.overwritesExistingFile)
        #expect(try !XCInfo.Download.parse(["15.0"]).downloadOptions.options.overwritesExistingFile)
        #expect(try XCInfo.Install.parse(["15.0", "--overwrite"]).installationOptions.downloadOptions.options.overwritesExistingFile)
    }
}
