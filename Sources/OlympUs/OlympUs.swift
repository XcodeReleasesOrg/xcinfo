//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
import XCIFoundation

public enum OlympUsError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingSessionKey
    case signInRequestFailed
    case incorrectCredentials
    case accountLocked
    case privacyAcknowledgementRequired
    case requestAuthentication
    case verificationCodeLocked
    case requestSmsFailed
    case incorrectVerificationCode
    case deviceTrustFailed
    case olympusSessionFailed
    case downloadAuthFailed
    case sessionInvalid

    public var description: String {
        switch self {
        case .missingSessionKey:
            "Apple's sign-in configuration could not be loaded."
        case .signInRequestFailed:
            "Signing in to Apple failed."
        case .incorrectCredentials:
            """
            Apple rejected the password for this Apple ID.
            Use the password of your Apple ID, not your Mac password.
            Repeated failed sign-ins can lock your Apple ID, so check the password before trying again.
            """
        case .accountLocked:
            "This Apple ID is locked. Unlock it at iforgot.apple.com."
        case .privacyAcknowledgementRequired:
            "Apple needs you to accept new terms. Sign in at appleid.apple.com once, then try again."
        case .requestAuthentication:
            "Two-factor authentication could not be started."
        case .verificationCodeLocked:
            "Too many verification codes were entered. Try again later."
        case .requestSmsFailed:
            "The verification code could not be sent by SMS."
        case .incorrectVerificationCode:
            "The verification code is incorrect."
        case .deviceTrustFailed:
            "The verification code could not be checked."
        case .olympusSessionFailed:
            "Apple did not create a session."
        case .downloadAuthFailed:
            "Apple did not authorize downloads for this account."
        case .sessionInvalid:
            "The stored session is no longer valid."
        }
    }
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
            "Validating existing session"
        case .requestingServiceKey:
            "Requesting service key"
        case .signingIn:
            "Signing in with credentials"
        case .requestingAuth:
            "Requesting authentication"
        case .sendingSecurityCode:
            "Sending security code"
        case .requestingTrust:
            "Requesting trust"
        case .gettingSession:
            "Requesting download session"
        case .gettingDownloadAuth:
            "Requesting download auth info"
        }
    }
}

public enum ValidationType: Sendable, Equatable {
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
            URL(string: "https://idmsa.apple.com/appleauth/auth/verify/trusteddevice/securitycode")!
        case .verificationCode:
            URL(string: "https://idmsa.apple.com/appleauth/auth/verify/phone/securitycode")!
        }
    }

    var body: Data {
        switch self {
        case let .securityCode(code):
            try! JSONEncoder().encode(VerifyTrustedDeviceRequest(securityCode: SecurityCode(code: code)))
        case let .verificationCode(phoneId, code):
            try! JSONEncoder().encode(VerifyPhoneRequest(
                phoneNumber: VerifyPhoneRequest.TrustedNumber(id: phoneId),
                securityCode: SecurityCode(code: code)
            ))
        }
    }
}

extension OlympUs.AuthenticationAssets: Codable {}

public struct AuthenticationSessionStore: Sendable {
    public var load: @Sendable (_ account: String) async throws -> Data?
    public var save: @Sendable (_ data: Data, _ account: String) async throws -> Void
    public var removeAll: @Sendable () async throws -> Int
    public var loadLegacyCookies: @Sendable () async -> Data?
    public var removeLegacyCookies: @Sendable () async -> Void

    public init(
        load: @escaping @Sendable (String) async throws -> Data?,
        save: @escaping @Sendable (Data, String) async throws -> Void,
        removeAll: @escaping @Sendable () async throws -> Int,
        loadLegacyCookies: @escaping @Sendable () async -> Data? = { nil },
        removeLegacyCookies: @escaping @Sendable () async -> Void = {}
    ) {
        self.load = load
        self.save = save
        self.removeAll = removeAll
        self.loadLegacyCookies = loadLegacyCookies
        self.removeLegacyCookies = removeLegacyCookies
    }
}

struct StoredSession: Codable, Equatable {
    var assets: OlympUs.AuthenticationAssets
    var cookies: Data?
}

