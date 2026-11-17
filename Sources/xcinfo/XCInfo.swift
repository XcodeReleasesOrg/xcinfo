//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import ArgumentParser
import Dependencies
import Foundation
import XCIFoundation
import XCInfoTUI
import xcinfoCore

@main
struct XCInfo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcinfo",
        abstract: "Lists, installs and removes Xcode versions using xcodereleases.com.",
        discussion: """
        Exit codes: 0 success, 1 unexpected error, 3 version not found, 4 sign-in failed, \
        5 download failed, 6 extraction failed, 7 installation failed, 8 uninstallation failed, \
        9 xcodereleases.com or cache unavailable, 10 an answer was needed with --non-interactive or after the input ended, \
        130 stopped with Ctrl-C (a paused download resumes on the next run). Invalid arguments exit with 64.
        """,
        version: version,
        subcommands: [
            Cleanup.self,
            Download.self,
            Extract.self,
            Info.self,
            Install.self,
            Installed.self,
            List.self,
            Switch.self,
            Tui.self,
            Uninstall.self
        ]
    )

    func run() async throws {
        guard TUIApp.isAvailable else {
            throw CleanExit.helpRequest(self)
        }
        try await Tui.parse([]).run()
    }
}

struct DefaultOptions: ParsableArguments {
    @Flag(
        name: [.customLong("verbose"), .customShort("v")],
        help: "Show more debugging information."
    )
    var isVerbose: Bool = false

    @Flag(
        name: .customLong("ansi"),
        inversion: .prefixedNo,
        help: "Show output with colors. Colors are off when the output is not a terminal or NO_COLOR is set."
    )
    var useANSI: Bool = true

    @Flag(name: [.customLong("quiet"), .customShort("q")], help: "Only show results, warnings and errors.")
    var isQuiet: Bool = false

    @Flag(name: .customLong("json"), help: "Print the result as JSON, without progress or status messages.")
    var isJSON: Bool = false

    @Flag(
        name: .customLong("non-interactive"),
        help: "Never ask: fail with exit code 10 where xcinfo would ask a question. Set XCINFO_APPLE_ID and XCINFO_APPLE_PASSWORD for sign-in."
    )
    var isNonInteractive: Bool = false

    var renderer: TerminalRenderer {
        TerminalRenderer(options: .detect(isVerbose: isVerbose, isQuiet: isQuiet, isJSON: isJSON, allowsColors: useANSI))
    }

    @discardableResult
    func run<Result>(_ operation: (Core, TerminalRenderer) async throws -> Result) async throws -> Result {
        let renderer = renderer
        Logger.isANSIEnabled = renderer.options.usesColors
        do {
            return try await withDependencies {
                $0.logger = renderer.logger
                if isNonInteractive {
                    $0.prompt = .unavailable
                }
            } operation: {
                try await operation(Core(), renderer)
            }
        } catch {
            renderer.report(error)
            throw ExitCode(error.exitCode)
        }
    }
}

struct ListOptions: ParsableArguments {
    @Flag(
        inversion: .prefixedNo,
        help: "Update the list of known Xcode versions."
    )
    var updateList = true
}

struct VersionOptions: ParsableArguments {
    @Argument(
        help: "A version number of an Xcode version or `latest`.",
        transform: XcodeVersion.init
    )
    var xcodeVersion: XcodeVersion
}

struct DownloadOptions: ParsableArguments {
    @Option(
        name: [.long, .short],
        help: "The download destination folder.",
        completion: .directory
    )
    var downloadDirectory: URL = .init(fileURLWithPath: "\(NSHomeDirectory())/Downloads").standardizedFileURL

    @Flag(name: .customLong("prevent-sleep"), help: "Keep the Mac awake while downloading.")
    var preventSleep: Bool = false

    @Flag(
        name: .customLong("sleep"),
        inversion: .prefixedNo,
        help: "Deprecated, use --prevent-sleep. --no-sleep keeps the Mac awake, --sleep lets it sleep."
    )
    var allowsSleep: Bool?

