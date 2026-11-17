//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import ArgumentParser
import XCIFoundation
import xcinfoCore

extension XCInfo {
    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Downloads an Xcode version",
            discussion: "Downloads a specific version of Xcode."
        )

        @OptionGroup
        var versionOptions: VersionOptions

        @OptionGroup
        var downloadOptions: DownloadOptions

        @OptionGroup()
        var globals: DefaultOptions

        @OptionGroup
        var listOptions: ListOptions

        func run() async throws {
            do {
                try await globals.run { core in
                    try await core.download(
                        version: versionOptions.xcodeVersion,
                        options: downloadOptions.options,
                        updateVersionList: listOptions.updateList
                    )
                }
            } catch let error as CoreError {
                globals.logger.error(error.localizedDescription)
                throw ExitCode.failure
            }
        }
    }
}

extension DownloadOptions {
    var options: Core.DownloadOptions {
        .init(destination: downloadDirectory, disableSleep: disableSleep)
    }
}
