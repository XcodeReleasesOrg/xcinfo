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
            "The Apple ID or password is incorrect."
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

public struct CookieStore: Sendable {
    public var load: @Sendable () -> Data?
    public var save: @Sendable (_ data: Data) -> Void
    public var remove: @Sendable () -> Void

    public init(
        load: @escaping @Sendable () -> Data?,
        save: @escaping @Sendable (Data) -> Void,
        remove: @escaping @Sendable () -> Void
    ) {
        self.load = load
        self.save = save
        self.remove = remove
    }
}

public extension CookieStore {
    static let keychain = CookieStore(
        load: {
            let item = KeychainPasswordItem(service: "xcinfo.cookies", account: "olympus")
            if let data = try? item.readData() {
                return data
            }
            guard
                let legacy = UserDefaults.standard.array(forKey: "cookies"),
                let data = try? PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0)
            else {
                return nil
            }
            if (try? item.saveData(data, overwriteExisting: true)) != nil {
                UserDefaults.standard.removeObject(forKey: "cookies")
            }
            return data
        },
        save: { data in
            try? KeychainPasswordItem(service: "xcinfo.cookies", account: "olympus").saveData(data, overwriteExisting: true)
        },
        remove: {
            try? KeychainPasswordItem(service: "xcinfo.cookies", account: "olympus").deleteItem()
            UserDefaults.standard.removeObject(forKey: "cookies")
        }
    )
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
    private nonisolated let cookieStore: CookieStore
    private nonisolated let sessionStore: AuthenticationSessionStore
    private nonisolated let prompt: PromptClient
    private let srpGroup: SRPGroup
    private let now: @Sendable () -> Date

    public init(
        logger: Logger,
        session: URLSession,
        cookieStore: CookieStore = .keychain,
        sessionStore: AuthenticationSessionStore = .keychain,
        prompt: PromptClient = .live,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.logger = logger
        self.session = session
        self.cookieStore = cookieStore
        self.sessionStore = sessionStore
        self.prompt = prompt
        self.now = now
        srpGroup = .rfc5054_2048
        restoreCookies()
    }

    private func displayState() {
        guard let state, let index = OlympUsState.allCases.firstIndex(of: state) else { return }
        logger.log("[\(index)/\(OlympUsState.allCases.count - 1)] \(state.description)")
    }

    // MARK: - Stored session -

    struct ServiceKeyResponse: Codable {
        var authServiceKey: String
    }

    public nonisolated func storedAuthenticationAssets(for account: String) -> AuthenticationAssets? {
        do {
            return try JSONDecoder().decode(AuthenticationAssets.self, from: sessionStore.load(account))
        } catch {
            return nil
        }
    }

    @discardableResult
    private func storeAuthenticationAssets(assets: AuthenticationAssets, for account: String) -> Bool {
        do {
            try sessionStore.save(JSONEncoder().encode(assets), account)
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

    // MARK: - Step 0: service key and hashcash -

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
        let rememberMe = true
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
        let hashcash = await hashcash(serviceKey: serviceKey)
        state = .signingIn
        session.configuration.httpCookieStorage?.removeCookies(since: Date(timeIntervalSinceReferenceDate: 0))

        let client = SRPClient(group: srpGroup, hash: .sha256, privateKey: privateKey.map { BigUInt(bigEndian: $0) })

        let initResponse: SignInInitResponse
        do {
            var request = signInRequest(url: signInURL.appendingPathComponent("init"), serviceKey: serviceKey, hashcash: hashcash)
            request.httpBody = try JSONEncoder().encode(SignInInitRequest(
                a: Data(client.publicKey.bytes()).base64EncodedString(),
                accountName: accountName
            ))
            let (data, response) = try await session.data(for: request)
            try Self.checkSignInStatus(response)
            initResponse = try JSONDecoder().decode(SignInInitResponse.self, from: data)
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
        completeURL.queryItems = [URLQueryItem(name: "isRememberMeEnabled", value: "true")]
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
        logger.log("Two-factor authentication is enabled for your account.")
        logger.log("Please enter the \(requiredCodeLength) digit verification code shown on one of your trusted devices.")
        if !trustedPhoneNumbers.isEmpty {
            logger.log("Type 'sms' to receive a verification code on a trusted phone number.")
        }
        let input = prompt.ask("Apple ID Verification Code: ", "Invalid code length") { value in
            !(value == "sms" && !trustedPhoneNumbers.isEmpty) && requiredCodeLength != value.count
        }
        guard input == "sms" else {
            return .securityCode(input)
        }

        let phoneIndex = prompt.choose(
            "Please choose your trusted device: ",
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
            "Please enter the received verification code:",
            "Invalid code length"
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
        cookieStore.remove()
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

extension OlympUs {
    private func storeCookies() {
        guard let cookies = session.configuration.httpCookieStorage?.cookies else { return }
        let properties = cookies.compactMap { cookie in
            cookie.properties.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0) else { return }
        cookieStore.save(data)
    }

    private nonisolated func restoreCookies() {
        guard
            let cookieStorage = session.configuration.httpCookieStorage,
            let data = cookieStore.load(),
            let cookies = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return }

        for cookieProperties in cookies {
            let properties = Dictionary(uniqueKeysWithValues: cookieProperties.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            if let cookie = HTTPCookie(properties: properties) {
                cookieStorage.setCookie(cookie)
            }
        }
    }
}
