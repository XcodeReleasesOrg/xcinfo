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
            try await globals.run { core, output in
                let url = try await core.extractXIP(source: source, options: extractionOptions.options)
                if output.options.isJSON {
                    try output.printJSON(PathPayload(path: url.path))
                }
            }
        }
    }
}

extension ExtractionOptions {
    var options: Core.ExtractionOptions {
        .init(destination: installationDirectory, useLegacyUnxip: useSystemUnxip)
    }
}
