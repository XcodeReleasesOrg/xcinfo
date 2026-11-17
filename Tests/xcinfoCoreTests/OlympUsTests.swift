import CryptoKit
import Foundation
@testable import OlympUs
import os
import Testing
import XCIFoundation
@testable import xcinfoCore

private enum AppleEndpoint {
    static let config = "/olympus/v1/app/config"
    static let signOut = "/logout"
    static let signIn = "/appleauth/auth/signin"
    static let signInInit = "/appleauth/auth/signin/init"
    static let signInComplete = "/appleauth/auth/signin/complete"
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
private let sessionHeaders = ["scnt": "scnt-value", "X-Apple-ID-Session-Id": "session-id"]

final class OlympUsFixture: Sendable {
    let server: StubServer
    let sessionStore: InMemorySessionStore
    let logs = LogRecorder()
    let prompt: FakePrompt
    let olymp: OlympUs

    init(
        storedAssets: [String: Data] = [:],
        legacyCookies: [HTTPCookie] = [],
        prompt: FakePrompt = FakePrompt(),
        promptClient: PromptClient? = nil,
        handler: @escaping StubServer.Handler
    ) {
        server = StubServer(handler: handler)
        sessionStore = InMemorySessionStore(storedAssets, legacyCookies: legacyCookies)
        self.prompt = prompt
        olymp = OlympUs(
            logger: logs.logger(isVerbose: true),
            session: server.session(),
            sessionStore: sessionStore.store,
            prompt: promptClient ?? prompt.client,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
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

private func isOlympUsError(_ expected: OlympUsError) -> @Sendable (any Error) -> Bool {
    { ($0 as? OlympUsError) == expected }
}

private func appleServer(
    srp: FakeAppleSRPServer,
    completion: @escaping @Sendable (URLRequest, Bool) -> StubResponse = { _, valid in
        valid ? .json(#"{"authType":"hsa2"}"#, statusCode: 409, headers: sessionHeaders) : .json("{}", statusCode: 401)
    },
    otherwise: @escaping @Sendable (URLRequest) -> StubResponse = { _ in StubResponse() }
) -> StubServer.Handler {
    { request in
        switch request.url?.path {
        case AppleEndpoint.signIn:
            StubResponse(headers: ["X-Apple-HC-Bits": "8", "X-Apple-HC-Challenge": "challenge"])
        case AppleEndpoint.signInInit:
            srp.initResponse(for: request)
        case AppleEndpoint.signInComplete:
            completion(request, srp.isValidCompletion(request))
        default:
            otherwise(request)
        }
    }
}

struct OlympUsServiceKeyTests {
    @Test
    func `the service key of a stored session is reused`() async throws {
        let fixture = OlympUsFixture(storedAssets: ["user": OlympUs.AuthenticationAssets.fixtureData]) { _ in
            Issue.record("Must not request")
            return StubResponse()
        }

        let key = try await fixture.olymp.getServiceKey(for: "user")

        #expect(key == "service-key")
        #expect(fixture.logs.messages.last == "[1/7] Requesting service key")
    }

    @Test
    func `the service key is read from the sign-out redirect`() async throws {
        let fixture = OlympUsFixture { request in
            request.url?.path == "/logout"
                ? StubResponse(statusCode: 302, headers: ["Location": "https://idmsa.apple.com/appleauth/signout?widgetKey=redirect-key&asop=destroy-session"])
                : .json(#"{"authServiceKey":"config-key"}"#)
        }

        let key = try await fixture.olymp.getServiceKey(for: "user")

        #expect(key == "redirect-key")
        let request = try #require(fixture.server.requests.values.first)
        #expect(request.url?.absoluteString == "https://appstoreconnect.apple.com/logout")
        #expect(request.httpMethod == "HEAD")
        #expect(fixture.server.requests.values.count == 1)
    }

    @Test
    func `the app config is the fallback for the service key`() async throws {
        let fixture = OlympUsFixture { _ in .json(#"{"authServiceKey":"fresh-key"}"#) }

        let key = try await fixture.olymp.getServiceKey(for: "user")

        #expect(key == "fresh-key")
        #expect(fixture.server.requests.values.map { $0.url?.absoluteString } == [
            "https://appstoreconnect.apple.com/logout",
            "https://appstoreconnect.apple.com/olympus/v1/app/config?hostname=itunesconnect.apple.com",
        ])
    }

    @Test
    func `a missing service key fails`() async throws {
        let fixture = OlympUsFixture { request in
            request.url?.path == "/logout" ? StubResponse(statusCode: 200) : .json(#"{"message":"Not Found"}"#, statusCode: 404)
        }

        await #expect(performing: {
            try await fixture.olymp.getServiceKey(for: "user")
        }, throws: { error in
            guard case let OlympUsError.missingSessionKey(reason) = error else { return false }
            return reason.contains("HTTP 200") && reason.contains("HTTP 404")
                && (error as? OlympUsError)?.description.contains("configuration endpoint: HTTP 404") == true
        })
    }
}

struct OlympUsSignInTests {
    private let srp = FakeAppleSRPServer(accountName: "user@example.invalid", password: "correct horse")

    @Test(arguments: [PasswordProtocol.s2k, .s2kFo])
    func `sign in proves the password with srp`(passwordProtocol: PasswordProtocol) async throws {
        let srp = FakeAppleSRPServer(accountName: "user@example.invalid", password: "correct horse", passwordProtocol: passwordProtocol)
        let fixture = OlympUsFixture(handler: appleServer(srp: srp))

        let result = try await fixture.olymp.signIn(accountName: "user@example.invalid", password: "correct horse", serviceKey: "key")

        #expect(result.requiresTwoFactorAuthentication)
        #expect(result.assets == OlympUs.AuthenticationAssets(serviceKey: "key", scnt: "scnt-value", asid: "session-id", authenticationType: "hsa2"))
        let completion = try #require(fixture.server.requests(to: AppleEndpoint.signInComplete).first)
        #expect(completion.url?.query == "isRememberMeEnabled=false")
        let body = try json(completion)
        #expect(body["accountName"] as? String == "user@example.invalid")
        #expect(body["rememberMe"] as? Bool == false)
        #expect(body["m2"] is String)
    }

    @Test
    func `sign in never sends the password`() async throws {
        let fixture = OlympUsFixture(handler: appleServer(srp: srp))

        _ = try await fixture.olymp.signIn(accountName: "user@example.invalid", password: "correct horse", serviceKey: "key")

        let bodies = fixture.server.requests.values.compactMap(\.httpBody).map { String(decoding: $0, as: UTF8.self) }
        #expect(!bodies.contains { $0.contains("correct horse") })
        let initBody = try json(try #require(fixture.server.requests(to: AppleEndpoint.signInInit).first))
        #expect(initBody["protocols"] as? [String] == ["s2k", "s2k_fo"])
        #expect(initBody["a"] is String)
    }

    @Test
    func `sign in sends the widget key and a hashcash stamp`() async throws {
        let fixture = OlympUsFixture(handler: appleServer(srp: srp))

        _ = try await fixture.olymp.signIn(accountName: "user@example.invalid", password: "correct horse", serviceKey: "key")

        let challenge = try #require(fixture.server.requests(to: AppleEndpoint.signIn).first)
        #expect(challenge.url?.query == "widgetKey=key")
        for path in [AppleEndpoint.signInInit, AppleEndpoint.signInComplete] {
            let request = try #require(fixture.server.requests(to: path).first)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Apple-Widget-Key") == "key")
            #expect(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
        }
        #expect(fixture.server.requests(to: AppleEndpoint.signInInit).first?.value(forHTTPHeaderField: "X-Apple-HC") == nil)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let localDate = formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000))
        let stamp = try #require(fixture.server.requests(to: AppleEndpoint.signInComplete).first?.value(forHTTPHeaderField: "X-Apple-HC"))
        #expect(stamp.hasPrefix("1:8:\(localDate):challenge::"))
        #expect(Hashcash.hasLeadingZeroBits(8, in: Array(Insecure.SHA1.hash(data: Data(stamp.utf8)))))
    }

    @Test
    func `sign in works without a hashcash challenge`() async throws {
        let handler = appleServer(srp: srp)
        let fixture = OlympUsFixture { request in
            request.url?.path == AppleEndpoint.signIn ? StubResponse() : handler(request)
        }

        _ = try await fixture.olymp.signIn(accountName: "user@example.invalid", password: "correct horse", serviceKey: "key")

        #expect(fixture.server.requests(to: AppleEndpoint.signInComplete).first?.value(forHTTPHeaderField: "X-Apple-HC") == nil)
    }

    @Test
    func `verbose output shows each sign in step without secrets`() async throws {
        let fixture = OlympUsFixture(handler: appleServer(srp: srp, completion: { _, _ in
            .json(#"{"serviceErrors":[{"code":"-20101","message":"Your Apple ID or password was incorrect."}]}"#, statusCode: 401)
        }))

        await #expect(performing: {
            try await fixture.olymp.signIn(accountName: "user@example.invalid", password: "correct horse", serviceKey: "key")
        }, throws: isOlympUsError(.incorrectCredentials))

        let messages = fixture.logs.messages
        #expect(messages.contains("POST /appleauth/auth/signin/init: HTTP 200"))
        #expect(messages.contains("Password protocol s2k, 1000 iterations"))
        #expect(messages.contains("POST /appleauth/auth/signin/complete: HTTP 401"))
        #expect(messages.contains("Apple: -20101 Your Apple ID or password was incorrect."))
        #expect(!messages.contains { $0.contains("correct horse") || $0.contains("challenge-token") })
    }

    @Test
    func `a successful sign in without two factor authentication is reported`() async throws {
        let fixture = OlympUsFixture(handler: appleServer(srp: srp, completion: { _, valid in
            valid ? .json("{}", statusCode: 200, headers: sessionHeaders) : .json("{}", statusCode: 401)
        }))

        let result = try await fixture.olymp.signIn(accountName: "user@example.invalid", password: "correct horse", serviceKey: "key")

        #expect(!result.requiresTwoFactorAuthentication)
        #expect(result.assets.scnt == "scnt-value")
    }

    @Test
    func `a wrong password is reported`() async throws {
        let fixture = OlympUsFixture(handler: appleServer(srp: srp))

        await #expect(performing: {
            try await fixture.olymp.signIn(accountName: "user@example.invalid", password: "wrong", serviceKey: "key")
        }, throws: isOlympUsError(.incorrectCredentials))
    }

    @Test(arguments: [
        (401, OlympUsError.incorrectCredentials),
        (403, .accountLocked),
        (412, .privacyAcknowledgementRequired),
        (500, .signInRequestFailed),
    ])
    func `rejected sign ins are reported specifically`(statusCode: Int, error: OlympUsError) async throws {
        let fixture = OlympUsFixture(handler: appleServer(srp: srp, completion: { _, _ in .json("{}", statusCode: statusCode) }))

        await #expect(performing: {
            try await fixture.olymp.signIn(accountName: "user@example.invalid", password: "correct horse", serviceKey: "key")
        }, throws: isOlympUsError(error))
    }

