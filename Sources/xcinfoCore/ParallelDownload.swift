//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import Foundation
import XCIFoundation

struct RemoteFile: Equatable, Sendable {
    let length: Int64
    let validator: String?

    init?(_ response: HTTPURLResponse) {
        guard
            response.statusCode == 206,
            let range = response.contentRange,
            range.start == 0,
            let length = range.length,
            length > 0
        else { return nil }
        self.length = length
        let etag = response.value(forHTTPHeaderField: "ETag")
        validator = etag.flatMap { $0.hasPrefix("W/") ? nil : $0 } ?? response
            .value(forHTTPHeaderField: "Last-Modified")
    }
}

struct ContentRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    let length: Int64?

    init?(_ value: String) {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndLength = parts[1].split(separator: "/", maxSplits: 1)
        let bounds = rangeAndLength[0].split(separator: "-", maxSplits: 1)
        guard
            rangeAndLength.count == 2,
            bounds.count == 2,
            let start = Int64(bounds[0]),
            let end = Int64(bounds[1]),
            start <= end
        else { return nil }
        self.start = start
        self.end = end
        length = Int64(rangeAndLength[1])
    }
}

extension HTTPURLResponse {
    var contentRange: ContentRange? {
        value(forHTTPHeaderField: "Content-Range").flatMap(ContentRange.init)
    }

    var isUnauthorizedDownload: Bool {
        url?.absoluteString.hasPrefix("https://developer.apple.com/unauthorized") == true
    }
}

struct PartialDownload: Codable, Equatable, Sendable {
    struct Piece: Codable, Equatable, Sendable {
        var start: Int64
        var end: Int64
        var received: Int64

        var next: Int64 {
            start + received
        }

        var remaining: Int64 {
            max(0, end - next)
        }

        var isComplete: Bool {
            remaining == 0
        }
    }

    let url: URL
    let length: Int64
    let validator: String?
    var pieces: [Piece]

    init(url: URL, file: RemoteFile, connections: Int) {
        self.url = url
        length = file.length
        validator = file.validator
        let size = max(1, (file.length + Int64(connections) - 1) / Int64(connections))
        pieces = stride(from: Int64(0), to: file.length, by: Int64.Stride(size)).map { start in
            Piece(start: start, end: min(start + size, file.length), received: 0)
        }
    }

    var received: Int64 {
        pieces.reduce(0) { $0 + $1.received }
    }

    func matches(_ url: URL, _ file: RemoteFile) -> Bool {
        self.url == url && length == file.length && validator == file.validator
    }
}

final class PartFile: Sendable {
    let url: URL
    private let descriptor: Int32

    init(url: URL, length: Int64) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard ftruncate(descriptor, off_t(length)) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(descriptor)
            throw POSIXError(code)
        }
        self.url = url
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    func write(_ data: Data, count: Int, at offset: Int64) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < count {
                let result = pwrite(descriptor, base + written, count - written, off_t(offset) + off_t(written))
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += result
            }
        }
    }
}

actor PieceQueue {
    struct Claim: Equatable, Sendable {
        let index: Int
        let next: Int64
        let end: Int64
    }

    private(set) var partial: PartialDownload
    private var active: Set<Int> = []
    private var received: Int64
    private let file: PartFile
    private let minimumSplit: Int64
    private let progress: AsyncStream<Int64>.Continuation

    init(_ partial: PartialDownload, file: PartFile, minimumSplit: Int64, progress: AsyncStream<Int64>.Continuation) {
        self.partial = partial
        self.file = file
        self.minimumSplit = minimumSplit
        self.progress = progress
        received = partial.received
    }

    func claim() -> Claim? {
        if let index = partial.pieces.indices.first(where: { !active.contains($0) && !partial.pieces[$0].isComplete }) {
            active.insert(index)
            return current(index)
        }
        guard
            let index = active.max(by: { partial.pieces[$0].remaining < partial.pieces[$1].remaining }),
            partial.pieces[index].remaining >= 2 * minimumSplit
        else { return nil }
        let piece = partial.pieces[index]
        let middle = piece.next + piece.remaining / 2
        partial.pieces[index].end = middle
        partial.pieces.append(.init(start: middle, end: piece.end, received: 0))
        active.insert(partial.pieces.count - 1)
        return current(partial.pieces.count - 1)
    }

    func current(_ index: Int) -> Claim? {
        let piece = partial.pieces[index]
        return piece.isComplete ? nil : Claim(index: index, next: piece.next, end: piece.end)
    }

    func release(_ index: Int) {
        active.remove(index)
    }

    func write(_ data: Data, to index: Int) throws -> Bool {
        let piece = partial.pieces[index]
        let count = Int(min(Int64(data.count), piece.remaining))
        if count > 0 {
            try file.write(data, count: count, at: piece.next)
            partial.pieces[index].received += Int64(count)
            received += Int64(count)
            progress.yield(received)
        }
        return partial.pieces[index].isComplete
    }
}

