//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import ArgumentParser
import Foundation
import XCIFoundation
import xcinfoCore

extension XCInfo {
    struct Extract: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Extract an Xcode archive (.xip or .aea)",
            discussion: "Only extracts the archive: no download, checksum check or setup."
        )

        @Argument(help: "The Xcode archive to extract (.xip or .aea).", completion: .file(extensions: ArchiveFormat.fileExtensions))
        var source: URL

        @OptionGroup
        var extractionOptions: ExtractionOptions

        @OptionGroup
        var globals: DefaultOptions

        func run() async throws {
            try await globals.run { core, output in
                extractionOptions.reportDeprecations(to: output)
                let url = try await core.extractArchive(source: source, options: extractionOptions.options)
                if output.options.isJSON {
                    try output.printJSON(PathPayload(path: url.path))
                }
            }
        }
    }
}

extension ExtractionOptions {
    var options: Core.ExtractionOptions {
        .init(destination: installationDirectory)
    }
}
