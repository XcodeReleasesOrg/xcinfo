//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see LICENSE.md
//

import Foundation

struct DownloadSource: Equatable {
    let url: URL
    let note: String?
    let derivedFallback: URL?

    init(listed: URL, offered: [URL]?, format: ArchiveFormat? = nil) throws {
        let offered = offered ?? []
        let xip = offered.first { $0.pathExtension.lowercased() == "xip" }
        let aea = offered.first { $0.pathExtension.lowercased() == "aea" }
        let listedFormat = ArchiveFormat(rawValue: listed.pathExtension.lowercased())
        switch format {
        case .xip:
            guard let url = xip ?? (listedFormat == .xip && offered.isEmpty ? listed : nil) else {
                throw CoreError.archiveFormatNotOffered(.xip, offered: offered.map(\.lastPathComponent))
            }
            self.url = url
            note = "Downloading the .xip as requested."
            derivedFallback = nil
        case .aea:
            if let url = aea ?? (listedFormat == .aea ? listed : nil) {
                self.url = url
                note = "Downloading the .aea as requested."
            } else if offered.isEmpty {
                url = listed.deletingPathExtension().appendingPathExtension("aea")
                note = "Downloading the .aea as requested, from an address derived from the .xip's: \(url)"
            } else {
                throw CoreError.archiveFormatNotOffered(.aea, offered: offered.map(\.lastPathComponent))
            }
            derivedFallback = nil
        case nil:
            switch (listedFormat, xip, aea) {
            case let (_, xip?, aea):
                url = xip
                note = aea == nil ? nil : "Apple offers this version as .xip and .aea. Downloading the .xip, which xcodereleases.com has a checksum for."
                derivedFallback = nil
            case let (.xip, nil, aea?):
                url = aea
                note = "Apple offers this version only as .aea. Downloading \(aea.lastPathComponent)."
                derivedFallback = nil
            case (.xip, nil, nil):
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
}