    @Test
    func `an unknown account is reported when the challenge is refused`() async throws {
        let fixture = OlympUsFixture(handler: appleServer(srp: srp))

        await #expect(performing: {
            try await fixture.olymp.signIn(accountName: "someone@example.invalid", password: "correct horse", serviceKey: "key")
        }, throws: isOlympUsError(.incorrectCredentials))
        #expect(fixture.server.requests(to: AppleEndpoint.signInComplete).isEmpty)
    }

    @Test
    func `a broken challenge fails the sign in`() async throws {
        let fixture = OlympUsFixture { request in
            request.url?.path == AppleEndpoint.signInInit ? .json(#"{"unexpected":true}"#) : StubResponse()
        }

        await #expect(performing: {
            try await fixture.olymp.signIn(accountName: "user@example.invalid", password: "correct horse", serviceKey: "key")
        }, throws: isOlympUsError(.signInRequestFailed))
    }
}

struct OlympUsTwoFactorTests {
    private let assets = OlympUs.AuthenticationAssets.fixture

    @Test
    func `a code from a trusted device is asked for`() async throws {
        let prompt = FakePrompt(answers: ["123456"])
        let fixture = OlympUsFixture(prompt: prompt) { _ in .json(authResponse) }

        let validation = try await fixture.olymp.requestAuthentication(assets: assets)

        #expect(validation == .securityCode("123456"))
        #expect(prompt.asked.values == ["Apple ID verification code: "])
        let request = try #require(fixture.server.requests(to: AppleEndpoint.auth).first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "X-Apple-Widget-Key") == "service-key")
        #expect(request.value(forHTTPHeaderField: "scnt") == "scnt-value")
        #expect(request.value(forHTTPHeaderField: "X-Apple-ID-Session-Id") == "session-id")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(fixture.logs.messages.contains("Enter the 6 digit verification code that Apple shows on one of your trusted Apple devices."))
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
            readLine: { _ in "" },
            readSecret: { _ in "" }
        )
        let fixture = OlympUsFixture(promptClient: promptClient) { _ in .json(authResponse) }

