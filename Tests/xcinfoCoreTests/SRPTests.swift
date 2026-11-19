import CryptoKit
import Foundation
@testable import OlympUs
import Testing

private func hex(_ string: String) -> BigUInt {
    BigUInt(hex: string)!
}

private func bytes(_ string: String) -> [UInt8] {
    hex(string).bytes()
}

private extension BigUInt {
    func isProbablePrime(rounds: [UInt64]) -> Bool {
        let one = BigUInt.one
        let minusOne = self - one
        var d = minusOne
        var r = 0
        while !d.bit(at: 0) {
            d = d.shiftedRight(by: 1)
            r += 1
        }
        witness: for base in rounds {
            var x = BigUInt(base).power(d, modulus: self)
            if x == one || x == minusOne {
                continue
            }
            for _ in 0 ..< r - 1 {
                x = (x * x) % self
                if x == minusOne {
                    continue witness
                }
            }
            return false
        }
        return true
    }
}

struct BigUIntTests {
    @Test
    func `arithmetic matches 64-bit arithmetic`() {
        let values: [UInt64] = [0, 1, 2, 3, 0xffffffff, 0x100000000, 0x123456789abc, UInt64(UInt32.max) * 3]
        for a in values {
            for b in values {
                #expect(BigUInt(a) + BigUInt(b) == BigUInt(UInt64(a).addingReportingOverflow(b).partialValue))
                if a >= b {
                    #expect(BigUInt(a) - BigUInt(b) == BigUInt(a - b))
                }
                if b > 0 {
                    #expect(BigUInt(a) / BigUInt(b) == BigUInt(a / b))
                    #expect(BigUInt(a) % BigUInt(b) == BigUInt(a % b))
                }
            }
        }
    }

    @Test
    func `division of large numbers round trips`() {
        let dividend = hex("1F3A5C7E9B0D2F4A6C8E0B1D3F5A7C9E1B3D5F7A9C0E2B4D6F8A1C3E5B7D9F0A2C4E6B8D")
        let divisor = hex("9F8E7D6C5B4A39281706F5E4D3C2B1A0")

        let (quotient, remainder) = dividend.quotientAndRemainder(dividingBy: divisor)

        #expect(remainder < divisor)
        #expect(quotient * divisor + remainder == dividend)
    }

    @Test
    func `bytes round trip with padding`() {
        let value = hex("0102030405")

        #expect(value.bytes() == [1, 2, 3, 4, 5])
        #expect(value.bytes(paddedTo: 8) == [0, 0, 0, 1, 2, 3, 4, 5])
        #expect(BigUInt(bigEndian: [0, 0, 1, 2]) == hex("0102"))
        #expect(BigUInt.zero.bytes().isEmpty)
        #expect(BigUInt(hex: "xyz") == nil)
    }

    @Test
    func `modular power matches small numbers`() {
        #expect(BigUInt(4).power(BigUInt(13), modulus: BigUInt(497)) == BigUInt(445))
        #expect(BigUInt(2).power(BigUInt(0), modulus: BigUInt(7)) == BigUInt(1))
    }

    @Test(arguments: [SRPGroup.rfc5054_1024, .rfc5054_2048])
    func `montgomery exponentiation matches square and multiply`(group: SRPGroup) throws {
        let base = try #require(BigUInt(hex: "60975527035CF2AD1989806F0407210BC81EDC04E2762A56AFD529DDDA2D4393E487CB59D31AC550"))
        let exponent = try #require(BigUInt(hex: "F3A5C7E9B0D2F4A6C8E0B1D3F5A7C9E1"))
        var expected = BigUInt.one
        for index in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            expected = (expected * expected) % group.prime
            if exponent.bit(at: index) {
                expected = (expected * base) % group.prime
            }
        }

        #expect(base.power(exponent, modulus: group.prime) == expected)
        #expect(group.prime.power(exponent, modulus: group.prime) == .zero)
        #expect(base.power(.zero, modulus: group.prime) == .one)
    }

    @Test(arguments: [SRPGroup.rfc5054_1024, .rfc5054_2048])
    func `the srp groups use safe primes`(group: SRPGroup) {
        let prime = group.prime
        let half = (prime - BigUInt.one).shiftedRight(by: 1)

        #expect(prime.isProbablePrime(rounds: [2, 3]))
        #expect(half.isProbablePrime(rounds: [2]))
    }
}

