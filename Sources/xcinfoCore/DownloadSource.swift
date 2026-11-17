//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation

struct DownloadSource: Equatable {
    let url: URL
    let note: String?
    let derivedFallback: URL?

    init(listed: URL, offered: [URL]?) {
        let offered = offered ?? []
        let xip = offered.first { $0.pathExtension.lowercased() == "xip" }
        let aea = offered.first { $0.pathExtension.lowercased() == "aea" }
        switch (listed.pathExtension.lowercased(), xip, aea) {
        case let (_, xip?, aea):
            url = xip
            note = aea == nil ? nil : "Apple offers this version as .xip and .aea. Downloading the .xip, which xcodereleases.com has a checksum for."
            derivedFallback = nil
        case let ("xip", nil, aea?):
            url = aea
            note = "Apple offers this version only as .aea. Downloading \(aea.lastPathComponent)."
            derivedFallback = nil
        case ("xip", nil, nil) where offered.isEmpty:
            url = listed
            note = nil
            derivedFallback = listed.deletingPathExtension().appendingPathExtension("aea")
        default:
            url = aea ?? listed
            note = nil
            derivedFallback = nil
        }
    }
}
