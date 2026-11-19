import CryptoKit
import Dependencies
import Foundation
@testable import OlympUs
import os
import Testing
import XCIFoundation
@testable import xcinfoCore

final class FakeVaultStorage: Sendable {
    private let state: OSAllocatedUnfairLock<(data: Data?, legacy: LegacyKeychainItems)>
    private let failsReading: Bool
    let reads = Recorder<Void>()
    let writes = Recorder<Data>()
    let deletes = Recorder<Void>()
    let legacyDeletes = Recorder<Void>()

    init(contents: VaultContents? = nil, legacy: LegacyKeychainItems = LegacyKeychainItems(), failsReading: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: (contents.map { try! JSONEncoder().encode($0) }, legacy))
        self.failsReading = failsReading
    }

    var storage: VaultStorage {
        VaultStorage(
            read: { [state, reads, failsReading] in
                reads.append(())
                if failsReading {
                    throw KeychainPasswordItem.KeychainError.unhandledError(status: -128)
                }
                return state.withLock { $0.data }
            },
            write: { [state, writes] data in
                writes.append(data)
                state.withLock { $0.data = data }
            },
            delete: { [state, deletes] in
                deletes.append(())
                state.withLock { $0.data = nil }
            },
            readLegacy: { [state] in
                state.withLock { $0.legacy }
            },
            deleteLegacy: { [state, legacyDeletes] in
                legacyDeletes.append(())
                state.withLock { $0.legacy = LegacyKeychainItems() }
            }
        )
    }

    var storedContents: VaultContents? {
        state.withLock { $0.data }.flatMap { try? JSONDecoder().decode(VaultContents.self, from: $0) }
    }

    var storedText: String {
        state.withLock { $0.data }.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

extension KeychainClient {
    static func vault(_ vault: KeychainVault) -> KeychainClient {
        KeychainClient(
            load: { try await vault.load() },
            reload: { try await vault.reload() },
            stage: { change in try await vault.stage(change) },
            commit: { change in try await vault.commit(change) }
        )
    }
}

struct KeychainVaultTests {
    @Test
    func `the keychain is read once per run`() async throws {
        let storage = FakeVaultStorage(contents: VaultContents(accountName: "user"))
        let vault = KeychainVault(storage: storage.storage)

        _ = try await vault.load()
        try await vault.stage { $0.sessions["user"] = Data("a".utf8) }
        _ = try await vault.load()
        try await vault.commit { $0.sessions["user"] = Data("b".utf8) }
        _ = try await vault.load()

        #expect(storage.reads.values.count == 1)
        #expect(storage.writes.values.count == 1)
        #expect(storage.storedContents?.sessions["user"] == Data("b".utf8))
    }

    @Test
    func `staged changes are written only on commit and unchanged contents are not written`() async throws {
        let storage = FakeVaultStorage(contents: VaultContents(accountName: "user"))
        let vault = KeychainVault(storage: storage.storage)

        try await vault.stage { $0.accountName = "other" }
        #expect(storage.writes.values.isEmpty)
        try await vault.commit { _ in }
        #expect(storage.writes.values.count == 1)
        try await vault.commit { _ in }
        #expect(storage.writes.values.count == 1)
    }

    @Test
    func `old items are moved into one item without the password`() async throws {
        let logs = LogRecorder()
        let storage = FakeVaultStorage(legacy: LegacyKeychainItems(
            accountName: "user@example.invalid",
            hadStoredPassword: true,
            sessions: ["user@example.invalid": OlympUs.AuthenticationAssets.fixtureData],
            cookies: Data("cookies".utf8)
        ))
        let vault = KeychainVault(storage: storage.storage)

        let contents = try await withDependencies { $0.logger = logs.logger() } operation: {
            try await vault.load()
        }

        #expect(contents.accountName == "user@example.invalid")
        #expect(contents.sessions["user@example.invalid"] == OlympUs.AuthenticationAssets.fixtureData)
        #expect(contents.legacyCookies == Data("cookies".utf8))
        #expect(storage.writes.values.count == 1)
        #expect(storage.legacyDeletes.values.count == 1)
        #expect(logs.messages.contains("Moved the stored Apple ID and session into one Keychain item named 'xcinfo'."))
        #expect(logs.messages.contains { $0.hasPrefix("Removed the stored Apple ID password from the Keychain") })
    }

    @Test
    func `nothing is migrated when there are no old items`() async throws {
        let storage = FakeVaultStorage()
        let vault = KeychainVault(storage: storage.storage)

        let contents = try await vault.load()

        #expect(contents == VaultContents())
        #expect(storage.writes.values.isEmpty)
        #expect(storage.legacyDeletes.values.isEmpty)
    }

    @Test
    func `a denied read is reported and not retried`() async throws {
        let storage = FakeVaultStorage(contents: VaultContents(accountName: "user"), failsReading: true)
        let vault = KeychainVault(storage: storage.storage)

        await #expect(throws: KeychainAccessError.self) { try await vault.load() }
        await #expect(throws: KeychainAccessError.self) { try await vault.commit { $0.accountName = nil } }

        #expect(storage.reads.values.count == 1)
        #expect(storage.writes.values.isEmpty)
    }

    @Test
    func `an empty vault deletes its item`() async throws {
        let storage = FakeVaultStorage(contents: VaultContents(accountName: "user", sessions: ["user": Data("s".utf8)]))
        let vault = KeychainVault(storage: storage.storage)

        try await vault.commit { contents in
            contents.accountName = nil
            contents.sessions = [:]
        }

        #expect(storage.deletes.values.count == 1)
        #expect(storage.storedContents == nil)
    }
}

struct CredentialsTests {
    private func service(
        storage: FakeVaultStorage,
        prompt: FakePrompt = FakePrompt(),
        logs: LogRecorder = LogRecorder(),
        environment: [String: String] = [:],
        isInteractive: Bool = true
    ) -> (CredentialService, KeychainVault) {
        let vault = KeychainVault(storage: storage.storage)
        let service = withDependencies {
            $0.keychain = .vault(vault)
            $0.prompt = prompt.client
            $0.logger = logs.logger()
        } operation: {
            CredentialService(environment: environment, isInteractive: isInteractive)
        }
        return (service, vault)
    }

    @Test
    func `the stored account name is used and only the password is asked for`() async throws {
        let prompt = FakePrompt(passwords: ["secret"])
        let (service, _) = service(storage: FakeVaultStorage(contents: VaultContents(accountName: "user@example.invalid")), prompt: prompt)

        #expect(try await service.accountName() == "user@example.invalid")
        #expect(try await service.password(for: "user@example.invalid") == "secret")
        #expect(prompt.lines.values.isEmpty)
        #expect(prompt.secrets.values == ["Apple ID password for user@example.invalid (not your Mac password):"])
        #expect(prompt.agreed.values.isEmpty)
    }

    @Test
    func `a missing account name is asked for and remembered without the password`() async throws {
        let storage = FakeVaultStorage()
        let prompt = FakePrompt(answers: ["user@example.invalid"], passwords: ["secret"])
        let (service, vault) = service(storage: storage, prompt: prompt)

        #expect(try await service.accountName() == "user@example.invalid")
        _ = try await service.password(for: "user@example.invalid")
        try await vault.commit { _ in }

        #expect(prompt.lines.values == ["Apple ID (email):"])
        #expect(storage.storedContents?.accountName == "user@example.invalid")
        #expect(!storage.storedText.contains("secret"))
    }

    @Test
    func `environment variables provide the account name and password`() async throws {
        let prompt = FakePrompt()
        let (service, _) = service(
            storage: FakeVaultStorage(contents: VaultContents(accountName: "stored@example.invalid")),
            prompt: prompt,
            environment: ["XCINFO_APPLE_ID": "env@example.invalid", "XCINFO_APPLE_PASSWORD": "from-env"],
            isInteractive: false
        )

        #expect(try await service.accountName() == "env@example.invalid")
        #expect(try await service.password(for: "env@example.invalid") == "from-env")
        #expect(prompt.secrets.values.isEmpty)
    }

    @Test
    func `without a terminal a missing password fails instead of waiting`() async throws {
        let (service, _) = service(storage: FakeVaultStorage(contents: VaultContents(accountName: "user")), isInteractive: false)

        #expect(try await service.accountName() == "user")
        await #expect(throws: CredentialsError.passwordUnavailable) { try await service.password(for: "user") }
    }

    @Test
    func `without a terminal a missing account name fails`() async {
        let (service, _) = service(storage: FakeVaultStorage(), isInteractive: false)

        await #expect(throws: CredentialsError.accountNameUnavailable) { try await service.accountName() }
    }

    @Test
    func `a refused keychain offers a retry, a new sign-in or cancelling`() async throws {
        let logs = LogRecorder()
        let prompt = FakePrompt(answers: ["user"], choices: [1])
        let storage = FakeVaultStorage(failsReading: true)
        let (service, _) = service(storage: storage, prompt: prompt, logs: logs)

        #expect(try await service.accountName() == "user")
        #expect(prompt.chosen.values == [["Try the Keychain again", "Sign in anew", "Cancel"]])
        #expect(storage.reads.values.count == 1)
        #expect(logs.events.contains(.message(
            "The Keychain item 'xcinfo' could not be read: access to the Keychain was denied in the macOS dialog.",
            .warning
        )))
        #expect(!logs.messages.contains { $0.contains("unhandledError") })
    }

    @Test
    func `trying the keychain again reads it once more and cancelling stops`() async throws {
        let retry = FakePrompt(answers: ["user"], choices: [0, 1])
        let storage = FakeVaultStorage(failsReading: true)
        let (retrying, _) = service(storage: storage, prompt: retry)
        _ = try await retrying.accountName()
        #expect(storage.reads.values.count == 2)

        let (cancelling, _) = service(storage: FakeVaultStorage(failsReading: true), prompt: FakePrompt(choices: [2]))
        await #expect(throws: CancellationError.self) { try await cancelling.accountName() }
    }

    @Test(arguments: [
        (
            errSecAuthFailed,
            "macOS refused access to the Keychain item: the password in the Keychain dialog was not accepted, or access was denied"
        ),
        (errSecUserCanceled, "access to the Keychain was denied in the macOS dialog"),
        (errSecInteractionNotAllowed, "macOS could not show the Keychain dialog")
    ])
    func `keychain errors are explained in plain words`(status: OSStatus, text: String) {
        #expect(KeychainPasswordItem.KeychainError.unhandledError(status: status).description == text)
    }

    @Test
    func `cleanup deletes the stored account name`() async {
        let storage = FakeVaultStorage(contents: VaultContents(accountName: "user"))
        let logs = LogRecorder()
        let (service, _) = service(storage: storage, logs: logs)

        #expect(await service.cleanup())

        #expect(storage.storedContents == nil)
        #expect(logs.messages.isEmpty)
    }

    @Test
    func `store keeps the account name next to the session`() async throws {
        let storage = FakeVaultStorage(contents: VaultContents(accountName: "old", sessions: ["new": Data([1])]))
        let (service, _) = service(storage: storage, logs: LogRecorder())

        try await service.store("new")

        #expect(storage.storedContents == VaultContents(accountName: "new", sessions: ["new": Data([1])]))
    }

    @Test
    func `errors explain how to provide credentials`() {
        #expect(CredentialsError.passwordUnavailable.localizedDescription.contains("XCINFO_APPLE_PASSWORD"))
        #expect(CredentialsError.accountNameUnavailable.localizedDescription.contains("XCINFO_APPLE_ID"))
    }
}

