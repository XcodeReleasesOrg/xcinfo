//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import Foundation
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has immutable value types without Sendable annotations.

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
            "latest"
        case let .version(string):
            string
        case let .exactly(xcode):
            xcode.labeledName
        }
    }
}
