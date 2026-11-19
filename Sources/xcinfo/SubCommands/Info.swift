//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
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

        @OptionGroup
        var versionOption: VersionOptions

        @OptionGroup
        var listOptions: ListOptions

        @OptionGroup
        var globals: DefaultOptions

        func run() async throws {
            try await globals.run { core, output in
                let xcode = try await core.info(version: versionOption.xcodeVersion, shouldUpdate: listOptions.updateList)
                if output.options.isJSON {
                    try output.printJSON(XcodePayload(xcode))
                } else {
                    xcode.infoLines.forEach(output.print)
                }
            }
        }
    }
}