        _ = try await fixture.olymp.requestAuthentication(assets: assets)

        #expect(validators.values == [
            "Apple ID verification code: |Enter 6 digits|12345=true,123456=false,1234567=true,sms=false",
        ])
    }

    @Test
    func `sms is only offered with trusted phone numbers`() async throws {
        let prompt = FakePrompt(answers: ["123456"])
        let fixture = OlympUsFixture(prompt: prompt) { _ in
            .json(#"{"securityCode":{"length":6}}"#)
        }

        let validation = try await fixture.olymp.requestAuthentication(assets: assets)

        #expect(validation == .securityCode("123456"))
        #expect(!fixture.logs.messages.contains { $0.contains("sms") })
    }

    @Test
    func `a locked verification is reported`() async throws {
        let fixture = OlympUsFixture { _ in
            .json(#"{"securityCode":{"length":6,"securityCodeLocked":true}}"#)
        }

        await #expect(performing: {
            try await fixture.olymp.requestAuthentication(assets: assets)
        }, throws: isOlympUsError(.verificationCodeLocked))
    }

    @Test
    func `sms sends a code to the chosen phone number`() async throws {
        let prompt = FakePrompt(answers: ["sms", "654321"], choices: [1])
        let fixture = OlympUsFixture(prompt: prompt) { request in
            request.url?.path == AppleEndpoint.auth ? .json(authResponse) : .json("{}")
        }

        let validation = try await fixture.olymp.requestAuthentication(assets: assets)

        #expect(validation == .verificationCode(2, "654321"))
        #expect(prompt.chosen.values == [["+1 (•••) •••-••11", "+49 ••• ••••22"]])
        #expect(prompt.asked.values == ["Apple ID verification code: ", "Verification code from the text message: "])
        let request = try #require(fixture.server.requests(to: AppleEndpoint.verifyPhone).first)
        #expect(request.httpMethod == "PUT")
        let body = try json(request)
        #expect((body["phoneNumber"] as? NSDictionary)?["id"] as? Int == 2)
        #expect(body["mode"] as? String == "sms")
    }

    @Test(arguments: [StubResponse.failure(.notConnectedToInternet), StubResponse(statusCode: 423)])
    func `a failed sms request fails`(failure: StubResponse) async throws {
        let prompt = FakePrompt(answers: ["sms"], choices: [0])
        let fixture = OlympUsFixture(prompt: prompt) { request in
            request.url?.path == AppleEndpoint.auth ? .json(authResponse) : failure
        }

        await #expect(performing: {
            try await fixture.olymp.requestAuthentication(assets: assets)
        }, throws: isOlympUsError(.requestSmsFailed))
    }

    @Test
    func `a failed authentication request fails`() async throws {
        let fixture = OlympUsFixture { _ in .json("{}", statusCode: 409) }

        await #expect(performing: {
            try await fixture.olymp.requestAuthentication(assets: assets)
        }, throws: isOlympUsError(.requestAuthentication))
    }

    @Test
    func `a trusted device code is sent to the trusted device endpoint`() async throws {
        let fixture = OlympUsFixture { _ in StubResponse(statusCode: 204) }

        let status = try await fixture.olymp.sendSecurityCode(validationType: .securityCode("123456"), assets: assets)

        #expect(status == 204)
        let request = try #require(fixture.server.requests(to: AppleEndpoint.trustedDeviceCode).first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let body = try json(request)
        #expect((body["securityCode"] as? NSDictionary)?["code"] as? String == "123456")
    }

    @Test
    func `an sms code is sent to the phone endpoint`() async throws {
        let fixture = OlympUsFixture { _ in StubResponse(statusCode: 200) }

        try await fixture.olymp.sendSecurityCode(validationType: .verificationCode(2, "654321"), assets: assets)

        let request = try #require(fixture.server.requests(to: AppleEndpoint.phoneCode).first)
        let body = try json(request)
        #expect((body["phoneNumber"] as? NSDictionary)?["id"] as? Int == 2)
        #expect(body["mode"] as? String == "sms")
        #expect((body["securityCode"] as? NSDictionary)?["code"] as? String == "654321")
    }

    @Test(arguments: [
        (400, OlympUsError.incorrectVerificationCode),
        (401, .incorrectVerificationCode),
        (412, .privacyAcknowledgementRequired),
        (500, .deviceTrustFailed),
    ])
    func `a wrong code fails`(statusCode: Int, error: OlympUsError) async throws {
        let fixture = OlympUsFixture { _ in StubResponse(statusCode: statusCode) }

        await #expect(performing: {
            try await fixture.olymp.sendSecurityCode(validationType: .securityCode("000000"), assets: assets)
        }, throws: isOlympUsError(error))
    }

    @Test
    func `a failed code request fails`() async throws {
        let fixture = OlympUsFixture { _ in .failure(.timedOut) }

        await #expect(performing: {
            try await fixture.olymp.sendSecurityCode(validationType: .securityCode("123456"), assets: assets)
        }, throws: isOlympUsError(.deviceTrustFailed))
    }

    @Test
    func `trust returns the cookies of the response`() async throws {
        let fixture = OlympUsFixture { _ in StubResponse(headers: ["Set-Cookie": "myacinfo=trusted; Path=/"]) }

        let cookies = try await fixture.olymp.requestTrust(assets: assets)

        #expect(cookies.map(\.name) == ["myacinfo"])
        #expect(cookies.map(\.value) == ["trusted"])
        let request = try #require(fixture.server.requests(to: AppleEndpoint.trust).first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test(arguments: [StubResponse.failure(.timedOut), StubResponse(statusCode: 500)])
    func `a failed trust request fails`(failure: StubResponse) async throws {
        let fixture = OlympUsFixture { _ in failure }

        await #expect(performing: {
            try await fixture.olymp.requestTrust(assets: assets)
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
    func `the session and its cookies are saved once download auth succeeds`() async throws {
        let fixture = OlympUsFixture { request in
            request.url?.path == AppleEndpoint.downloads
                ? StubResponse(headers: ["Set-Cookie": downloadAuthCookie])
                : StubResponse(headers: ["Set-Cookie": "dqsid=abc; Path=/; Domain=.apple.com, myacinfo=def; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Path=/; Domain=.apple.com, nodomain=1; Path=/"])
        }

        try await fixture.olymp.getOlympusSession(assets: assets, for: "user")
        #expect(fixture.sessionStore.data(for: "user") == nil)
        try await fixture.olymp.getDownloadAuth(assets: assets)

        let stored = try #require(fixture.sessionStore.storedSession(for: "user"))
        #expect(stored.assets == assets)
        #expect(fixture.cookieNames == ["ADCDownloadAuth", "dqsid", "myacinfo", "nodomain"])
        #expect(fixture.sessionStore.cookieNames(for: "user") == ["dqsid", "myacinfo"])
        #expect(fixture.sessionStore.saves.values == ["user"])
        #expect(fixture.logs.messages.contains("Saved the session with 2 cookies."))
    }

    @Test
    func `a session whose only change is a new download cookie is not saved again`() async throws {
        let stored = InMemorySessionStore.session(cookies: [HTTPCookie(properties: [.domain: ".apple.com", .path: "/", .name: "myacinfo", .value: "account"])!])
        let fixture = OlympUsFixture(storedAssets: ["user": stored]) { _ in StubResponse(headers: ["Set-Cookie": downloadAuthCookie]) }

        try await fixture.olymp.validateSession(for: "user")
        try await fixture.olymp.getDownloadAuth(assets: assets)

        #expect(fixture.sessionStore.saves.values.isEmpty)
        #expect(fixture.logs.messages.contains("The session is unchanged and is not saved again."))
    }

    @Test
    func `an expired stored cookie alone does not cause a keychain write`() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = InMemorySessionStore.session(cookies: [
            HTTPCookie(properties: [.domain: ".apple.com", .path: "/", .name: "myacinfo", .value: "account"])!,
            HTTPCookie(properties: [.domain: "appstoreconnect.apple.com", .path: "/", .name: "dqsid", .value: "old", .expires: now.addingTimeInterval(-60)])!,
        ])
        let fixture = OlympUsFixture(storedAssets: ["user": stored]) { _ in StubResponse(headers: ["Set-Cookie": downloadAuthCookie]) }

        try await fixture.olymp.validateSession(for: "user")
        try await fixture.olymp.getDownloadAuth(assets: assets)

        #expect(fixture.sessionStore.saves.values.isEmpty)
        #expect(fixture.logs.messages.contains("The session is unchanged and is not saved again."))
    }

    @Test
    func `a refreshed cookie value saves the session and names the cookie`() async throws {
        let stored = InMemorySessionStore.session(cookies: [HTTPCookie(properties: [.domain: ".apple.com", .path: "/", .name: "myacinfo", .value: "old"])!])
        let fixture = OlympUsFixture(storedAssets: ["user": stored]) { _ in
            StubResponse(headers: ["Set-Cookie": "\(downloadAuthCookie), myacinfo=new; Path=/; Domain=.apple.com"])
        }

        try await fixture.olymp.validateSession(for: "user")
        try await fixture.olymp.getDownloadAuth(assets: assets)

        #expect(fixture.sessionStore.saves.values == ["user"])
        #expect(fixture.logs.messages.contains("Saving the session because these cookies changed: myacinfo."))
    }

    @Test(arguments: [201, 401, 500])
    func `a session needs a 200 response`(statusCode: Int) async throws {
        let fixture = OlympUsFixture { _ in StubResponse(statusCode: statusCode) }

        await #expect(performing: {
            try await fixture.olymp.getOlympusSession(assets: assets, for: "user")
        }, throws: isOlympUsError(.olympusSessionFailed))
        #expect(fixture.sessionStore.accounts.isEmpty)
    }

    @Test
    func `download auth needs the download cookie`() async throws {
        let fixture = OlympUsFixture { _ in StubResponse(headers: ["Set-Cookie": downloadAuthCookie]) }

        try await fixture.olymp.getDownloadAuth(assets: assets)

        #expect(fixture.cookieNames.contains("ADCDownloadAuth"))
        let request = try #require(fixture.server.requests(to: AppleEndpoint.downloads).first)
        #expect(request.url?.host == "developer.apple.com")
        #expect(request.httpMethod == "POST")
    }

    @Test
    func `download auth logs which xcode archives apple lists`() async throws {
        let listing = """
        {"downloads": [
          {"name": "Xcode 27.3 beta 2", "files": [{"remotePath": "/Developer_Tools/Xcode_27.3_beta_2/Xcode_27.3_beta_2.xip"}, {"remotePath": "/Developer_Tools/Xcode_27.3_beta_2/Xcode_27.3_beta_2.aea"}]},
          {"name": "Xcode 27.2", "files": [{"remotePath": "/Developer_Tools/Xcode_27.2/Xcode_27.2.xip"}]},
          {"name": "Command Line Tools for Xcode 27.2", "files": [{"remotePath": "/Developer_Tools/CLT/Command_Line_Tools.dmg"}]}
        ]}
        """
        let fixture = OlympUsFixture { _ in StubResponse(headers: ["Set-Cookie": downloadAuthCookie], body: Data(listing.utf8)) }

        try await fixture.olymp.getDownloadAuth(assets: assets)

        #expect(fixture.logs.messages.contains("Apple lists 2 Xcode archives, 1 of them as .aea."))
        #expect(fixture.logs.messages.contains("  Xcode 27.3 beta 2: .xip, .aea"))
    }

    @Test
    func `download auth fails without the download cookie`() async throws {
        let fixture = OlympUsFixture { _ in StubResponse(headers: ["Set-Cookie": "other=1; Path=/"]) }

        await #expect(performing: {
            try await fixture.olymp.getDownloadAuth(assets: assets)
        }, throws: isOlympUsError(.downloadAuthFailed))
    }

    @Test
    func `download auth fails when the request fails`() async throws {
        let fixture = OlympUsFixture { _ in .failure(.timedOut) }

        await #expect(performing: {
            try await fixture.olymp.getDownloadAuth(assets: assets)
        }, throws: isOlympUsError(.downloadAuthFailed))
    }

    @Test
    func `a stored session is validated`() async throws {
        let fixture = OlympUsFixture(storedAssets: ["user": OlympUs.AuthenticationAssets.fixtureData]) { _ in StubResponse() }

        try await fixture.olymp.validateSession(for: "user")

        #expect(fixture.server.requests(to: AppleEndpoint.session).count == 1)
        #expect(fixture.logs.messages.contains("Reusing valid session."))
        #expect(fixture.logs.messages.first == "[0/7] Validating existing session")
    }

    @Test
    func `an expired stored session is invalid`() async throws {
        let fixture = OlympUsFixture(storedAssets: ["user": OlympUs.AuthenticationAssets.fixtureData]) { _ in StubResponse(statusCode: 401) }

        await #expect(performing: {
            try await fixture.olymp.validateSession(for: "user")
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
            try await fixture.olymp.validateSession(for: "user")
        }, throws: isOlympUsError(.sessionInvalid))
        #expect(await fixture.olymp.storedAuthenticationAssets(for: "user") == nil)
    }

    @Test
    func `stored cookies are restored with the session, session-only cookies included`() async throws {
        let persistent = try #require(HTTPCookie(properties: [.domain: ".apple.com", .path: "/", .name: "myacinfo", .value: "1", .expires: Date().addingTimeInterval(3600)]))
        let sessionOnly = try #require(HTTPCookie(properties: [.domain: ".apple.com", .path: "/", .name: "DES1234", .value: "trusted"]))
        let stored = InMemorySessionStore.session(cookies: [persistent, sessionOnly])
        let fixture = OlympUsFixture(storedAssets: ["user": stored]) { _ in StubResponse() }

        #expect(await fixture.olymp.storedAuthenticationAssets(for: "user") == assets)

        #expect(fixture.cookieNames == ["DES1234", "myacinfo"])
        #expect(fixture.logs.messages.contains("Restored 2 cookies: DES1234, myacinfo"))
        #expect(!fixture.logs.messages.contains { $0.contains("trusted") })
    }

    @Test
    func `a session survives a restart`() async throws {
        let sessionStore = InMemorySessionStore()
        let server = StubServer { request in
            request.url?.path == AppleEndpoint.downloads
                ? StubResponse(headers: ["Set-Cookie": downloadAuthCookie])
                : StubResponse(headers: ["Set-Cookie": "myacinfo=session; Path=/; Domain=.apple.com"])
        }
        let first = OlympUs(logger: LogRecorder().logger(), session: server.session(), sessionStore: sessionStore.store, prompt: FakePrompt().client)
        try await first.getOlympusSession(assets: assets, for: "user")
        try await first.getDownloadAuth(assets: assets)

        let restartedLogs = LogRecorder()
        let restarted = OlympUs(logger: restartedLogs.logger(), session: server.session(), sessionStore: sessionStore.store, prompt: FakePrompt().client)
        try await restarted.validateSession(for: "user")

        #expect(restarted.session.configuration.httpCookieStorage?.cookies?.map(\.name).sorted() == ["myacinfo"])
        #expect(restartedLogs.messages.contains("Stored session found."))
        #expect(restartedLogs.messages.contains("Reusing valid session."))
    }

    @Test
    func `signing in keeps only the trusted browser cookie of an expired session`() async throws {
        let trust = try #require(HTTPCookie(properties: [.domain: ".apple.com", .path: "/", .name: "DES1234", .value: "trusted"]))
        let expired = try #require(HTTPCookie(properties: [.domain: ".apple.com", .path: "/", .name: "myacinfo", .value: "expired"]))
        let abuse = try #require(HTTPCookie(properties: [.domain: "idmsa.apple.com", .path: "/", .name: "aasp", .value: "old"]))
        let srp = FakeAppleSRPServer(accountName: "user", password: "secret")
        let fixture = OlympUsFixture(storedAssets: ["user": InMemorySessionStore.session(cookies: [trust, expired, abuse])], handler: appleServer(srp: srp))

        _ = try await fixture.olymp.signIn(accountName: "user", password: "secret", serviceKey: "key")

        #expect(fixture.cookieNames == ["DES1234"])
        #expect(fixture.logs.messages.contains("Kept 1 trusted-browser cookies for the sign-in, removed 2 others."))
    }

    @Test
    func `a session in the old format is migrated with the old cookies`() async throws {
        let cookie = try #require(HTTPCookie(properties: [.domain: ".apple.com", .path: "/", .name: "myacinfo", .value: "1"]))
        let fixture = OlympUsFixture(storedAssets: ["user": OlympUs.AuthenticationAssets.fixtureData], legacyCookies: [cookie]) { _ in
            StubResponse(headers: ["Set-Cookie": downloadAuthCookie])
        }

        try await fixture.olymp.validateSession(for: "user")
        try await fixture.olymp.getDownloadAuth(assets: assets)

        #expect(fixture.sessionStore.cookieNames(for: "user") == ["myacinfo"])
        #expect(!fixture.sessionStore.hasLegacyCookies)
    }

    @Test
    func `a failing session read is reported instead of treated as no session`() async {
        let logs = LogRecorder()
        let server = StubServer { _ in
            Issue.record("Must not request")
            return StubResponse()
        }
        let olymp = OlympUs(
            logger: logs.logger(),
            session: server.session(),
            sessionStore: AuthenticationSessionStore(
                load: { _ in throw KeychainAccessError(underlying: "denied") },
                save: { _, _ in },
                removeAll: { 0 }
            ),
            prompt: FakePrompt().client
        )

        #expect(await olymp.storedAuthenticationAssets(for: "user") == nil)
        #expect(logs.events.contains(.message("Could not read the stored Apple session from the Keychain (\(KeychainAccessError(underlying: "denied"))). Allow xcinfo to access the Keychain to avoid signing in again.", .warning)))
    }

    @Test
    func `cleanup removes the stored session and cookies`() async throws {
        let fixture = OlympUsFixture(storedAssets: ["user": InMemorySessionStore.session(cookies: [])], legacyCookies: [HTTPCookie(properties: [.domain: ".apple.com", .path: "/", .name: "old", .value: "1"])!]) { _ in StubResponse() }

        await fixture.olymp.cleanup()

        #expect(fixture.sessionStore.accounts.isEmpty)
        #expect(!fixture.sessionStore.hasLegacyCookies)
        #expect(fixture.logs.messages == ["Deleted Apple developer portal session info from keychain."])
    }

    @Test
    func `cleanup reports when nothing was stored`() async {
        let fixture = OlympUsFixture { _ in StubResponse() }

        await fixture.olymp.cleanup()

        #expect(fixture.logs.messages == ["No Apple developer portal session info was stored."])
    }

    @Test
    func `cleanup reports a failing store`() async {
        let logs = LogRecorder()
        let server = StubServer { _ in StubResponse() }
        let olymp = OlympUs(
            logger: logs.logger(),
            session: server.session(),
            sessionStore: AuthenticationSessionStore(
                load: { _ in nil },
                save: { _, _ in },
                removeAll: { throw CocoaError(.fileWriteNoPermission) }
            ),
            prompt: FakePrompt().client
        )

        await olymp.cleanup()

        #expect(logs.messages == ["Error deleting Keychain entries. Please open Keychain Access.app and remove the item named 'xcinfo'."])
    }

    @Test
    func `errors describe what went wrong`() {
        #expect(OlympUsError.incorrectCredentials.description.contains("Apple rejected the password for this Apple ID."))
        #expect(OlympUsError.incorrectCredentials.description.contains("not your Mac password"))
        #expect(OlympUsError.incorrectCredentials.description.contains("can lock your Apple ID"))
        #expect(OlympUsError.incorrectVerificationCode.description == "The verification code is incorrect.")
        #expect(OlympUsError.accountLocked.description.contains("iforgot.apple.com"))
    }
}

