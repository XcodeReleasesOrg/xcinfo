import Dependencies
import Foundation
import os
import Testing
@testable import xcinfoCore

private final class FakeKeychain: Sendable {
    let items: OSAllocatedUnfairLock<[String: String]>
    let failsReading: Bool

    init(_ items: [String: String] = [:], failsReading: Bool = false) {
        self.items = OSAllocatedUnfairLock(initialState: items)
        self.failsReading = failsReading
    }

    var client: KeychainClient {
        KeychainClient(
            accounts: { [items] service in
                #expect(service == "xcinfo.appleid")
                return items.withLock { Array($0.keys) }
            },
            readPassword: { [items, failsReading] _, account in
                guard !failsReading, let password = items.withLock({ $0[account] }) else {
                    throw CredentialsError.keychainError("missing")
                }
                return password
            },
            savePassword: { [items] password, _, account in
                items.withLock { $0[account] = password }
            },
            deleteAll: { [items] _ in
                items.withLock { items in
                    defer { items.removeAll() }
                    return items.count
                }
            }
        )
    }
}

struct CredentialsTests {
    private func service(keychain: FakeKeychain, prompt: FakePrompt = FakePrompt(), logs: LogRecorder = LogRecorder()) -> CredentialService {
        withDependencies {
            $0.keychain = keychain.client
            $0.prompt = prompt.client
            $0.logger = logs.logger()
        } operation: {
            CredentialService()
        }
    }

    @Test
    func `stored credentials are read from the keychain`() throws {
        let credentials = try service(keychain: FakeKeychain(["user@example.invalid": "secret"])).appleIDCredentials()

        #expect(credentials == Credentials(username: "user@example.invalid", password: "secret"))
    }

    @Test
    func `missing credentials are asked for and stored when agreed`() throws {
        let keychain = FakeKeychain()
        let prompt = FakePrompt(answers: ["user@example.invalid"], agree: true, passwords: ["secret"])
        let logs = LogRecorder()

        let credentials = try service(keychain: keychain, prompt: prompt, logs: logs).appleIDCredentials()

        #expect(credentials == Credentials(username: "user@example.invalid", password: "secret"))
        #expect(prompt.lines.values == ["Username:"])
        #expect(prompt.secrets.values == ["Password:"])
        #expect(prompt.agreed.values == ["Do you want to store these credentials in the macOS Keychain?"])
        #expect(keychain.items.withLock { $0 } == ["user@example.invalid": "secret"])
        #expect(logs.messages.prefix(2) == ["Apple's Developer Download page requires a login.", "Please provide your Apple Developer Program account credentials."])
    }

    @Test
    func `asked credentials are not stored when declined`() throws {
        let keychain = FakeKeychain()
        let prompt = FakePrompt(answers: ["user"], agree: false, passwords: ["secret"])

        _ = try service(keychain: keychain, prompt: prompt).appleIDCredentials()

        #expect(keychain.items.withLock { $0 }.isEmpty)
    }

    @Test
    func `an unreadable password is asked for again`() throws {
        let logs = LogRecorder()
        let prompt = FakePrompt(answers: ["user"], agree: false, passwords: ["new"])

        let credentials = try service(keychain: FakeKeychain(["user": "old"], failsReading: true), prompt: prompt, logs: logs).appleIDCredentials()

        #expect(credentials.password == "new")
        #expect(logs.messages.first == "Could not read password from the Keychain.")
    }

    @Test
    func `cleanup deletes the stored credentials`() {
        let keychain = FakeKeychain(["user": "secret"])
        let logs = LogRecorder()

        service(keychain: keychain, logs: logs).cleanup()

        #expect(keychain.items.withLock { $0 }.isEmpty)
        #expect(logs.messages == ["Deleted stored Apple ID credentials from keychain."])

        let empty = LogRecorder()
        service(keychain: keychain, logs: empty).cleanup()
        #expect(empty.messages == ["No Apple ID credentials were stored."])
    }
}
