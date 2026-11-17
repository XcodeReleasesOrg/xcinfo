//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import CryptoKit
import Foundation
import Security

struct AEAAuthData: Sendable, Equatable {
    static let certificateChainKey = "com.apple.ias.signature.certificate-chain"

    let entries: [String: Data]

    init(_ data: Data) throws {
        var entries: [String: Data] = [:]
        var offset = data.startIndex
        while offset < data.endIndex {
            guard data.endIndex - offset >= 4 else { throw AEAError.malformedAuthData }
            let size = data[offset ..< offset + 4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            guard size > 4, offset + size <= data.endIndex else { throw AEAError.malformedAuthData }
            let entry = data[offset + 4 ..< offset + size]
            guard let separator = entry.firstIndex(of: 0), let key = String(data: entry[entry.startIndex ..< separator], encoding: .utf8) else {
                throw AEAError.malformedAuthData
            }
            entries[key] = Data(entry[(separator + 1)...])
            offset += size
        }
        self.entries = entries
    }

    var certificates: [SecCertificate] {
        get throws {
            guard
                let chain = entries[Self.certificateChainKey],
                let pem = String(data: chain, encoding: .utf8)
            else { throw AEAError.untrusted("The archive has no signing certificate chain.") }
            let certificates = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().compactMap { block -> SecCertificate? in
                let body = block.components(separatedBy: "-----END CERTIFICATE-----")[0]
                guard let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { return nil }
                return SecCertificateCreateWithData(nil, der as CFData)
            }
            guard !certificates.isEmpty else { throw AEAError.untrusted("The signing certificate chain could not be read.") }
            return certificates
        }
    }
}

struct AEASigningTrust: Sendable {
    static let apple = AEASigningTrust(
        anchors: [],
        rootName: "Apple Root CA - G3",
        rootSHA256: "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
        intermediateCommonName: "Apple Platform Signing ECC CA 1 - G1"
    )

    let anchors: [Data]
    let rootName: String
    let rootSHA256: String
    let intermediateCommonName: String

    func signingKey(from authData: AEAAuthData) throws -> P256.Signing.PublicKey {
        let certificates = try authData.certificates
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust else {
            throw AEAError.untrusted("The signing certificates could not be checked.")
        }
        if !anchors.isEmpty {
            let anchorCertificates = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            SecTrustSetAnchorCertificates(trust, anchorCertificates as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            throw AEAError.untrusted("The signing certificate is not trusted: \(error.map { CFErrorCopyDescription($0) as String } ?? "unknown reason").")
        }
        guard
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            chain.count >= 3,
            let root = chain.last
        else { throw AEAError.untrusted("The signing certificate chain is incomplete.") }
        let rootHash = SHA256.hash(data: SecCertificateCopyData(root) as Data).map { String(format: "%02x", $0) }.joined()
        guard rootHash == rootSHA256 else {
            throw AEAError.untrusted("The signing certificate does not lead to \(rootName).")
        }
        var name: CFString?
        SecCertificateCopyCommonName(chain[1], &name)
        guard name as String? == intermediateCommonName else {
            throw AEAError.untrusted("The signing certificate was not issued by \(intermediateCommonName).")
        }
        guard
            let key = SecCertificateCopyKey(chain[0]),
            let representation = SecKeyCopyExternalRepresentation(key, nil) as Data?,
            let publicKey = try? P256.Signing.PublicKey(x963Representation: representation)
        else { throw AEAError.untrusted("The signing key is not a P-256 key.") }
        return publicKey
    }
}

enum AEAError: LocalizedError, Equatable {
    case notAnArchive
    case malformedAuthData
    case untrusted(String)
    case invalidSignature
    case unsupportedProfile(String)
    case archiveUtilityUnavailable(profile: String)
    case archiveUtilityFailed(String)
    case unexpectedContents(String)

    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            "The file is not an Apple Encrypted Archive."
        case .malformedAuthData:
            "The archive's authentication data could not be read."
        case let .untrusted(reason):
            "\(reason) Nothing was extracted."
        case .invalidSignature:
            "The archive's signature does not match its signing certificate. The file may be damaged or altered. Nothing was extracted."
        case let .unsupportedProfile(profile):
            "This archive uses the profile \(profile), which xcinfo cannot open itself."
        case let .archiveUtilityUnavailable(profile):
            "This archive uses the profile \(profile). Extracting it needs archiveutil, which comes with macOS 15 or later. Use a .xip of this version if Apple offers one."
        case let .archiveUtilityFailed(detail):
            "archiveutil could not extract the archive: \(detail)"
        case let .unexpectedContents(detail):
            detail
        }
    }
}
