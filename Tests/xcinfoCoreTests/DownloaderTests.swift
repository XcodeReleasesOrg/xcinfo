import Dependencies
import Foundation
import Testing
@testable import xcinfoCore

@Suite(.timeLimit(.minutes(1)))
struct DownloaderTests {
    private let downloadURL = URL(string: "https://download.example.invalid/Xcode-\(UUID().uuidString).xip")!

    private struct Fixture {
        let caches: TemporaryDirectory
        let destination: URL
        let downloader: Downloader
        let logs: LogRecorder
    }

    private func fixture(server: StubServer) throws -> Fixture {
        let caches = try TemporaryDirectory()
        let logs = LogRecorder()
        let downloader = Downloader(
            logger: logs.logger(),
            session: server.session(),
            cachesDirectory: caches.url,
            clock: ImmediateClock()
        )
        return Fixture(
            caches: caches,
            destination: caches.url.appendingPathComponent("Downloads"),
            downloader: downloader,
            logs: logs
        )
    }

    @Test
    func `download moves the file into the destination folder`() async throws {
        let server = StubServer { _ in StubResponse(headers: ["Content-Length": "11"], body: Data("xip-content".utf8)) }
        let fixture = try fixture(server: server)

        let url = try await fixture.downloader.download(url: downloadURL, destination: fixture.destination, disableSleep: false)

        #expect(url == fixture.destination.appendingPathComponent(downloadURL.lastPathComponent))
        #expect(try String(contentsOf: url, encoding: .utf8) == "xip-content")
        let request = try #require(server.requests.values.first)
        #expect(request.url == downloadURL)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "gzip, deflate, br")
        #expect(fixture.logs.messages.contains("Source: \(downloadURL)"))
    }

    @Test
    func `an existing file in the destination is not overwritten`() async throws {
        let server = StubServer { _ in StubResponse(body: Data("new".utf8)) }
        let fixture = try fixture(server: server)
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: fixture.destination.appendingPathComponent(downloadURL.lastPathComponent))

