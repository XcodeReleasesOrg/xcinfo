import Foundation
import OlympUs
import os

final class InMemorySessionStore: Sendable {
    private let items: OSAllocatedUnfairLock<[String: Data]>

    init(_ items: [String: Data] = [:]) {
        self.items = OSAllocatedUnfairLock(initialState: items)
    }

    var accounts: [String] {
        items.withLock { Array($0.keys) }
    }

    func data(for account: String) -> Data? {
        items.withLock { $0[account] }
    }

    var store: AuthenticationSessionStore {
        AuthenticationSessionStore(
            load: { [items] account in
                guard let data = items.withLock({ $0[account] }) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return data
            },
            save: { [items] data, account in
                items.withLock { $0[account] = data }
            },
            removeAll: { [items] in
                items.withLock { items in
                    let count = items.count
                    items.removeAll()
                    return count
                }
            }
        )
    }
}

final class TemporaryDefaults: @unchecked Sendable { // Wraps UserDefaults, which is thread-safe but not annotated Sendable.
    let suiteName = "xcinfo-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

extension OlympUs.AuthenticationAssets {
    static let fixture = try! JSONDecoder().decode(
        OlympUs.AuthenticationAssets.self,
        from: Data(#"{"serviceKey":"service-key","scnt":"scnt-value","asid":"session-id","authenticationType":"hsa2"}"#.utf8)
    )

    static var fixtureData: Data {
        try! JSONEncoder().encode(fixture)
    }
}