final class RangeTransfer: NSObject, URLSessionDataDelegate, Sendable {
    enum Event: Sendable {
        case data(Data)
        case completed(URLError?)
    }

    let events: AsyncStream<Event>

    private let continuation: AsyncStream<Event>.Continuation
    private let task: URLSessionDataTask

    init(task: URLSessionDataTask) {
        self.task = task
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
        super.init()
        continuation.onTermination = { [task] _ in task.cancel() }
        task.delegate = self
        task.resume()
    }

    var response: HTTPURLResponse? {
        task.response as? HTTPURLResponse
    }

    func cancel() {
        task.cancel()
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        continuation.yield(.completed(error.map { $0 as? URLError ?? URLError(.unknown) }))
        continuation.finish()
    }
}

enum PieceError: Error, CustomStringConvertible {
    case transfer(URLError)
    case incomplete
    case rangeIgnored

    var description: String {
        switch self {
        case let .transfer(error): error.localizedDescription
        case .incomplete: "the connection ended early"
        case .rangeIgnored: "the server did not send the requested part of the file"
        }
    }
}

extension Downloader {
    static let defaultMinimumSplit: Int64 = 16 * 1_024 * 1_024

    func partialDownloadURL(for url: URL) -> URL {
        cachesDirectory.appendingPathComponent(url.appendingPathExtension("part").lastPathComponent)
    }

    func partialStateURL(for url: URL) -> URL {
        cachesDirectory
            .appendingPathComponent(url.appendingPathExtension("part").appendingPathExtension("json").lastPathComponent)
    }

    func removePartialDownload(for url: URL) {
        try? FileManager.default.removeItem(at: partialDownloadURL(for: url))
        try? FileManager.default.removeItem(at: partialStateURL(for: url))
    }

    private func savePartial(_ partial: PartialDownload) {
        do {
            try JSONEncoder().encode(partial).write(to: partialStateURL(for: partial.url), options: .atomic)
        } catch {
            logger.error("Unable to save unfinished download")
            logger.error(error.localizedDescription)
        }
    }

    private func restoredPartial(for url: URL, file: RemoteFile) -> PartialDownload? {
        guard let data = try? Data(contentsOf: partialStateURL(for: url)) else { return nil }
        let size = (try? FileManager.default
            .attributesOfItem(atPath: partialDownloadURL(for: url).path)[.size] as? NSNumber)?.int64Value
        guard
            let partial = try? JSONDecoder().decode(PartialDownload.self, from: data),
            partial.matches(url, file),
            size == file.length
        else {
            logger.warn("The saved progress of an earlier download could not be used. The download starts over.")
            removePartialDownload(for: url)
            return nil
        }
        return partial
    }

    private func rangeRequest(_ url: URL, from start: Int64, to end: Int64, validator: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.addValue("bytes=\(start)-\(end - 1)", forHTTPHeaderField: "Range")
        request.addValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let validator {
            request.addValue(validator, forHTTPHeaderField: "If-Range")
        }
        return request
    }

    func probe(_ url: URL) async throws -> RemoteFile? {
        let transfer = RangeTransfer(task: session.dataTask(with: rangeRequest(url, from: 0, to: 1)))
        defer { transfer.cancel() }
        for await event in transfer.events {
            if case .completed(.some) = event {
                return nil
            }
            break
        }
        try Task.checkCancellation()
        guard let response = transfer.response else { return nil }
        if response.isUnauthorizedDownload {
            throw XCAPIError.unauthorized
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw XCAPIError.unexpectedStatusCode(response.statusCode)
        }
        return RemoteFile(response)
    }