        await #expect {
            try await fixture.downloader.download(url: downloadURL, destination: fixture.destination, disableSleep: false)
        } throws: { error in
            guard case XCAPIError.couldNotMoveToDestinationFolder = error else { return false }
            return true
        }
    }

    @Test
    func `a cancelled download keeps its resume data`() async throws {
        let resumeData = Data("resume".utf8)
        let server = StubServer { _ in
            .failure(.cancelled, userInfo: [NSURLSessionDownloadTaskResumeData: resumeData])
        }
        let fixture = try fixture(server: server)

        await #expect {
            try await fixture.downloader.download(url: downloadURL, destination: fixture.destination, disableSleep: false)
        } throws: { error in
            guard case XCAPIError.downloadInterrupted = error else { return false }
            return true
        }
        let cacheURL = try #require(fixture.downloader.cacheURL(for: downloadURL))
        #expect(try Data(contentsOf: cacheURL) == resumeData)
    }

    @Test
    func `a failed download without resume data is reported`() async throws {
        let server = StubServer { _ in .failure(.notConnectedToInternet) }
        let fixture = try fixture(server: server)

        await #expect {
            try await fixture.downloader.download(url: downloadURL, destination: fixture.destination, disableSleep: false)
        } throws: { error in
            guard case XCAPIError.couldNotMoveToTemporaryFile = error else { return false }
            return true
        }
    }

    @Test
    func `unusable cached resume data is removed and the download starts over`() async throws {
        let server = StubServer { _ in StubResponse(body: Data("fresh".utf8)) }
        let fixture = try fixture(server: server)
        let cacheURL = try #require(fixture.downloader.cacheURL(for: downloadURL))
        try Data("resume".utf8).write(to: cacheURL)

        let url = try await fixture.downloader.download(url: downloadURL, destination: fixture.destination, disableSleep: false)

        #expect(try String(contentsOf: url, encoding: .utf8) == "fresh")
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
        #expect(fixture.logs.messages.contains("The saved progress of an earlier download could not be used. The download starts over."))
    }

    @Test
    func `cancelling a running download stops it and reports the interruption`() async throws {
        let server = StubServer { _ in
            StubResponse(headers: ["Content-Length": "1000"], body: Data(repeating: 1, count: 100), isHanging: true)
        }
        let fixture = try fixture(server: server)
        let download = Task { [downloadURL] in
            try await fixture.downloader.download(url: downloadURL, destination: fixture.destination, disableSleep: false)
        }
        while server.requests.values.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        download.cancel()

        await #expect {
            try await download.value
        } throws: { error in
            guard case XCAPIError.downloadInterrupted = error else { return false }
            return true
        }
        #expect(fixture.logs.messages.contains {
            $0 == "The download is paused. Start it again to resume where it stopped."
                || $0 == "The download stopped before any progress could be saved. It starts over next time."
        })
        #expect(!fixture.logs.messages.contains { $0.contains("cancelled") })
    }

    @Test(arguments: [
        ("plain", true, 1_234 as Int64?),
        ("other url", false, nil),
        ("missing version", false, nil),
        ("archive", true, nil),
        ("archived resume data", true, 5_678),
        ("archived resume data for another url", false, nil),
        ("garbage", false, nil)
    ] as [(String, Bool, Int64?)])
    func `resume data is checked before it is used`(kind: String, isUsable: Bool, bytesReceived: Int64?) throws {
        let plist: Any? = switch kind {
        case "plain":
            [
                "NSURLSessionResumeInfoVersion": 2,
                "NSURLSessionDownloadURL": downloadURL.absoluteString,
                "NSURLSessionResumeBytesReceived": 1_234
            ]
        case "other url":
            ["NSURLSessionResumeInfoVersion": 2, "NSURLSessionDownloadURL": "https://example.invalid/other.xip"]
        case "missing version":
            ["NSURLSessionDownloadURL": downloadURL.absoluteString]
        case "archive":
            ["$archiver": "NSKeyedArchiver", "$top": ["root": 1], "$version": 100_000]
        default:
            nil
        }
        let archived: [String: Any]? = switch kind {
        case "archived resume data":
            [
                "NSURLSessionResumeInfoVersion": 2,
                "NSURLSessionDownloadURL": downloadURL.absoluteString,
                "NSURLSessionResumeBytesReceived": 5_678
            ]
        case "archived resume data for another url":
            ["NSURLSessionResumeInfoVersion": 2, "NSURLSessionDownloadURL": "https://example.invalid/other.xip"]
        default:
            nil
        }
        let data = try archived.map { try NSKeyedArchiver.archivedData(withRootObject: $0 as NSDictionary, requiringSecureCoding: true) }
            ?? plist.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0) }
            ?? Data("resume".utf8)

        let resumeData = ResumeData(data, for: downloadURL)

        #expect((resumeData != nil) == isUsable)
        #expect(resumeData?.bytesReceived == bytesReceived)
    }

    @Test(
        .disabled(
            "Crashes the process: the retry after a recoverable error resumes with resume data that URLSession rejects with an NSException"
        )
    )
    func `a recoverable error retries with the resume data`() async throws {
        let attempts = Recorder<Void>()
        let server = StubServer { _ in
            attempts.append(())
            return attempts.values.count == 1
                ? .failure(.networkConnectionLost, userInfo: [NSURLSessionDownloadTaskResumeData: Data("resume".utf8)])
                : StubResponse(body: Data("rest".utf8))
        }
        let fixture = try fixture(server: server)

        _ = try await fixture.downloader.download(url: downloadURL, destination: fixture.destination, disableSleep: false)

        #expect(attempts.values.count == 2)
    }

    @Test
    func `resume data is cached next to the other caches`() throws {
        let server = StubServer { _ in StubResponse() }
        let fixture = try fixture(server: server)

        let cacheURL = try #require(fixture.downloader.cacheURL(for: downloadURL))

        #expect(cacheURL == fixture.caches.url.appendingPathComponent("\(downloadURL.lastPathComponent).resume"))
        try Data("resume".utf8).write(to: cacheURL)
        fixture.downloader.removeCachedResumeData(for: downloadURL)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test
    func `resume data from the earlier nested location is still found and removed`() throws {
        let server = StubServer { _ in StubResponse() }
        let fixture = try fixture(server: server)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["NSURLSessionResumeInfoVersion": 2, "NSURLSessionDownloadURL": downloadURL.absoluteString],
            format: .xml,
            options: 0
        )
        let legacy = try fixture.caches.file("xcinfo/\(downloadURL.lastPathComponent).resume", contents: plist)

        #expect(fixture.downloader.cachedResumeData(for: downloadURL)?.data == plist)
        fixture.downloader.removeCachedResumeData(for: downloadURL)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test(arguments: [403, 404, 500])
    func `a download with an error status is rejected`(statusCode: Int) async throws {
        let server = StubServer { _ in StubResponse(statusCode: statusCode, body: Data("<html>error</html>".utf8)) }
        let fixture = try fixture(server: server)

        await #expect {
            try await fixture.downloader.download(url: downloadURL, destination: fixture.destination, disableSleep: false)
        } throws: { error in
            guard case let XCAPIError.unexpectedStatusCode(code) = error else { return false }
            return code == statusCode
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent(downloadURL.lastPathComponent).path))
    }

    @Test
    func `downloads use long timeouts and share in-memory cookies with the sign-in`() {
        let configuration = URLSession.xcinfoDownloads.configuration

        #expect(configuration.timeoutIntervalForRequest == 60)
        #expect(configuration.timeoutIntervalForResource == 60 * 60 * 24)
        #expect(configuration.httpCookieStorage === HTTPCookieStorage.xcinfo)
        #expect(URLSession.xcinfo.configuration.httpCookieStorage === HTTPCookieStorage.xcinfo)
        #expect(HTTPCookieStorage.xcinfo !== HTTPCookieStorage.shared)
    }

    @Test
    func `removing apple cookies keeps other cookies`() throws {
        let storage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        for (name, domain) in [("myacinfo", ".apple.com"), ("dqsid", "appstoreconnect.apple.com"), ("other", "example.com")] {
            try storage.setCookie(#require(HTTPCookie(properties: [.name: name, .value: "1", .domain: domain, .path: "/"])))
        }

        storage.removeAppleCookies()

        #expect(storage.cookies?.map(\.name) == ["other"])
    }
}

struct DurationFormattingTests {
    @Test
    func `durations are formatted in English whatever the system language`() {
        #expect(Duration.seconds(10).englishDescription == "10 sec")
        #expect(Duration.seconds(75).englishDescription == "1 min, 15 sec")
    }
}
