//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import ArgumentParser
import Dependencies
import Foundation
import XCIFoundation
import XCInfoTUI
import xcinfoCore

extension XCInfo {
    struct Tui: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "tui",
            abstract: "Browse, install and uninstall Xcode versions in a full-screen terminal UI",
            discussion: "Also starts when xcinfo runs without a subcommand in an interactive terminal."
        )

        @OptionGroup()
        var globals: DefaultOptions

        func run() async throws {
            guard TUIApp.isAvailable else {
                throw ValidationError("The terminal UI needs an interactive terminal.")
            }
            let globals = globals
            let app = TUIApp(
                actions: TUIActions(
                    load: {
                        try await withDependencies {
                            $0.logger = Logger { _ in }
                        } operation: {
                            let core = Core()
                            let list = try await core.list(shouldUpdate: true, showAllVersions: true, filter: nil)
                            let installed = try await core.installedXcodes(shouldUpdate: false)
                            return (list, installed)
                        }
                    },
                    perform: { command, session in
                        do {
                            try await withDependencies {
                                $0.logger = session.logger
                                $0.prompt = session.prompt
                            } operation: {
                                try await perform(command, core: Core())
                            }
                            return TUIOutcome(succeeded: true, message: "Done.")
                        } catch {
                            return TUIOutcome(succeeded: false, message: Task.isCancelled ? "Stopped." : error.message)
                        }
                    }
                ),
                usesColors: globals.renderer.options.usesColors,
                showsVerbose: globals.isVerbose
            )
            try await app.run()
        }
    }
}

private let downloadsDirectory = URL(fileURLWithPath: "\(NSHomeDirectory())/Downloads").standardizedFileURL

private func perform(_ command: TUICommand, core: Core) async throws {
    switch command {
    case let .install(xcode):
        try await core.install(
            options: .init(
                version: .version(xcode.version.build ?? xcode.displayVersion),
                archiveFile: nil,
                downloadOptions: .init(destination: downloadsDirectory, disableSleep: true),
                extractionOptions: .init(destination: URL(fileURLWithPath: "/Applications"))
            ),
            updateVersionList: false
        )
    case let .download(xcode):
        try await core.download(
            version: .version(xcode.version.build ?? xcode.displayVersion),
            options: .init(destination: downloadsDirectory, disableSleep: true),
            updateVersionList: false
        )
    case let .uninstall(application):
        try await core.uninstall(application.xcode.version.build?.lowercased() ?? application.xcode.displayVersion, updateVersionList: false)
    case .quit, .refresh:
        break
    }
}
