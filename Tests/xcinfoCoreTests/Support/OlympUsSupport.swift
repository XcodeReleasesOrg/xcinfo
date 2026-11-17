import CryptoKit
import Foundation
@testable import OlympUs
import os

final class InMemorySessionStore: Sendable {
    private let items: OSAllocatedUnfairLock<[String: Data]>

    init(_ items: [String: Data] = [:]) {
        self.items = OSAllocatedUnfairLock(initialState: items)
    }

    var accounts: [String] {
        items.withLock { Array($0.keys) }
    }

    func data(for account: String) -> Data? {
        items.withLock { $0[account] }
    }

    var store: AuthenticationSessionStore {
        AuthenticationSessionStore(
            load: { [items] account in
                guard let data = items.withLock({ $0[account] }) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return data
            },
            save: { [items] data, account in
                items.withLock { $0[account] = data }
            },
            removeAll: { [items] in
                items.withLock { items in
                    let count = items.count
                    items.removeAll()
                    return count
                }
            }
        )
    }
}

final class InMemoryCookieStore: Sendable {
    private let data = OSAllocatedUnfairLock<Data?>(initialState: nil)

    init(cookies: [HTTPCookie] = []) {
        if !cookies.isEmpty {
            let properties = cookies.compactMap { cookie in
                cookie.properties.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
            }
            let encoded = try? PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
            data.withLock { $0 = encoded }
        }
    }

    var store: CookieStore {
        CookieStore(
            load: { [data] in data.withLock { $0 } },
            save: { [data] newValue in data.withLock { $0 = newValue } },
            remove: { [data] in data.withLock { $0 = nil } }
        )
    }

    var cookieNames: Set<String> {
        guard
            let data = data.withLock({ $0 }),
            let cookies = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return [] }
        return Set(cookies.compactMap { $0[HTTPCookiePropertyKey.name.rawValue] as? String })
    }

    var isEmpty: Bool {
        data.withLock { $0 == nil }
    }
}

final class FakeAppleSRPServer: Sendable {
    let accountName: String
    let salt: [UInt8]
    let iterations: Int
    let passwordProtocol: PasswordProtocol
    private let verifier: BigUInt
    private let serverPrivateKey = BigUInt(hex: "E487CB59D31AC550471E81F00F6928E01DDA08E974A004F49E61F5D105284D20")!
    private let clientPublicKey = OSAllocatedUnfairLock<BigUInt?>(initialState: nil)
    private let group = SRPGroup.rfc5054_2048

    init(accountName: String, password: String, passwordProtocol: PasswordProtocol = .s2k) {
        self.accountName = accountName
        salt = Array("apple-salt".utf8)
        iterations = 1000
        self.passwordProtocol = passwordProtocol
        let key = derivedPasswordKey(password: password, salt: salt, iterations: iterations, protocol: passwordProtocol)
        let client = SRPClient(group: .rfc5054_2048, hash: .sha256, privateKey: .one)
        let exponent = client.passwordVerifierExponent(identity: "", password: key, salt: salt)
        verifier = SRPGroup.rfc5054_2048.generator.power(exponent, modulus: SRPGroup.rfc5054_2048.prime)
    }

    private var multiplier: BigUInt {
        SRPClient(group: group, hash: .sha256, privateKey: .one).multiplier
    }

    var serverPublicKey: BigUInt {
        (multiplier * verifier + group.generator.power(serverPrivateKey, modulus: group.prime)) % group.prime
    }

    func initResponse(for request: URLRequest) -> StubResponse {
        guard
            let body = request.httpBody,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let a = (json["a"] as? String).flatMap({ Data(base64Encoded: $0) }),
            json["accountName"] as? String == accountName
        else {
            return .json("{}", statusCode: 401)
        }
        clientPublicKey.withLock { $0 = BigUInt(bigEndian: a) }
        let response: [String: Any] = [
            "iteration": iterations,
            "salt": Data(salt).base64EncodedString(),
            "protocol": passwordProtocol.rawValue,
            "b": Data(serverPublicKey.bytes()).base64EncodedString(),
            "c": "challenge-token",
        ]
        return StubResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: try! JSONSerialization.data(withJSONObject: response))
    }

    func isValidCompletion(_ request: URLRequest) -> Bool {
        guard
            let body = request.httpBody,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            json["c"] as? String == "challenge-token",
            let m1 = (json["m1"] as? String).flatMap({ Data(base64Encoded: $0) }),
            let clientPublicKey = clientPublicKey.withLock({ $0 })
        else { return false }

        let sha256: ([UInt8]) -> [UInt8] = { Array(SHA256.hash(data: $0)) }
        let length = group.length
        let u = BigUInt(bigEndian: sha256(clientPublicKey.bytes(paddedTo: length) + serverPublicKey.bytes(paddedTo: length)))
        let secret = (clientPublicKey * verifier.power(u, modulus: group.prime)).power(serverPrivateKey, modulus: group.prime)
        let sessionKey = sha256(secret.bytes())
        let xored = zip(sha256(group.prime.bytes()), sha256(group.generator.bytes())).map { $0 ^ $1 }
        let expected = sha256(xored + sha256(Array(accountName.utf8)) + salt + clientPublicKey.bytes() + serverPublicKey.bytes() + sessionKey)
        return Array(m1) == expected
    }
}

extension OlympUs.AuthenticationAssets {
    static let fixture = try! JSONDecoder().decode(
        OlympUs.AuthenticationAssets.self,
        from: Data(#"{"serviceKey":"service-key","scnt":"scnt-value","asid":"session-id","authenticationType":"hsa2"}"#.utf8)
    )

    static var fixtureData: Data {
        try! JSONEncoder().encode(fixture)
    }
}
