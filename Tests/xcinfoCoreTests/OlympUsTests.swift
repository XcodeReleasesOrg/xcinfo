import Foundation
@testable import OlympUs
import os
import Testing
import XCIFoundation
@testable import xcinfoCore

private enum AppleEndpoint {
    static let config = "/olympus/v1/app/config"
    static let signIn = "/appleauth/auth/signin"
    static let auth = "/appleauth/auth"
    static let verifyPhone = "/appleauth/auth/verify/phone"
    static let trustedDeviceCode = "/appleauth/auth/verify/trusteddevice/securitycode"
    static let phoneCode = "/appleauth/auth/verify/phone/securitycode"
    static let trust = "/appleauth/auth/2sv/trust"
    static let session = "/olympus/v1/session"
    static let downloads = "/services-account/QH65B2/downloadws/listDownloads.action"
}

private let authResponse = """
{
  "trustedPhoneNumbers": [
    { "numberWithDialCode": "+1 (•••) •••-••11", "pushMode": "sms", "obfuscatedNumber": "(•••) •••-••11", "id": 1 },
    { "numberWithDialCode": "+49 ••• ••••22", "pushMode": "sms", "obfuscatedNumber": "••• ••••22", "id": 2 }
  ],
  "securityCode": { "length": 6, "tooManyCodesSent": false, "tooManyCodesValidated": false, "securityCodeLocked": false }
}
"""

private let downloadAuthCookie = "ADCDownloadAuth=download-token; Path=/; Domain=.apple.com"

final class OlympUsFixture: Sendable {
    let server: StubServer
    let defaults = TemporaryDefaults()
    let sessionStore: InMemorySessionStore
    let logs = LogRecorder()
    let prompt: FakePrompt
    let olymp: OlympUs

    init(
        storedAssets: [String: Data] = [:],
        prompt: FakePrompt = FakePrompt(),
        promptClient: PromptClient? = nil,
        handler: @escaping StubServer.Handler
    ) {
        server = StubServer(handler: handler)
        sessionStore = InMemorySessionStore(storedAssets)
        self.prompt = prompt
        olymp = OlympUs(
            logger: logs.logger(isVerbose: true),
            session: server.session(),
            userDefaults: defaults.defaults,
            sessionStore: sessionStore.store,
            prompt: promptClient ?? prompt.client
        )
    }

    var cookieNames: Set<String> {
        Set(olymp.session.configuration.httpCookieStorage?.cookies?.map(\.name) ?? [])
    }
}

private func json(_ request: URLRequest) throws -> NSDictionary {
    let body = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
}

private func isOlympUsError(_ expected: OlympUsError) -> (any Error) -> Bool {
    { ($0 as? OlympUsError) == expected }
}

struct OlympUsServiceKeyTests {
    @Test
    func `the service key of a stored session is reused`() async throws {
        let fixture = OlympUsFixture(storedAssets: ["user": OlympUs.AuthenticationAssets.fixtureData]) { _ in
            Issue.record("Must not request")
            return StubResponse()
        }

        let key = try await fixture.olymp.getServiceKey(for: "user").singleOutput()

        #expect(key == "service-key")
        #expect(fixture.logs.messages == ["[1/7] Requesting service key"])
        #expect(fixture.logs.rawMessages.first?.hasPrefix("\u{1B}[1A") == true)
    }

    @Test
    func `the service key is requested from the app config`() async throws {
        let fixture = OlympUsFixture { _ in .json(#"{"authServiceKey":"fresh-key"}"#) }

        let key = try await fixture.olymp.getServiceKey(for: "user").singleOutput()

        #expect(key == "fresh-key")
        let request = try #require(fixture.server.requests.values.first)
        #expect(request.url?.absoluteString == "https://appstoreconnect.apple.com/olympus/v1/app/config?hostname=itunesconnect.apple.com")
    }

    @Test
    func `a missing service key fails`() async throws {
        let fixture = OlympUsFixture { _ in .json("{}", statusCode: 500) }

        await #expect(performing: {
            try await fixture.olymp.getServiceKey(for: "user").singleOutput()
        }, throws: isOlympUsError(.missingSessionKey))
    }
}

