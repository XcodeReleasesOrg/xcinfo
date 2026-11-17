//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
import Rainbow
import XCIFoundation

public enum OlympUsError: Error, Sendable {
    case missingSessionKey
    case signInRequestFailed
    case requestAuthentication
    case requestSmsFailed
    case deviceTrustFailed
    case olympusSessionFailed
    case downloadAuthFailed
    case sessionInvalid
}

public enum OlympUsState: CaseIterable, CustomStringConvertible, Sendable {
    case validatingExistingSession
    case requestingServiceKey
    case signingIn
    case requestingAuth
    case sendingSecurityCode
    case requestingTrust
    case gettingSession
    case gettingDownloadAuth

    public var description: String {
        switch self {
        case .validatingExistingSession:
            return "Validating existing session"
        case .requestingServiceKey:
            return "Requesting service key"
        case .signingIn:
            return "Signing in with credentials"
        case .requestingAuth:
            return "Requesting authentication"
        case .sendingSecurityCode:
            return "Sending security code"
        case .requestingTrust:
            return "Requesting trust"
        case .gettingSession:
            return "Requesting download session"
        case .gettingDownloadAuth:
            return "Requesting download auth info"
        }
    }
}

public enum ValidationType: Sendable {
    case securityCode(String)
    case verificationCode(Int, String)
}

private struct SecurityCode: Codable {
    let code: String
}

private struct VerifyPhoneRequest: Codable {
    struct TrustedNumber: Codable {
        let id: Int
    }

    let phoneNumber: VerifyPhoneRequest.TrustedNumber
    var mode = "sms"
    var securityCode: SecurityCode? = nil
}

private struct VerifyTrustedDeviceRequest: Codable {
    let securityCode: SecurityCode
}

extension ValidationType {
    var verificationURL: URL {
        switch self {
        case .securityCode:
            return URL(string: "https://idmsa.apple.com/appleauth/auth/verify/trusteddevice/securitycode")!
        case .verificationCode:
            return URL(string: "https://idmsa.apple.com/appleauth/auth/verify/phone/securitycode")!
        }
    }

    var body: Data {
        switch self {
        case let .securityCode(code):
            let body = VerifyTrustedDeviceRequest(securityCode: SecurityCode(code: code))
            return try! JSONEncoder().encode(body)
        case let .verificationCode(phoneId, code):
            let body = VerifyPhoneRequest(
                phoneNumber: VerifyPhoneRequest.TrustedNumber(id: phoneId),
                securityCode: SecurityCode(code: code)
            )
            return try! JSONEncoder().encode(body)
        }
    }
}

extension OlympUs.AuthenticationAssets: Codable {}

public struct AuthenticationSessionStore: Sendable {
    public var load: @Sendable (_ account: String) throws -> Data
    public var save: @Sendable (_ data: Data, _ account: String) throws -> Void
    public var removeAll: @Sendable () throws -> Int

    public init(
        load: @escaping @Sendable (String) throws -> Data,
        save: @escaping @Sendable (Data, String) throws -> Void,
        removeAll: @escaping @Sendable () throws -> Int
    ) {
        self.load = load
        self.save = save
        self.removeAll = removeAll
    }
}

public extension AuthenticationSessionStore {
    static let keychain = AuthenticationSessionStore(
        load: { account in
            try KeychainPasswordItem(service: "xcinfo.session", account: account).readData()
        },
        save: { data, account in
            try KeychainPasswordItem(service: "xcinfo.session", account: account).saveData(data, overwriteExisting: true)
        },
        removeAll: {
            let items = try KeychainPasswordItem.passwordItems(forService: "xcinfo.session")
            for item in items {
                try item.deleteItem()
            }
            return items.count
        }
    )
}

