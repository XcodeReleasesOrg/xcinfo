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

    @discardableResult
    func authenticate(username: String, password: @Sendable () async throws -> String) async throws -> DownloadListing? {
        do {
            try await olymp.validateSession(for: username)
            guard let assets = await olymp.storedAuthenticationAssets(for: username) else {
                throw OlympUsError.sessionInvalid
            }
            return try await olymp.getDownloadAuth(assets: assets)
        } catch OlympUsError.sessionInvalid {
            logger.verbose("Signing in again.")
        }

        let serviceKey = try await olymp.getServiceKey(for: username)
        let signIn = try await olymp.signIn(accountName: username, password: password(), serviceKey: serviceKey)
        if signIn.requiresTwoFactorAuthentication {
            let validationType = try await olymp.requestAuthentication(assets: signIn.assets)
            try await olymp.sendSecurityCode(validationType: validationType, assets: signIn.assets)
            try await olymp.requestTrust(assets: signIn.assets)
        }
        try await olymp.getOlympusSession(assets: signIn.assets, for: username)
        return try await olymp.getDownloadAuth(assets: signIn.assets)
    }
}