struct OlympUsSignInTests {
    @Test
    func `sign in posts the credentials and keeps the session headers`() async throws {
        let fixture = OlympUsFixture { _ in
            .json(#"{"authType":"hsa2"}"#, headers: ["scnt": "scnt-value", "X-Apple-ID-Session-Id": "session-id"])
        }

        let assets = try await fixture.olymp.signIn(accountName: "user@example.invalid", password: "secret", serviceKey: "key").singleOutput()

        #expect(assets.serviceKey == "key")
        #expect(assets.scnt == "scnt-value")
        #expect(assets.asid == "session-id")
        #expect(assets.authenticationType == "hsa2")
        let request = try #require(fixture.server.requests(to: AppleEndpoint.signIn).first)
        #expect(request.url?.host == "idmsa.apple.com")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Requested-With") == "X-Requested-With")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/javascript")
        #expect(request.value(forHTTPHeaderField: "X-Apple-Widget-Key") == "key")
        let body = try json(request)
        #expect(body["accountName"] as? String == "user@example.invalid")
        #expect(body["password"] as? String == "secret")
        #expect(body["rememberMe"] as? Bool == true)
    }

    @Test
    func `sign in without session headers still succeeds`() async throws {
        let fixture = OlympUsFixture { _ in .json(#"{"authType":"sa"}"#) }

        let assets = try await fixture.olymp.signIn(accountName: "user", password: "secret", serviceKey: "key").singleOutput()

        #expect(assets.scnt == nil)
        #expect(assets.asid == nil)
        #expect(assets.authenticationType == "sa")
    }

    @Test
    func `a rejected sign in fails`() async throws {
        let fixture = OlympUsFixture { _ in .json(#"{"serviceErrors":[]}"#, statusCode: 401) }

        await #expect(performing: {
            try await fixture.olymp.signIn(accountName: "user", password: "wrong", serviceKey: "key").singleOutput()
        }, throws: isOlympUsError(.signInRequestFailed))
    }
}

struct OlympUsTwoFactorTests {
    private let assets = OlympUs.AuthenticationAssets.fixture

    @Test
    func `a code from a trusted device is asked for`() async throws {
        let prompt = FakePrompt(answers: ["123456"])
        let fixture = OlympUsFixture(prompt: prompt) { _ in .json(authResponse) }

        let validation = try await fixture.olymp.requestAuthentication(assets: assets).singleOutput()

        guard case let .securityCode(code) = validation else {
            Issue.record("Expected a security code, got \(validation)")
            return
        }
        #expect(code == "123456")
        #expect(prompt.asked.values == ["Apple ID Verification Code: "])
        let request = try #require(fixture.server.requests(to: AppleEndpoint.auth).first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Apple-Widget-Key") == "service-key")
        #expect(request.value(forHTTPHeaderField: "scnt") == "scnt-value")
        #expect(request.value(forHTTPHeaderField: "X-Apple-ID-Session-Id") == "session-id")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(fixture.logs.messages.contains("Please enter a 6 digit verification code generated on one of your trusted devices."))
    }

    @Test
    func `the code input accepts the code length or sms`() async throws {
        let validators = Recorder<String>()
        let promptClient = PromptClient(
            ask: { message, invalidMessage, isInvalid in
                let results = ["12345", "123456", "1234567", "sms"].map { "\($0)=\(isInvalid($0))" }
                validators.append("\(message)|\(invalidMessage)|\(results.joined(separator: ","))")
                return "123456"
            },
            choose: { _, _ in 0 },
            agree: { _ in true },
            readSecret: { _ in "" }
        )
        let fixture = OlympUsFixture(promptClient: promptClient) { _ in .json(authResponse) }

        _ = try await fixture.olymp.requestAuthentication(assets: assets).singleOutput()

        #expect(validators.values == [
            "Apple ID Verification Code: |Invalide code length|12345=true,123456=false,1234567=true,sms=false",
        ])
    }

    @Test
    func `sms sends a code to the chosen phone number`() async throws {
        let prompt = FakePrompt(answers: ["sms", "654321"], choices: [1])
        let fixture = OlympUsFixture(prompt: prompt) { request in
            request.url?.path == AppleEndpoint.auth ? .json(authResponse) : .json("{}")
        }

        let validation = try await fixture.olymp.requestAuthentication(assets: assets).singleOutput()

        guard case let .verificationCode(phoneID, code) = validation else {
            Issue.record("Expected a verification code, got \(validation)")
            return
        }
        #expect(phoneID == 2)
        #expect(code == "654321")
        #expect(prompt.chosen.values == [["+1 (•••) •••-••11", "+49 ••• ••••22"]])
        #expect(prompt.asked.values == ["Apple ID Verification Code: ", "Please enter the received verification code:"])
        let request = try #require(fixture.server.requests(to: AppleEndpoint.verifyPhone).first)
        #expect(request.httpMethod == "PUT")
        let body = try json(request)
        #expect((body["phoneNumber"] as? NSDictionary)?["id"] as? Int == 2)
        #expect(body["mode"] as? String == "sms")
    }

    @Test
    func `a failed sms request fails`() async throws {
        let prompt = FakePrompt(answers: ["sms"], choices: [0])
        let fixture = OlympUsFixture(prompt: prompt) { request in
            request.url?.path == AppleEndpoint.auth ? .json(authResponse) : .failure(.notConnectedToInternet)
        }

        await #expect(performing: {
            try await fixture.olymp.requestAuthentication(assets: assets).singleOutput()
        }, throws: isOlympUsError(.requestSmsFailed))
    }

    @Test
    func `a failed authentication request fails`() async throws {
        let fixture = OlympUsFixture { _ in .json("{}", statusCode: 409) }

        await #expect(performing: {
            try await fixture.olymp.requestAuthentication(assets: assets).singleOutput()
        }, throws: isOlympUsError(.requestAuthentication))
    }

    @Test
    func `a trusted device code is sent to the trusted device endpoint`() async throws {
        let fixture = OlympUsFixture { _ in StubResponse(statusCode: 204) }

        let status = try await fixture.olymp.sendSecurityCode(validationType: .securityCode("123456"), assets: assets).singleOutput()

        #expect(status == 204)
        let request = try #require(fixture.server.requests(to: AppleEndpoint.trustedDeviceCode).first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json,application/json")
        let body = try json(request)
        #expect((body["securityCode"] as? NSDictionary)?["code"] as? String == "123456")
    }

    @Test
    func `an sms code is sent to the phone endpoint`() async throws {
        let fixture = OlympUsFixture { _ in StubResponse(statusCode: 200) }

        _ = try await fixture.olymp.sendSecurityCode(validationType: .verificationCode(2, "654321"), assets: assets).singleOutput()

        let request = try #require(fixture.server.requests(to: AppleEndpoint.phoneCode).first)
        let body = try json(request)
        #expect((body["phoneNumber"] as? NSDictionary)?["id"] as? Int == 2)
        #expect(body["mode"] as? String == "sms")
        #expect((body["securityCode"] as? NSDictionary)?["code"] as? String == "654321")
    }

    @Test(arguments: [400, 401, 412])
    func `a wrong code fails`(statusCode: Int) async throws {
        let fixture = OlympUsFixture { _ in StubResponse(statusCode: statusCode) }

        await withKnownIssue("A rejected security code counts as success") {
            await #expect(performing: {
                try await fixture.olymp.sendSecurityCode(validationType: .securityCode("000000"), assets: assets).singleOutput()
            }, throws: isOlympUsError(.deviceTrustFailed))
        }
    }

    @Test
    func `a failed code request fails`() async throws {
        let fixture = OlympUsFixture { _ in .failure(.timedOut) }

        await #expect(performing: {
            try await fixture.olymp.sendSecurityCode(validationType: .securityCode("123456"), assets: assets).singleOutput()
        }, throws: isOlympUsError(.deviceTrustFailed))
    }

    @Test
    func `trust returns the cookies of the response`() async throws {
        let fixture = OlympUsFixture { _ in StubResponse(headers: ["Set-Cookie": "myacinfo=trusted; Path=/"]) }

        let cookies = try await fixture.olymp.requestTrust(assets: assets).singleOutput()

        #expect(cookies.map(\.name) == ["myacinfo"])
        #expect(cookies.map(\.value) == ["trusted"])
        let request = try #require(fixture.server.requests(to: AppleEndpoint.trust).first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test
    func `a failed trust request fails`() async throws {
        let fixture = OlympUsFixture { _ in .failure(.timedOut) }

        await #expect(performing: {
            try await fixture.olymp.requestTrust(assets: assets).singleOutput()
        }, throws: isOlympUsError(.deviceTrustFailed))
    }

    @Test
    func `validation types point to their endpoint`() throws {
        #expect(ValidationType.securityCode("1").verificationURL.path == AppleEndpoint.trustedDeviceCode)
        #expect(ValidationType.verificationCode(1, "1").verificationURL.path == AppleEndpoint.phoneCode)
    }
}