public actor OlympUs {
    private let logger: Logger

    public private(set) var state: OlympUsState? {
        didSet {
            displayState()
        }
    }

    public nonisolated let session: URLSession
    private nonisolated(unsafe) let userDefaults: UserDefaults // UserDefaults is documented as thread-safe but not annotated Sendable.
    private nonisolated let sessionStore: AuthenticationSessionStore
    private nonisolated let prompt: PromptClient

    public init(
        logger: Logger,
        session: URLSession,
        userDefaults: UserDefaults = .standard,
        sessionStore: AuthenticationSessionStore = .keychain,
        prompt: PromptClient = .live
    ) {
        self.logger = logger
        self.session = session
        self.userDefaults = userDefaults
        self.sessionStore = sessionStore
        self.prompt = prompt
        restoreCookies()
    }

    private func displayState() {
        guard let state, let index = OlympUsState.allCases.firstIndex(of: state) else { return }
        let message = "[\(index)/\(OlympUsState.allCases.count - 1)] \(state.description)"
        logger.log(message)
    }

    // MARK: - Step 0: request a service key a.k.a. widget key -

    struct ServiceKeyResponse: Codable {
        var authServiceKey: String
    }

    public nonisolated func storedAuthenticationAssets(for account: String) -> AuthenticationAssets? {
        do {
            let codedAssets = try sessionStore.load(account)
            return try JSONDecoder().decode(AuthenticationAssets.self, from: codedAssets)
        } catch {
            return nil
        }
    }

    @discardableResult
    private func storeAuthenticationAssets(assets: AuthenticationAssets, for account: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(assets)
            try sessionStore.save(data, account)
            return true
        } catch {
            return false
        }
    }

    public func validateSession(for account: String) async throws {
        state = .validatingExistingSession
        guard let assets = storedAuthenticationAssets(for: account) else {
            throw OlympUsError.sessionInvalid
        }
        do {
            try await getOlympusSession(assets: assets, for: account)
        } catch {
            logger.verbose("Session invalid. Starting authentication.")
            throw OlympUsError.sessionInvalid
        }
        logger.verbose("Reusing valid session.")
    }

    private let sessionKeyURL = URL(string: "https://appstoreconnect.apple.com/olympus/v1/app/config")!
    public func getServiceKey(for account: String) async throws -> String {
        state = .requestingServiceKey
        if let serviceKey = storedAuthenticationAssets(for: account)?.serviceKey {
            return serviceKey
        }
        var components = URLComponents(url: sessionKeyURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "hostname", value: "itunesconnect.apple.com")]
        do {
            let (data, _) = try await session.data(from: components.url!)
            return try JSONDecoder().decode(ServiceKeyResponse.self, from: data).authServiceKey
        } catch {
            throw OlympUsError.missingSessionKey
        }
    }

    // MARK: - Step 1: sign in -

    struct SignInRequest: Codable {
        var accountName: String
        var password: String
        var rememberMe = true
    }

    struct SignInResponse: Codable {
        var authType: String
    }

    private let signInURL = URL(string: "https://idmsa.apple.com/appleauth/auth/signin")!

    public struct AuthenticationAssets: Sendable {
        var serviceKey: String?
        var scnt: String?
        var asid: String?
        var authenticationType: String?
    }

    public func signIn(
        accountName: String,
        password: String,
        serviceKey: String
    ) async throws -> AuthenticationAssets {
        state = .signingIn
        session.configuration.httpCookieStorage?.removeCookies(since: Date(timeIntervalSinceReferenceDate: 0))

        var request = URLRequest(url: signInURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("X-Requested-With", forHTTPHeaderField: "X-Requested-With")
        request.addValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
        request.addValue(serviceKey, forHTTPHeaderField: "X-Apple-Widget-Key")

        let body = SignInRequest(accountName: accountName, password: password)
        request.httpBody = try? JSONEncoder().encode(body)

        var authenticationAssets = AuthenticationAssets(serviceKey: serviceKey)
        do {
            let (data, response) = try await session.data(for: request)
            if
                let httpResponse = response as? HTTPURLResponse,
                let scnt = httpResponse.allHeaderFields["scnt"] as? String,
                let asid = httpResponse.allHeaderFields["X-Apple-ID-Session-Id"] as? String
            {
                authenticationAssets.asid = asid
                authenticationAssets.scnt = scnt
            }
            let signInResponse = try JSONDecoder().decode(SignInResponse.self, from: data)
            authenticationAssets.authenticationType = signInResponse.authType
            return authenticationAssets
        } catch {
            throw OlympUsError.signInRequestFailed
        }
    }

    // MARK: - Step 2: request auth -

    private let authURL = URL(string: "https://idmsa.apple.com/appleauth/auth")!
    private let verifyPhoneURL = URL(string: "https://idmsa.apple.com/appleauth/auth/verify/phone")!
    public struct TrustedNumber: Codable, Sendable {
        let numberWithDialCode: String
        let pushMode: String
        let obfuscatedNumber: String
        let id: Int
    }

    public struct CodeDescription: Codable, Sendable {
        let length: Int
        let tooManyCodesSent: Bool
        let tooManyCodesValidated: Bool
        let securityCodeLocked: Bool
    }

    private struct RequestAuthResponse: Codable {
        let trustedPhoneNumbers: [TrustedNumber]
        let securityCode: CodeDescription
    }

    enum HttpMethod: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
    }

    public func requestAuthentication(assets: AuthenticationAssets) async throws -> ValidationType {
        state = .requestingAuth
        let response: RequestAuthResponse
        do {
            let (data, _) = try await session.data(for: request(forURL: authURL, assets: assets, method: .post))
            response = try JSONDecoder().decode(RequestAuthResponse.self, from: data)
        } catch {
            throw OlympUsError.requestAuthentication
        }

        let requiredCodeLength = response.securityCode.length
        logger.log("\nTwo-factor authentication is enabled for your account.")
        logger
            .log(
                "Please enter a \(requiredCodeLength) digit verification code generated on one of your trusted devices."
            )
        logger.log("Type '\("sms".magenta)' to receive a verification code on a trusted phone number.")
        let input = prompt.ask("Apple ID Verification Code: ", "Invalide code length") { value in
            value != "sms" && requiredCodeLength != value.count
        }
        switch input {
        case "sms":
            let phoneIndex = prompt.choose(
                "Please choose your trusted device: ",
                response.trustedPhoneNumbers.map(\.numberWithDialCode)
            )
            let phoneId = response.trustedPhoneNumbers[phoneIndex].id
            var request = request(forURL: verifyPhoneURL, assets: assets, method: .put)
            let body = VerifyPhoneRequest(phoneNumber: VerifyPhoneRequest.TrustedNumber(id: phoneId))
            request.httpBody = try? JSONEncoder().encode(body)

            do {
                _ = try await session.data(for: request)
            } catch {
                throw OlympUsError.requestSmsFailed
            }
            let smsCode = prompt.ask(
                "Please enter the received verification code:",
                "Invalid code length"
            ) { value in
                requiredCodeLength != value.count
            }
            logger.log("\n")
            return .verificationCode(phoneId, smsCode)
        default:
            logger.log("\n")
            return .securityCode(input)
        }
    }