struct AppleAuthenticatorTests {
    private let srp = FakeAppleSRPServer(accountName: "user", password: "secret")

    @Test
    func `a valid stored session only needs the download auth`() async throws {
        let fixture = OlympUsFixture(storedAssets: ["user": OlympUs.AuthenticationAssets.fixtureData]) { request in
            request.url?.path == AppleEndpoint.downloads
                ? StubResponse(headers: ["Set-Cookie": downloadAuthCookie])
                : StubResponse()
        }
        let authenticator = AppleAuthenticator(olymp: fixture.olymp, logger: fixture.logs.logger())

        try await authenticator.authenticate(username: "user", password: { "secret" })

        #expect(fixture.server.requests.values.compactMap(\.url?.path) == [AppleEndpoint.session, AppleEndpoint.downloads])
    }

    @Test
    func `a new sign in with two factor authentication walks through every step`() async throws {
        let prompt = FakePrompt(answers: ["123456"])
        let fixture = OlympUsFixture(prompt: prompt, handler: appleServer(srp: srp, otherwise: { request in
            switch request.url?.path {
            case AppleEndpoint.config:
                .json(#"{"authServiceKey":"service-key"}"#)
            case AppleEndpoint.auth:
                .json(authResponse)
            case AppleEndpoint.trustedDeviceCode:
                StubResponse(statusCode: 204)
            case AppleEndpoint.trust:
                StubResponse(headers: ["Set-Cookie": "myacinfo=trusted; Path=/"])
            case AppleEndpoint.downloads:
                StubResponse(headers: ["Set-Cookie": downloadAuthCookie])
            default:
                StubResponse()
            }
        }))
        let authenticator = AppleAuthenticator(olymp: fixture.olymp, logger: fixture.logs.logger())

        try await authenticator.authenticate(username: "user", password: { "secret" })

        #expect(fixture.server.requests.values.compactMap(\.url?.path) == [
            AppleEndpoint.signOut,
            AppleEndpoint.config,
            AppleEndpoint.signIn,
            AppleEndpoint.signInInit,
            AppleEndpoint.signInComplete,
            AppleEndpoint.auth,
            AppleEndpoint.trustedDeviceCode,
            AppleEndpoint.trust,
            AppleEndpoint.session,
            AppleEndpoint.downloads,
        ])
        #expect(fixture.sessionStore.data(for: "user") != nil)
        #expect(Array(fixture.logs.messages.prefix(3)) == [
            "[0/7] Validating existing session",
            "No stored session found.",
            "Signing in again.",
        ])
    }

    @Test
    func `a valid session never asks for the password`() async throws {
        let fixture = OlympUsFixture(storedAssets: ["user": OlympUs.AuthenticationAssets.fixtureData]) { request in
            request.url?.path == AppleEndpoint.downloads
                ? StubResponse(headers: ["Set-Cookie": downloadAuthCookie])
                : StubResponse()
        }
        let authenticator = AppleAuthenticator(olymp: fixture.olymp, logger: fixture.logs.logger())

        try await authenticator.authenticate(username: "user", password: {
            Issue.record("Must not ask for the password")
            return ""
        })
    }

    @Test
    func `a sign in without two factor authentication skips the code`() async throws {
        let fixture = OlympUsFixture(handler: appleServer(
            srp: srp,
            completion: { _, valid in valid ? .json("{}", headers: sessionHeaders) : .json("{}", statusCode: 401) },
            otherwise: { request in
                switch request.url?.path {
                case AppleEndpoint.config:
                    .json(#"{"authServiceKey":"service-key"}"#)
                case AppleEndpoint.downloads:
                    StubResponse(headers: ["Set-Cookie": downloadAuthCookie])
                default:
                    StubResponse()
                }
            }
        ))
        let authenticator = AppleAuthenticator(olymp: fixture.olymp, logger: fixture.logs.logger())

        try await authenticator.authenticate(username: "user", password: { "secret" })

        let paths = fixture.server.requests.values.compactMap(\.url?.path)
        #expect(!paths.contains(AppleEndpoint.auth))
        #expect(!paths.contains(AppleEndpoint.trust))
        #expect(paths.last == AppleEndpoint.downloads)
    }

    @Test
    func `a wrong password fails the authentication`() async throws {
        let fixture = OlympUsFixture(handler: appleServer(srp: srp, otherwise: { request in
            request.url?.path == AppleEndpoint.config ? .json(#"{"authServiceKey":"service-key"}"#) : StubResponse(statusCode: 401)
        }))
        let authenticator = AppleAuthenticator(olymp: fixture.olymp, logger: fixture.logs.logger())

        await #expect(performing: {
            try await authenticator.authenticate(username: "user", password: { "wrong" })
        }, throws: isOlympUsError(.incorrectCredentials))
        #expect(!fixture.server.requests.values.compactMap(\.url?.path).contains(AppleEndpoint.auth))
    }
}

