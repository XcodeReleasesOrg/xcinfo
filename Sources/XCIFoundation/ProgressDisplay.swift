//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
import Rainbow

public struct ProgressDisplay: Sendable {
    public var ratio: Double
    public let width: Int
    var partChars = [" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]

    public init(ratio: Double, width: Int) {
        self.ratio = ratio
        self.width = width
    }

    public var representation: String {
        let progress = min(1, max(0, ratio))
        let widthPercentage = progress * Double(width)
        let fullCharWidth = widthPercentage.rounded(.down)
        let partCharWidth = widthPercentage - fullCharWidth

        let partWidth = Int(partCharWidth * Double(partChars.count))
        let fullChars = String(repeating: "█", count: Int(fullCharWidth))
        if fullCharWidth < Double(width) {
            let emptyChars = String(repeating: " ", count: Int(Double(width) - fullCharWidth - 1))
            let bar = fullChars + partChars[partWidth] + emptyChars
            return "[\(bar.cyan)] \(ratio.formatted(.percent.precision(.fractionLength(1)).locale(Locale(identifier: "en_US"))))"
        } else {
            return "[\(fullChars)] 100.0%"
        }
    }
}