struct SRPTests {
    private let salt = bytes("BEB25379D1A8581EB5A727673A2441EE")
    private let clientPrivateKey = hex("60975527035CF2AD1989806F0407210BC81EDC04E2762A56AFD529DDDA2D4393")
    private let serverPrivateKey = hex("E487CB59D31AC550471E81F00F6928E01DDA08E974A004F49E61F5D105284D20")

    private var client: SRPClient {
        SRPClient(group: .rfc5054_1024, hash: .sha1, privateKey: clientPrivateKey)
    }

    @Test
    func `rfc 5054 multiplier and password exponent`() {
        #expect(client.multiplier == hex("7556AA045AEF2CDD07ABAF0F665C3E818913186F"))
        #expect(client.passwordVerifierExponent(identity: "alice", password: Array("password123".utf8), salt: salt)
            == hex("94B7555AABE9127CC58CCF4993DB6CF84D16C124"))
    }

    @Test
    func `rfc 5054 client public key`() {
        #expect(client.publicKey == hex("""
        61D5E490F6F1B79547B0704C436F523DD0E560F0C64115BB72557EC44352E8903211C04692272D8B2D1A5358A2CF1B6E0BFCF99F921530EC8E39356179EAE45E42BA92AEACED825171E1E8B9AF6D9C03E1327F44BE087EF06530E69F66615261EEF54073CA11CF5858F0EDFDFE15EFEAB349EF5D76988A3672FAC47B0769447B
        """))
    }

    @Test
    func `rfc 5054 scrambler and premaster secret`() throws {
        let serverPublicKey = hex("""
        BD0C61512C692C0CB6D041FA01BB152D4916A1E77AF46AE105393011BAF38964DC46A0670DD125B95A981652236F99D9B681CBF87837EC996C6DA04453728610D0C6DDB58B318885D7D82C7F8DEB75CE7BD4FBAA37089E6F9C6059F388838E7A00030B331EB76840910440B1B27AAEAEEB4012B7D7665238A8E3FB004B117B58
        """)

        let proof = try client.proof(
            accountName: "alice",
            passwordIdentity: "alice",
            password: Array("password123".utf8),
            salt: salt,
            serverPublicKey: serverPublicKey
        )

        #expect(proof.scrambler == hex("CE38B9593487DA98554ED47D70A7AE5F462EF019"))
        #expect(proof.premasterSecret == hex("""
        B0DC82BABCF30674AE450C0287745E7990A3381F63B387AAF271A10D233861E359B48220F7C4693C9AE12B0A6F67809F0876E2D013800D6C41BB59B6D5979B5C00A172B4A2A5903A0BDCAF8A709585EB2AFAFA8F3499B200210DCC1F10EB33943CD67FC88A2F39A4BE5BEC4EC0A3212DC346D7E474B29EDE8A469FFECA686E5A
        """))
    }

    @Test
    func `client and server agree on the session with apple's parameters`() throws {
        let group = SRPGroup.rfc5054_2048
        let client = SRPClient(group: group, hash: .sha256)
        let salt = Array("pepper".utf8)
        let passwordKey = derivedPasswordKey(password: "correct horse", salt: salt, iterations: 1_000, protocol: .s2k)

        let verifierExponent = client.passwordVerifierExponent(identity: "", password: passwordKey, salt: salt)
        let verifier = group.generator.power(verifierExponent, modulus: group.prime)
        let serverPrivateKey = serverPrivateKey
        let serverPublicKey = (client.multiplier * verifier + group.generator.power(serverPrivateKey, modulus: group.prime)) % group.prime

        let proof = try client.proof(
            accountName: "user@example.invalid",
            passwordIdentity: "",
            password: passwordKey,
            salt: salt,
            serverPublicKey: serverPublicKey
        )

        let u = client.scrambler(serverPublicKey: serverPublicKey)
        let serverSecret = (client.publicKey * verifier.power(u, modulus: group.prime)).power(serverPrivateKey, modulus: group.prime)
        #expect(proof.premasterSecret == serverSecret)
        #expect(proof.sessionKey == Array(SHA256.hash(data: serverSecret.bytes())))
        #expect(proof.expectedServerProof == Array(SHA256.hash(data: client.publicKey.bytes() + proof.clientProof + proof.sessionKey)))
    }

    @Test
    func `the client proof hashes the generator padded to the group size`() throws {
        let serverPublicKey =
            hex(
                "BD0C61512C692C0CB6D041FA01BB152D4916A1E77AF46AE105393011BAF38964DC46A0670DD125B95A981652236F99D9B681CBF87837EC996C6DA04453728610D0C6DDB58B318885D7D82C7F8DEB75CE7BD4FBAA37089E6F9C6059F388838E7A00030B331EB76840910440B1B27AAEAEEB4012B7D7665238A8E3FB004B117B58"
            )
        let group = SRPGroup.rfc5054_1024
        let sha1: ([UInt8]) -> [UInt8] = { Array(Insecure.SHA1.hash(data: $0)) }

        let proof = try client.proof(
            accountName: "alice",
            passwordIdentity: "alice",
            password: Array("password123".utf8),
            salt: salt,
            serverPublicKey: serverPublicKey
        )

        let paddedGenerator = [UInt8](repeating: 0, count: group.length - 1) + [2]
        let xored = zip(sha1(group.prime.bytes()), sha1(paddedGenerator)).map { $0 ^ $1 }
        let expected = sha1(xored + sha1(Array("alice".utf8)) + salt + client.publicKey.bytes() + serverPublicKey.bytes() + proof
            .sessionKey)
        #expect(proof.clientProof == expected)
        #expect(proof.expectedServerProof == sha1(client.publicKey.bytes() + proof.clientProof + proof.sessionKey))
    }

    @Test
    func `a server public key of zero is rejected`() {
        #expect(throws: SRPError.invalidServerPublicKey) {
            try client.proof(
                accountName: "a",
                passwordIdentity: "a",
                password: [1],
                salt: [1],
                serverPublicKey: SRPGroup.rfc5054_1024.prime
            )
        }
    }

    @Test
    func `pbkdf2 matches rfc 7914`() {
        let key = pbkdf2SHA256(password: Array("passwd".utf8), salt: Array("salt".utf8), iterations: 1, keyLength: 64)

        #expect(key.map { String(format: "%02x", $0) }
            .joined() ==
            "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
    }

    @Test
    func `s2k_fo derives the key from the hex digest`() {
        let salt = Array("salt".utf8)
        let digest = Array(SHA256.hash(data: Data("secret".utf8)))
        let hexDigest = Array(digest.map { String(format: "%02x", $0) }.joined().utf8)

        #expect(derivedPasswordKey(password: "secret", salt: salt, iterations: 10, protocol: .s2k)
            == pbkdf2SHA256(password: digest, salt: salt, iterations: 10, keyLength: 32))
        #expect(derivedPasswordKey(password: "secret", salt: salt, iterations: 10, protocol: .s2kFo)
            == pbkdf2SHA256(password: hexDigest, salt: salt, iterations: 10, keyLength: 32))
    }
}

struct HashcashTests {
    @Test(arguments: [8, 11, 12])
    func `a stamp has the requested leading zero bits`(bits: Int) throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let stamp = try Hashcash(bits: bits, challenge: "4d74fb15eb23f465f1f6fcbf534e5877").stamp(
            date: date,
            timeZone: #require(TimeZone(identifier: "UTC"))
        )

        #expect(stamp.hasPrefix("1:\(bits):20231114221320:4d74fb15eb23f465f1f6fcbf534e5877::"))
        #expect(Hashcash.hasLeadingZeroBits(bits, in: Array(Insecure.SHA1.hash(data: Data(stamp.utf8)))))
    }

    @Test
    func `leading zero bits are counted per bit`() {
        #expect(Hashcash.hasLeadingZeroBits(12, in: [0x00, 0x0f, 0xff]))
        #expect(!Hashcash.hasLeadingZeroBits(13, in: [0x00, 0x0f, 0xff]))
        #expect(Hashcash.hasLeadingZeroBits(0, in: [0xff]))
    }
}
