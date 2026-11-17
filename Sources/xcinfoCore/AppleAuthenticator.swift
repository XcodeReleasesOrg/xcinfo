//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
import OlympUs
import XCIFoundation

struct AuthenticationError: Error {}

final class AppleAuthenticator: Sendable {
    let olymp: OlympUs
    let logger: Logger

    init(olymp: OlympUs, logger: Logger) {
        self.olymp = olymp
        self.logger = logger
    }

    func authenticate(credentials: Credentials) async throws {
        try await authenticate(username: credentials.username, password: credentials.password)
    }

    func authenticate(username: String, password: String) async throws {
        do {
            var assets: OlympUs.AuthenticationAssets?
            do {
                try await olymp.validateSession(for: username)
            } catch {
                let serviceKey = try await olymp.getServiceKey(for: username)
                let authenticationAssets = try await olymp.signIn(
                    accountName: username,
                    password: password,
                    serviceKey: serviceKey
                )
                assets = authenticationAssets
                let validationType = try await olymp.requestAuthentication(assets: authenticationAssets)
                try await olymp.sendSecurityCode(validationType: validationType, assets: authenticationAssets)
                try await olymp.requestTrust(assets: authenticationAssets)
                try await olymp.getOlympusSession(assets: authenticationAssets, for: username)
            }
            try await olymp.getDownloadAuth(
                assets: assets ?? olymp.storedAuthenticationAssets(for: username)!
            )
        } catch {
            throw AuthenticationError()
        }
    }
}