struct SessionCookieTests {
    private let assets = OlympUs.AuthenticationAssets.fixture
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let sessionCookies = [
        "dqsid=host-only; Path=/; Secure",
        "myacinfo=account; Path=/; Domain=.apple.com; Secure; Expires=Wed, 21 Oct 2099 07:28:00 GMT",
        "dslang=US-EN; Path=/; Domain=.apple.com",
        "site=USA; Path=/; Domain=.apple.com",
    ].joined(separator: ", ")

    private func fixture() -> OlympUsFixture {
        OlympUsFixture { [sessionCookies] request in
            request.url?.path == AppleEndpoint.downloads
                ? StubResponse(headers: ["Set-Cookie": downloadAuthCookie])
                : StubResponse(headers: ["Set-Cookie": sessionCookies])
        }
    }

    @Test(arguments: [
        ("myacinfo", ".apple.com", nil, true),
        ("DES58b0eba556d80ed2b98707e15ffafd344", ".apple.com", nil, true),
        ("ADCDownloadAuth", ".apple.com", nil, false),
        ("DSESSIONID", "developer.apple.com", nil, true),
        ("dqsid", "appstoreconnect.apple.com", nil, true),
        ("itctx", ".apple.com", nil, true),
        ("itcdq", ".apple.com", nil, true),
        ("acn01", ".apple.com", nil, true),
        ("aasp", "idmsa.apple.com", nil, true),
        ("dslang", ".apple.com", nil, false),
        ("site", ".apple.com", nil, false),
        ("myacinfo", ".example.com", nil, false),
        ("myacinfo", "notapple.com", nil, false),
        ("myacinfo", ".apple.com", -1, false),
        ("myacinfo", ".apple.com", 3600, true),
    ] as [(String, String, Double?, Bool)])
    func `only the cookies the session needs are kept`(name: String, domain: String, expiresIn: Double?, isKept: Bool) throws {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "1", .domain: domain, .path: "/"]
        if let expiresIn {
            properties[.expires] = now.addingTimeInterval(expiresIn)
        }
        let cookie = try #require(HTTPCookie(properties: properties))

