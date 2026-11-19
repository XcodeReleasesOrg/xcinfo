//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import ArgumentParser
import Foundation
import XCIFoundation
import xcinfoCore

extension Core.ListFilter: EnumerableFlag {
    public static func help(for value: Self) -> ArgumentHelp? {
        switch value {
        case .onlyGM:
            "List only versions marked GM. xcodereleases.com no longer marks new releases as GM, so this finds only older versions."
        case .onlyReleases:
            "List only versions marked as final releases. Older versions marked GM are not included; use --only-gm for them."
        }
    }
}

extension XCInfo {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List all available Xcode versions",
            discussion: "List all available Xcode versions available according to xcodereleases.com."
        )

        @OptionGroup
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
            try await globals.run { core, output in
                let list = try await core.list(
                    shouldUpdate: listOptions.updateList,
                    showAllVersions: showAllVersions,
                    filter: listFilter
                )
                if output.options.isJSON {
                    try output.printJSON(ListPayload(list))
                } else {
                    list.lines(terminalColumns: WindowSize.current?.columns).forEach(output.print)
                }
            }
        }
    }
}
