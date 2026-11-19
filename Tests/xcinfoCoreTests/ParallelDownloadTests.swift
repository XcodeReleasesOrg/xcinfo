//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import Dependencies
import Foundation
import Testing
@testable import xcinfoCore

@Suite(.timeLimit(.minutes(1)))
struct ParallelDownloadTests {
    private let downloadURL = URL(string: "https://download.example.invalid/Xcode-\(UUID().uuidString).xip")!
    private let content = Data((0 ..< 1_000).map { UInt8($0 % 251) })

    private struct Fixture {
        let caches: TemporaryDirectory
        let destination: URL
        let downloader: Downloader
        let logs: LogRecorder
    }

    private func fixture(
        server: StubServer,
        connections: Int = 4,
        minimumSplit: Int64 = 1_000_000,
        caches: TemporaryDirectory? = nil
    ) throws -> Fixture {
        let caches = try caches ?? TemporaryDirectory()
        let logs = LogRecorder()
        let downloader = Downloader(
            logger: logs.logger(),
            session: server.session(),
            cachesDirectory: caches.url,
            clock: ImmediateClock(),
            connections: connections,
            minimumSplit: minimumSplit
        )
        return Fixture(
            caches: caches,
            destination: caches.url.appendingPathComponent("Downloads"),
            downloader: downloader,
            logs: logs
        )
    }

    private static func range(of request: URLRequest) -> (start: Int, end: Int)? {
        guard let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes=") else { return nil }
        let bounds = header.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
        return bounds.count == 2 ? (bounds[0], bounds[1]) : nil
    }

    private func rangeResponse(_ request: URLRequest, content: Data, etag: String = "\"v1\"") -> StubResponse {
        guard let (start, end) = Self.range(of: request) else {
            return StubResponse(headers: ["Content-Length": "\(content.count)"], body: content)
        }
        let last = min(end, content.count - 1)
        return StubResponse(
            statusCode: 206,
            headers: ["Content-Range": "bytes \(start)-\(last)/\(content.count)", "ETag": etag],
            body: content.subdata(in: start ..< last + 1)
        )
    }

    private func pieceRequests(_ server: StubServer) -> [URLRequest] {
        server.requests.values.filter { $0.value(forHTTPHeaderField: "Range") != "bytes=0-0" }
    }

    @Test
    func `a download is split into ranges and put back together`() async throws {
        let server = StubServer { [content] request in rangeResponse(request, content: content) }
        let fixture = try fixture(server: server)

        let url = try await fixture.downloader.download(
            url: downloadURL,
            destination: fixture.destination,
            disableSleep: false
        )

        #expect(url == fixture.destination.appendingPathComponent(downloadURL.lastPathComponent))
        #expect(try Data(contentsOf: url) == content)
        let ranges = pieceRequests(server).compactMap { $0.value(forHTTPHeaderField: "Range") }.sorted()
        #expect(ranges == ["bytes=0-249", "bytes=250-499", "bytes=500-749", "bytes=750-999"])
        #expect(pieceRequests(server).allSatisfy { $0.value(forHTTPHeaderField: "If-Range") == "\"v1\"" })
        #expect(server.requests.values.allSatisfy { $0.value(forHTTPHeaderField: "Accept-Encoding") == "identity" })
        #expect(!FileManager.default.fileExists(atPath: fixture.downloader.partialDownloadURL(for: downloadURL).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.downloader.partialStateURL(for: downloadURL).path))
    }

