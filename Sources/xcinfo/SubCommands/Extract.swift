//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import ArgumentParser
import Foundation
import XCIFoundation
import xcinfoCore

extension XCInfo {
    struct Extract: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Extract an Xcode XIB"
        )

        @Argument
        var source: URL

        @OptionGroup
        var extractionOptions: ExtractionOptions

        @OptionGroup()
        var globals: DefaultOptions

        func run() async throws {
            do {
                try await globals.run { core in
                    try await core.extractXIP(source: source, options: extractionOptions.options)
                }
            } catch let error as CoreError {
                globals.logger.error(error.localizedDescription)
                throw ExitCode.failure
            }
        }
    }
}

extension ExtractionOptions {
    var options: Core.ExtractionOptions {
        .init(destination: installationDirectory, useLegacyUnxip: useSystemUnxip)
    }
}
