//
//  Copyright © 2022 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import ArgumentParser
import XCIFoundation
import xcinfoCore

extension XCInfo {
    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Downloads an Xcode version",
            discussion: """
            Downloads a specific version of Xcode. Signs in to Apple when the stored session has expired and asks \
            for the password then. Run `xcinfo signin` first to sign in ahead of time, or set XCINFO_APPLE_ID and \
            XCINFO_APPLE_PASSWORD for unattended use.
            """
        )

        @OptionGroup
        var versionOptions: VersionOptions

        @OptionGroup
        var downloadOptions: DownloadOptions

        @OptionGroup
        var globals: DefaultOptions

        @OptionGroup
        var listOptions: ListOptions

        func run() async throws {
            try await globals.run { core, output in
                let (xcode, url) = try await core.download(
                    version: versionOptions.xcodeVersion,
                    options: downloadOptions.options,
                    updateVersionList: listOptions.updateList
                )
                if output.options.isJSON {
                    try output.printJSON(DownloadPayload(path: url.path, xcode: xcode))
                }
            }
        }
    }
}

extension DownloadOptions {
    var options: Core.DownloadOptions {
        .init(
            destination: downloadDirectory,
            disableSleep: disableSleep,
            verifiesChecksum: !skipsVerification,
            archiveFormat: archiveFormat,
            overwritesExistingFile: overwritesExistingFile,
            architecture: architecture,
            connections: connections
        )
    }
}
