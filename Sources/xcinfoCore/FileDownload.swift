//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
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
    private let sleepAssertion: SleepAssertion?

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

        sleepAssertion = disableSleep ? SleepAssertion(logger: logger) : nil
        super.init()

        task.delegate = self
        task.resume()
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse {
            if response.isUnauthorizedDownload {
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

        sleepAssertion?.release()
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

final class SleepAssertion: Sendable {
    private let id: IOPMAssertionID
    private let logger: Logger

    init?(logger: Logger) {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Preventing sleep during large file download" as CFString,
            &id
        )
        logger.verbose("Sleep temporary disabled: \(result == 0)")
        guard result == 0 else { return nil }
        self.id = id
        self.logger = logger
    }

    func release() {
        let result = IOPMAssertionRelease(id)
        logger.verbose("Sleep enabled again: \(result == 0)")
    }
}

struct DownloadProgressReport {
    private var progress = DownloadProgress()
    private var lastDisplay: ContinuousClock.Instant?
    private var lastMilestone = 0
    private var lastTotal: Int64

    init(alreadyReceived: Int64 = 0) {
        lastTotal = alreadyReceived
    }

    static func bytes(_ count: Int64) -> String {
        bytes(Measurement(value: Double(count), unit: .bytes))
    }

    static func bytes(_ measurement: Measurement<UnitInformationStorage>) -> String {
        measurement.formatted(.byteCount(style: .file, spellsOutZero: false).locale(Locale(identifier: "en_US")))
    }

    static func finished(after duration: Duration) -> OutputProgress {
        OutputProgress(
            title: "Downloading",
            fraction: 1,
            detail: "done in \(duration.englishDescription)",
            isFinished: true
        )
    }

    mutating func update(
        bytesWritten: Int64? = nil,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) -> OutputProgress? {
        guard totalBytesExpectedToWrite > 0 else { return nil }
        progress.update(
            bytesWritten: bytesWritten ?? totalBytesWritten - lastTotal,
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )
        lastTotal = totalBytesWritten
        let now = ContinuousClock.now
        let milestone = Int(progress.progress * 10)
        let isMilestone = milestone > lastMilestone && milestone < 10
        if let lastDisplay, lastDisplay.duration(to: now) < .seconds(1), !isMilestone {
            return nil
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
        return OutputProgress(
            title: "Downloading",
            fraction: progress.progress,
            detail: details.joined(separator: ", "),
            isMilestone: isMilestone
        )
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

    mutating func append(_ value: Double, at date: Date = Date()) {
        while let first = buffer.first, date.timeIntervalSince(first.date) > 10 {
            buffer.remove(at: 0)
        }
        buffer.append(SpeedMeasurement(value: value, date: date))
    }

    func averageSpeed() -> Double {
        guard buffer.count > 1 else { return -1 }

        let deltaTime = buffer.last!.date.timeIntervalSince(buffer.first!.date)
        return buffer.reduce(0) { $0 + $1.value } / deltaTime
    }
}
