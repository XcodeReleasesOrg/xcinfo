//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import ArgumentParser
import Dependencies
import XCIFoundation
import xcinfoCore

extension XCInfo {
    struct Cleanup: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove stored credentials",
            discussion: "Remove stored Apple ID credentials and session authentification items from the macOS keychain."
        )

        @OptionGroup()
        var globals: DefaultOptions

        func run() throws {
            Logger.isANSIEnabled = globals.useANSI
            withDependencies {
                $0.logger = globals.logger
            } operation: {
                Core().cleanup()
            }
        }
    }
}
