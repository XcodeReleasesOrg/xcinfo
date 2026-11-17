//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.

public enum XcodeVersion: Sendable {
    case version(String)
    case latest
    case exactly(Xcode)
}

public extension XcodeVersion {
    init(_ string: String) throws {
        if string == "latest" {
            self = .latest
        } else {
            self = .version(string)
        }
    }
}

extension XcodeVersion: CustomStringConvertible {
    public var description: String {
        switch self {
        case .latest:
            return "latest"
        case let .version(string):
            return string
        case let .exactly(xcode):
            return xcode.labeledName
        }
    }
}