struct PasswordBytesTests {
    private let passwords = ["  Grüße aus Köln 🎉  ", "plain", "trailing ", String(repeating: "ä", count: 64)]

    @Test
    func `the derived key uses the exact utf8 bytes of the password`() {
        let salt = Array("salt".utf8)
        for password in passwords {
            let digest = Array(SHA256.hash(data: Data(password.utf8)))

            #expect(derivedPasswordKey(password: password, salt: salt, iterations: 10, protocol: .s2k)
                == pbkdf2SHA256(password: digest, salt: salt, iterations: 10, keyLength: 32))
        }
    }

    @Test
    func `a typed password reaches the sign-in unchanged`() async throws {
        for password in passwords {
            let srp = FakeAppleSRPServer(accountName: "user", password: password)
            let prompt = FakePrompt(passwords: [password])
            let vault = KeychainVault(storage: FakeVaultStorage(contents: VaultContents(accountName: "user")).storage)
            let credentials = withDependencies {
                $0.keychain = .vault(vault)
                $0.prompt = prompt.client
                $0.logger = LogRecorder().logger()
            } operation: {
                CredentialService(environment: [:], isInteractive: true)
            }
            let server = StubServer { request in
                switch request.url?.path {
                case "/appleauth/auth/signin/init":
                    srp.initResponse(for: request)
                case "/appleauth/auth/signin/complete":
                    srp.isValidCompletion(request) ? .json("{}", statusCode: 409) : .json("{}", statusCode: 401)
                default:
                    StubResponse()
                }
            }
            let olymp = OlympUs(
                logger: LogRecorder().logger(),
                session: server.session(),
                sessionStore: InMemorySessionStore().store,
                prompt: prompt.client
            )

            let typed = try await credentials.password(for: "user")
            let result = try await olymp.signIn(accountName: "user", password: typed, serviceKey: "key")

            #expect(typed == password)
            #expect(result.requiresTwoFactorAuthentication)
        }
    }

    @Test
    func `a password from the environment is used unchanged`() async throws {
        let credentials = CredentialService(environment: ["XCINFO_APPLE_PASSWORD": " Grüße 🎉 "], isInteractive: false)

        #expect(try await credentials.password(for: "user") == " Grüße 🎉 ")
    }
}