        #expect(cookie.isNeededForSession(at: now) == isKept)
    }

    @Test(arguments: [
        ("site", ".apple.com", nil, "not needed"),
        ("ADCDownloadAuth", ".apple.com", nil, "renewed on every run"),
        ("dqsid", "localhost", nil, "not an Apple domain"),
        ("dqsid", ".apple.com", -1, "expired"),
    ] as [(String, String, Double?, String)])
    func `a dropped cookie names its reason`(name: String, domain: String, expiresIn: Double?, reason: String) throws {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "1", .domain: domain, .path: "/"]
        if let expiresIn {
            properties[.expires] = now.addingTimeInterval(expiresIn)
        }
        let cookie = try #require(HTTPCookie(properties: properties))

        #expect([cookie].droppedList(at: now) == "\(name) on \(domain), \(reason)")
    }

    @Test
    func `only needed cookies are saved and the verbose log lists kept and dropped names`() async throws {
        let fixture = fixture()

        try await fixture.olymp.getOlympusSession(assets: assets, for: "user")
        try await fixture.olymp.getDownloadAuth(assets: assets)

        #expect(fixture.sessionStore.cookieNames(for: "user") == ["dqsid", "myacinfo"])
        #expect(fixture.logs.messages.contains("Keeping cookies: dqsid, myacinfo. Dropping cookies: ADCDownloadAuth on .apple.com, renewed on every run; dslang on .apple.com, not needed; site on .apple.com, not needed."))
    }

    @Test
    func `a host-only cookie from a response is stored once for its own host`() async throws {
        let fixture = fixture()

        try await fixture.olymp.getOlympusSession(assets: assets, for: "user")

        let dqsid = fixture.olymp.session.configuration.httpCookieStorage?.cookies?.filter { $0.name == "dqsid" } ?? []
        #expect(dqsid.map(\.domain) == ["appstoreconnect.apple.com"])
    }

    @Test
    func `restored cookies keep their domain, path, expiry and secure flag`() async throws {
        let first = fixture()
        try await first.olymp.getOlympusSession(assets: assets, for: "user")
        try await first.olymp.getDownloadAuth(assets: assets)
        let saved = try #require(first.sessionStore.data(for: "user"))

        let restarted = OlympUsFixture(storedAssets: ["user": saved]) { _ in StubResponse() }
        _ = await restarted.olymp.storedAuthenticationAssets(for: "user")

        let original = (first.olymp.session.configuration.httpCookieStorage?.cookies ?? []).filter { $0.isNeededForSession(at: now) }
        let restored = restarted.olymp.session.configuration.httpCookieStorage?.cookies ?? []
        let attributes: (HTTPCookie) -> String = { "\($0.name)|\($0.domain)|\($0.path)|\($0.expiresDate?.description ?? "session")|\($0.isSecure)" }
        #expect(Set(restored.map(attributes)) == Set(original.map(attributes)))
        let myacinfo = try #require(restored.first { $0.name == "myacinfo" })
        #expect(myacinfo.domain == ".apple.com")
        #expect(myacinfo.isSecure)
        #expect(myacinfo.expiresDate != nil)
        #expect(restored.map(attributes).contains("dqsid|appstoreconnect.apple.com|/|session|true"))
    }

    @Test
    func `a stored jar with unneeded cookies is saved again without them`() async throws {
        let cookies = try [
            ("myacinfo", "account"), ("ADCDownloadAuth", "token"), ("site", "USA"), ("dslang", "US-EN"),
        ].map { name, value in
            try #require(HTTPCookie(properties: [.domain: ".apple.com", .path: "/", .name: name, .value: value]))
        }
        let fixture = OlympUsFixture(storedAssets: ["user": InMemorySessionStore.session(cookies: cookies)]) { _ in
            StubResponse(headers: ["Set-Cookie": downloadAuthCookie])
        }

        try await fixture.olymp.validateSession(for: "user")
        try await fixture.olymp.getDownloadAuth(assets: assets)

        #expect(fixture.cookieNames == ["ADCDownloadAuth", "myacinfo"])
        #expect(fixture.logs.messages.contains("Dropped 3 stored cookies: ADCDownloadAuth on .apple.com, renewed on every run; dslang on .apple.com, not needed; site on .apple.com, not needed"))
        #expect(fixture.logs.messages.contains("Saving the session because the stored session still had cookies it no longer needs: ADCDownloadAuth, dslang, site."))
        #expect(fixture.sessionStore.saves.values == ["user"])
        #expect(fixture.sessionStore.cookieNames(for: "user") == ["myacinfo"])
    }
}
