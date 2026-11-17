//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import ArgumentParser
import Dependencies
import XCIFoundation
import xcinfoCore

extension XCInfo {
    struct Cleanup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove stored credentials",
            discussion: "Remove stored Apple ID credentials and session authentification items from the macOS keychain."
        )

        @OptionGroup()
        var globals: DefaultOptions

        func run() async throws {
            try await globals.run { core, output in
                await core.cleanup()
                if output.options.isJSON {
                    try output.printJSON([String: String]())
                }
            }
        }
    }
}
