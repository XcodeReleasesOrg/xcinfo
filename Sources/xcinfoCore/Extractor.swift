//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see LICENSE.md
//

import Foundation
import XCIFoundation

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

    let temporaryDirectory: URL
    let logger: Logger

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

    func extractXIP() async throws -> URL {
        let target = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.ensureFolderExists(target)
        defer { try? FileManager.default.removeItem(at: target) }

        logger.verbose("Extracting the .xip archive into a temporary folder: \(target.path)")

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

        var milestones = ProgressMilestones()
        for await progress in progressUpdates {
            logger.progress(OutputProgress(
                title: "Extracting",
                fraction: min(progress, 0.999),
                isMilestone: milestones.reached(progress)
            ))
        }
        try await extraction
        logger.progress(OutputProgress(title: "Extracting", fraction: 1, isFinished: true))
        logger.verbose("Done extracting: \(target.path)")

        if let applicationURL = moveToDestinationFolder(tempFolder: target) {
            return applicationURL
        } else {
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

struct ProgressMilestones {
    private var reachedTenths = 0

    mutating func reached(_ fraction: Double) -> Bool {
        let tenths = Int(fraction * 10)
        guard tenths > reachedTenths else { return false }
        reachedTenths = tenths
        return true
    }
}
