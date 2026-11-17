//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import ArgumentParser
import Dependencies
import XCIFoundation
import xcinfoCore

extension XCInfo {
    struct Cleanup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove the stored Apple ID and Apple session",
            discussion: """
            Deletes the Keychain item 'xcinfo' (the stored Apple ID and the Apple session) and the Apple cookies \
            left by older versions. The next download signs in again, with two-factor authentication. Downloaded \
            archives, saved download progress and the cached list of Xcode versions are kept.
            """
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