    @Option(
        name: .customLong("archive-format"),
        help: "Download this archive format (xip or aea) instead of choosing automatically, which prefers .xip."
    )
    var archiveFormat: ArchiveFormat?

    @Flag(
        name: .customLong("overwrite"),
        help: "Move an existing archive that cannot be confirmed as the right download to the Trash and download it anew."
    )
    var overwritesExistingFile: Bool = false

    @Flag(name: .customLong("no-verify"), help: "Skip the SHA-1 check of the archive against xcodereleases.com.")
    var skipsVerification: Bool = false

    @Flag(
        name: .customLong("apple-silicon"),
        help: "When a version has separate downloads, take the Apple silicon one. The default follows this Mac."
    )
    var prefersAppleSilicon: Bool = false

    @Flag(
        name: .customLong("universal"),
        help: "When a version has separate downloads, take the Universal one (Apple silicon and Intel)."
    )
    var prefersUniversal: Bool = false

    var architecture: XcodeArchitecture? {
        prefersUniversal ? .universal : prefersAppleSilicon ? .appleSilicon : nil
    }

    mutating func validate() throws {
        guard !(prefersAppleSilicon && prefersUniversal) else {
            throw ValidationError("Use either --apple-silicon or --universal, not both.")
        }
    }

    var disableSleep: Bool {
        preventSleep || allowsSleep == false
    }
}

struct ExtractionOptions: ParsableArguments {
    @Option(
        name: [.long, .short],
        help: "The directory to install the code version in.",
        completion: .directory
    )
    var installationDirectory: URL = .init(fileURLWithPath: "/Applications")

    @Flag(help: .hidden)
    var useSystemUnxip: Bool = false

    func reportDeprecations(to output: TerminalRenderer) {
        if useSystemUnxip {
            output.render(.message("--use-system-unxip is no longer needed: xcinfo always extracts .xip archives with its built-in unxip.", .warning))
        }
    }
}

struct InstallationOptions: ParsableArguments {
    @Argument(
        help: "A version number of an Xcode version or `latest`. Optional with --archive-path, which reads it from the archive.",
        transform: XcodeVersion.init
    )
    var xcodeVersion: XcodeVersion?

    @Option(
        name: [.customLong("archive-path"), .customLong("xip-path")],
        help: "The path to an existing Xcode archive (.xip or .aea). --xip-path is a deprecated alias.",
        completion: .file(extensions: ArchiveFormat.fileExtensions)
    )
    var archiveFile: URL?

    @OptionGroup
    var downloadOptions: DownloadOptions

    @OptionGroup
    var extractionOptions: ExtractionOptions

    @Flag(
        name: [.customLong("preserve-archive"), .customLong("preserve-xip")],
        help: "Keep the downloaded archive after extraction. --preserve-xip is a deprecated alias."
    )
    var shouldPreserveArchive: Bool = false

    @Flag(
        name: [.customLong("no-symlink")],
        help: "Skip creating a symbolic link to `/Applications/Xcode.app`."
    )
    var skipSymlinkCreation: Bool = false

    @Flag(
        name: [.customLong("no-xcode-select")],
        help: "Skip selecting the new Xcode version as the current Command Line Tools."
    )
    var skipXcodeSelection: Bool = false

    mutating func validate() throws {
        if xcodeVersion == nil, archiveFile == nil {
            throw ValidationError("Missing expected argument '<xcode-version>'. Give an Xcode version, or an archive with --archive-path.")
        }
    }
}

extension ArchiveFormat: ExpressibleByArgument {}

extension URL: @retroactive ExpressibleByArgument {
    public init?(argument: String) {
        self.init(fileURLWithPath: argument)
    }

    public var defaultValueDescription: String {
        path
    }

    public static var defaultCompletionKind: CompletionKind {
        .directory
    }
}
