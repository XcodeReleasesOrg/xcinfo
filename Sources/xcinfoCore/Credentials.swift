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

public enum CredentialsError: Error, Equatable, LocalizedError {
    case keychainError(String)
    case invalidPassword
    case accountNameUnavailable
    case passwordUnavailable

    public var errorDescription: String? {
        switch self {
        case let .keychainError(message):
            message
        case .invalidPassword:
            "The password is empty."
        case .accountNameUnavailable:
            "No Apple ID available. Run xcinfo in a terminal or set XCINFO_APPLE_ID."
        case .passwordUnavailable:
            "No Apple ID password available. Run xcinfo in a terminal or set XCINFO_APPLE_PASSWORD."
        }
    }
}

struct CredentialService {
    static let accountNameVariable = "XCINFO_APPLE_ID"
    static let passwordVariable = "XCINFO_APPLE_PASSWORD"

    var environment: [String: String] = ProcessInfo.processInfo.environment
    var isInteractive: Bool = isatty(STDIN_FILENO) != 0

    @Dependency(\.keychain) private var keychain
    @Dependency(\.logger) private var logger
    @Dependency(\.prompt) private var prompt

    func accountName() async throws -> String {
        if let accountName = environment[Self.accountNameVariable], !accountName.isEmpty {
            return accountName
        }
        do {
            if let accountName = try await keychain.load().accountName {
                return accountName
            }
        } catch {
            logger.warn("\(error)")
        }
        guard isInteractive else {
            throw CredentialsError.accountNameUnavailable
        }
        logger.log("Downloading Xcode needs a sign-in to Apple's Developer Portal with the Apple ID of your developer account.")
        let accountName = await prompt.readLine("Apple ID (email):").trimmingCharacters(in: .whitespaces)
        guard !accountName.isEmpty else {
            throw CredentialsError.accountNameUnavailable
        }
        try? await keychain.stage { $0.accountName = accountName }
        return accountName
    }

    func password(for accountName: String) async throws -> String {
        if let password = environment[Self.passwordVariable], !password.isEmpty {
            return password
        }
        guard isInteractive else {
            throw CredentialsError.passwordUnavailable
        }
        logger.log("Apple needs a new sign-in. xcinfo does not store your Apple ID password, so it asks for it now.")
        let password = await prompt.readSecret("Apple ID password for \(accountName) (not your Mac password):")
        guard !password.isEmpty else {
            throw CredentialsError.invalidPassword
        }
        return password
    }

    func cleanup() async {
        do {
            if try await keychain.load().accountName != nil {
                try await keychain.commit { $0.accountName = nil }
                logger.success("Deleted the stored Apple ID from the Keychain.")
            } else {
                logger.log("No Apple ID was stored.")
            }
        } catch {
            logger.error("Error deleting the stored Apple ID. Please open Keychain Access.app and remove the item named 'xcinfo'.")
        }
    }
}
