//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import Foundation

public extension FileManager {
    func isSymbolicLink(atPath path: String) -> Bool {
        guard let type = try? attributesOfItem(atPath: path)[.type] as? FileAttributeType else { return false }
        return type == .typeSymbolicLink
    }
}