struct SignInStorageTests {
    @Test
    func `a full sign in stores the session but never the password, and reads the keychain once`() async throws {
        let storage = FakeVaultStorage()
        let vault = KeychainVault(storage: storage.storage)
        let keychain = KeychainClient.vault(vault)
        let logs = LogRecorder()
        let prompt = FakePrompt(answers: ["user", "123456"], passwords: ["correct horse"])
        let srp = FakeAppleSRPServer(accountName: "user", password: "correct horse")
        let server = StubServer { request in
            switch request.url?.path {
            case "/appleauth/auth/signin":
                StubResponse(headers: ["X-Apple-HC-Bits": "8", "X-Apple-HC-Challenge": "challenge"])
            case "/appleauth/auth/signin/init":
                srp.initResponse(for: request)
            case "/appleauth/auth/signin/complete":
                srp.isValidCompletion(request) ? .json("{}", statusCode: 409, headers: ["scnt": "s", "X-Apple-ID-Session-Id": "i"]) : .json(
                    "{}",
                    statusCode: 401
                )
            case "/olympus/v1/app/config":
                .json(#"{"authServiceKey":"key"}"#)
            case "/appleauth/auth":
                .json(#"{"securityCode":{"length":6}}"#)
            case "/appleauth/auth/verify/trusteddevice/securitycode":
                StubResponse(statusCode: 204)
            case "/appleauth/auth/2sv/trust":
                StubResponse(headers: ["Set-Cookie": "DES1234=trusted; Path=/; Domain=.apple.com"])
            case "/services-account/QH65B2/downloadws/listDownloads.action":
                StubResponse(headers: ["Set-Cookie": "ADCDownloadAuth=token; Path=/; Domain=.apple.com"])
            default:
                StubResponse()
            }
        }

        try await withDependencies {
            $0.keychain = keychain
            $0.prompt = prompt.client
            $0.logger = logs.logger()
        } operation: {
            let credentials = CredentialService(environment: [:], isInteractive: true)
            let accountName = try await credentials.accountName()
            let olymp = OlympUs(logger: logs.logger(), session: server.session(), sessionStore: .vault(keychain), prompt: prompt.client)
            try await AppleAuthenticator(olymp: olymp, logger: logs.logger()).authenticate(username: accountName) {
                try await credentials.password(for: accountName)
            }
        }

        #expect(storage.reads.values.count == 1)
        #expect(storage.writes.values.count == 1)
        let contents = try #require(storage.storedContents)
        #expect(contents.accountName == "user")
        #expect(contents.sessions["user"] != nil)
        #expect(!storage.storedText.contains("correct horse"))
        #expect(!logs.messages.contains { $0.contains("correct horse") })
    }
}

struct SignInSessionTests {
    @Test(arguments: [
        (StubResponse(statusCode: 500), "GET /olympus/v1/session: HTTP 500"),
        (StubResponse(statusCode: 401), "GET /olympus/v1/session: HTTP 401"),
        (StubResponse(error: URLError(.timedOut)), "GET /olympus/v1/session: \(URLError(.timedOut).localizedDescription)")
    ])
    func `a failing App Store Connect session does not stop the sign-in and is logged`(
        sessionResponse: StubResponse,
        logged: String
    ) async throws {
        let logs = LogRecorder()
        let prompt = FakePrompt(answers: ["123456"])
        let srp = FakeAppleSRPServer(accountName: "user", password: "correct horse")
        let server = StubServer { request in
            switch request.url?.path {
            case "/logout":
                StubResponse(statusCode: 302, headers: ["Location": "https://idmsa.apple.com/appleauth/signout?widgetKey=key"])
            case "/appleauth/auth/signin":
                StubResponse(headers: ["X-Apple-HC-Bits": "8", "X-Apple-HC-Challenge": "challenge"])
            case "/appleauth/auth/signin/init":
                srp.initResponse(for: request)
            case "/appleauth/auth/signin/complete":
                srp.isValidCompletion(request) ? .json("{}", statusCode: 409, headers: ["scnt": "s", "X-Apple-ID-Session-Id": "i"]) : .json(
                    "{}",
                    statusCode: 401
                )
            case "/appleauth/auth":
                .json(#"{"securityCode":{"length":6}}"#)
            case "/appleauth/auth/verify/trusteddevice/securitycode":
                StubResponse(statusCode: 204)
            case "/appleauth/auth/2sv/trust":
                StubResponse(statusCode: 204, headers: ["Set-Cookie": "DES1234=trust-cookie-value; Path=/; Domain=.apple.com"])
            case "/olympus/v1/session":
                sessionResponse
            case "/services-account/QH65B2/downloadws/listDownloads.action":
                StubResponse(headers: ["Set-Cookie": "ADCDownloadAuth=download-cookie-value; Path=/; Domain=.apple.com"])
            default:
                StubResponse(statusCode: 404)
            }
        }
        let olymp = OlympUs(
            logger: logs.logger(),
            session: server.session(),
            sessionStore: InMemorySessionStore().store,
            prompt: prompt.client
        )

        _ = try await AppleAuthenticator(olymp: olymp, logger: logs.logger()).authenticate(username: "user") { "correct horse" }

        #expect(logs.messages.contains("POST /appleauth/auth/verify/trusteddevice/securitycode: HTTP 204"))
        #expect(logs.messages.contains("GET /appleauth/auth/2sv/trust: HTTP 204"))
        #expect(logs.messages.contains(logged))
        #expect(logs.messages.contains { $0.hasPrefix("No App Store Connect session") })
        #expect(logs.messages.contains("POST /services-account/QH65B2/downloadws/listDownloads.action: HTTP 200"))
        #expect(!logs.messages.contains { $0.contains("correct horse") || $0.contains("cookie-value") })
    }

    @Test
    func `a failing download authorization still fails the sign-in`() async throws {
        let logs = LogRecorder()
        let server = StubServer { request in
            switch request.url?.path {
            case "/services-account/QH65B2/downloadws/listDownloads.action":
                StubResponse(statusCode: 403)
            default:
                StubResponse()
            }
        }
        let olymp = OlympUs(
            logger: logs.logger(),
            session: server.session(),
            sessionStore: InMemorySessionStore().store,
            prompt: FakePrompt().client
        )

        await #expect(throws: OlympUsError.downloadAuthFailed) {
            try await olymp.getDownloadAuth(assets: .init(serviceKey: "key", scnt: "s", asid: "i"))
        }
        #expect(logs.messages.contains("POST /services-account/QH65B2/downloadws/listDownloads.action: HTTP 403"))
    }
}
