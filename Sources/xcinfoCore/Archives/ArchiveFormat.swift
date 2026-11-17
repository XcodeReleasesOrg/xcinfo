//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see LICENSE.md
//

import Foundation

public enum ArchiveFormat: String, Sendable, CaseIterable {
    case xip
    case aea

    public static let fileExtensions = allCases.map(\.rawValue)

    var magic: Data {
        switch self {
        case .xip: Data("xar!".utf8)
        case .aea: Data("AEA1".utf8)
        }
    }

    public init?(contentsOf url: URL) {
        guard
            let handle = try? FileHandle(forReadingFrom: url),
            let prefix = try? handle.read(upToCount: 4)
        else { return nil }
        try? handle.close()
        guard let format = Self.allCases.first(where: { $0.magic == prefix }) else { return nil }
        self = format
    }
}