//    MARK: - send security code -

    @discardableResult
    public func sendSecurityCode(
        validationType: ValidationType,
        assets: AuthenticationAssets
    ) async throws -> Int {
        state = .sendingSecurityCode
        var request = request(forURL: validationType.verificationURL, assets: assets, method: .post)
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = validationType.body
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw OlympUsError.deviceTrustFailed
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OlympUsError.deviceTrustFailed
        }
        return httpResponse.statusCode
    }

//    MARK: - requesting trust -

    private let trustURL = URL(string: "https://idmsa.apple.com/appleauth/auth/2sv/trust")!

    @discardableResult
    public func requestTrust(assets: AuthenticationAssets) async throws -> [HTTPCookie] {
        state = .requestingTrust
        let request = request(forURL: trustURL, assets: assets, method: .get)
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw OlympUsError.deviceTrustFailed
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OlympUsError.deviceTrustFailed
        }
        return HTTPCookie.cookies(
            withResponseHeaderFields: httpResponse.allHeaderFields as! [String: String],
            for: trustURL
        )
    }

//    MARK: - get session from Olympus -

    private let olympusSessionURL = URL(string: "https://appstoreconnect.apple.com/olympus/v1/session")!
    public func getOlympusSession(assets: AuthenticationAssets, for account: String) async throws {
        state = .gettingSession
        let request = request(forURL: olympusSessionURL, assets: assets, method: .get)
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw OlympUsError.olympusSessionFailed
        }
        guard handle(response: response) else {
            throw OlympUsError.olympusSessionFailed
        }
        storeAuthenticationAssets(assets: assets, for: account)
    }

    private func handle(response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            return false
        }

        let allHeaderFields = response.allHeaderFields

        guard let originalCookies = allHeaderFields["Set-Cookie"] as? String else {
            return true
        }

        let regex = try! NSRegularExpression(pattern: #"(?<!Expires=\w{3}),"#, options: [])
        var cookieDict: [String: String] = [:]
        var startIndex = originalCookies.startIndex
        regex.enumerateMatches(
            in: originalCookies,
            options: [],
            range: NSRange(originalCookies.startIndex..., in: originalCookies)
        ) { result, _, _ in
            guard let nsrange = result?.range,
                  let range = Range<String.Index>(nsrange, in: originalCookies) else { return }
            let match = originalCookies[startIndex ..< range.lowerBound]
            startIndex = range.upperBound
            let keyValuePair = match.split(separator: "=")
            let key = String(keyValuePair[0]).trimmingCharacters(in: .whitespaces)
            cookieDict[key] = String(keyValuePair.dropFirst().joined(separator: "="))
        }

        let lastMatch = originalCookies[startIndex...]
        let keyValuePair = lastMatch.split(separator: "=")
        let key = String(keyValuePair[0]).trimmingCharacters(in: .whitespaces)
        cookieDict[key] = String(keyValuePair.dropFirst().joined(separator: "="))

        let appleURL = URL(string: "apple.com")!
        let cookies = cookieDict
            .flatMap {
                HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "\($0.key)=\($0.value)"], for: appleURL)
            }

        cookies.forEach {
            session.configuration.httpCookieStorage?.setCookie($0)
        }

        storeCookies()
        return true
    }

    private let downloadAuthURL =
        URL(string: "https://developer.apple.com/services-account/QH65B2/downloadws/listDownloads.action")!
    public func getDownloadAuth(assets: AuthenticationAssets) async throws {
        state = .gettingDownloadAuth
        let request = request(forURL: downloadAuthURL, assets: assets, method: .post)
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw OlympUsError.downloadAuthFailed
        }
        guard
            handle(response: response),
            session.configuration.httpCookieStorage?.cookies?
            .contains(where: { $0.name == "ADCDownloadAuth" }) == true
        else {
            throw OlympUsError.downloadAuthFailed
        }
    }

    public nonisolated func cleanup() {
        removeDownloadSessionInfo()
        removeCookies()
    }

    private nonisolated func removeDownloadSessionInfo() {
        do {
            if try sessionStore.removeAll() > 0 {
                logger.success("Deleted Apple developer portal session info from keychain.")
            } else {
                logger.log("No Apple developer portal session info was stored.")
            }
        } catch {
            logger
                .error(
                    "Error deleting Keychain entries. Please open Keychain Access.app and remove items named 'xcinfo.session'."
                )
        }
    }

