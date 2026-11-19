//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
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

        if resumeData == nil {
            logger.verbose("Starting download")
        }
        logger.log("Source: \(url)")

        do {
            return try await follow(download, url: url, start: start)
        } catch XCAPIError.downloadInterrupted where Task.isCancelled {
            if let resumeData = await download.cancel() {
                saveResumeData(resumeData, for: url)
                logger.log("The download is paused. Start it again to resume where it stopped.")
            } else {
                logger.warn("The download stopped before any progress could be saved. It starts over next time.")
            }
            throw XCAPIError.downloadInterrupted
        }
    }

    private func follow(_ download: FileDownload, url: URL, start: ContinuousClock.Instant) async throws -> URL {
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
                let isMilestone = milestone > lastMilestone && milestone < 10
                if let lastDisplay, lastDisplay.duration(to: now) < .seconds(1), !isMilestone {
                    continue
                }
                lastDisplay = now
                lastMilestone = max(lastMilestone, milestone)

                var details = [
                    "\(Self.bytes(progress.remainingBytes)) of \(Self.bytes(progress.totalBytes)) remaining"
                ]
                if progress.downloadSpeed.value > 0 {
                    details.append("\(Self.bytes(progress.downloadSpeed))/s")
                    let secondsLeft = progress.remainingBytes.value / progress.downloadSpeed.value
                    if secondsLeft.isFinite, secondsLeft >= 1 {
                        details.append("about \(Duration.seconds(Int(secondsLeft)).englishDescription) left")
                    }
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
                    detail: "done in \(downloadTime.englishDescription)",
                    isFinished: true
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
                    logger.log("The download is paused. Start it again to resume where it stopped.")
                    throw XCAPIError.downloadInterrupted
                case nil where isCancelled:
                    logger.warn("The download stopped before any progress could be saved. It starts over next time.")
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
        try? FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)
        return cachesDirectory.appendingPathComponent(url.appendingPathExtension("resume").lastPathComponent)
    }

    private func legacyCacheURL(for url: URL) -> URL {
        cachesDirectory.appendingPathComponent("xcinfo").appendingPathComponent(url.appendingPathExtension("resume").lastPathComponent)
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
        try? FileManager.default.removeItem(at: legacyCacheURL(for: url))
        guard let cacheURL = cacheURL(for: url) else {
            return
        }

        try? FileManager.default.removeItem(at: cacheURL)
    }

    func cachedResumeData(for url: URL) -> ResumeData? {
        guard
            let cacheURL = cacheURL(for: url),
            let data = (try? Data(contentsOf: cacheURL)) ?? (try? Data(contentsOf: legacyCacheURL(for: url)))
        else { return nil }
        guard let resumeData = ResumeData(data, for: url) else {
            logger.warn("The saved progress of an earlier download could not be used. The download starts over.")
            removeCachedResumeData(for: url)
            return nil
        }
        return resumeData
    }

    func download(url: URL, destination: URL, disableSleep: Bool) async throws -> URL {
        let cached = cachedResumeData(for: url)
        if let cached {
            let received = cached.bytesReceived.map { bytes in
                ", \(Self.bytes(Measurement(value: Double(bytes), unit: .bytes))) already downloaded"
            }
            logger.log("Resuming the earlier download\(received ?? "").")
        }
        var resumeData = cached?.data
        var isResumingCachedDownload = cached != nil

        let tmpURL: URL
        var retries = 0
        while true {
            do {
                tmpURL = try await start(url: url, disableSleep: disableSleep, resumeData: resumeData)
                break
            } catch XCAPIError.downloadInterrupted {
                throw XCAPIError.downloadInterrupted
            } catch let XCAPIError.recoverableDownloadError(_, recoveredResumeData) where retries < Self.maximumRetries {
                retries += 1
                logger.verbose("The download failed. Retrying where it stopped (\(retries) of \(Self.maximumRetries)).")
                resumeData = recoveredResumeData
                isResumingCachedDownload = false
                try await clock.sleep(for: .seconds(3))
            } catch let XCAPIError.recoverableDownloadError(_, recoveredResumeData) {
                saveResumeData(recoveredResumeData, for: url)
                throw XCAPIError.recoverableDownloadError(url: url, resumeData: recoveredResumeData)
            } catch where isResumingCachedDownload && !Task.isCancelled {
                logger.warn("The earlier download could not be resumed (\(error)). Starting over.")
                removeCachedResumeData(for: url)
                resumeData = nil
                isResumingCachedDownload = false
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

struct ResumeData: Sendable, Equatable {
    let data: Data
    let bytesReceived: Int64?

    init?(_ data: Data, for url: URL) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        if plist["$archiver"] as? String == "NSKeyedArchiver", plist["$top"] != nil {
            let archived = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [
                    NSDictionary.self,
                    NSArray.self,
                    NSString.self,
                    NSNumber.self,
                    NSData.self,
                    NSDate.self,
                    NSURL.self,
                    NSURLRequest.self
                ],
                from: data
            ) as? [String: Any]
            if let downloadURL = archived?["NSURLSessionDownloadURL"] as? String, downloadURL != url.absoluteString {
                return nil
            }
            self.data = data
            bytesReceived = (archived?["NSURLSessionResumeBytesReceived"] as? NSNumber)?.int64Value
            return
        }
        guard plist["NSURLSessionResumeInfoVersion"] != nil else { return nil }
        if let downloadURL = plist["NSURLSessionDownloadURL"] as? String, downloadURL != url.absoluteString {
            return nil
        }
        self.data = data
        bytesReceived = (plist["NSURLSessionResumeBytesReceived"] as? NSNumber)?.int64Value
    }
}

extension Duration {
    var englishDescription: String {
        formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated).locale(Locale(identifier: "en_US")))
    }
}
