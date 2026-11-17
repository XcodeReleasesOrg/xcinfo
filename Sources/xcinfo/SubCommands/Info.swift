//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import ArgumentParser
import XCIFoundation
import xcinfoCore

extension XCInfo {
    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Xcode version info",
            discussion: "Display information like SDK, release note link, etc of an Xcode version."
        )

        @OptionGroup()
        var versionOption: VersionOptions

        @OptionGroup
        var listOptions: ListOptions

        @OptionGroup()
        var globals: DefaultOptions

        func run() async throws {
            do {
                try await globals.run { core in
                    try await core.info(version: versionOption.xcodeVersion, shouldUpdate: listOptions.updateList)
                }
            } catch {
                globals.logger.error(error.localizedDescription)
                throw ExitCode.failure
            }
        }
    }
}
