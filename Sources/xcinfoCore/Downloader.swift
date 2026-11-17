//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
import Rainbow
import XCIFoundation

enum DownloadError: Error {
    case listUpdateError
}

struct Downloader: Sendable {
    static let maximumRetries = 3

    private let logger: Logger
    private let session: URLSession
    private let cachesDirectory: URL
    private let clock: any Clock<Duration>

    init(logger: Logger, session: URLSession, cachesDirectory: URL, clock: any Clock<Duration> = ContinuousClock()) {
        self.logger = logger
        self.session = session
        self.cachesDirectory = cachesDirectory
        self.clock = clock
    }

    private static func bytes(_ measurement: Measurement<UnitInformationStorage>) -> String {
        measurement.formatted(.byteCount(style: .file, spellsOutZero: false).locale(Locale(identifier: "en_US")))
    }

    func start(url: URL, disableSleep: Bool, resumeData: Data? = nil) async throws -> URL {
        let start = ContinuousClock.now

        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: url)
            request.addValue(
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                forHTTPHeaderField: "Accept"
            )
            request.addValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")

            task = session.downloadTask(with: request)
        }

        let download = FileDownload(
            task: task,
            logger: logger,
            disableSleep: disableSleep
        )

        logger.verbose(resumeData == nil ? "Starting download" : "Resuming download")
        logger.log("Source: \(url)")

        var progress = DownloadProgress()
        var lastDisplay: ContinuousClock.Instant?
        var lastMilestone = 0

        for await event in download.events {
            switch event {
            case let .progress(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite):
                progress.update(
                    bytesWritten: bytesWritten,
                    totalBytesWritten: totalBytesWritten,
                    totalBytesExpectedToWrite: totalBytesExpectedToWrite
                )
                let now = ContinuousClock.now
                let milestone = Int(progress.progress * 10)
                let isMilestone = milestone > lastMilestone
                if let lastDisplay, lastDisplay.duration(to: now) < .seconds(1), !isMilestone {
                    continue
                }
                lastDisplay = now
                lastMilestone = max(lastMilestone, milestone)

                var details = [
                    "\(Self.bytes(progress.remainingBytes)) of \(Self.bytes(progress.totalBytes)) remaining",
                ]
                if progress.downloadSpeed.value > 0 {
                    details.append("\(Self.bytes(progress.downloadSpeed))/s")
                }
                logger.progress(OutputProgress(
                    title: "Downloading",
                    fraction: progress.progress,
                    detail: details.joined(separator: ", "),
                    isMilestone: isMilestone
                ))
            case let .finished(downloadedURL):
                let downloadTime = start.duration(to: .now)
                logger.progress(OutputProgress(
                    title: "Downloading",
                    fraction: 1,
                    detail: "done in \(downloadTime.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))"
                ))

                guard let downloadedURL else {
                    throw XCAPIError.couldNotMoveToTemporaryFile
                }
                return downloadedURL
            case let .rejected(error):
                throw error
            case let .failed(resumeData, isCancelled):
                switch resumeData {
                case let resumeData? where isCancelled:
                    saveResumeData(resumeData, for: url)
                    throw XCAPIError.downloadInterrupted
                case let resumeData?:
                    throw XCAPIError.recoverableDownloadError(url: url, resumeData: resumeData)
                case nil:
                    throw XCAPIError.couldNotMoveToTemporaryFile
                }
            }
        }
        throw XCAPIError.downloadInterrupted
    }

    func cacheURL(for url: URL) -> URL? {
        let cache = cachesDirectory.appendingPathComponent("xcinfo")

        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false, attributes: nil)

        let fileName = url.appendingPathExtension("resume").lastPathComponent
        return cache.appendingPathComponent(fileName)
    }

    private func saveResumeData(_ resumeData: Data, for url: URL) {
        guard let targetURL = cacheURL(for: url) else {
            logger.error("Unable to save unfinished download")
            return
        }

        do {
            try resumeData.write(to: targetURL)
        } catch {
            logger.error("Unable to save unfinished download")
            logger.error(error.localizedDescription)
        }
    }

    func removeCachedResumeData(for url: URL) {
        guard let cacheURL = cacheURL(for: url) else {
            return
        }

        try? FileManager.default.removeItem(at: cacheURL)
    }

    func download(url: URL, destination: URL, disableSleep: Bool) async throws -> URL {
        var resumeData = cacheURL(for: url).flatMap { try? Data(contentsOf: $0) }

        let tmpURL: URL
        var retries = 0
        while true {
            do {
                tmpURL = try await start(url: url, disableSleep: disableSleep, resumeData: resumeData)
                break
            } catch let XCAPIError.recoverableDownloadError(_, recoveredResumeData) where retries < Self.maximumRetries {
                retries += 1
                resumeData = recoveredResumeData
                try await clock.sleep(for: .seconds(3))
            } catch let XCAPIError.recoverableDownloadError(_, recoveredResumeData) {
                saveResumeData(recoveredResumeData, for: url)
                throw XCAPIError.recoverableDownloadError(url: url, resumeData: recoveredResumeData)
            }
        }
        removeCachedResumeData(for: url)

        let destFile = destination.appendingPathComponent(tmpURL.lastPathComponent)
        do {
            try FileManager.default.ensureFolderExists(destination)
            if tmpURL != destFile {
                try FileManager.default.moveItem(at: tmpURL, to: destFile)
            }
            return destFile
        } catch let error as NSError {
            throw XCAPIError.couldNotMoveToDestinationFolder(tmpURL, destFile, error)
        }
    }
}
