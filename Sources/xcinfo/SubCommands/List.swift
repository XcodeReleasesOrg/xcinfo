//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import ArgumentParser
import XCIFoundation
import xcinfoCore

extension Core.ListFilter: EnumerableFlag {}

extension XCInfo {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List all available Xcode versions",
            discussion: "List all available Xcode versions available according to xcodereleases.com."
        )

        @OptionGroup()
        var globals: DefaultOptions

        @Flag
        var listFilter: Core.ListFilter?

        @Flag(
            name: [.customLong("all"), .customShort("a")],
            help: "Shows all Xcode version ever released. If false or omitted, only installable versions of the last year are printed."
        )
        var showAllVersions = false

        @OptionGroup
        var listOptions: ListOptions

        func run() async throws {
            do {
                try await globals.run { core in
                    try await core.list(
                        shouldUpdate: listOptions.updateList,
                        showAllVersions: showAllVersions,
                        filter: listFilter
                    )
                }
            } catch {
                globals.logger.error(error.localizedDescription)
                throw ExitCode.failure
            }
        }
    }
}