struct OlympUsSessionTests {
    private let assets = OlympUs.AuthenticationAssets.fixture

    @Test
    func `a session stores the assets and the cookies`() async throws {
        let fixture = OlympUsFixture { _ in
            StubResponse(headers: ["Set-Cookie": "dqsid=abc; Path=/; Domain=.apple.com, myacinfo=def; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Path=/; Domain=.apple.com, nodomain=1; Path=/"])
        }

        try await fixture.olymp.getOlympusSession(assets: assets, for: "user").singleOutput()

        #expect(fixture.sessionStore.data(for: "user") != nil)
        let stored = try JSONDecoder().decode(OlympUs.AuthenticationAssets.self, from: try #require(fixture.sessionStore.data(for: "user")))
        #expect(stored.scnt == "scnt-value")
        #expect(fixture.cookieNames == ["dqsid", "myacinfo", "nodomain"])
        let storedCookies = try #require(fixture.defaults.defaults.array(forKey: "cookies") as? [[String: Any]])
        #expect(Set(storedCookies.compactMap { $0["Name"] as? String }).isSuperset(of: ["dqsid", "myacinfo"]))
        #expect(fixture.logs.messages == ["[6/7] Requesting download session"])
    }

    @Test
    func `a session without cookies is accepted`() async throws {
        let fixture = OlympUsFixture { _ in StubResponse() }

        try await fixture.olymp.getOlympusSession(assets: assets, for: "user").singleOutput()

        #expect(fixture.sessionStore.data(for: "user") != nil)
        #expect(fixture.defaults.defaults.object(forKey: "cookies") == nil)
    }

    @Test(arguments: [201, 401, 500])
    func `a session needs a 200 response`(statusCode: Int) async throws {
        let fixture = OlympUsFixture { _ in StubResponse(statusCode: statusCode) }

        await #expect(performing: {
            try await fixture.olymp.getOlympusSession(assets: assets, for: "user").singleOutput()
        }, throws: isOlympUsError(.olympusSessionFailed))
        #expect(fixture.sessionStore.accounts.isEmpty)
    }

    @Test
    func `download auth needs the download cookie`() async throws {
        let fixture = OlympUsFixture { _ in StubResponse(headers: ["Set-Cookie": downloadAuthCookie]) }

        try await fixture.olymp.getDownloadAuth(assets: assets).singleOutput()

        #expect(fixture.cookieNames.contains("ADCDownloadAuth"))
        let request = try #require(fixture.server.requests(to: AppleEndpoint.downloads).first)
        #expect(request.url?.host == "developer.apple.com")
        #expect(request.httpMethod == "POST")
    }

    @Test
    func `download auth fails without the download cookie`() async throws {
        let fixture = OlympUsFixture { _ in StubResponse(headers: ["Set-Cookie": "other=1; Path=/"]) }

        await #expect(performing: {
            try await fixture.olymp.getDownloadAuth(assets: assets).singleOutput()
        }, throws: isOlympUsError(.downloadAuthFailed))
    }

    @Test
    func `download auth fails when the request fails`() async throws {
        let fixture = OlympUsFixture { _ in .failure(.timedOut) }

        await #expect(performing: {
            try await fixture.olymp.getDownloadAuth(assets: assets).singleOutput()
        }, throws: isOlympUsError(.downloadAuthFailed))
    }

    @Test
    func `a stored session is validated`() async throws {
        let fixture = OlympUsFixture(storedAssets: ["user": OlympUs.AuthenticationAssets.fixtureData]) { _ in StubResponse() }

        try await fixture.olymp.validateSession(for: "user").singleOutput()

        #expect(fixture.server.requests(to: AppleEndpoint.session).count == 1)
        #expect(fixture.logs.messages.contains("Reusing valid session."))
        #expect(fixture.logs.messages.first == "[0/7] Validating existing session")
        #expect(fixture.logs.rawMessages.first?.hasPrefix("\u{1B}[1A") == false)
    }

    @Test
    func `an expired stored session is invalid`() async throws {
        let fixture = OlympUsFixture(storedAssets: ["user": OlympUs.AuthenticationAssets.fixtureData]) { _ in StubResponse(statusCode: 401) }

        await #expect(performing: {
            try await fixture.olymp.validateSession(for: "user").singleOutput()
        }, throws: isOlympUsError(.sessionInvalid))
        #expect(fixture.logs.messages.contains("Session invalid. Starting authentication."))
    }

    @Test
    func `without a stored session there is nothing to validate`() async throws {
        let fixture = OlympUsFixture { _ in
            Issue.record("Must not request")
            return StubResponse()
        }

        await #expect(performing: {
            try await fixture.olymp.validateSession(for: "user").singleOutput()
        }, throws: isOlympUsError(.sessionInvalid))
        #expect(fixture.olymp.storedAuthenticationAssets(for: "user") == nil)
    }

    @Test
    func `stored cookies are restored into the session`() throws {
        let defaults = TemporaryDefaults()
        let cookie = try #require(HTTPCookie(properties: [.domain: ".apple.com", .path: "/", .name: "restored", .value: "1"]))
        defaults.defaults.set([cookie.properties!], forKey: "cookies")
        let server = StubServer { _ in StubResponse() }

        let olymp = OlympUs(
            logger: LogRecorder().logger(),
            session: server.session(),
            userDefaults: defaults.defaults,
            sessionStore: InMemorySessionStore().store,
            prompt: FakePrompt().client
        )

        #expect(olymp.session.configuration.httpCookieStorage?.cookies?.map(\.name) == ["restored"])
    }

    @Test
    func `cleanup reports when nothing was stored`() {
        let fixture = OlympUsFixture { _ in StubResponse() }

        fixture.olymp.cleanup()

        #expect(fixture.logs.messages == ["No Apple developer portal session info was stored."])
    }

    @Test
    func `cleanup reports a failing store`() {
        let logs = LogRecorder()
        let server = StubServer { _ in StubResponse() }
        let olymp = OlympUs(
            logger: logs.logger(),
            session: server.session(),
            userDefaults: TemporaryDefaults().defaults,
            sessionStore: AuthenticationSessionStore(
                load: { _ in throw CocoaError(.fileNoSuchFile) },
                save: { _, _ in },
                removeAll: { throw CocoaError(.fileWriteNoPermission) }
            ),
            prompt: FakePrompt().client
        )

        olymp.cleanup()

        #expect(logs.messages == ["Error deleting Keychain entries. Please open Keychain Access.app and remove items named 'xcinfo.session'."])
    }
}

