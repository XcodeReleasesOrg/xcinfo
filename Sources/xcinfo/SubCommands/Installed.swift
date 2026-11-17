//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import ArgumentParser
import XCIFoundation
import xcinfoCore

extension XCInfo {
    struct Installed: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show installed Xcode versions",
            discussion: "Show all installed versions of Xcode and their location on this computer."
        )

        @OptionGroup()
        var globals: DefaultOptions

        @OptionGroup
        var listOptions: ListOptions

        func run() async throws {
            do {
                try await globals.run { core in
                    try await core.installedXcodes(shouldUpdate: listOptions.updateList)
                }
            } catch {
                globals.logger.error(error.localizedDescription)
                throw ExitCode.failure
            }
        }
    }
}