//    MARK: - Helpers -

    private func request(forURL url: URL, assets: AuthenticationAssets, method: HttpMethod = .get) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.addValue(assets.serviceKey!, forHTTPHeaderField: "X-Apple-Widget-Key")
        request.addValue(assets.scnt!, forHTTPHeaderField: "scnt")
        request.addValue(assets.asid!, forHTTPHeaderField: "X-Apple-ID-Session-Id")
        if [HttpMethod.post, .put].contains(method) {
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("application/json", forHTTPHeaderField: "Accept")
        }
        return request
    }
}

//    MARK: - Cookies -

extension OlympUs {
    private func storeCookies() {
        guard let cookies = session.configuration.httpCookieStorage?.cookies else { return }

        let cookiesArray = cookies.compactMap { $0.properties }
        userDefaults.set(cookiesArray, forKey: "cookies")
    }

    private nonisolated func restoreCookies() {
        guard let cookieStorage = session.configuration.httpCookieStorage else { return }


        if let cookies = userDefaults.array(forKey: "cookies") as? [[HTTPCookiePropertyKey: Any]] {
            for cookieProperties in cookies {
                if let cookie = HTTPCookie(properties: cookieProperties) {
                    cookieStorage.setCookie(cookie)
                }
            }
        }
    }

    private nonisolated func removeCookies() {
        userDefaults.removeObject(forKey: "cookies")
    }
}
