import ArgumentParser
import Foundation
import Testing
@testable import xcinfo
@testable import xcinfoCore

private func parse<Command: ParsableCommand>(_ type: Command.Type, _ arguments: [String]) throws -> Command {
    let command = try XCInfo.parseAsRoot(arguments)
    return try #require(command as? Command)
}

struct CommandLineTests {
    @Test
    func `subcommands are registered`() {
        let names = XCInfo.configuration.subcommands.map { $0._commandName }

        #expect(names == ["cleanup", "download", "extract", "info", "install", "installed", "list", "switch", "tui", "uninstall"])
        #expect(XCInfo.configuration.commandName == "xcinfo")
    }

    @Test
    func `global options default to colors and quiet output`() throws {
        let list = try parse(XCInfo.List.self, ["list"])

        #expect(!list.globals.isVerbose)
        #expect(list.globals.useANSI)
        #expect(!list.globals.isQuiet)
        #expect(!list.globals.isJSON)
        #expect(list.listOptions.updateList)
        #expect(!list.showAllVersions)
        #expect(list.listFilter == nil)
    }

    @Test(arguments: [
        (["list", "-v"], true, true),
        (["list", "--verbose"], true, true),
        (["list", "--no-ansi"], false, false),
        (["list", "--ansi"], false, true),
    ])
    func `global options are parsed`(arguments: [String], isVerbose: Bool, useANSI: Bool) throws {
        let list = try parse(XCInfo.List.self, arguments)

        #expect(list.globals.isVerbose == isVerbose)
        #expect(list.globals.useANSI == useANSI)
    }

    @Test(arguments: [
        (["list", "--all"], true, Core.ListFilter?.none, true),
        (["list", "-a"], true, nil, true),
        (["list", "--only-gm"], false, .onlyGM, true),
        (["list", "--only-releases"], false, .onlyReleases, true),
        (["list", "--no-update-list"], false, nil, false),
        (["list", "--update-list"], false, nil, true),
    ])
    func `list options are parsed`(arguments: [String], showAll: Bool, filter: Core.ListFilter?, updateList: Bool) throws {
        let list = try parse(XCInfo.List.self, arguments)

        #expect(list.showAllVersions == showAll)
        #expect(list.listFilter == filter)
        #expect(list.listOptions.updateList == updateList)
    }

    @Test(arguments: [
        (["list", "-q"], true, false),
        (["list", "--quiet"], true, false),
        (["list", "--json"], false, true),
        (["list", "--quiet", "--json"], true, true),
    ])
    func `output modes are parsed`(arguments: [String], isQuiet: Bool, isJSON: Bool) throws {
        let list = try parse(XCInfo.List.self, arguments)

        #expect(list.globals.isQuiet == isQuiet)
        #expect(list.globals.isJSON == isJSON)
        #expect(list.globals.renderer.options.isQuiet == isQuiet)
        #expect(list.globals.renderer.options.isJSON == isJSON)
    }

