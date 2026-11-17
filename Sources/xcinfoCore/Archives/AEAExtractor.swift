//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import AppleArchive
import Foundation
import System
import XCIFoundation

struct AEAExtractor: Sendable {
    typealias ArchiveUtility = @Sendable (_ archive: URL, _ workingDirectory: URL) async throws -> ProcessResult

    let trust: AEASigningTrust
    let archiveUtility: ArchiveUtility?
    let logger: Logger

    func extract(_ source: URL, into directory: URL) async throws {
        do {
            try await extractWithAppleArchive(source, into: directory)
        } catch let AEAError.unsupportedProfile(profile) {
            guard let archiveUtility else { throw AEAError.archiveUtilityUnavailable(profile: profile) }
            logger.verbose("The archive uses the profile \(profile). Extracting it with archiveutil.")
            try await extractWithArchiveUtility(archiveUtility, source, into: directory)
        }
    }

    private func extractWithArchiveUtility(_ archiveUtility: ArchiveUtility, _ source: URL, into directory: URL) async throws {
        logger.check("Extracting with archiveutil", .running)
        let result = try await archiveUtility(source, directory)
        guard result.exitStatus == EXIT_SUCCESS else {
            logger.check("Extracting with archiveutil", .failed)
            let detail = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit status \(result.exitStatus)"
            throw AEAError.archiveUtilityFailed(detail)
        }
        logger.check("Extracting with archiveutil", .passed)
        for line in result.stdout.split(separator: "\n") {
            logger.verbose(String(line))
        }
    }

    private func extractWithAppleArchive(_ source: URL, into directory: URL) async throws {
        let (progressUpdates, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let trust = trust
        let logger = logger
        async let extraction: Void = {
            defer { continuation.finish() }
            try AppleArchiveExtraction(source: source, directory: directory, trust: trust, logger: logger)
                .run { continuation.yield($0) }
        }()

        var milestones = ProgressMilestones()
        for await progress in progressUpdates {
            logger.progress(OutputProgress(title: "Extracting", fraction: min(progress, 0.999), isMilestone: milestones.reached(progress)))
        }
        try await extraction
    }
}

private struct AppleArchiveExtraction {
    let source: URL
    let directory: URL
    let trust: AEASigningTrust
    let logger: Logger

    func run(progress: @escaping @Sendable (Double) -> Void) throws {
        guard let file = ArchiveByteStream.fileStream(
            path: FilePath(source.path),
            mode: .readOnly,
            options: [],
            permissions: FilePermissions(rawValue: 0o644)
        ) else { throw AEAError.notAnArchive }
        defer { try? file.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
        guard let counted = ArchiveByteStream.customStream(instance: ProgressReportingStream(inner: file, size: size, report: progress)) else {
            throw AEAError.notAnArchive
        }
        defer { try? counted.close() }

        guard let context = ArchiveEncryptionContext(from: counted) else { throw AEAError.notAnArchive }
        guard context.profile == .hkdf_sha256_hmac__none__ecdsa_p256 else {
            throw AEAError.unsupportedProfile(context.profile.name)
        }
        guard let authData = context.authData else { throw AEAError.untrusted("The archive has no signing certificate chain.") }
        let signingKey = try trust.signingKey(from: AEAAuthData(authData))
        logger.verbose("The archive is signed by a certificate that leads to \(trust.rootName).")
        try context.setSigningPublicKey(signingKey)

        guard let decrypted = ArchiveByteStream.decryptionStream(readingFrom: counted, encryptionContext: context) else {
            throw AEAError.invalidSignature
        }
        defer { try? decrypted.close() }
        guard let decoder = ArchiveStream.decodeStream(readingFrom: decrypted) else { throw AEAError.invalidSignature }
        defer { try? decoder.close() }
        guard let writer = ArchiveStream.extractStream(extractingTo: FilePath(directory.path), flags: [.ignoreOperationNotPermitted]) else {
            throw AEAError.unexpectedContents("The extraction folder \(directory.path) could not be opened.")
        }
        defer { try? writer.close() }
        _ = try ArchiveStream.process(readingFrom: decoder, writingTo: writer)
    }
}

final class ProgressReportingStream: ArchiveByteStreamProtocol {
    let inner: ArchiveByteStream
    let size: Int64
    let report: @Sendable (Double) -> Void

    init(inner: ArchiveByteStream, size: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.inner = inner
        self.size = size
        self.report = report
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = try inner.read(into: buffer)
        reportPosition()
        return count
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int {
        let count = try inner.read(into: buffer, atOffset: offset)
        if size > 0 {
            report(Double(offset + Int64(count)) / Double(size))
        }
        return count
    }

    func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
        try inner.write(from: buffer)
    }