struct AppleAuthenticatorTests {
    @Test
    func `a valid stored session only needs the download auth`() async throws {
        let fixture = OlympUsFixture(storedAssets: ["user": OlympUs.AuthenticationAssets.fixtureData]) { request in
            request.url?.path == AppleEndpoint.downloads
                ? StubResponse(headers: ["Set-Cookie": downloadAuthCookie])
                : StubResponse()
        }
        let authenticator = AppleAuthenticator(olymp: fixture.olymp, logger: fixture.logs.logger())

        try await authenticator.authenticationProviding.authenticate(Credentials(username: "user", password: "secret"))

        #expect(fixture.server.requests.values.compactMap(\.url?.path) == [AppleEndpoint.session, AppleEndpoint.downloads])
    }

    @Test
    func `a new sign in walks through every step`() async throws {
        let prompt = FakePrompt(answers: ["123456"])
        let fixture = OlympUsFixture(prompt: prompt) { request in
            switch request.url?.path {
            case AppleEndpoint.config:
                return .json(#"{"authServiceKey":"service-key"}"#)
            case AppleEndpoint.signIn:
                return .json(#"{"authType":"hsa2"}"#, headers: ["scnt": "scnt-value", "X-Apple-ID-Session-Id": "session-id"])
            case AppleEndpoint.auth:
                return .json(authResponse)
            case AppleEndpoint.trustedDeviceCode:
                return StubResponse(statusCode: 204)
            case AppleEndpoint.trust:
                return StubResponse(headers: ["Set-Cookie": "myacinfo=trusted; Path=/"])
            case AppleEndpoint.session:
                return StubResponse()
            case AppleEndpoint.downloads:
                return StubResponse(headers: ["Set-Cookie": downloadAuthCookie])
            default:
                return StubResponse(statusCode: 404)
            }
        }
        let authenticator = AppleAuthenticator(olymp: fixture.olymp, logger: fixture.logs.logger())

        try await authenticator.authenticate(credentials: Credentials(username: "user", password: "secret"))

        #expect(fixture.server.requests.values.compactMap(\.url?.path) == [
            AppleEndpoint.config,
            AppleEndpoint.signIn,
            AppleEndpoint.auth,
            AppleEndpoint.trustedDeviceCode,
            AppleEndpoint.trust,
            AppleEndpoint.session,
            AppleEndpoint.downloads,
        ])
        #expect(fixture.sessionStore.data(for: "user") != nil)
        #expect(Array(fixture.logs.messages.prefix(3)) == [
            "[0/7] Validating existing session",
            "[1/7] Requesting service key",
            "[2/7] Signing in with credentials",
        ])
    }

    @Test
    func `a failing step fails the authentication`() async throws {
        let fixture = OlympUsFixture { request in
            request.url?.path == AppleEndpoint.config
                ? .json(#"{"authServiceKey":"service-key"}"#)
                : StubResponse(statusCode: 401)
        }
        let authenticator = AppleAuthenticator(olymp: fixture.olymp, logger: fixture.logs.logger())

        await #expect(throws: AuthenticationError.self) {
            try await authenticator.authenticate(credentials: Credentials(username: "user", password: "wrong"))
        }
        #expect(fixture.server.requests.values.compactMap(\.url?.path) == [AppleEndpoint.config, AppleEndpoint.signIn])
    }
}
