//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import ArgumentParser
import Foundation
import XCIFoundation
import xcinfoCore

extension XCInfo {
    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install an Xcode version",
            discussion: "Install a specific version of Xcode."
        )

        @OptionGroup
        var installationOptions: InstallationOptions

        @OptionGroup
        var listOptions: ListOptions

        @OptionGroup
        var globals: DefaultOptions

        func run() async throws {
            try await globals.run { core, output in
                installationOptions.extractionOptions.reportDeprecations(to: output)
                let application = try await core.install(
                    options: .init(
                        version: installationOptions.xcodeVersion,
                        archiveFile: installationOptions.archiveFile,
                        downloadOptions: installationOptions.downloadOptions.options,
                        extractionOptions: installationOptions.extractionOptions.options,
                        skipSymlinkCreation: installationOptions.skipSymlinkCreation,
                        skipXcodeSelection: installationOptions.skipXcodeSelection,
                        shouldPreserveArchive: installationOptions.shouldPreserveArchive
                    ),
                    updateVersionList: listOptions.updateList
                )
                if output.options.isJSON {
                    try output.printJSON(ApplicationPayload(application))
                }
            }
        }
    }
}