    func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int {
        try inner.write(from: buffer, atOffset: offset)
    }

    func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 {
        try inner.seek(toOffset: offset, relativeTo: origin)
    }

    func cancel() {
        inner.cancel()
    }

    func close() throws {}

    private func reportPosition() {
        guard size > 0, let position = try? inner.seek(toOffset: 0, relativeTo: .current) else { return }
        report(Double(position) / Double(size))
    }
}

extension ArchiveEncryptionContext.Profile {
    var name: String {
        switch self {
        case .hkdf_sha256_hmac__none__ecdsa_p256: "signed (hkdf_sha256_hmac__none__ecdsa_p256)"
        case .hkdf_sha256_aesctr_hmac__symmetric__none: "symmetric key (hkdf_sha256_aesctr_hmac__symmetric__none)"
        case .hkdf_sha256_aesctr_hmac__symmetric__ecdsa_p256: "symmetric key, signed (hkdf_sha256_aesctr_hmac__symmetric__ecdsa_p256)"
        case .hkdf_sha256_aesctr_hmac__ecdhe_p256__none: "ECDHE (hkdf_sha256_aesctr_hmac__ecdhe_p256__none)"
        case .hkdf_sha256_aesctr_hmac__ecdhe_p256__ecdsa_p256: "ECDHE, signed (hkdf_sha256_aesctr_hmac__ecdhe_p256__ecdsa_p256)"
        case .hkdf_sha256_aesctr_hmac__scrypt__none: "password (hkdf_sha256_aesctr_hmac__scrypt__none)"
        default: "unknown"
        }
    }
}

extension Extractor {
    func extractAEA(trust: AEASigningTrust, archiveUtility: AEAExtractor.ArchiveUtility?) async throws -> URL {
        let target = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: target) }
        logger.verbose("Extracting the .aea archive into a temporary folder: \(target.path)")

        try await AEAExtractor(trust: trust, archiveUtility: archiveUtility, logger: logger).extract(source, into: target)
        logger.progress(OutputProgress(title: "Extracting", fraction: 1, isFinished: true))

        let bundles = try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return url.pathExtension == "app" && values?.isDirectory == true && values?.isSymbolicLink != true
            }
        guard bundles.count == 1, let bundle = bundles.first, Bundle(url: bundle)?.bundleIdentifier == "com.apple.dt.Xcode" else {
            throw AEAError.unexpectedContents("The archive did not contain exactly one Xcode app.")
        }
        let targetURL = destination.appendingPathComponent(appFilename ?? bundle.lastPathComponent)
        logger.verbose("Moving application to \(targetURL.path)")
        do {
            try FileManager.default.moveItem(at: bundle, to: targetURL)
        } catch {
            throw ExtractionError("Application could not be moved to \(destination.path): \(error.localizedDescription)")
        }
        return targetURL
    }
}

struct AEASignatureCheck {
    let source: URL
    let trust: AEASigningTrust

    func run(progress: @escaping @Sendable (Double) -> Void) throws {
        guard let file = ArchiveByteStream.fileStream(
            path: FilePath(source.path),
            mode: .readOnly,
            options: [],
            permissions: FilePermissions(rawValue: 0o644)
        ) else { throw AEAError.notAnArchive }
        defer { try? file.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
        guard let counted = ArchiveByteStream.customStream(instance: ProgressReportingStream(inner: file, size: size, report: progress)) else {
            throw AEAError.notAnArchive
        }
        defer { try? counted.close() }
        guard let context = ArchiveEncryptionContext(from: counted) else { throw AEAError.notAnArchive }
        guard context.profile == .hkdf_sha256_hmac__none__ecdsa_p256 else {
            throw AEAError.unsupportedProfile(context.profile.name)
        }
        guard let authData = context.authData else { throw AEAError.untrusted("The archive has no signing certificate chain.") }
        try context.setSigningPublicKey(trust.signingKey(from: AEAAuthData(authData)))
        guard let decrypted = ArchiveByteStream.decryptionStream(readingFrom: counted, encryptionContext: context) else {
            throw AEAError.invalidSignature
        }
        defer { try? decrypted.close() }
        guard let sink = ArchiveByteStream.customStream(instance: DiscardingStream()) else { throw AEAError.notAnArchive }
        defer { try? sink.close() }
        do {
            _ = try ArchiveByteStream.process(readingFrom: decrypted, writingTo: sink)
        } catch {
            throw AEAError.invalidSignature
        }
    }
}

private final class DiscardingStream: ArchiveByteStreamProtocol {
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int { 0 }
    func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int { 0 }
    func write(from buffer: UnsafeRawBufferPointer) throws -> Int { buffer.count }
    func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int { buffer.count }
    func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 { offset }
    func cancel() {}
    func close() throws {}
}
