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
                                $0.keychain = $0.keychain.handingOverTerminal(to: session, logsState: globals.isVerbose || ProcessInfo.processInfo.environment["XCINFO_DEBUG_KEYCHAIN"] == "1")
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
    case let .install(xcode, installOptions):
        try FileManager.default.createDirectory(at: installOptions.folderURL, withIntermediateDirectories: true)
        try await core.install(
            options: .init(
                version: .version(xcode.version.build ?? xcode.displayVersion),
                archiveFile: nil,
                downloadOptions: .init(destination: downloadsDirectory, disableSleep: true),
                extractionOptions: .init(destination: installOptions.folderURL),
                skipSymlinkCreation: !installOptions.createsSymlink,
                skipXcodeSelection: !installOptions.selectsXcode
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

private let firstKeychainRead = FirstUse()

actor FirstUse {
    private var isUsed = false

    func claim() -> Bool {
        defer { isUsed = true }
        return !isUsed
    }
}

extension KeychainClient {
    func handingOverTerminal(to session: TUISession, logsState: Bool, firstUse: FirstUse = firstKeychainRead) -> KeychainClient {
        var client = self
        let load = self.load
        let reload = self.reload
        client.load = {
            guard await firstUse.claim() else { return try await load() }
            return try await session.withTerminalReleased(
                leavingFullScreen: false,
                message: "Waiting for macOS to unlock the xcinfo Keychain item…"
            ) { state in
                if logsState {
                    session.logger.log("Reading the Keychain with \(state).")
                }
                return try await load()
            }
        }
        client.reload = {
            try await session.withTerminalReleased(
                leavingFullScreen: true,
                message: "Leaving the full-screen view so macOS can show the Keychain dialog…"
            ) { state in
                if logsState {
                    session.logger.log("Reading the Keychain again with \(state).")
                }
                return try await reload()
            }
        }
        return client
    }
}
