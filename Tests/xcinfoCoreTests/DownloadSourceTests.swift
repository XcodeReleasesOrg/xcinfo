import Foundation
import OlympUs
import Testing
@testable import xcinfoCore
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has immutable value types without Sendable annotations.

private let folder = "https://download.developer.apple.com/Developer_Tools/Xcode_27.4"
private let xip = URL(string: "\(folder)/Xcode_27.4.xip")!
private let aea = URL(string: "\(folder)/Xcode_27.4.aea")!

struct DownloadSourceTests {
    @Test(arguments: [
        (xip, [xip, aea] as [URL]?, xip, true, nil as URL?),
        (xip, [aea], aea, true, nil),
        (xip, nil, xip, false, aea),
        (xip, [], xip, false, aea),
        (aea, [xip, aea], xip, true, nil),
        (aea, nil, aea, false, nil)
    ])
    func `xip is preferred, aea is used when it is the only file, and the derived aea is a last resort`(
        listed: URL, offered: [URL]?, expected: URL, hasNote: Bool, fallback: URL?
    ) throws {
        let source = try DownloadSource(listed: listed, offered: offered)

        #expect(source.url == expected)
        #expect((source.note != nil) == hasNote)
        #expect(source.derivedFallback == fallback)
    }
}

struct ArchiveFormatChoiceTests {
    @Test(arguments: [
        (ArchiveFormat.xip, [xip, aea] as [URL]?, xip),
        (.xip, nil, xip),
        (.aea, [xip, aea], aea),
        (.aea, nil, aea),
        (.aea, [], aea)
    ])
    func `a requested format is downloaded when it is offered or can be derived`(
        format: ArchiveFormat,
        offered: [URL]?,
        expected: URL
    ) throws {
        let source = try DownloadSource(listed: xip, offered: offered, format: format)

        #expect(source.url == expected)
        #expect(source.derivedFallback == nil)
        #expect(source.note != nil)
    }

    @Test(arguments: [(ArchiveFormat.xip, [aea]), (.aea, [xip])])
    func `a requested format that apple does not offer is an error`(format: ArchiveFormat, offered: [URL]) {
        #expect {
            try DownloadSource(listed: xip, offered: offered, format: format)
        } throws: { error in
            guard case let CoreError.archiveFormatNotOffered(requested, names) = error else { return false }
            return requested == format && names == offered.map(\.lastPathComponent) && error.localizedDescription
                .contains("--archive-format")
        }
    }

    @Test
    func `resume data is kept per format`() throws {
        let caches = try TemporaryDirectory()
        let downloader = Downloader(logger: LogRecorder().logger(), session: .shared, cachesDirectory: caches.url)

        #expect(downloader.cacheURL(for: xip) != downloader.cacheURL(for: aea))
    }
}

struct DownloadListingTests {
    private let json = """
    {"downloads": [
      {"name": "Xcode 27.4", "files": [{"remotePath": "/Developer_Tools/Xcode_27.4/Xcode_27.4.aea"}, {"remotePath": "/Developer_Tools/Xcode_27.4/Release_Notes.pdf"}]},
      {"name": "Xcode 27.5 beta", "files": [{"remotePath": "Developer_Tools/Xcode_27.5_beta/Xcode_27.5_beta.xip"}]},
      {"name": "Something else", "files": [{"size": 1}]},
      {"files": []}
    ], "other": true}
    """

    @Test
    func `archives are found by the folder of the listed url`() throws {
        let listing = try #require(DownloadListing(data: Data(json.utf8)))

        #expect(listing.archiveURLs(inFolderOf: xip, named: "Xcode 99") == [aea])
    }

    @Test
    func `archives are found by name when the url does not match`() throws {
        let listing = try #require(DownloadListing(data: Data(json.utf8)))

        #expect(try listing.archiveURLs(inFolderOf: nil, named: "xcode 27.5 BETA") == [
            #require(URL(string: "https://download.developer.apple.com/Developer_Tools/Xcode_27.5_beta/Xcode_27.5_beta.xip"))
        ])
        #expect(listing.archiveURLs(inFolderOf: nil, named: "Xcode 1.0").isEmpty)
    }

    @Test(arguments: ["", "[]", #"{"downloads": "none"}"#, "<html>"])
    func `an unknown listing shape is ignored`(body: String) {
        #expect(DownloadListing(data: Data(body.utf8)) == nil)
    }
}

struct DownloadFormatFlowTests {
    private func core(
        logs: LogRecorder,
        caches: TemporaryDirectory,
        listing: DownloadListing?,
        download: @escaping @Sendable (URL, URL, Bool) async throws -> URL
    ) -> Core {
        let xcodes = [Xcode.fixture("27.4", build: "27D1", download: xip.absoluteString)]
        return .test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            accountName: { "user" },
            authenticate: { _, _ in },
            downloadListing: listing,
            download: download,
            applicationsDirectory: caches.url
        )
    }

    @Test
    func `the aea is downloaded when apple offers only that`() async throws {
        let caches = try TemporaryDirectory()
        let requested = Recorder<URL>()
        let logs = LogRecorder()
        let listing = DownloadListing(downloads: [.init(
            name: "Xcode 27.4",
            files: [.init(remotePath: "/Developer_Tools/Xcode_27.4/Xcode_27.4.aea")]
        )])
        let core = core(logs: logs, caches: caches, listing: listing) { url, destination, _ in
            requested.append(url)
            return try caches.file(url.lastPathComponent, contents: Data("AEA1".utf8))
        }

        _ = try await core.download(version: .latest, options: .init(destination: caches.url, disableSleep: false), updateVersionList: true)

        #expect(requested.values == [aea])
        #expect(logs.messages.contains("Apple offers this version only as .aea. Downloading Xcode_27.4.aea."))
    }

    @Test
    func `a missing xip falls back to the derived aea and says so`() async throws {
        let caches = try TemporaryDirectory()
        let requested = Recorder<URL>()
        let logs = LogRecorder()
        let core = core(logs: logs, caches: caches, listing: nil) { url, _, _ in
            requested.append(url)
            guard url.pathExtension == "aea" else { throw XCAPIError.unexpectedStatusCode(404) }
            return try caches.file(url.lastPathComponent, contents: Data("AEA1".utf8))
        }

        _ = try await core.download(version: .latest, options: .init(destination: caches.url, disableSleep: false), updateVersionList: true)

        #expect(requested.values == [xip, aea])
        #expect(logs.messages.contains("Apple has no file at Xcode_27.4.xip. Trying the .aea at the same path, a derived address: \(aea)"))
    }

    @Test
    func `other download errors do not try the derived aea`() async throws {
        let caches = try TemporaryDirectory()
        let requested = Recorder<URL>()
        let core = core(logs: LogRecorder(), caches: caches, listing: nil) { url, _, _ in
            requested.append(url)
            throw XCAPIError.unexpectedStatusCode(403)
        }

        await #expect(throws: CoreError.self) {
            try await core.download(version: .latest, options: .init(destination: caches.url, disableSleep: false), updateVersionList: true)
        }
        #expect(requested.values == [xip])
    }
}
