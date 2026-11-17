import Foundation
import OlympUs
import Testing
@testable import xcinfoCore

@Suite(.timeLimit(.minutes(1)))
struct DownloaderTests {
    private let downloadURL = URL(string: "https://download.example.invalid/Xcode-\(UUID().uuidString).xip")!

    private struct Fixture {
        let caches: TemporaryDirectory
        let destination: URL
        let defaults: TemporaryDefaults
        let sessionStore: InMemorySessionStore
        let olymp: OlympUs
        let downloader: Downloader
        let logs: LogRecorder
    }

    private func fixture(server: StubServer) throws -> Fixture {
        let caches = try TemporaryDirectory()
        let defaults = TemporaryDefaults()
        let sessionStore = InMemorySessionStore()
        let logs = LogRecorder()
        let proxy = URLSessionDelegateProxy()
        let olymp = OlympUs(
            logger: logs.logger(),
            session: server.session(delegate: proxy),
            userDefaults: defaults.defaults,
            sessionStore: sessionStore.store,
            prompt: FakePrompt().client
        )
        let downloader = Downloader(
            logger: logs.logger(),
            olymp: olymp,
            sessionDelegateProxy: proxy,
            cachesDirectory: caches.url
        )
        return Fixture(
            caches: caches,
            destination: caches.url.appendingPathComponent("Downloads"),
            defaults: defaults,
            sessionStore: sessionStore,
            olymp: olymp,
            downloader: downloader,
            logs: logs
        )
    }

    @Test
    func `download moves the file into the destination folder`() async throws {
        let server = StubServer { _ in StubResponse(headers: ["Content-Length": "11"], body: Data("xip-content".utf8)) }
        let fixture = try fixture(server: server)

        let url = try await fixture.downloader.downloadProviding.download(downloadURL, fixture.destination, false)

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
            try await fixture.downloader.downloadProviding.download(downloadURL, fixture.destination, false)
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
            try await fixture.downloader.downloadProviding.download(downloadURL, fixture.destination, false)
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
            try await fixture.downloader.downloadProviding.download(downloadURL, fixture.destination, false)
        } throws: { error in
            guard case XCAPIError.couldNotMoveToTemporaryFile = error else { return false }
            return true
        }
    }

    @Test(.disabled("Crashes the process: URLSession raises an NSException for resume data that was not produced by a real download"))
    func `cached resume data is used and removed after a successful download`() async throws {
        let server = StubServer { _ in StubResponse(body: Data("rest".utf8)) }
        let fixture = try fixture(server: server)
        let cacheURL = try #require(fixture.downloader.cacheURL(for: downloadURL))
        try Data("resume".utf8).write(to: cacheURL)

        _ = try await fixture.downloader.downloadProviding.download(downloadURL, fixture.destination, false)

        #expect(!FileManager.default.fileExists(atPath: cacheURL.path), "Known issue: resume data is never cleared")
    }

    @Test(.disabled("Crashes the process: the retry after a recoverable error resumes with resume data that URLSession rejects with an NSException"))
    func `a recoverable error retries with the resume data`() async throws {
        let attempts = Recorder<Void>()
        let server = StubServer { _ in
            attempts.append(())
            return attempts.values.count == 1
                ? .failure(.networkConnectionLost, userInfo: [NSURLSessionDownloadTaskResumeData: Data("resume".utf8)])
                : StubResponse(body: Data("rest".utf8))
        }
        let fixture = try fixture(server: server)

        _ = try await fixture.downloader.downloadProviding.download(downloadURL, fixture.destination, false)

        #expect(attempts.values.count == 2)
    }

    @Test
    func `resume data is cached next to the other caches`() throws {
        let server = StubServer { _ in StubResponse() }
        let fixture = try fixture(server: server)

        let cacheURL = try #require(fixture.downloader.cacheURL(for: downloadURL))

        #expect(cacheURL == fixture.caches.url.appendingPathComponent("xcinfo/\(downloadURL.lastPathComponent).resume"))
        try Data("resume".utf8).write(to: cacheURL)
        fixture.downloader.removeCachedResumeData(for: downloadURL)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test
    func `cleanup removes the stored session and cookies`() throws {
        let server = StubServer { _ in StubResponse() }
        let fixture = try fixture(server: server)
        try fixture.sessionStore.store.save(Data("assets".utf8), "user")
        fixture.defaults.defaults.set([["Name": "cookie"]], forKey: "cookies")

        fixture.downloader.downloadProviding.cleanup()

        #expect(fixture.sessionStore.accounts.isEmpty)
        #expect(fixture.defaults.defaults.object(forKey: "cookies") == nil)
        #expect(fixture.logs.messages == ["Deleted Apple developer portal session info from keychain."])
    }
}
