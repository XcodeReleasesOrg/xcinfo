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

    private static func string(fromByteCount measurement: Measurement<UnitInformationStorage>) -> String {
        let formatter = ByteCountFormatter()
        formatter.zeroPadsFractionDigits = true
        return formatter.string(from: measurement)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "jms", options: 0, locale: nil)
        return formatter.string(from: Date())
    }

    func start(url: URL, disableSleep: Bool, resumeData: Data? = nil) async throws -> URL {
        var progressDisplay = ProgressDisplay(ratio: 0, width: 20)
        let start = Date()

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

        if resumeData == nil {
            logger.verbose("[\(Self.timestamp())] Starting download")
        } else {
            logger.verbose("[\(Self.timestamp())] Resuming download")
        }

        logger.log("Source: \(url)")
        var hasLoggedTotalSize = false
        var previouslyDisplayedNonANSIProgress = -1
        var progress = DownloadProgress()
        let clock = ContinuousClock()
        var lastDisplay: ContinuousClock.Instant?

        for await event in download.events {
            switch event {
            case let .progress(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite):
                progress.update(
                    bytesWritten: bytesWritten,
                    totalBytesWritten: totalBytesWritten,
                    totalBytesExpectedToWrite: totalBytesExpectedToWrite
                )
                let now = clock.now
                if let lastDisplay, lastDisplay.duration(to: now) < .seconds(1) {
                    continue
                }
                lastDisplay = now

                if !hasLoggedTotalSize {
                    logger.log(
                        "Source: \(url) (\(Self.string(fromByteCount: progress.totalBytes)))\n",
                        onSameLine: true
                    )
                    hasLoggedTotalSize = true
                }
                if Logger.isANSIEnabled {
                    progressDisplay.ratio = progress.progress
                    let logMessage = [
                        progressDisplay.representation,
                        "remaining: \(Self.string(fromByteCount: progress.remainingBytes))",
                        "speed: \(Self.string(fromByteCount: progress.downloadSpeed))/s"
                    ].joined(separator: ", ")
                    logger.log(logMessage, onSameLine: true)
                } else {
                    let percent = Int(100 * progress.progress)
                    print(String(format: "%.1f %", 100 * progress.progress))
                    if percent.isMultiple(of: 5), previouslyDisplayedNonANSIProgress != percent {
                        logger.log("Download progress: \(percent) %")
                        previouslyDisplayedNonANSIProgress = percent
                    }
                }
            case let .finished(downloadedURL):
                let downloadTime = Date().timeIntervalSinceReferenceDate - start.timeIntervalSinceReferenceDate
                if Logger.isANSIEnabled {
                    progressDisplay.ratio = 1
                    let formatter = DateComponentsFormatter()
                    formatter.unitsStyle = .abbreviated
                    formatter.allowedUnits = [.hour, .minute, .second]
                    let logMessage = [
                        progressDisplay.representation,
                        "Download time: \(formatter.string(from: downloadTime) ?? "???")"
                    ].joined(separator: ", ")
                    logger.log(logMessage, onSameLine: true)
                } else {
                    logger.log("Download progress: 100 %")
                }

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
