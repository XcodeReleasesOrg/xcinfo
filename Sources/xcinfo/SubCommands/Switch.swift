//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import ArgumentParser
import XCIFoundation
import xcinfoCore

extension XCInfo {
    struct Switch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Switch to another installed Xcode",
            discussion: """
            Points /Applications/Xcode.app to the chosen installed Xcode and selects it with xcode-select, \\
            which needs the Mac administrator password. With several matches, xcinfo asks which one to use.
            """
        )

        @Argument(help: "The version or build number of an installed Xcode, or `latest`. Without it, xcinfo asks.")
        var xcodeVersion: String?

        @Flag(name: [.customLong("no-symlink")], help: "Leave /Applications/Xcode.app unchanged.")
        var skipSymlinkCreation: Bool = false

        @Flag(name: [.customLong("no-xcode-select")], help: "Leave the xcode-select selection unchanged.")
        var skipXcodeSelection: Bool = false

        @OptionGroup
        var listOptions: ListOptions

        @OptionGroup()
        var globals: DefaultOptions

        func run() async throws {
            try await globals.run { core, output in
                let application = try await core.switchXcode(
                    to: xcodeVersion?.lowercased(),
                    options: .init(skipSymlinkCreation: skipSymlinkCreation, skipXcodeSelection: skipXcodeSelection),
                    updateVersionList: listOptions.updateList
                )
                if output.options.isJSON {
                    try output.printJSON(ApplicationPayload(application))
                }
            }
        }
    }
}
