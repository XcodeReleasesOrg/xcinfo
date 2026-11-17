//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
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
    func authenticate(
        username: String,
        password: @Sendable () async throws -> String
    ) async throws -> DownloadListing? {
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
        do {
            try await olymp.getOlympusSession(assets: signIn.assets, for: username)
        } catch {
            logger
                .verbose(
                    "No App Store Connect session (\(error.localizedDescription)); the download authorization decides whether the sign-in worked."
                )
        }
        return try await olymp.getDownloadAuth(assets: signIn.assets)
    }
}