    @Test
    func `list filters are exclusive`() {
        #expect(throws: (any Error).self) {
            try XCInfo.parseAsRoot(["list", "--only-gm", "--only-releases"])
        }
    }

    @Test(arguments: [
        ("latest", "latest"),
        ("15.0.1", "15.0.1"),
        ("15A240d", "15A240d"),
    ])
    func `info takes a version`(argument: String, expected: String) throws {
        let info = try parse(XCInfo.Info.self, ["info", argument])

        #expect(info.versionOption.xcodeVersion.description == expected)
        #expect(info.listOptions.updateList)
    }

    @Test(arguments: [["info"], ["download"], ["install"], ["extract"]])
    func `commands that need an argument fail without it`(arguments: [String]) {
        #expect(throws: (any Error).self) {
            try XCInfo.parseAsRoot(arguments)
        }
    }

    @Test
    func `download defaults to the downloads folder`() throws {
        let download = try parse(XCInfo.Download.self, ["download", "15.0"])

        #expect(download.versionOptions.xcodeVersion.description == "15.0")
        #expect(download.downloadOptions.downloadDirectory == URL(fileURLWithPath: "\(NSHomeDirectory())/Downloads").standardizedFileURL)
        #expect(!download.downloadOptions.disableSleep)
        #expect(download.downloadOptions.options.destination == download.downloadOptions.downloadDirectory)
    }

    @Test(arguments: [
        ["download", "15.0", "-d", "/tmp/xcinfo-downloads"],
        ["download", "15.0", "--download-directory", "/tmp/xcinfo-downloads"],
    ])
    func `download directory is parsed`(arguments: [String]) throws {
        let download = try parse(XCInfo.Download.self, arguments)

        #expect(download.downloadOptions.downloadDirectory.path == "/tmp/xcinfo-downloads")
    }

    @Test
    func `no verify turns off the checksum for download and install`() throws {
        let verified = try parse(XCInfo.Download.self, ["download", "15.0"])
        let download = try parse(XCInfo.Download.self, ["download", "15.0", "--no-verify"])
        let install = try parse(XCInfo.Install.self, ["install", "15.0", "--no-verify"])

        #expect(verified.downloadOptions.options.verifiesChecksum)
        #expect(!download.downloadOptions.options.verifiesChecksum)
        #expect(!install.installationOptions.downloadOptions.options.verifiesChecksum)
    }

    @Test
    func `no sleep keeps the system awake`() throws {
        let noSleep = try parse(XCInfo.Download.self, ["download", "15.0", "--no-sleep"])
        let sleep = try parse(XCInfo.Download.self, ["download", "15.0", "--sleep"])

        let preventSleep = try parse(XCInfo.Download.self, ["download", "15.0", "--prevent-sleep"])

        #expect(noSleep.downloadOptions.options.disableSleep)
        #expect(!sleep.downloadOptions.options.disableSleep)
        #expect(preventSleep.downloadOptions.options.disableSleep)
    }

    @Test
    func `install defaults`() throws {
        let install = try parse(XCInfo.Install.self, ["install", "latest"])
        let options = install.installationOptions

        #expect(options.xcodeVersion?.description == "latest")
        #expect(options.archiveFile == nil)
        #expect(options.extractionOptions.installationDirectory == URL(fileURLWithPath: "/Applications"))
        #expect(!options.extractionOptions.useSystemUnxip)
        #expect(!options.shouldPreserveArchive)
        #expect(!options.skipSymlinkCreation)
        #expect(!options.skipXcodeSelection)
        #expect(install.listOptions.updateList)
    }

    @Test
    func `install options are parsed`() throws {
        let install = try parse(XCInfo.Install.self, [
            "install", "15.0",
            "--xip-path", "/tmp/Xcode.xip",
            "-i", "/tmp/Apps",
            "-d", "/tmp/Downloads",
            "--use-system-unxip",
            "--preserve-xip",
            "--no-symlink",
            "--no-xcode-select",
            "--no-update-list",
        ])
        let options = install.installationOptions

        #expect(options.archiveFile?.path == "/tmp/Xcode.xip")
        #expect(options.extractionOptions.installationDirectory.path == "/tmp/Apps")
        #expect(options.downloadOptions.downloadDirectory.path == "/tmp/Downloads")
        #expect(options.extractionOptions.useSystemUnxip)
        #expect(options.extractionOptions.options.destination.path == "/tmp/Apps")
        #expect(options.shouldPreserveArchive)
        #expect(options.skipSymlinkCreation)
        #expect(options.skipXcodeSelection)
        #expect(!install.listOptions.updateList)
    }

    @Test(arguments: [
        ["--archive-path", "/tmp/Xcode.aea", "--preserve-archive"],
        ["--xip-path", "/tmp/Xcode.aea", "--preserve-xip"],
    ])
    func `archive options accept the new names and the deprecated xip names`(arguments: [String]) throws {
        let options = try parse(XCInfo.Install.self, ["install", "15.0"] + arguments).installationOptions

        #expect(options.archiveFile?.path == "/tmp/Xcode.aea")
        #expect(options.shouldPreserveArchive)
    }

    @Test
    func `install takes the version from the archive when none is given`() throws {
        let options = try parse(XCInfo.Install.self, ["install", "--archive-path", "/tmp/Xcode.aea"]).installationOptions

        #expect(options.xcodeVersion == nil)
        #expect(options.archiveFile?.path == "/tmp/Xcode.aea")
        #expect(throws: (any Error).self) { try parse(XCInfo.Install.self, ["install"]) }
    }

    @Test
    func `the archive format can be chosen for download and install`() throws {
        #expect(try parse(XCInfo.Download.self, ["download", "15.0"]).downloadOptions.options.archiveFormat == nil)
        #expect(try parse(XCInfo.Download.self, ["download", "15.0", "--archive-format", "aea"]).downloadOptions.options.archiveFormat == .aea)
        #expect(try parse(XCInfo.Install.self, ["install", "15.0", "--archive-format", "xip"]).installationOptions.downloadOptions.options.archiveFormat == .xip)
        #expect(throws: (any Error).self) { try parse(XCInfo.Download.self, ["download", "15.0", "--archive-format", "dmg"]) }
    }

    @Test
    func `use system unxip is still accepted but hidden`() throws {
        #expect(try parse(XCInfo.Extract.self, ["extract", "/tmp/Xcode.xip", "--use-system-unxip"]).extractionOptions.useSystemUnxip)
        #expect(!XCInfo.Extract.helpMessage().contains("use-system-unxip"))
    }

    @Test
    func `install accepts the long installation directory option`() throws {
        let install = try parse(XCInfo.Install.self, ["install", "15.0", "--installation-directory", "/tmp/Apps"])

        #expect(install.installationOptions.extractionOptions.installationDirectory.path == "/tmp/Apps")
    }

    @Test
    func `extract takes a source and extraction options`() throws {
        let extract = try parse(XCInfo.Extract.self, ["extract", "/tmp/Xcode.xip", "-i", "/tmp/Apps", "--use-system-unxip"])

        #expect(extract.source.path == "/tmp/Xcode.xip")
        #expect(extract.extractionOptions.installationDirectory.path == "/tmp/Apps")
        #expect(extract.extractionOptions.useSystemUnxip)
    }

    @Test
    func `installed takes list options`() throws {
        let installed = try parse(XCInfo.Installed.self, ["installed", "--no-update-list", "-v"])

        #expect(!installed.listOptions.updateList)
        #expect(installed.globals.isVerbose)
    }

    @Test(arguments: [
        (["uninstall"], String?.none),
        (["uninstall", "15.0"], "15.0"),
        (["uninstall", "15.0 Beta 2"], "15.0 Beta 2"),
    ])
    func `uninstall takes an optional version`(arguments: [String], version: String?) throws {
        #expect(try !parse(XCInfo.Uninstall.self, arguments).deletePermanently)
        #expect(try parse(XCInfo.Uninstall.self, arguments + ["--delete-permanently"]).deletePermanently)
        let uninstall = try parse(XCInfo.Uninstall.self, arguments)

        #expect(uninstall.xcodeVersion == version)
    }

    @Test
    func `cleanup takes only global options`() throws {
        let cleanup = try parse(XCInfo.Cleanup.self, ["cleanup", "--no-ansi"])

        #expect(!cleanup.globals.useANSI)
        #expect(throws: (any Error).self) {
            try XCInfo.parseAsRoot(["cleanup", "--all"])
        }
    }

    @Test
    func `unknown subcommands and options are rejected`() {
        #expect(throws: (any Error).self) {
            try XCInfo.parseAsRoot(["upgrade"])
        }
        #expect(throws: (any Error).self) {
            try XCInfo.parseAsRoot(["list", "--everything"])
        }
    }

    @Test
    func `urls are parsed from file paths`() throws {
        let url = try #require(URL(argument: "/tmp/some folder/Xcode.xip"))

        #expect(url.path == "/tmp/some folder/Xcode.xip")
        #expect(URL(fileURLWithPath: "/Applications").defaultValueDescription == "/Applications")
    }
}
