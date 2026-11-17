//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import ArgumentParser
import XCIFoundation
import xcinfoCore

extension XCInfo {
    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Uninstall an Xcode version",
            discussion: "Uninstall a specific version of Xcode."
        )

        @OptionGroup()
        var globals: DefaultOptions

        @Argument(
            help: "The version number of the Xcode to uninstall."
        )
        var xcodeVersion: String?

        @OptionGroup
        var listOptions: ListOptions

        func run() async throws {
            do {
                try await globals.run { core in
                    try await core.uninstall(xcodeVersion?.lowercased(), updateVersionList: listOptions.updateList)
                }
            } catch let error as CoreError {
                globals.logger.error(error.localizedDescription)
                throw ExitCode.failure
            }
        }
    }
}
