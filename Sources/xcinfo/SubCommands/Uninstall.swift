//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import ArgumentParser
import XCIFoundation
import xcinfoCore

extension XCInfo {
    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Uninstall an Xcode version",
            discussion: "Moves a specific version of Xcode to the Trash after asking, showing its full path."
        )

        @OptionGroup
        var globals: DefaultOptions

        @Argument(
            help: "The version number of the Xcode to uninstall."
        )
        var xcodeVersion: String?

        @OptionGroup
        var listOptions: ListOptions

        @Flag(name: .customLong("delete-permanently"), help: "Delete the Xcode right away instead of moving it to the Trash.")
        var deletePermanently: Bool = false

        func run() async throws {
            try await globals.run { core, output in
                let removed = try await core.uninstall(
                    xcodeVersion?.lowercased(),
                    updateVersionList: listOptions.updateList,
                    deletePermanently: deletePermanently
                )
                if output.options.isJSON {
                    try output.printJSON(PathPayload(path: removed?.url.path))
                }
            }
        }
    }
}
