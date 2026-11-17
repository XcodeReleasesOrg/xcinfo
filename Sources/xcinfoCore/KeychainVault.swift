//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Dependencies
import Foundation
import OlympUs
import XCIFoundation

public struct VaultContents: Codable, Equatable, Sendable {
    public var version = 1
    public var accountName: String?
    public var sessions: [String: Data] = [:]
    public var legacyCookies: Data?

    public init(accountName: String? = nil, sessions: [String: Data] = [:], legacyCookies: Data? = nil) {
        self.accountName = accountName
        self.sessions = sessions
        self.legacyCookies = legacyCookies
    }

    var isEmpty: Bool {
        accountName == nil && sessions.isEmpty && legacyCookies == nil
    }
}

public struct KeychainAccessError: Error, CustomStringConvertible, Sendable {
    public var underlying: String
    public var status: OSStatus?

    public init(underlying: String, status: OSStatus? = nil) {
        self.underlying = underlying
        self.status = status
    }

    public var description: String {
        "The Keychain item 'xcinfo' could not be read: \(underlying)."
    }

    public var canBeRetried: Bool {
        status == errSecAuthFailed || status == errSecUserCanceled || status == errSecInteractionNotAllowed
    }
}

public struct LegacyKeychainItems: Sendable, Equatable {
    public var accountName: String?
    public var hadStoredPassword: Bool
    public var sessions: [String: Data]
    public var cookies: Data?

    public init(accountName: String? = nil, hadStoredPassword: Bool = false, sessions: [String: Data] = [:], cookies: Data? = nil) {
        self.accountName = accountName
        self.hadStoredPassword = hadStoredPassword
        self.sessions = sessions
        self.cookies = cookies
    }

    var isEmpty: Bool {
        accountName == nil && !hadStoredPassword && sessions.isEmpty && cookies == nil
    }
}

public struct VaultStorage: Sendable {
    public var read: @Sendable () throws -> Data?
    public var write: @Sendable (_ data: Data) throws -> Void
    public var delete: @Sendable () throws -> Void
    public var readLegacy: @Sendable () -> LegacyKeychainItems
    public var deleteLegacy: @Sendable () -> Void

    public init(
        read: @escaping @Sendable () throws -> Data?,
        write: @escaping @Sendable (Data) throws -> Void,
        delete: @escaping @Sendable () throws -> Void,
        readLegacy: @escaping @Sendable () -> LegacyKeychainItems,
        deleteLegacy: @escaping @Sendable () -> Void
    ) {
        self.read = read
        self.write = write
        self.delete = delete
        self.readLegacy = readLegacy
        self.deleteLegacy = deleteLegacy
    }
}

extension VaultStorage {
    static let service = "xcinfo"

    static let keychain = VaultStorage(
        read: {
            do {
                return try KeychainPasswordItem(service: service, account: service).readData()
            } catch KeychainPasswordItem.KeychainError.noPassword {
                return nil
            }
        },
        write: { data in
            try KeychainPasswordItem(service: service, account: service).saveData(data, overwriteExisting: true)
        },
        delete: {
            try KeychainPasswordItem(service: service, account: service).deleteItem()
        },
        readLegacy: {
            var legacy = LegacyKeychainItems()
            if let item = try? KeychainPasswordItem.passwordItems(forService: "xcinfo.appleid").first {
                legacy.accountName = item.account
                legacy.hadStoredPassword = true
            }
            for item in (try? KeychainPasswordItem.passwordItems(forService: "xcinfo.session")) ?? [] {
                legacy.sessions[item.account] = try? item.readData()
            }
            if let cookies = try? KeychainPasswordItem(service: "xcinfo.cookies", account: "olympus").readData() {
                legacy.cookies = cookies
            } else if let cookies = UserDefaults.standard.array(forKey: "cookies") {
                legacy.cookies = try? PropertyListSerialization.data(fromPropertyList: cookies, format: .binary, options: 0)
            }
            return legacy
        },
        deleteLegacy: {
            for service in ["xcinfo.appleid", "xcinfo.session", "xcinfo.cookies"] {
                for item in (try? KeychainPasswordItem.passwordItems(forService: service)) ?? [] {
                    try? item.deleteItem()
                }
            }
            UserDefaults.standard.removeObject(forKey: "cookies")
        }
    )
}

public actor KeychainVault {
    private let storage: VaultStorage
    private var contents: VaultContents?
    private var written: VaultContents?
    private var readError: KeychainAccessError?

    public init(storage: VaultStorage) {
        self.storage = storage
    }

    static let shared = KeychainVault(storage: .keychain)

    public func load() throws -> VaultContents {
        if let readError {
            throw readError
        }
        if let contents {
            return contents
        }
        @Dependency(\.logger) var logger

        let data: Data?
        do {
            data = try storage.read()
        } catch {
            let status: OSStatus? = if case let KeychainPasswordItem.KeychainError.unhandledError(status) = error { status } else { nil }
            let accessError = KeychainAccessError(underlying: "\(error)", status: status)
            readError = accessError
            throw accessError
        }

        if let data {
            let decoded = (try? JSONDecoder().decode(VaultContents.self, from: data)) ?? VaultContents()
            contents = decoded
            written = decoded
            return decoded
        }

        let legacy = storage.readLegacy()
        let migrated = VaultContents(accountName: legacy.accountName, sessions: legacy.sessions, legacyCookies: legacy.cookies)
        contents = migrated
        written = VaultContents()
        if !legacy.isEmpty {
            do {
                try flush()
                storage.deleteLegacy()
                logger.log("Moved the stored Apple ID and session into one Keychain item named 'xcinfo'.")
                if legacy.hadStoredPassword {
                    logger.log("Removed the stored Apple ID password from the Keychain: xcinfo now keeps only the account name and the session, and asks for the password when Apple needs it.")
                }
            } catch {
                logger.warn("Could not move the stored Apple ID and session into one Keychain item (\(error)).")
            }
        }
        return migrated
    }

    public func reload() throws -> VaultContents {
        readError = nil
        contents = nil
        written = nil
        return try load()
    }

    public func stage(_ change: @Sendable (inout VaultContents) -> Void) throws {
        var updated = try load()
        change(&updated)
        contents = updated
    }

    public func commit(_ change: @Sendable (inout VaultContents) -> Void) throws {
        try stage(change)
        try flush()
    }

    private func flush() throws {
        guard let contents, contents != written else { return }
        if contents.isEmpty {
            try? storage.delete()
        } else {
            try storage.write(JSONEncoder().encode(contents))
        }
        written = contents
    }
}

extension AuthenticationSessionStore {
    static func vault(_ keychain: KeychainClient) -> AuthenticationSessionStore {
        AuthenticationSessionStore(
            load: { account in
                try await keychain.load().sessions[account]
            },
            save: { data, account in
                try await keychain.commit { $0.sessions[account] = data }
            },
            removeAll: {
                let count = try await keychain.load().sessions.count
                try await keychain.commit { contents in
                    contents.sessions = [:]
                    contents.legacyCookies = nil
                }
                return count
            },
            loadLegacyCookies: {
                try? await keychain.load().legacyCookies
            },
            removeLegacyCookies: {
                try? await keychain.stage { $0.legacyCookies = nil }
            }
        )
    }
}