    @Test
    func `an idle connection takes over half of the largest remaining range`() async throws {
        let server = StubServer { [content] request in rangeResponse(request, content: content) }
        let fixture = try fixture(server: server, connections: 1, minimumSplit: 10)
        let partFile = try PartFile(url: fixture.downloader.partialDownloadURL(for: downloadURL), length: 1_000)
        let (_, progress) = AsyncStream.makeStream(of: Int64.self)
        let file = try #require(RemoteFile(HTTPURLResponse(
            url: downloadURL, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes 0-0/1000"]
        )!))
        let pieces = PieceQueue(
            PartialDownload(url: downloadURL, file: file, connections: 1),
            file: partFile,
            minimumSplit: 10,
            progress: progress
        )

        let first = try #require(await pieces.claim())
        _ = try await pieces.write(Data(count: 200), to: first.index)
        let second = try #require(await pieces.claim())

        #expect(first == .init(index: 0, next: 0, end: 1_000))
        #expect(second == .init(index: 1, next: 600, end: 1_000))
        #expect(await pieces.current(0) == .init(index: 0, next: 200, end: 600))
        #expect(try await pieces.write(Data(count: 500), to: 0))
        #expect(await pieces.partial.received == 600)
    }

    @Test
    func `a failed range is retried without stopping the others`() async throws {
        let attempts = Recorder<Int>()
        let server = StubServer { [content] request in
            if let (start, _) = Self.range(of: request), start == 500 {
                attempts.append(start)
                if attempts.values.count == 1 {
                    return .failure(.networkConnectionLost)
                }
            }
            return rangeResponse(request, content: content)
        }
        let fixture = try fixture(server: server, connections: 2)

        let url = try await fixture.downloader.download(
            url: downloadURL,
            destination: fixture.destination,
            disableSleep: false
        )

        #expect(try Data(contentsOf: url) == content)
        #expect(attempts.values.count == 2)
        #expect(fixture.logs.messages.contains { $0.hasPrefix("A connection failed") && $0.hasSuffix("(1 of 3).") })
    }

    @Test
    func `a range that keeps failing stops the download and the next run resumes the missing parts`() async throws {
        let failing = StubServer { [content] request in
            if let (start, _) = Self.range(of: request), start == 500 {
                return .failure(.networkConnectionLost)
            }
            return rangeResponse(request, content: content)
        }
        let first = try fixture(server: failing, connections: 2)

        await #expect {
            try await first.downloader.download(url: downloadURL, destination: first.destination, disableSleep: false)
        } throws: { error in
            guard case XCAPIError.downloadFailed = error else { return false }
            return true
        }
        #expect(first.logs.messages.contains("The download stopped. Start it again to resume where it stopped."))
        let saved = try JSONDecoder().decode(
            PartialDownload.self,
            from: Data(contentsOf: first.downloader.partialStateURL(for: downloadURL))
        )
        let missing = saved.pieces.filter { !$0.isComplete }.map { "bytes=\($0.next)-\($0.end - 1)" }.sorted()
        #expect(missing.contains("bytes=500-999"))

        let working = StubServer { [content] request in rangeResponse(request, content: content) }
        let second = try fixture(server: working, connections: 2, caches: first.caches)
        let url = try await second.downloader.download(
            url: downloadURL,
            destination: second.destination,
            disableSleep: false
        )

        #expect(try Data(contentsOf: url) == content)
        #expect(pieceRequests(working).compactMap { $0.value(forHTTPHeaderField: "Range") }.sorted() == missing)
        #expect(second.logs.messages.contains { $0.hasPrefix("Resuming the earlier download") })
    }

    @Test
    func `saved progress for a changed file is dropped`() async throws {
        let old = StubServer { [content] request in
            Self.range(of: request)?.start == 500 ? .failure(.networkConnectionLost) : rangeResponse(
                request,
                content: content
            )
        }
        let first = try fixture(server: old, connections: 2)
        _ = try? await first.downloader.download(url: downloadURL, destination: first.destination, disableSleep: false)
        #expect(FileManager.default.fileExists(atPath: first.downloader.partialStateURL(for: downloadURL).path))

        let changed = Data(content.reversed())
        let new = StubServer { request in rangeResponse(request, content: changed, etag: "\"v2\"") }
        let second = try fixture(server: new, connections: 2, caches: first.caches)
        let url = try await second.downloader.download(
            url: downloadURL,
            destination: second.destination,
            disableSleep: false
        )

        #expect(try Data(contentsOf: url) == changed)
        #expect(second.logs.messages
            .contains("The saved progress of an earlier download could not be used. The download starts over."))
    }

    @Test
    func `a server without range support is downloaded over one connection`() async throws {
        let server = StubServer { [content] _ in StubResponse(
            headers: ["Content-Length": "\(content.count)"],
            body: content
        ) }
        let fixture = try fixture(server: server)

        let url = try await fixture.downloader.download(
            url: downloadURL,
            destination: fixture.destination,
            disableSleep: false
        )

        #expect(try Data(contentsOf: url) == content)
        #expect(server.requests.values.count == 2)
    }

    @Test
    func `a server that ignores the ranges after the probe falls back to one connection`() async throws {
        let server = StubServer { [content] request in
            request.value(forHTTPHeaderField: "Range") == "bytes=0-0"
                ? rangeResponse(request, content: content)
                : StubResponse(headers: ["Content-Length": "\(content.count)"], body: content)
        }
        let fixture = try fixture(server: server, connections: 2)

        let url = try await fixture.downloader.download(
            url: downloadURL,
            destination: fixture.destination,
            disableSleep: false
        )

        #expect(try Data(contentsOf: url) == content)
        #expect(fixture.logs.messages
            .contains(
                "The server did not send the requested part of the file. Downloading it again over one connection."
            ))
        #expect(!FileManager.default.fileExists(atPath: fixture.downloader.partialStateURL(for: downloadURL).path))
    }

    @Test(arguments: [403, 404])
    func `an error status from the probe is reported`(statusCode: Int) async throws {
        let server = StubServer { _ in StubResponse(statusCode: statusCode, body: Data("<html>error</html>".utf8)) }
        let fixture = try fixture(server: server)

        await #expect {
            try await fixture.downloader.download(
                url: downloadURL,
                destination: fixture.destination,
                disableSleep: false
            )
        } throws: { error in
            guard case let XCAPIError.unexpectedStatusCode(code) = error else { return false }
            return code == statusCode
        }
    }

    @Test
    func `cancelling a parallel download saves its progress`() async throws {
        let server = StubServer { [content] request in
            guard let (start, _) = Self.range(of: request),
                  start > 0 || request.value(forHTTPHeaderField: "Range") != "bytes=0-0"
            else {
                return rangeResponse(request, content: content)
            }
            var response = rangeResponse(request, content: content)
            response.body = response.body.prefix(10)
            response.isHanging = true
            return response
        }
        let fixture = try fixture(server: server, connections: 2)
        let download = Task { [downloadURL] in
            try await fixture.downloader.download(
                url: downloadURL,
                destination: fixture.destination,
                disableSleep: false
            )
        }
        while server.requests.values.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }

        download.cancel()

        await #expect {
            try await download.value
        } throws: { error in
            guard case XCAPIError.downloadInterrupted = error else { return false }
            return true
        }
        #expect(fixture.logs.messages.contains("The download is paused. Start it again to resume where it stopped."))
        #expect(FileManager.default.fileExists(atPath: fixture.downloader.partialStateURL(for: downloadURL).path))
    }

    @Test(arguments: [
        ("bytes 0-0/1000", 0 as Int64?, 0 as Int64?, 1_000 as Int64?),
        ("bytes 500-999/1000", 500, 999, 1_000),
        ("bytes 0-0/*", 0, 0, nil),
        ("items 0-0/1000", nil, nil, nil),
        ("bytes 9-1/1000", nil, nil, nil)
    ] as [(String, Int64?, Int64?, Int64?)])
    func `content ranges are parsed`(value: String, start: Int64?, end: Int64?, length: Int64?) {
        let range = ContentRange(value)

        #expect(range?.start == start)
        #expect(range?.end == end)
        #expect(range?.length == length)
    }
}
