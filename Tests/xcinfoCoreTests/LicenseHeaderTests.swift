//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see LICENSE.md
//

import Foundation
import Testing

struct LicenseHeaderTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test
    func `every source header names the license in LICENSE.md`() throws {
        let license = try String(contentsOf: Self.root.appendingPathComponent("LICENSE.md"), encoding: .utf8)
        #expect(license.contains("GNU LESSER GENERAL PUBLIC LICENSE"))

        let files = ["Sources", "Tests"].flatMap { folder in
            (FileManager.default.enumerator(at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? [])
                .filter { $0.pathExtension == "swift" }
        }
        #expect(!files.isEmpty)
        for file in files {
            let header = try String(contentsOf: file, encoding: .utf8).prefix(300)
            #expect(!header.contains("MIT license"), "\(file.lastPathComponent)")
        }
    }
}
