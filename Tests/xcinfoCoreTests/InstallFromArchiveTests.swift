import Foundation
import Testing
import XCIFoundation
@testable import xcinfo
@testable import xcinfoCore
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has immutable value types without Sendable annotations.

struct InstallFromArchiveTests {
    private let xcodes = [Xcode.fixture("15.0", build: "15A240d"), .fixture("16.0", build: "16A1")]

    private func core(
        logs: LogRecorder,
        caches: TemporaryDirectory,
        applications: TemporaryDirectory,
        archiveBuild: String,
        sha1: String? = nil,
        agrees: Bool = true
    ) -> Core {
        let xcodes = [Xcode.fixture("15.0", build: "15A240d", sha1: sha1), .fixture("16.0", build: "16A1")]
        return Core.test(
            logs: logs,
            isVerbose: true,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            extract: { _, destination, filename in
                let app = destination.appendingPathComponent(filename ?? "Xcode-beta.app")
                let contents = app.appendingPathComponent("Contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: ["ProductBuildVersion": archiveBuild], format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("version.plist"))
                return app
            },
            shell: FakeShell(),
            prompt: FakePrompt(agree: agrees, passwords: ["sudo-password"]),
            applicationsDirectory: applications.url,
            revealInFinder: { _ in }
        )
    }

    private func options(archive: URL, version: XcodeVersion?, destination: URL) -> Core.InstallationOptions {
        Core.InstallationOptions(
            version: version,
            archiveFile: archive,
            downloadOptions: .init(destination: destination, disableSleep: false),
            extractionOptions: .init(destination: destination),
            skipSymlinkCreation: true,
            skipXcodeSelection: true
        )
    }

    @Test
    func `without a version the archive's build names and identifies the xcode`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let archive = try caches.file("Xcode.aea", contents: Data("AEA1".utf8))
        let logs = LogRecorder()
        let core = core(logs: logs, caches: caches, applications: applications, archiveBuild: "16A1")

        let app = try await core.install(
            options: options(archive: archive, version: nil, destination: applications.url),
            updateVersionList: true
        )

        #expect(app.xcode.version.build == "16A1")
        #expect(app.url.lastPathComponent == "Xcode_16.0.app")
        #expect(FileManager.default.fileExists(atPath: app.url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.url.path) == ["Xcode_16.0.app"])
        #expect(logs.messages.contains("The archive contains Xcode 16.0 (16A1)."))
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    @Test
    func `a xip without a version is identified the same way and then checked against its sha1`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let archive = try caches.file("Xcode.xip", contents: .xipMagic)
        let logs = LogRecorder()
        let core = core(
            logs: logs,
            caches: caches,
            applications: applications,
            archiveBuild: "15A240d",
            sha1: "0000000000000000000000000000000000000000",
            agrees: false
        )

        await #expect(throws: CoreError.self) {
            try await core.install(options: options(archive: archive, version: nil, destination: applications.url), updateVersionList: true)
        }

        #expect(logs.messages.contains("The archive contains Xcode 15.0 (15A240d)."))
        #expect(logs.messages.contains { $0.contains("is corrupt") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.url.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    @Test
    func `an archive whose build is not listed fails and leaves nothing behind`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let archive = try caches.file("Xcode.aea", contents: Data("AEA1".utf8))
        let core = core(logs: LogRecorder(), caches: caches, applications: applications, archiveBuild: "99Z1")

        await #expect {
            try await core.install(options: options(archive: archive, version: nil, destination: applications.url), updateVersionList: true)
        } throws: { error in
            guard case let CoreError.unknownArchiveVersion(build) = error else { return false }
            return build == "99Z1"
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.url.path).isEmpty)
    }

    @Test
    func `a given version that differs from the archive is warned about`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let archive = try caches.file("Xcode.aea", contents: Data("AEA1".utf8))
        let logs = LogRecorder()
        let core = core(logs: logs, caches: caches, applications: applications, archiveBuild: "16A1")

        let app = try await core.install(
            options: options(archive: archive, version: .version("15.0"), destination: applications.url),
            updateVersionList: true
        )

        #expect(app.xcode.version.build == "15A240d")
        #expect(logs.messages
            .contains("The archive contains Xcode build 16A1, not 15A240d as requested. xcinfo continues with Xcode 15.0 (15A240d)."))
    }

    @Test
    func `the version is required without an archive`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let core = core(logs: LogRecorder(), caches: caches, applications: applications, archiveBuild: "16A1")
        let options = Core.InstallationOptions(
            version: nil,
            archiveFile: nil,
            downloadOptions: .init(destination: caches.url, disableSleep: false),
            extractionOptions: .init(destination: applications.url)
        )

        await #expect {
            try await core.install(options: options, updateVersionList: true)
        } throws: { error in
            guard case CoreError.versionRequired = error else { return false }
            return error.exitCode == 64
        }
    }
}
