//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation

public struct KeychainPasswordItem {
    // MARK: Types

    public enum KeychainError: Error, CustomStringConvertible {
        case noPassword
        case unexpectedPasswordData
        case unexpectedItemData
        case unhandledError(status: OSStatus)
        case passwordAlreadySet

        public var description: String {
            switch self {
            case .noPassword:
                return "No password set."
            case .unexpectedPasswordData:
                return "unexpectedPasswordData"
            case .unexpectedItemData:
                return "unexpectedItemData"
            case let .unhandledError(status):
                return KeychainPasswordItem.explanation(for: status)
            case .passwordAlreadySet:
                return "Password already exists."
            }
        }
    }

    public static func explanation(for status: OSStatus) -> String {
        switch status {
        case errSecAuthFailed:
            return "macOS refused access to the Keychain item: the password in the Keychain dialog was not accepted, or access was denied"
        case errSecUserCanceled:
            return "access to the Keychain was denied in the macOS dialog"
        case errSecInteractionNotAllowed:
            return "macOS could not show the Keychain dialog"
        default:
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown Keychain error"
            return "\(message) (OSStatus \(status))"
        }
    }

    // MARK: Properties

    public let service: String
    public private(set) var account: String
    public let accessGroup: String?

    // MARK: Intialization

    public init(service: String, account: String, accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    // MARK: Keychain access

    public func readPassword() throws -> String {
        /*
         Build a query to find the item that matches the service, account and
         access group.
         */
        var query = KeychainPasswordItem.keychainQuery(withService: service, account: account, accessGroup: accessGroup)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecReturnData as String] = kCFBooleanTrue

        // Try to fetch the existing keychain item that matches the query.
        var queryResult: AnyObject?
        let status = withUnsafeMutablePointer(to: &queryResult) {
            SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer($0))
        }

        // Check the return status and throw an error if appropriate.
        guard status != errSecItemNotFound else { throw KeychainError.noPassword }
        guard status == noErr else { throw KeychainError.unhandledError(status: status) }

        // Parse the password string from the query result.
        guard let existingItem = queryResult as? [String: AnyObject],
              let passwordData = existingItem[kSecValueData as String] as? Data,
              let password = String(data: passwordData, encoding: .utf8)
        else {
            throw KeychainError.unexpectedPasswordData
        }

        return password
    }

    public func readData() throws -> Data {
        /*
         Build a query to find the item that matches the service, account and
         access group.
         */
        var query = KeychainPasswordItem.keychainQuery(withService: service, account: account, accessGroup: accessGroup)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecReturnData as String] = kCFBooleanTrue

        // Try to fetch the existing keychain item that matches the query.
        var queryResult: AnyObject?
        let status = withUnsafeMutablePointer(to: &queryResult) {
            SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer($0))
        }

        // Check the return status and throw an error if appropriate.
        guard status != errSecItemNotFound else { throw KeychainError.noPassword }
        guard status == noErr else { throw KeychainError.unhandledError(status: status) }

        // Parse the password string from the query result.
        guard let existingItem = queryResult as? [String: AnyObject],
              let passwordData = existingItem[kSecValueData as String] as? Data
        else {
            throw KeychainError.unexpectedPasswordData
        }

        return passwordData
    }

    public func savePassword(_ password: String, overwriteExisting: Bool = false) throws {
        try saveData(Data(password.utf8), overwriteExisting: overwriteExisting)
    }

    public func saveData(_ data: Data, overwriteExisting: Bool = false) throws {
        let query = KeychainPasswordItem.keychainQuery(withService: service, account: account, accessGroup: accessGroup)
        if overwriteExisting {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecItemNotFound else {
                guard status == noErr else { throw KeychainError.unhandledError(status: status) }
                return
            }
        }
        var newItem = query
        newItem[kSecValueData as String] = data as AnyObject?
        let status = SecItemAdd(newItem as CFDictionary, nil)
        guard status != errSecDuplicateItem else { throw KeychainError.passwordAlreadySet }
        guard status == noErr else { throw KeychainError.unhandledError(status: status) }
    }

    public static func firstItem(forService service: String, accessGroup: String? = nil) throws -> (account: String, data: Data)? {
        var query = KeychainPasswordItem.keychainQuery(withService: service, accessGroup: accessGroup)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecReturnData as String] = kCFBooleanTrue

        var result: AnyObject?
        let status = withUnsafeMutablePointer(to: &result) {
            SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer($0))
        }
        guard status != errSecItemNotFound else { return nil }
        guard status == noErr else { throw KeychainError.unhandledError(status: status) }
        guard
            let item = result as? [String: AnyObject],
            let account = item[kSecAttrAccount as String] as? String,
            let data = item[kSecValueData as String] as? Data
        else {
            throw KeychainError.unexpectedItemData
        }
        return (account, data)
    }

    public mutating func renameAccount(_ newAccountName: String) throws {
        // Try to update an existing item with the new account name.
        var attributesToUpdate = [String: AnyObject]()
        attributesToUpdate[kSecAttrAccount as String] = newAccountName as AnyObject?

        let query = KeychainPasswordItem.keychainQuery(withService: service, account: account, accessGroup: accessGroup)
        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)

        // Throw an error if an unexpected status was returned.
        guard status == noErr || status == errSecItemNotFound
        else { throw KeychainError.unhandledError(status: status) }

        account = newAccountName
    }

    public func deleteItem() throws {
        // Delete the existing item from the keychain.
        let query = KeychainPasswordItem.keychainQuery(withService: service, account: account, accessGroup: accessGroup)
        let status = SecItemDelete(query as CFDictionary)

        // Throw an error if an unexpected status was returned.
        guard status == noErr || status == errSecItemNotFound
        else { throw KeychainError.unhandledError(status: status) }
    }

    public static func passwordItems(
        forService service: String,
        accessGroup: String? = nil
    ) throws -> [KeychainPasswordItem] {
        // Build a query for all items that match the service and access group.
        var query = KeychainPasswordItem.keychainQuery(withService: service, accessGroup: accessGroup)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecReturnData as String] = kCFBooleanFalse

        // Fetch matching items from the keychain.
        var queryResult: AnyObject?
        let status = withUnsafeMutablePointer(to: &queryResult) {
            SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer($0))
        }

        // If no items were found, return an empty array.
        guard status != errSecItemNotFound else { return [] }

        // Throw an error if an unexpected status was returned.
        guard status == noErr else { throw KeychainError.unhandledError(status: status) }

        // Cast the query result to an array of dictionaries.
        guard let resultData = queryResult as? [[String: AnyObject]] else { throw KeychainError.unexpectedItemData }

        // Create a `KeychainPasswordItem` for each dictionary in the query result.
        var passwordItems = [KeychainPasswordItem]()
        for result in resultData {
            guard let account = result[kSecAttrAccount as String] as? String
            else { throw KeychainError.unexpectedItemData }

            let passwordItem = KeychainPasswordItem(service: service, account: account, accessGroup: accessGroup)
            passwordItems.append(passwordItem)
        }

        return passwordItems
    }

    // MARK: Convenience

    private static func keychainQuery(
        withService service: String,
        account: String? = nil,
        accessGroup: String? = nil
    ) -> [String: AnyObject] {
        var query = [String: AnyObject]()
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = service as AnyObject?

        if let account = account {
            query[kSecAttrAccount as String] = account as AnyObject?
        }

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup as AnyObject?
        }

        return query
    }
}
