//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
import XCIFoundation
import XCUnxip

struct Extractor: Sendable {
    struct ExtractionError: LocalizedError {
        var errorDescription: String?

        init(_ errorDescription: String) {
            self.errorDescription = errorDescription
        }
    }

    let source: URL
    let destination: URL
    let appFilename: String?

    private let temporaryDirectory: URL
    private let logger: Logger

    init(
        forReadingFromContainerAt url: URL,
        destination: URL,
        appFilename: String?,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        logger: Logger
    ) {
        source = url
        self.destination = destination
        self.appFilename = appFilename
        self.temporaryDirectory = temporaryDirectory
        self.logger = logger
    }

    func extractExperimental() async throws -> URL {
        let target = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.ensureFolderExists(target)
        defer { try? FileManager.default.removeItem(at: target) }

        logger.log("")
        logger.verbose("Extracting xip to \(target.path)", onSameLine: true)

        let (progressUpdates, continuation) = AsyncStream.makeStream(
            of: Double.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        async let extraction: Void = {
            defer { continuation.finish() }
            try await Unxip(input: source, output: target, logger: logger)
                .extract { progress in
                    continuation.yield(progress)
                }
        }()

        let input = source.lastPathComponent
        var previouslyDisplayedNonANSIProgress = -1
        var progressDisplay = ProgressDisplay(ratio: 0, width: 20)
        for await progress in progressUpdates {
            progressDisplay.ratio = progress
            if Logger.isANSIEnabled && !logger.isVerbose {
                logger.log("\(progressDisplay.representation)", onSameLine: true)
            } else {
                let percent = Int(progress * 100)
                if percent.isMultiple(of: 5), previouslyDisplayedNonANSIProgress != Int(progress) {
                    if progress < 1 {
                        logger.log("Expanding items from \(input): \(percent) %")
                    }
                    previouslyDisplayedNonANSIProgress = percent
                }
            }
        }
        try await extraction

        logger.success("Done extracting: \(target.path)")

        if let applicationURL = moveToDestinationFolder(tempFolder: target) {
            return applicationURL
        } else {
            throw ExtractionError("Application could not be moved to \(destination.path).")
        }
    }

    private enum UnarchivingEvent: Sendable {
        case progress(Double, String)
        case finished
    }

    func extract() async throws -> URL {
        let container: PKSignedContainer
        do {
            container = try PKSignedContainer(forReadingFromContainerAt: source)
        } catch {
            throw ExtractionError(error.localizedDescription)
        }

        let target = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target) }
        logger.verbose("Extracting xip to \(target.path)")

        let (events, continuation) = AsyncStream.makeStream(of: UnarchivingEvent.self)
        container.startUnarchiving(atPath: target.path, notifyOn: .main, progress: { progress, statusMessage in
            continuation.yield(.progress(progress, statusMessage))
        }, finish: { _ in
            continuation.yield(.finished)
            continuation.finish()
        })

        var previouslyDisplayedNonANSIProgress = -1
        var progressDisplay = ProgressDisplay(ratio: 0, width: 20)
        for await event in events {
            guard case let .progress(progress, statusMessage) = event else { break }
            let ratio = progress / 100
            switch ratio {
            case _ where ratio < 0:
                logger.log(statusMessage)
            case _ where ratio > 1:
                logger.log("Probably done: \(statusMessage)")
            default:
                progressDisplay.ratio = ratio
                if Logger.isANSIEnabled {
                    logger.log("\(progressDisplay.representation)", onSameLine: true)
                } else {
                    if Int(progress).isMultiple(of: 5), previouslyDisplayedNonANSIProgress != Int(progress) {
                        logger.log("\(statusMessage.isEmpty ? "Done" : statusMessage): \(Int(progress)) %")
                        previouslyDisplayedNonANSIProgress = Int(progress)
                    }
                }
            }
        }
        withExtendedLifetime(container) {}

        guard FileManager.default.fileExists(atPath: target.path) else {
            let result = try await ProcessRunner.run("/usr/bin/xip", arguments: ["--expand", source.path])
            let prefix = "xip: error: "
            throw ExtractionError(String(result.stderr.suffix(from: prefix.endIndex)))
        }

        logger.success("Done extracting: \(target.path)")
        if let applicationURL = moveToDestinationFolder(tempFolder: target) {
            return applicationURL
        } else {
            logger.error("Extraction failed", onSameLine: true)
            throw ExtractionError("Application could not be moved to \(destination.path).")
        }
    }

    private func moveToDestinationFolder(tempFolder: URL) -> URL? {
        let fileManager = FileManager.default

        let appName: String
        var sourceURL: URL = tempFolder.appendingPathComponent("Xcode.app")
        if !fileManager.fileExists(atPath: sourceURL.path) {
            sourceURL = tempFolder.appendingPathComponent("Xcode-beta.app")
            appName = appFilename ?? "Xcode-beta.app"
            if !fileManager.fileExists(atPath: sourceURL.path) {
                return nil
            }
        } else {
            appName = appFilename ?? "Xcode.app"
        }

        let targetURL = destination.appendingPathComponent(appName)
        logger.verbose("Moving application to \(targetURL.path)")
        do {
            try fileManager.moveItem(at: sourceURL, to: targetURL)
            return targetURL
        } catch {
            logger.error("Moving application failed. Error: \(error.localizedDescription)")
            return nil
        }
    }
}
