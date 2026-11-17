//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see LICENSE.md
//

import Foundation
import IOKit
import IOKit.pwr_mgt
import XCIFoundation

final class FileDownload: NSObject, URLSessionDownloadDelegate, Sendable {
    enum Event: Sendable {
        case progress(bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64)
        case finished(downloadedURL: URL?)
        case rejected(XCAPIError)
        case failed(resumeData: Data?, isCancelled: Bool)
    }

    let name: String
    let events: AsyncStream<Event>

    private let continuation: AsyncStream<Event>.Continuation
    private let task: URLSessionDownloadTask
    private let logger: Logger
    private let sleepAssertionID: IOPMAssertionID

    init(
        task: URLSessionDownloadTask,
        logger: Logger,
        disableSleep: Bool = false
    ) {
        name = task.originalRequest?.url?.absoluteString ?? task.currentRequest?.url?
            .absoluteString ?? "<unnnamed download>"
        self.task = task
        self.logger = logger
        (events, continuation) = AsyncStream.makeStream(of: Event.self)

        var sleepAssertionID: IOPMAssertionID = 0
        if disableSleep {
            let reasonForActivity = "Preventing sleep during large file download"
            let success = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reasonForActivity as CFString,
                &sleepAssertionID
            )
            logger.verbose("Sleep temporary disabled: \(success == 0)")
        }
        self.sleepAssertionID = sleepAssertionID
        super.init()

        task.delegate = self
        task.resume()
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse {
            if response.url?.absoluteString.hasPrefix("https://developer.apple.com/unauthorized") == true {
                finish(with: .rejected(.unauthorized))
                return
            }
            guard (200 ..< 300).contains(response.statusCode) else {
                finish(with: .rejected(.unexpectedStatusCode(response.statusCode)))
                return
            }
        }

        let fileName = (name as NSString).lastPathComponent
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = folder.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: target)
            finish(with: .finished(downloadedURL: target))
        } catch {
            logger.error("Could not move temporary file from\n\(location)\nto\n\(target)")
            finish(with: .failed(resumeData: nil, isCancelled: false))
        }
    }

    private func finish(with event: Event) {
        continuation.yield(event)
        continuation.finish()

        if sleepAssertionID != 0 {
            let success = IOPMAssertionRelease(sleepAssertionID)
            logger.verbose("Sleep enabled again: \(success == 0)")
        }
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        continuation.yield(
            .progress(
                bytesWritten: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
        )
    }

    func cancel() async -> Data? {
        await withCheckedContinuation { continuation in
            task.cancel { resumeData in
                continuation.resume(returning: resumeData)
            }
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as? URLError else {
            return
        }
        if error.code == .cancelled, error.downloadTaskResumeData == nil {
            finish(with: .failed(resumeData: nil, isCancelled: true))
            return
        }
        if error.code != .cancelled {
            logger.error(error.localizedDescription)
        }
        finish(with: .failed(resumeData: error.downloadTaskResumeData, isCancelled: error.code == .cancelled))
    }
}

struct DownloadProgress {
    private(set) var progress: Double = 0
    private var totalBytesExpectedToWriteValue: Double = 0
    private var downloadSpeedValues = SpeedMeasurements()

    mutating func update(bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        totalBytesExpectedToWriteValue = Double(totalBytesExpectedToWrite)
        downloadSpeedValues.append(Double(bytesWritten))
    }

    var totalBytes: Measurement<UnitInformationStorage> {
        Measurement<UnitInformationStorage>(value: totalBytesExpectedToWriteValue, unit: .bytes)
    }

    var remainingBytes: Measurement<UnitInformationStorage> {
        let bytesRemaining = max(0, totalBytesExpectedToWriteValue - totalBytesExpectedToWriteValue * progress)
        return Measurement<UnitInformationStorage>(value: bytesRemaining, unit: .bytes)
    }

    var downloadSpeed: Measurement<UnitInformationStorage> {
        Measurement<UnitInformationStorage>(value: downloadSpeedValues.averageSpeed(), unit: .bytes)
    }
}

struct SpeedMeasurement {
    var value: Double
    let date: Date
}

struct SpeedMeasurements {
    private var buffer: [SpeedMeasurement]

    init() {
        buffer = []
    }

    mutating func append(_ value: Double) {
        let now = Date()
        while let first = buffer.first, now.timeIntervalSince(first.date) > 10 {
            buffer.remove(at: 0)
        }
        buffer.append(SpeedMeasurement(value: value, date: now))
    }

    func averageSpeed() -> Double {
        guard buffer.count > 1 else { return -1 }

        let deltaTime = buffer.last!.date.timeIntervalSince(buffer.first!.date)
        return buffer.reduce(0) { $0 + $1.value } / deltaTime
    }
}