public struct SignInResult: Sendable, Equatable {
    public var assets: OlympUs.AuthenticationAssets
    public var requiresTwoFactorAuthentication: Bool
}

public actor OlympUs {
    private let logger: Logger

    public private(set) var state: OlympUsState? {
        didSet {
            displayState()
        }
    }

    public nonisolated let session: URLSession
    private nonisolated let sessionStore: AuthenticationSessionStore
    private nonisolated let prompt: PromptClient
    private let srpGroup: SRPGroup
    private let now: @Sendable () -> Date

    public init(
        logger: Logger,
        session: URLSession,
        sessionStore: AuthenticationSessionStore,
        prompt: PromptClient = .live,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.logger = logger
        self.session = session
        self.sessionStore = sessionStore
        self.prompt = prompt
        self.now = now
        srpGroup = .rfc5054_2048
    }

    private var loadedAccount: String?
    private var loadedAssets: AuthenticationAssets?
    private var savedSession: SavedSessionKey?
    private var hasWarnedAboutSaving = false
    private var hasLegacyCookies = false

    private func displayState() {
        guard let state, let index = OlympUsState.allCases.firstIndex(of: state) else { return }
        logger.log("[\(index)/\(OlympUsState.allCases.count - 1)] \(state.description)")
    }

    // MARK: - Stored session -

    struct ServiceKeyResponse: Codable {
        var authServiceKey: String
    }

    public func storedAuthenticationAssets(for account: String) async -> AuthenticationAssets? {
        if loadedAccount == account {
            return loadedAssets
        }
        loadedAccount = account
        loadedAssets = nil
        savedSession = nil

        let data: Data?
        do {
            data = try await sessionStore.load(account)
        } catch {
            logger.warn("Could not read the stored Apple session from the Keychain (\(error)). Allow xcinfo to access the Keychain to avoid signing in again.")
            return nil
        }

        guard let data else {
            logger.verbose("No stored session found.")
            restoreCookies(from: await sessionStore.loadLegacyCookies())
            return nil
        }
        if let stored = try? JSONDecoder().decode(StoredSession.self, from: data) {
            logger.verbose("Stored session found.")
            let droppedCookies = restoreCookies(from: stored.cookies)
            loadedAssets = stored.assets
            savedSession = droppedCookies ? nil : SavedSessionKey(assets: stored.assets, cookies: cookieKeys)
        } else if let legacyAssets = try? JSONDecoder().decode(AuthenticationAssets.self, from: data) {
            logger.verbose("Stored session found in the old format. It is saved in the new format after the next sign-in step.")
            restoreCookies(from: await sessionStore.loadLegacyCookies())
            loadedAssets = legacyAssets
            hasLegacyCookies = true
        } else {
            logger.verbose("The stored session could not be read and is ignored.")
        }
        return loadedAssets
    }

    @discardableResult
    private func persistSession(assets: AuthenticationAssets) async -> Bool {
        guard let account = loadedAccount else { return false }
        loadedAssets = assets
        let key = SavedSessionKey(assets: assets, cookies: cookieKeys)
        guard key != savedSession, let data = try? JSONEncoder().encode(StoredSession(assets: assets, cookies: cookieData())) else { return true }
        if hasLegacyCookies {
            await sessionStore.removeLegacyCookies()
            hasLegacyCookies = false
        }
        do {
            try await sessionStore.save(data, account)
            savedSession = key
            logger.verbose("Saved the session with \(sessionCookies.count) cookies.")
            return true
        } catch {
            if !hasWarnedAboutSaving {
                hasWarnedAboutSaving = true
                logger.warn("Could not save the Apple session in the Keychain (\(error)). The next sign-in will ask for two-factor authentication again.")
            }
            return false
        }
    }

    public func validateSession(for account: String) async throws {
        state = .validatingExistingSession
        guard let assets = await storedAuthenticationAssets(for: account) else {
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

    // MARK: - Step 0: service key and hashcash -

    private let sessionKeyURL = URL(string: "https://appstoreconnect.apple.com/olympus/v1/app/config")!
    public func getServiceKey(for account: String) async throws -> String {
        _ = await storedAuthenticationAssets(for: account)
        state = .requestingServiceKey
        if let serviceKey = await storedAuthenticationAssets(for: account)?.serviceKey {
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

    private let signInURL = URL(string: "https://idmsa.apple.com/appleauth/auth/signin")!

    func hashcash(serviceKey: String) async -> String? {
        var components = URLComponents(url: signInURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "widgetKey", value: serviceKey)]
        guard
            let (_, response) = try? await session.data(from: components.url!),
            let response = response as? HTTPURLResponse,
            let bitsValue = response.value(forHTTPHeaderField: "X-Apple-HC-Bits"),
            let bits = Int(bitsValue),
            let challenge = response.value(forHTTPHeaderField: "X-Apple-HC-Challenge")
        else {
            logger.verbose("No hashcash challenge received.")
            return nil
        }
        return Hashcash(bits: bits, challenge: challenge).stamp(date: now())
    }

    // MARK: - Step 1: sign in with SRP -

    public struct AuthenticationAssets: Sendable, Equatable {
        var serviceKey: String?
        var scnt: String?
        var asid: String?
        var authenticationType: String?
    }

    private struct SignInInitRequest: Encodable {
        let a: String
        let accountName: String
        let protocols = ["s2k", "s2k_fo"]
    }

    private struct SignInInitResponse: Decodable {
        let iteration: Int
        let salt: String
        let `protocol`: PasswordProtocol
        let b: String
        let c: String
    }

    private struct SignInCompleteRequest: Encodable {
        let accountName: String
        let c: String
        let m1: String
        let m2: String
        let rememberMe = false
    }

    private struct SignInCompleteResponse: Decodable {
        let authType: String?
    }

    public func signIn(
        accountName: String,
        password: String,
        serviceKey: String,
        privateKey: [UInt8]? = nil
    ) async throws -> SignInResult {
        _ = await storedAuthenticationAssets(for: accountName)
        removeCookiesExceptTrust()
        let hashcash = await hashcash(serviceKey: serviceKey)
        state = .signingIn

        let client = SRPClient(group: srpGroup, hash: .sha256, privateKey: privateKey.map { BigUInt(bigEndian: $0) })

        let initResponse: SignInInitResponse
        do {
            var request = signInRequest(url: signInURL.appendingPathComponent("init"), serviceKey: serviceKey, hashcash: nil)
            request.httpBody = try JSONEncoder().encode(SignInInitRequest(
                a: Data(client.publicKey.bytes()).base64EncodedString(),
                accountName: accountName
            ))
            let (data, response) = try await session.data(for: request)
            logResponse(request, response, data)
            try Self.checkSignInStatus(response)
            initResponse = try JSONDecoder().decode(SignInInitResponse.self, from: data)
            logger.verbose("Password protocol \(initResponse.protocol.rawValue), \(initResponse.iteration) iterations")
        } catch let error as OlympUsError {
            throw error
        } catch {
            throw OlympUsError.signInRequestFailed
        }

        guard
            let salt = Data(base64Encoded: initResponse.salt),
            let serverPublicKey = Data(base64Encoded: initResponse.b)
        else {
            throw OlympUsError.signInRequestFailed
        }
        let passwordKey = derivedPasswordKey(
            password: password,
            salt: Array(salt),
            iterations: initResponse.iteration,
            protocol: initResponse.protocol
        )
        let proof: SRPProof
        do {
            proof = try client.proof(
                accountName: accountName,
                passwordIdentity: "",
                password: passwordKey,
                salt: Array(salt),
                serverPublicKey: BigUInt(bigEndian: serverPublicKey)
            )
        } catch {
            throw OlympUsError.signInRequestFailed
        }

        var completeURL = URLComponents(url: signInURL.appendingPathComponent("complete"), resolvingAgainstBaseURL: false)!
        completeURL.queryItems = [URLQueryItem(name: "isRememberMeEnabled", value: "false")]
        var request = signInRequest(url: completeURL.url!, serviceKey: serviceKey, hashcash: hashcash)
        request.httpBody = try? JSONEncoder().encode(SignInCompleteRequest(
            accountName: accountName,
            c: initResponse.c,
            m1: Data(proof.clientProof).base64EncodedString(),
            m2: Data(proof.expectedServerProof).base64EncodedString()
        ))

        let data: Data
        let response: HTTPURLResponse
        do {
            let (responseData, urlResponse) = try await session.data(for: request)
            logResponse(request, urlResponse, responseData)
            guard let httpResponse = urlResponse as? HTTPURLResponse else { throw OlympUsError.signInRequestFailed }
            data = responseData
            response = httpResponse
        } catch {
            throw OlympUsError.signInRequestFailed
        }

        let requiresTwoFactorAuthentication: Bool
        switch response.statusCode {
        case 200 ..< 300:
            requiresTwoFactorAuthentication = false
        case 409:
            requiresTwoFactorAuthentication = true
        default:
            try Self.checkSignInStatus(response)
            throw OlympUsError.signInRequestFailed
        }

        let assets = AuthenticationAssets(
            serviceKey: serviceKey,
            scnt: response.value(forHTTPHeaderField: "scnt"),
            asid: response.value(forHTTPHeaderField: "X-Apple-ID-Session-Id"),
            authenticationType: (try? JSONDecoder().decode(SignInCompleteResponse.self, from: data))?.authType
        )
        return SignInResult(assets: assets, requiresTwoFactorAuthentication: requiresTwoFactorAuthentication)
    }

    private func signInRequest(url: URL, serviceKey: String, hashcash: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
        request.addValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.addValue(serviceKey, forHTTPHeaderField: "X-Apple-Widget-Key")
        if let hashcash {
            request.addValue(hashcash, forHTTPHeaderField: "X-Apple-HC")
        }
        return request
    }

    private struct ServiceErrors: Decodable {
        struct ServiceError: Decodable {
            let code: String?
            let message: String?
        }

        let serviceErrors: [ServiceError]?
    }

    private func logResponse(_ request: URLRequest, _ response: URLResponse, _ data: Data) {
        let status = (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "no HTTP response"
        logger.verbose("\(request.httpMethod ?? "GET") \(request.url?.path ?? ""): \(status)")
        let errors = (try? JSONDecoder().decode(ServiceErrors.self, from: data))?.serviceErrors ?? []
        for error in errors {
            logger.verbose("Apple: \([error.code, error.message].compactMap { $0 }.joined(separator: " "))")
        }
    }

    private static func checkSignInStatus(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw OlympUsError.signInRequestFailed }
        switch response.statusCode {
        case 200 ..< 300:
            return
        case 401:
            throw OlympUsError.incorrectCredentials
        case 403:
            throw OlympUsError.accountLocked
        case 412:
            throw OlympUsError.privacyAcknowledgementRequired
        default:
            throw OlympUsError.signInRequestFailed
        }
    }

    // MARK: - Step 2: two-factor authentication -

    private let authURL = URL(string: "https://idmsa.apple.com/appleauth/auth")!
    private let verifyPhoneURL = URL(string: "https://idmsa.apple.com/appleauth/auth/verify/phone")!
    public struct TrustedNumber: Codable, Sendable {
        let numberWithDialCode: String
        let pushMode: String?
        let obfuscatedNumber: String?
        let id: Int
    }

    public struct CodeDescription: Codable, Sendable {
        let length: Int
        let tooManyCodesSent: Bool?
        let tooManyCodesValidated: Bool?
        let securityCodeLocked: Bool?
    }

    private struct RequestAuthResponse: Codable {
        let trustedPhoneNumbers: [TrustedNumber]?
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
            let (data, _) = try await session.data(for: request(forURL: authURL, assets: assets, method: .get))
            response = try JSONDecoder().decode(RequestAuthResponse.self, from: data)
        } catch {
            throw OlympUsError.requestAuthentication
        }
        if response.securityCode.securityCodeLocked == true || response.securityCode.tooManyCodesValidated == true {
            throw OlympUsError.verificationCodeLocked
        }

        let requiredCodeLength = response.securityCode.length
        let trustedPhoneNumbers = response.trustedPhoneNumbers ?? []
        logger.log("Two-factor authentication is enabled for your Apple ID.")
        logger.log("Enter the \(requiredCodeLength) digit verification code that Apple shows on one of your trusted Apple devices.")
        if !trustedPhoneNumbers.isEmpty {
            logger.log("Type 'sms' to get the code by text message on a trusted phone number instead.")
        }
        let input = prompt.ask("Apple ID verification code: ", "Enter \(requiredCodeLength) digits") { value in
            !(value == "sms" && !trustedPhoneNumbers.isEmpty) && requiredCodeLength != value.count
        }
        guard input == "sms" else {
            return .securityCode(input)
        }

        let phoneIndex = prompt.choose(
            "Choose the trusted phone number for the text message: ",
            trustedPhoneNumbers.map(\.numberWithDialCode)
        )
        let phoneId = trustedPhoneNumbers[phoneIndex].id
        var request = request(forURL: verifyPhoneURL, assets: assets, method: .put)
        request.httpBody = try? JSONEncoder().encode(VerifyPhoneRequest(phoneNumber: VerifyPhoneRequest.TrustedNumber(id: phoneId)))

        do {
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode) else {
                throw OlympUsError.requestSmsFailed
            }
        } catch {
            throw OlympUsError.requestSmsFailed
        }
        let smsCode = prompt.ask(
            "Verification code from the text message: ",
            "Enter \(requiredCodeLength) digits"
        ) { value in
            requiredCodeLength != value.count
        }
        return .verificationCode(phoneId, smsCode)
    }

    @discardableResult
    public func sendSecurityCode(
        validationType: ValidationType,
        assets: AuthenticationAssets
    ) async throws -> Int {
        state = .sendingSecurityCode
        var request = request(forURL: validationType.verificationURL, assets: assets, method: .post)
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
        switch httpResponse.statusCode {
        case 200 ..< 300:
            return httpResponse.statusCode
        case 400, 401:
            throw OlympUsError.incorrectVerificationCode
        case 412:
            throw OlympUsError.privacyAcknowledgementRequired
        default:
            throw OlympUsError.deviceTrustFailed
        }
    }

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
        guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
            throw OlympUsError.deviceTrustFailed
        }
        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { headers, field in
            if let key = field.key as? String, let value = field.value as? String {
                headers[key] = value
            }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: headers, for: trustURL)
    }

    // MARK: - Step 3: session and download authorization -

    private let olympusSessionURL = URL(string: "https://appstoreconnect.apple.com/olympus/v1/session")!
    public func getOlympusSession(assets: AuthenticationAssets, for account: String) async throws {
        if loadedAccount != account {
            _ = await storedAuthenticationAssets(for: account)
        }
        state = .gettingSession
        let request = request(forURL: olympusSessionURL, assets: assets, method: .get)
        let response: URLResponse
        do {
            let (data, urlResponse) = try await session.data(for: request)
            logResponse(request, urlResponse, data)
            response = urlResponse
        } catch {
            throw OlympUsError.olympusSessionFailed
        }
        guard handle(response: response) else {
            throw OlympUsError.olympusSessionFailed
        }
        loadedAssets = assets
    }

    private func handle(response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            return false
        }
        if let url = response.url {
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { headers, field in
                if let key = field.key as? String, let value = field.value as? String {
                    headers[key] = value
                }
            }
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
            session.configuration.httpCookieStorage?.setCookies(cookies, for: url, mainDocumentURL: nil)
        }
        return true
    }

    private let downloadAuthURL =
        URL(string: "https://developer.apple.com/services-account/QH65B2/downloadws/listDownloads.action")!
    public func getDownloadAuth(assets: AuthenticationAssets) async throws {
        state = .gettingDownloadAuth
        let request = request(forURL: downloadAuthURL, assets: assets, method: .post)
        let response: URLResponse
        do {
            let (data, urlResponse) = try await session.data(for: request)
            logResponse(request, urlResponse, data)
            response = urlResponse
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
        await persistSession(assets: assets)
    }

    public func cleanup() async {
        do {
            await sessionStore.removeLegacyCookies()
            if try await sessionStore.removeAll() > 0 {
                logger.success("Deleted Apple developer portal session info from keychain.")
            } else {
                logger.log("No Apple developer portal session info was stored.")
            }
        } catch {
            logger
                .error(
                    "Error deleting Keychain entries. Please open Keychain Access.app and remove the item named 'xcinfo'."
                )
        }
    }

    private func request(forURL url: URL, assets: AuthenticationAssets, method: HttpMethod = .get) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.addValue(assets.serviceKey ?? "", forHTTPHeaderField: "X-Apple-Widget-Key")
        request.addValue(assets.scnt ?? "", forHTTPHeaderField: "scnt")
        request.addValue(assets.asid ?? "", forHTTPHeaderField: "X-Apple-ID-Session-Id")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if [HttpMethod.post, .put].contains(method) {
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

struct SavedSessionKey: Equatable {
    var assets: OlympUs.AuthenticationAssets
    var cookies: Set<String>
}

extension OlympUs {
    private var cookieKeys: Set<String> {
        Set(sessionCookies.map { "\($0.domain)|\($0.path)|\($0.name)|\($0.value)" })
    }

    private var sessionCookies: [HTTPCookie] {
        let date = now()
        return (session.configuration.httpCookieStorage?.cookies ?? []).filter { $0.isNeededForSession(at: date) }
    }

    private func removeCookiesExceptTrust() {
        guard let storage = session.configuration.httpCookieStorage else { return }
        let stale = (storage.cookies ?? []).filter { !$0.name.hasPrefix("DES") }
        stale.forEach(storage.deleteCookie)
        logger.verbose("Kept \((storage.cookies ?? []).count) trusted-browser cookies for the sign-in, removed \(stale.count) others.")
    }

    private func cookieData() -> Data? {
        let date = now()
        let allCookies = session.configuration.httpCookieStorage?.cookies ?? []
        let cookies = allCookies.filter { $0.isNeededForSession(at: date) }
        let dropped = allCookies.filter { !$0.isNeededForSession(at: date) }
        logger.verbose("Keeping cookies: \(cookies.nameList). Dropping cookies: \(dropped.nameList).")
        guard !cookies.isEmpty else { return nil }
        let properties = cookies.compactMap { cookie in
            cookie.properties.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
        }
        return try? PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
    }

    @discardableResult
    private func restoreCookies(from data: Data?) -> Bool {
        guard
            let cookieStorage = session.configuration.httpCookieStorage,
            let data,
            let cookies = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return false }

        let date = now()
        var restored: [HTTPCookie] = []
        var dropped: [HTTPCookie] = []
        for cookieProperties in cookies {
            let properties = Dictionary(uniqueKeysWithValues: cookieProperties.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            guard let cookie = HTTPCookie(properties: properties) else { continue }
            if cookie.isNeededForSession(at: date) {
                cookieStorage.setCookie(cookie)
                restored.append(cookie)
            } else {
                dropped.append(cookie)
            }
        }
        logger.verbose("Restored \(restored.count) cookies: \(restored.nameList)")
        if !dropped.isEmpty {
            logger.verbose("Dropped \(dropped.count) stored cookies: \(dropped.nameList)")
        }
        return !dropped.isEmpty
    }
}

extension HTTPCookie {
    static let sessionCookieNames: Set<String> = [
        "ADCDownloadAuth", "DSESSIONID", "aasp", "acn01", "dqsid", "itcdq", "itctx", "myacinfo",
    ]

    func isNeededForSession(at date: Date) -> Bool {
        guard domain == "apple.com" || domain.hasSuffix(".apple.com") else { return false }
        if let expiresDate, expiresDate <= date { return false }
        return name.hasPrefix("DES") || Self.sessionCookieNames.contains(name)
    }
}

extension [HTTPCookie] {
    var nameList: String {
        isEmpty ? "none" : map(\.name).sorted().joined(separator: ", ")
    }
}