    func downloadInParallel(url: URL, file: RemoteFile, disableSleep: Bool) async throws -> URL {
        let partial: PartialDownload
        if let restored = restoredPartial(for: url, file: file) {
            partial = restored
            logger
                .log(
                    "Resuming the earlier download, \(DownloadProgressReport.bytes(restored.received)) already downloaded."
                )
        } else {
            partial = PartialDownload(url: url, file: file, connections: connections)
        }
        logger.log("Source: \(url)")
        logger.verbose("Downloading over \(connections) connections.")

        let partFile = try PartFile(url: partialDownloadURL(for: url), length: file.length)
        let (progress, continuation) = AsyncStream.makeStream(of: Int64.self, bufferingPolicy: .bufferingNewest(1))
        let pieces = PieceQueue(partial, file: partFile, minimumSplit: minimumSplit, progress: continuation)
        let sleepAssertion = disableSleep ? SleepAssertion(logger: logger) : nil
        defer { sleepAssertion?.release() }

        let start = ContinuousClock.now
        var report = DownloadProgressReport(alreadyReceived: partial.received)
        var lastSave = ContinuousClock.now
        async let transfers: Void = transferAll(from: pieces, url: url, file: file, progress: continuation)
        for await received in progress {
            if let output = report.update(totalBytesWritten: received, totalBytesExpectedToWrite: file.length) {
                logger.progress(output)
            }
            if lastSave.duration(to: .now) >= .seconds(5) {
                lastSave = .now
                await savePartial(pieces.partial)
            }
        }

        do {
            try await transfers
        } catch PieceError.rangeIgnored {
            removePartialDownload(for: url)
            throw PieceError.rangeIgnored
        } catch {
            await savePartial(pieces.partial)
            if Task.isCancelled || error is CancellationError {
                logger.log("The download is paused. Start it again to resume where it stopped.")
                throw XCAPIError.downloadInterrupted
            }
            if let error = error as? PieceError {
                logger.log("The download stopped. Start it again to resume where it stopped.")
                throw XCAPIError.downloadFailed(error.description)
            }
            throw error
        }

        logger.progress(DownloadProgressReport.finished(after: start.duration(to: .now)))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: partFile.url, to: target)
        } catch {
            throw XCAPIError.couldNotMoveToTemporaryFile
        }
        try? FileManager.default.removeItem(at: partialStateURL(for: url))
        return target
    }

    private func transferAll(
        from pieces: PieceQueue,
        url: URL,
        file: RemoteFile,
        progress: AsyncStream<Int64>.Continuation
    ) async throws {
        defer { progress.finish() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< connections {
                group.addTask {
                    while let claim = await pieces.claim() {
                        try await transferWithRetries(claim, from: pieces, url: url, file: file)
                        await pieces.release(claim.index)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    private func transferWithRetries(
        _ claim: PieceQueue.Claim,
        from pieces: PieceQueue,
        url: URL,
        file: RemoteFile
    ) async throws {
        var claim = claim
        var failures = 0
        while true {
            do {
                try await transfer(claim, from: pieces, url: url, file: file)
                return
            } catch where Self.isRetryable(error) && !Task.isCancelled {
                guard let current = await pieces.current(claim.index) else { return }
                failures = current.next > claim.next ? 1 : failures + 1
                guard failures <= Self.maximumRetries else { throw error }
                logger
                    .verbose(
                        "A connection failed (\(error)). Retrying its part of the download (\(failures) of \(Self.maximumRetries))."
                    )
                try await clock.sleep(for: .seconds(3))
                claim = current
            }
        }
    }

    private static func isRetryable(_ error: any Error) -> Bool {
        switch error {
        case PieceError.transfer, PieceError.incomplete: true
        case let XCAPIError.unexpectedStatusCode(code): code >= 500 || code == 408 || code == 429
        default: false
        }
    }

    private func transfer(_ claim: PieceQueue.Claim, from pieces: PieceQueue, url: URL, file: RemoteFile) async throws {
        let transfer = RangeTransfer(task: session.dataTask(with: rangeRequest(
            url,
            from: claim.next,
            to: claim.end,
            validator: file.validator
        )))
        defer { transfer.cancel() }
        var isChecked = false
        for await event in transfer.events {
            switch event {
            case let .data(data):
                if !isChecked {
                    try check(transfer.response, startingAt: claim.next, file: file)
                    isChecked = true
                }
                if try await pieces.write(data, to: claim.index) {
                    return
                }
            case let .completed(error):
                try Task.checkCancellation()
                if let error {
                    throw PieceError.transfer(error)
                }
                try check(transfer.response, startingAt: claim.next, file: file)
                throw PieceError.incomplete
            }
        }
        try Task.checkCancellation()
        throw PieceError.incomplete
    }

    private func check(_ response: HTTPURLResponse?, startingAt start: Int64, file: RemoteFile) throws {
        guard let response else { throw PieceError.incomplete }
        if response.isUnauthorizedDownload {
            throw XCAPIError.unauthorized
        }
        switch response.statusCode {
        case 206:
            guard let range = response.contentRange, range.start == start, range.length == file.length else {
                throw PieceError.rangeIgnored
            }
        case 200 ..< 300:
            throw PieceError.rangeIgnored
        default:
            throw XCAPIError.unexpectedStatusCode(response.statusCode)
        }
    }
}
