//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import Foundation

public extension String {
    func paddedWithSpaces(to largestStringLength: Int) -> String {
        let lengthDelta = max(0, largestStringLength - count)
        return "\(self)\(String(repeating: " ", count: lengthDelta))"
    }
}
