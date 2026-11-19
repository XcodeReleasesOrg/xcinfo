//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import CryptoKit
import Foundation
import XCIFoundation

struct ArchiveChecksum: Sendable {
    static let chunkSize = 8 * 1_024 * 1_024

    let url: URL

    func sha1(logger: Logger) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        var hash = Insecure.SHA1()
        var read: Int64 = 0
        var milestones = ProgressMilestones()
        while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
            read += Int64(chunk.count)
            let fraction = size > 0 ? min(0.999, Double(read) / Double(size)) : 0
            logger.progress(OutputProgress(title: "Verifying", fraction: fraction, isMilestone: milestones.reached(fraction)))
            await Task.yield()
        }
        logger.progress(OutputProgress(title: "Verifying", fraction: 1, detail: "SHA-1 checked", isFinished: true))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
