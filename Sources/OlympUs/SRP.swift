//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import CommonCrypto
import CryptoKit
import Foundation

struct SRPGroup: Sendable {
    let prime: BigUInt
    let generator: BigUInt

    var length: Int {
        prime.byteCount
    }

    static let rfc5054_1024 = SRPGroup(
        prime: BigUInt(hex: """
        EEAF0AB9 ADB38DD6 9C33F80A FA8FC5E8 60726187 75FF3C0B 9EA2314C
        9C256576 D674DF74 96EA81D3 383B4813 D692C6E0 E0D5D8E2 50B98BE4
        8E495C1D 6089DAD1 5DC7D7B4 6154D6B6 CE8EF4AD 69B15D49 82559B29
        7BCF1885 C529F566 660E57EC 68EDBC3C 05726CC0 2FD4CBF4 976EAA9A
        FD5138FE 8376435B 9FC61D2F C0EB06E3
        """)!,
        generator: BigUInt(2)
    )

    static let rfc5054_2048 = SRPGroup(
        prime: BigUInt(hex: """
        AC6BDB41 324A9A9B F166DE5E 1389582F AF72B665 1987EE07 FC319294
        3DB56050 A37329CB B4A099ED 8193E075 7767A13D D52312AB 4B03310D
        CD7F48A9 DA04FD50 E8083969 EDB767B0 CF609517 9A163AB3 661A05FB
        D5FAAAE8 2918A996 2F0B93B8 55F97993 EC975EEA A80D740A DBF4FF74
        7359D041 D5C33EA7 1D281E44 6B14773B CA97B43A 23FB8016 76BD207A
        436C6481 F1D2B907 8717461A 5B9D32E6 88F87748 544523B5 24B0D57D
        5EA77A27 75D2ECFA 032CFBDB F52FB378 61602790 04E57AE6 AF874E73
        03CE5329 9CCC041C 7BC308D8 2A5698F3 A8D0C382 71AE35F8 E9DBFBB6
        94B5C803 D89F7AE4 35DE236D 525F5475 9B65E372 FCD68EF2 0FA7111F
        9E4AFF73
        """)!,
        generator: BigUInt(2)
    )
}

struct SRPHash: Sendable {
    let hash: @Sendable ([UInt8]) -> [UInt8]

    static let sha1 = SRPHash { Array(Insecure.SHA1.hash(data: $0)) }
    static let sha256 = SRPHash { Array(SHA256.hash(data: $0)) }

    func callAsFunction(_ parts: [UInt8]...) -> [UInt8] {
        hash(parts.flatMap { $0 })
    }
}

struct SRPProof: Sendable, Equatable {
    let clientProof: [UInt8]
    let expectedServerProof: [UInt8]
    let sessionKey: [UInt8]
    let premasterSecret: BigUInt
    let scrambler: BigUInt
}

enum SRPError: Error, Equatable {
    case invalidServerPublicKey
    case invalidScrambler
}

struct SRPClient: Sendable {
    let group: SRPGroup
    let hash: SRPHash
    let privateKey: BigUInt

    init(group: SRPGroup, hash: SRPHash, privateKey: BigUInt? = nil) {
        self.group = group
        self.hash = hash
        self.privateKey = privateKey ?? BigUInt(bigEndian: (0 ..< 32).map { _ in UInt8.random(in: .min ... .max) })
    }

    var publicKey: BigUInt {
        group.generator.power(privateKey, modulus: group.prime)
    }

    var multiplier: BigUInt {
        BigUInt(bigEndian: hash(group.prime.bytes(), group.generator.bytes(paddedTo: group.length)))
    }

    func passwordVerifierExponent(identity: String, password: [UInt8], salt: [UInt8]) -> BigUInt {
        let inner = hash(Array(identity.utf8), Array(":".utf8), password)
        return BigUInt(bigEndian: hash(salt, inner))
    }

    func scrambler(serverPublicKey: BigUInt) -> BigUInt {
        BigUInt(bigEndian: hash(publicKey.bytes(paddedTo: group.length), serverPublicKey.bytes(paddedTo: group.length)))
    }

    func proof(
        accountName: String,
        passwordIdentity: String,
        password: [UInt8],
        salt: [UInt8],
        serverPublicKey: BigUInt
    ) throws -> SRPProof {
        let prime = group.prime
        guard !(serverPublicKey % prime).isZero else {
            throw SRPError.invalidServerPublicKey
        }
        let u = scrambler(serverPublicKey: serverPublicKey)
        guard !u.isZero else {
            throw SRPError.invalidScrambler
        }

        let x = passwordVerifierExponent(identity: passwordIdentity, password: password, salt: salt)
        let gx = group.generator.power(x, modulus: prime)
        let kgx = (multiplier * gx) % prime
        let base = ((serverPublicKey % prime) + prime - kgx) % prime
        let exponent = privateKey + u * x
        let premasterSecret = base.power(exponent, modulus: prime)
        let sessionKey = hash(premasterSecret.bytes())

        let hashedPrime = hash(prime.bytes())
        let hashedGenerator = hash(group.generator.bytes())
        let xored = zip(hashedPrime, hashedGenerator).map { $0 ^ $1 }
        let clientProof = hash(
            xored,
            hash(Array(accountName.utf8)),
            salt,
            publicKey.bytes(),
            serverPublicKey.bytes(),
            sessionKey
        )
        let serverProof = hash(publicKey.bytes(), clientProof, sessionKey)

        return SRPProof(
            clientProof: clientProof,
            expectedServerProof: serverProof,
            sessionKey: sessionKey,
            premasterSecret: premasterSecret,
            scrambler: u
        )
    }
}

enum PasswordProtocol: String, Sendable, Codable {
    case s2k
    case s2kFo = "s2k_fo"
}

func derivedPasswordKey(password: String, salt: [UInt8], iterations: Int, protocol passwordProtocol: PasswordProtocol) -> [UInt8] {
    let digest = Array(SHA256.hash(data: Data(password.utf8)))
    let secret: [UInt8] = switch passwordProtocol {
    case .s2k:
        digest
    case .s2kFo:
        Array(digest.map { String(format: "%02x", $0) }.joined().utf8)
    }
    return pbkdf2SHA256(password: secret, salt: salt, iterations: iterations, keyLength: 32)
}

func pbkdf2SHA256(password: [UInt8], salt: [UInt8], iterations: Int, keyLength: Int) -> [UInt8] {
    var derived = [UInt8](repeating: 0, count: keyLength)
    let status = password.withUnsafeBufferPointer { passwordBuffer in
        passwordBuffer.withMemoryRebound(to: CChar.self) { passwordCharacters in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordCharacters.baseAddress,
                password.count,
                salt,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &derived,
                keyLength
            )
        }
    }
    precondition(status == kCCSuccess, "PBKDF2 failed with status \(status)")
    return derived
}
