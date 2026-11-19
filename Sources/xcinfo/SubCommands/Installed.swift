//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
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

        @OptionGroup
        var globals: DefaultOptions

        @OptionGroup
        var listOptions: ListOptions

        func run() async throws {
            try await globals.run { core, output in
                let applications = try await core.installedXcodes(shouldUpdate: listOptions.updateList)
                if output.options.isJSON {
                    try output.printJSON(applications.map(ApplicationPayload.init))
                } else {
                    applications.lines.forEach(output.print)
                }
            }
        }
    }
}
