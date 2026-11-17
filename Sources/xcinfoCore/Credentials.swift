//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Dependencies
import Foundation
import XCIFoundation

public struct Credentials: Sendable, Equatable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

enum CredentialsError: Error {
    case keychainError(String)
    case invalidPassword
}

struct CredentialService {
    static let service = "xcinfo.appleid"

    @Dependency(\.keychain) private var keychain
    @Dependency(\.logger) private var logger
    @Dependency(\.prompt) private var prompt

    func appleIDCredentials() throws -> Credentials {
        if let username = try? keychain.accounts(Self.service).first {
            do {
                let password = try keychain.readPassword(Self.service, username)
                return Credentials(username: username, password: password)
            } catch {
                logger.warn("Could not read password from the Keychain.")
            }
        }

        logger.log("Apple's Developer Download page requires a login.")
        logger.emphasized("Please provide your Apple Developer Program account credentials.")

        let username = prompt.readLine("Username:")
        let password = prompt.readSecret("Password:")

        logger.log("\n")
        let shouldStoreInKeychain = prompt.agree("Do you want to store these credentials in the macOS Keychain?")

        if shouldStoreInKeychain {
            do {
                try keychain.savePassword(password, Self.service, username)
            } catch {
                logger.warn("Could not save password to the Keychain.")
            }
        }

        return Credentials(username: username, password: password)
    }

    func cleanup() {
        do {
            if try keychain.deleteAll(Self.service) > 0 {
                logger.success("Deleted stored Apple ID credentials from keychain.")
            } else {
                logger.log("No Apple ID credentials were stored.")
            }
        } catch {
            logger
                .error(
                    "Error deleting Keychain entries. Please open Keychain Access.app and remove items named 'xcinfo.appleid'."
                )
        }
    }
}
