//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

// Many thanks to Saagar Jha: https://github.com/saagarjha/unxip

import Foundation
import libunxip
import XCIFoundation

struct Unxip: Sendable {
    let input: URL
    let output: URL
    let logger: Logger

    func extract(progress: (@Sendable (Double) -> Void)?) async throws {
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        let total = try handle.seekToEnd()
        try handle.seek(toOffset: 0)

        let outputDescriptor = open(output.path, O_RDONLY | O_DIRECTORY)
        guard outputDescriptor >= 0 else {
            throw CoreError.invalidExtractionOutputURL(output)
        }
        defer { close(outputDescriptor) }

        let chunks = FileChunks(handle: handle, total: total, progress: progress)
        for try await file in libunxip.Unxip.makeStream(
            from: .xip(),
            to: .disk(),
            input: DataReader(data: chunks),
            nil,
            nil,
            .init(compress: true, dryRun: false, output: outputDescriptor)
        ) {
            logger.verbose("Extracted: \(file.name)")
        }
    }
}

struct FileChunks: AsyncSequence, Sendable {
    typealias Element = [UInt8]

    let handle: FileHandle
    let total: UInt64
    let progress: (@Sendable (Double) -> Void)?
    var chunkSize = Int(PIPE_SIZE) * 16

    struct AsyncIterator: AsyncIteratorProtocol {
        let chunks: FileChunks
        var read: UInt64 = 0

        mutating func next() async throws -> [UInt8]? {
            guard let data = try chunks.handle.read(upToCount: chunks.chunkSize), !data.isEmpty else {
                return nil
            }
            read += UInt64(data.count)
            if chunks.total > 0 {
                chunks.progress?(Double(read) / Double(chunks.total))
            }
            return [UInt8](data)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: self)
    }
}
