import Foundation
import Testing
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.
@testable import xcinfoCore

private func isCoreError(_ error: any Error, _ predicate: (CoreError) -> Bool) -> Bool {
    guard let coreError = error as? CoreError else { return false }
    return predicate(coreError)
}

struct CoreInfoTests {
    private let xcode = Xcode(
        version: Version("15A240d", "15.0", .release),
        date: (2023, 9, 18),
        requires: "13.5",
        sdks: SDKs(macOS: Version("23A334")),
        compilers: Compilers(swift: Version("5.9.0.128.108", "5.9")),
        links: Links(
            download: Link("https://download.example.invalid/Xcode_15.xip"),
            notes: Link("https://notes.example.invalid/15")
        )
    )

    @Test
    func `info prints the version details`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let logs = LogRecorder()
        let xcodes = [xcode]
        let core = Core.test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            applicationsDirectory: applications.url
        )

        try await core.info(version: .version("15.0"), shouldUpdate: true)

        let messages = logs.messages
        #expect(Array(messages.prefix(4)) == [
            "\nIdentifying",
            "Found matching Xcode 15.0 (15A240d).",
            "\nVersion info",
            "15.0 (15A240d)",
        ])
        #expect(messages[4].hasPrefix("Release date: September 18, 2023 ("))
        #expect(Array(messages.dropFirst(5)) == [
            "Requires macOS 13.5",
            "\nSDKs",
            "macOS SDK: 23A334",
            "\nCompilers",
            "swift 5.9: 5.9.0.128.108",
            "\nLinks",
            "Download:      https://download.example.invalid/Xcode_15.xip",
            "Release Notes: https://notes.example.invalid/15",
        ])
    }

    @Test
    func `info without links stops after the compilers`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let logs = LogRecorder()
        let xcodes = [Xcode(version: Version("15A240d", "15.0", .release), date: (2023, 9, 18), requires: "13.5")]
        let core = Core.test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            applicationsDirectory: applications.url
        )

        try await core.info(version: .version("15A240d"), shouldUpdate: true)

        #expect(logs.messages.last == "Requires macOS 13.5")
    }

    @Test
    func `info without updating the list uses the cache`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        try JSONEncoder().encode([xcode]).write(to: caches.url.appendingPathComponent("xcinfo.json"))
        let logs = LogRecorder()
        let core = Core.test(logs: logs, cachesDirectory: caches.url, applicationsDirectory: applications.url)

        try await core.info(version: .version("15.0"), shouldUpdate: false)

        #expect(logs.messages.contains("15.0 (15A240d)"))
    }

    @Test
    func `latest is the first version of the list`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let logs = LogRecorder()
        let xcodes = [Xcode.fixture("14.0", build: "14A1"), .fixture("16.0", build: "16A1")]
        let core = Core.test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            applicationsDirectory: applications.url
        )

        try await core.info(version: .latest, shouldUpdate: true)

        #expect(logs.messages.contains("Found matching Xcode 14.0 (14A1)."))
    }

    @Test
    func `several matching versions let the user choose`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let logs = LogRecorder()
        let prompt = FakePrompt(choices: [1])
        let xcodes = [
            Xcode.fixture("15.0", build: "15A240d"),
            .fixture("15.0.1", build: "15A507"),
            .fixture("14.0", build: "14A1"),
        ]
        let core = Core.test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            prompt: prompt,
            applicationsDirectory: applications.url
        )

        try await core.info(version: .version("15"), shouldUpdate: true)

        #expect(prompt.chosen.values == [["15.0 (15A240d)", "15.0.1 (15A507)"]])
        #expect(logs.messages.contains("Found multiple possibilities for the requested version '15'."))
        #expect(logs.messages.contains("15.0.1 (15A507)"))
    }

    @Test
    func `build numbers select a version`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let logs = LogRecorder()
        let xcodes = [Xcode.fixture("15.0", build: "15A240d"), .fixture("14.0", build: "14A309")]
        let core = Core.test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            applicationsDirectory: applications.url
        )

        try await core.info(version: .version("14A3"), shouldUpdate: true)

        #expect(logs.messages.contains("Found matching Xcode 14.0 (14A309)."))
    }

    @Test(arguments: [
        XcodeVersion.version("99"),
        .version("nothing"),
    ])
    func `unknown versions are not found`(version: XcodeVersion) async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xcodes = [Xcode.fixture("15.0", build: "15A240d")]
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            applicationsDirectory: applications.url
        )

        await #expect {
            try await core.info(version: version, shouldUpdate: true)
        } throws: { error in
            isCoreError(error) { if case .versionNotFound = $0 { true } else { false } }
        }
    }

    @Test
    func `an empty list finds no version`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let core = Core.test(logs: LogRecorder(), cachesDirectory: caches.url, listXcodes: { [] }, applicationsDirectory: applications.url)

        await #expect {
            try await core.info(version: .latest, shouldUpdate: true)
        } throws: { error in
            isCoreError(error) { if case .versionNotFound = $0 { true } else { false } }
        }
    }
}

struct CoreDownloadTests {
    private let xcode = Xcode.fixture("15.0", build: "15A240d", download: "https://download.example.invalid/Xcode_15.xip")

    @Test
    func `download signs in and downloads to the destination`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let downloads = try TemporaryDirectory()
        let logs = LogRecorder()
        let credentials = Recorder<String>()
        let downloadCalls = Recorder<String>()
        let xcodes = [xcode]
        let core = Core.test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            getCredentials: { Credentials(username: "appleid@example.invalid", password: "secret") },
            authenticate: { credentials.append("\($0.username):\($0.password)") },
            download: { url, destination, disableSleep in
                downloadCalls.append("\(url.absoluteString) \(destination.path) \(disableSleep)")
                return destination.appendingPathComponent("Xcode_15.xip")
            },
            applicationsDirectory: applications.url
        )

        let (downloaded, url) = try await core.download(
            version: .version("15.0"),
            options: .init(destination: downloads.url, disableSleep: true),
            updateVersionList: true
        )

        #expect(downloaded.version.build == "15A240d")
        #expect(url == downloads.url.appendingPathComponent("Xcode_15.xip"))
        #expect(credentials.values == ["appleid@example.invalid:secret"])
        #expect(downloadCalls.values == ["https://download.example.invalid/Xcode_15.xip \(downloads.url.path) true"])
        #expect(logs.messages.contains("\nSign in to Apple Developer"))
        #expect(logs.messages.contains("\nDownloading"))
        #expect(logs.messages.last == "Download to \(downloads.url.path) complete.")
    }

    @Test
    func `versions without a download link cannot be downloaded`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xcodes = [Xcode.fixture("15.0", build: "15A240d", download: nil)]
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            authenticate: { _ in Issue.record("Must not sign in") },
            applicationsDirectory: applications.url
        )

        await #expect {
            try await core.download(version: .latest, options: .init(destination: caches.url, disableSleep: false), updateVersionList: true)
        } throws: { error in
            isCoreError(error) { if case .invalidDownloadURL = $0 { true } else { false } }
        }
    }

    @Test
    func `failed sign in is reported as an authentication failure`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xcodes = [xcode]
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            getCredentials: { Credentials(username: "user", password: "secret") },
            authenticate: { _ in throw AuthenticationError() },
            download: { _, _, _ in
                Issue.record("Must not download")
                return URL(fileURLWithPath: "/")
            },
            applicationsDirectory: applications.url
        )

        await #expect {
            try await core.download(version: .latest, options: .init(destination: caches.url, disableSleep: false), updateVersionList: true)
        } throws: { error in
            isCoreError(error) { if case .authenticationFailed = $0 { true } else { false } }
        }
    }

    @Test
    func `missing credentials are passed on`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xcodes = [xcode]
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            getCredentials: { throw CredentialsError.invalidPassword },
            applicationsDirectory: applications.url
        )

        await #expect(throws: CredentialsError.self) {
            try await core.download(version: .latest, options: .init(destination: caches.url, disableSleep: false), updateVersionList: true)
        }
    }

    @Test(arguments: [
        XCAPIError.downloadInterrupted,
        .couldNotMoveToTemporaryFile,
        .timeout,
    ])
    func `download errors are reported with their description`(apiError: XCAPIError) async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xcodes = [xcode]
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            getCredentials: { Credentials(username: "user", password: "secret") },
            authenticate: { _ in },
            download: { _, _, _ in throw apiError },
            applicationsDirectory: applications.url
        )

        await #expect {
            try await core.download(version: .latest, options: .init(destination: caches.url, disableSleep: false), updateVersionList: true)
        } throws: { error in
            isCoreError(error) { if case let .downloadFailed(description) = $0 { description == apiError.description } else { false } }
        }
    }
}

struct CoreInstallTests {
    private let xcode = Xcode.fixture("15.0", build: "15A240d")

    private func core(
        logs: LogRecorder,
        caches: TemporaryDirectory,
        applications: TemporaryDirectory,
        shell: FakeShell = FakeShell(),
        prompt: FakePrompt = FakePrompt(passwords: ["sudo-password"]),
        extractions: Recorder<String> = Recorder(),
        revealed: Recorder<URL> = Recorder(),
        download: (@Sendable (URL, URL, Bool) async throws -> URL)? = nil
    ) -> Core {
        let xcodes = [xcode]
        return .test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            getCredentials: { Credentials(username: "user", password: "secret") },
            authenticate: { _ in },
            download: download,
            extract: { source, destination, filename, useLegacyUnxip in
                extractions.append("\(source.lastPathComponent) \(destination.path) \(filename ?? "-") \(useLegacyUnxip)")
                return destination.appendingPathComponent(filename ?? "Xcode.app")
            },
            shell: shell,
            prompt: prompt,
            applicationsDirectory: applications.url,
            revealInFinder: { revealed.append($0) }
        )
    }

    private func options(
        xip: URL?,
        destination: URL,
        useLegacyUnxip: Bool = false,
        skipSymlinkCreation: Bool = false,
        skipXcodeSelection: Bool = false,
        shouldPreserveXIP: Bool = false
    ) -> Core.InstallationOptions {
        Core.InstallationOptions(
            version: .version("15.0"),
            xipFile: xip,
            downloadOptions: .init(destination: destination, disableSleep: false),
            extractionOptions: .init(destination: destination, useLegacyUnxip: useLegacyUnxip),
            skipSymlinkCreation: skipSymlinkCreation,
            skipXcodeSelection: skipXcodeSelection,
            shouldPreserveXIP: shouldPreserveXIP
        )
    }

    @Test
    func `install extracts, verifies, configures and selects the xcode`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let downloads = try TemporaryDirectory()
        let xip = try downloads.file("Xcode_15.xip")
        let logs = LogRecorder()
        let shell = FakeShell()
        let extractions = Recorder<String>()
        let revealed = Recorder<URL>()
        let core = core(
            logs: logs,
            caches: caches,
            applications: applications,
            shell: shell,
            extractions: extractions,
            revealed: revealed
        )

        try await core.install(
            options: options(xip: xip, destination: applications.url, useLegacyUnxip: true, shouldPreserveXIP: true),
            updateVersionList: true
        )

        let app = applications.url.appendingPathComponent("Xcode_15.0.app")
        #expect(extractions.values == ["Xcode_15.xip \(applications.url.path) Xcode_15.0.app true"])
        #expect(shell.calls.values == [
            ShellCall(command: "/usr/sbin/spctl", args: ["--assess", "--verbose", "--type", "execute", app.path], password: nil),
            ShellCall(command: "/usr/bin/codesign", args: ["--verify", "--verbose", app.path], password: nil),
            ShellCall(command: "ls", args: [], password: "sudo-password"),
            ShellCall(command: "/usr/sbin/DevToolsSecurity", args: ["-enable"], password: "sudo-password"),
            ShellCall(command: "/usr/sbin/dseditgroup", args: ["-o", "edit", "-t", "group", "-a", "staff", "_developer"], password: "sudo-password"),
            ShellCall(command: "\(app.path)/Contents/Developer/usr/bin/xcodebuild", args: ["-license", "accept"], password: "sudo-password"),
            ShellCall(command: "\(app.path)/Contents/Developer/usr/bin/xcodebuild", args: ["-runFirstLaunch"], password: "sudo-password"),
            ShellCall(command: "xcode-select", args: ["-s", app.path], password: "sudo-password"),
        ])
        let symlink = applications.url.appendingPathComponent("Xcode.app")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path) == app.path)
        #expect(revealed.values == [app])
        #expect(FileManager.default.fileExists(atPath: xip.path))
        #expect(logs.messages.last == "Installed Xcode to \(app.path)")
    }

    @Test
    func `install can skip the symlink and the selection`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xip = try caches.file("Xcode_15.xip")
        let shell = FakeShell()
        let core = core(logs: LogRecorder(), caches: caches, applications: applications, shell: shell)

        try await core.install(
            options: options(xip: xip, destination: applications.url, skipSymlinkCreation: true, skipXcodeSelection: true, shouldPreserveXIP: true),
            updateVersionList: true
        )

        #expect(!FileManager.default.fileExists(atPath: applications.url.appendingPathComponent("Xcode.app").path))
        #expect(!shell.calls.values.contains { $0.command == "xcode-select" })
    }

    @Test
    func `install replaces an existing symlink`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xip = try caches.file("Xcode_15.xip")
        let previous = try applications.directory("Xcode_14.app")
        let symlink = applications.url.appendingPathComponent("Xcode.app")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: previous)
        let core = core(logs: LogRecorder(), caches: caches, applications: applications)

        try await core.install(options: options(xip: xip, destination: applications.url, shouldPreserveXIP: true), updateVersionList: true)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path) == applications.url.appendingPathComponent("Xcode_15.0.app").path)
        #expect(FileManager.default.fileExists(atPath: previous.path))
    }

    @Test
    func `install moves an existing xcode out of the way of the symlink`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xip = try caches.file("Xcode_15.xip")
        let existing = try applications.fakeXcode(named: "Xcode.app", build: "15A240d")
        let core = core(
            logs: LogRecorder(),
            caches: caches,
            applications: applications,
            shell: .installedXcodes([existing])
        )

        try await core.install(options: options(xip: xip, destination: caches.url, shouldPreserveXIP: true), updateVersionList: true)

        let moved = applications.url.appendingPathComponent("Xcode_15.0.app")
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("Contents/version.plist").path))
        #expect(FileManager.default.isSymbolicLink(atPath: existing.path))
    }

    @Test
    func `install keeps a downloaded archive only when asked`() async throws {
        for shouldPreserveXIP in [true, false] {
            let caches = try TemporaryDirectory()
            let applications = try TemporaryDirectory()
            let downloads = try TemporaryDirectory()
            let archive = downloads.url.appendingPathComponent("Xcode_15.xip")
            let core = core(
                logs: LogRecorder(),
                caches: caches,
                applications: applications,
                download: { _, destination, _ in
                    let url = destination.appendingPathComponent("Xcode_15.xip")
                    try Data("xip".utf8).write(to: url)
                    return url
                }
            )

            try await core.install(
                options: options(xip: nil, destination: downloads.url, shouldPreserveXIP: shouldPreserveXIP),
                updateVersionList: true
            )

            #expect(FileManager.default.fileExists(atPath: archive.path) == shouldPreserveXIP)
        }
    }

    @Test
    func `install never deletes an archive the user passed in`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xip = try caches.file("Users-own.xip")
        let core = core(logs: LogRecorder(), caches: caches, applications: applications)

        try await core.install(options: options(xip: xip, destination: applications.url, shouldPreserveXIP: false), updateVersionList: true)

        #expect(FileManager.default.fileExists(atPath: xip.path))
    }

    @Test
    func `install asks for the password three times`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xip = try caches.file("Xcode_15.xip")
        let prompt = FakePrompt(passwords: ["one", "two", "three"])
        let shell = FakeShell { call in call.command == "ls" ? (1, "", "") : (0, "", "") }
        let core = core(logs: LogRecorder(), caches: caches, applications: applications, shell: shell, prompt: prompt)

        await #expect {
            try await core.install(options: options(xip: xip, destination: applications.url, shouldPreserveXIP: true), updateVersionList: true)
        } throws: { error in
            isCoreError(error) { if case .incorrectSuperUserPassword = $0 { true } else { false } }
        }
        #expect(prompt.secrets.values == ["Please enter your password:", "Sorry, try again:", "Sorry, try again:"])
        #expect(shell.privilegedCalls.map(\.password) == ["one", "two", "three"])
    }

    @Test
    func `install accepts the password on a later attempt`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xip = try caches.file("Xcode_15.xip")
        let prompt = FakePrompt(passwords: ["wrong", "right"])
        let shell = FakeShell { call in call.password == "wrong" ? (1, "", "") : (0, "", "") }
        let core = core(logs: LogRecorder(), caches: caches, applications: applications, shell: shell, prompt: prompt)

        try await core.install(options: options(xip: xip, destination: applications.url, shouldPreserveXIP: true), updateVersionList: true)

        #expect(shell.privilegedCalls.dropFirst(2).allSatisfy { $0.password == "right" })
    }

    @Test(arguments: [
        ("/usr/sbin/spctl", "gatekeeper"),
        ("/usr/bin/codesign", "codesign"),
    ])
    func `install stops when the verification fails`(command: String, kind: String) async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xip = try caches.file("Xcode_15.xip")
        let prompt = FakePrompt()
        let shell = FakeShell { call in call.command == command ? (3, "", "") : (0, "", "") }
        let core = core(logs: LogRecorder(), caches: caches, applications: applications, shell: shell, prompt: prompt)

        await #expect {
            try await core.install(options: options(xip: xip, destination: applications.url, shouldPreserveXIP: true), updateVersionList: true)
        } throws: { error in
            isCoreError(error) {
                switch $0 {
                case .gatekeeperVerificationFailed: kind == "gatekeeper"
                case .codesignVerificationFailed: kind == "codesign"
                default: false
                }
            }
        }
        #expect(prompt.secrets.values.isEmpty)
    }

    @Test(arguments: [
        "/usr/sbin/DevToolsSecurity",
        "/usr/sbin/dseditgroup",
        "xcode-select",
    ])
    func `install fails when a privileged step fails`(command: String) async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xip = try caches.file("Xcode_15.xip")
        let shell = FakeShell { call in call.command == command ? (1, "", "") : (0, "", "") }
        let core = core(logs: LogRecorder(), caches: caches, applications: applications, shell: shell)

        await #expect {
            try await core.install(options: options(xip: xip, destination: applications.url, shouldPreserveXIP: true), updateVersionList: true)
        } throws: { error in
            isCoreError(error) { if case .installationFailed = $0 { true } else { false } }
        }
    }

    @Test
    func `install fails when xcodebuild fails`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xip = try caches.file("Xcode_15.xip")
        let shell = FakeShell { call in call.args == ["-license", "accept"] ? (1, "", "") : (0, "", "") }
        let core = core(logs: LogRecorder(), caches: caches, applications: applications, shell: shell)

        await #expect {
            try await core.install(options: options(xip: xip, destination: applications.url, shouldPreserveXIP: true), updateVersionList: true)
        } throws: { error in
            isCoreError(error) { if case .installationFailed = $0 { true } else { false } }
        }
    }
}

struct CoreExtractTests {
    @Test(arguments: ["Xcode.xip", "Xcode.XIP"])
    func `extract passes the archive to the extractor`(name: String) async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.file(name)
        let logs = LogRecorder()
        let extractions = Recorder<String>()
        let core = Core.test(
            logs: logs,
            isVerbose: true,
            cachesDirectory: directory.url,
            extract: { source, destination, filename, useLegacyUnxip in
                extractions.append("\(source.lastPathComponent) \(filename ?? "-") \(useLegacyUnxip)")
                return destination.appendingPathComponent("Xcode.app")
            },
            applicationsDirectory: directory.url
        )

        let application = try await core.extractXIP(source: source, options: .init(destination: directory.url))

        #expect(application == nil)
        #expect(extractions.values == ["\(name) - false"])
        #expect(logs.messages.first == "\nExtracting")
        #expect(logs.messages.contains("XIP successfully extracted to \(directory.url.appendingPathComponent("Xcode.app").path)"))
        #expect(logs.messages.last?.hasPrefix("Extraction time: ") == true)
    }

    @Test
    func `extracting for an xcode returns the application`() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.file("Xcode.xip")
        let core = Core.test(logs: LogRecorder(), cachesDirectory: directory.url, extract: { _, destination, filename, _ in destination.appendingPathComponent(filename ?? "Xcode.app") }, applicationsDirectory: directory.url)

        let application = try await core.extractXIP(
            source: source,
            options: .init(destination: directory.url),
            xcode: .fixture("15.0", build: "15A240d")
        )

        #expect(application?.url == directory.url.appendingPathComponent("Xcode_15.0.app"))
        #expect(application?.xcode.version.build == "15A240d")
    }

    @Test(arguments: ["Xcode.dmg", "Xcode", "Xcode.xip.zip"])
    func `only xip archives can be extracted`(name: String) async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.file(name)
        let core = Core.test(logs: LogRecorder(), cachesDirectory: directory.url, applicationsDirectory: directory.url)

        await #expect {
            try await core.extractXIP(source: source, options: .init(destination: directory.url))
        } throws: { error in
            isCoreError(error) { if case let .unsupportedFile(fileExtension) = $0 { fileExtension == source.pathExtension } else { false } }
        }
    }

    @Test
    func `extraction errors are wrapped`() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.file("Xcode.xip")
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: directory.url,
            extract: { _, _, _, _ in throw Extractor.ExtractionError("broken") },
            applicationsDirectory: directory.url
        )

        await #expect {
            try await core.extractXIP(source: source, options: .init(destination: directory.url))
        } throws: { error in
            isCoreError(error) { if case let .extractionFailed(underlying) = $0 { underlying.localizedDescription == "broken" } else { false } }
        }
    }
}

struct CoreUninstallTests {
    private let xcodes = [
        Xcode.fixture("16.0", build: "16A1"),
        .fixture("15.0", build: "15A1", release: .beta(2)),
        .fixture("15.0", build: "15A2"),
    ]

    @Test
    func `uninstall removes the confirmed xcode`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let app16 = try applications.fakeXcode(named: "Xcode-16.app", build: "16A1")
        let app15 = try applications.fakeXcode(named: "Xcode-15.app", build: "15A2")
        let logs = LogRecorder()
        let prompt = FakePrompt(agree: true)
        let xcodes = xcodes
        let core = Core.test(
            logs: logs,
            isVerbose: true,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            shell: .installedXcodes([app16, app15]),
            prompt: prompt,
            applicationsDirectory: applications.url
        )

        try await core.uninstall("16", updateVersionList: true)

        #expect(!FileManager.default.fileExists(atPath: app16.path))
        #expect(FileManager.default.fileExists(atPath: app15.path))
        #expect(prompt.agreed.values == ["Are you sure you want to uninstall Xcode 16.0 (16A1)?"])
        #expect(logs.messages.last == "16.0 (16A1) uninstalled!")
    }

    @Test
    func `uninstall keeps the xcode when not confirmed`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let app = try applications.fakeXcode(named: "Xcode-16.app", build: "16A1")
        let logs = LogRecorder()
        let xcodes = xcodes
        let core = Core.test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            shell: .installedXcodes([app]),
            prompt: FakePrompt(agree: false),
            applicationsDirectory: applications.url
        )

        try await core.uninstall("16a1", updateVersionList: true)

        #expect(FileManager.default.fileExists(atPath: app.path))
        #expect(logs.messages.last == "kthxbye")
    }

    @Test
    func `uninstall lets the user choose between several matches`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let beta = try applications.fakeXcode(named: "Xcode-beta.app", build: "15A1")
        let release = try applications.fakeXcode(named: "Xcode-15.app", build: "15A2")
        let prompt = FakePrompt(choices: [1], agree: true)
        let xcodes = xcodes
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            shell: .installedXcodes([beta, release]),
            prompt: prompt,
            applicationsDirectory: applications.url
        )

        try await core.uninstall(nil, updateVersionList: true)

        let choices = try #require(prompt.chosen.values.first)
        #expect(choices.count == 2)
        #expect(choices.allSatisfy { $0.contains(applications.url.path) })
        let removed = [beta, release].filter { !FileManager.default.fileExists(atPath: $0.path) }
        #expect(removed.count == 1)
    }

    @Test
    func `uninstall matches beta versions`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let beta = try applications.fakeXcode(named: "Xcode-beta.app", build: "15A1")
        let release = try applications.fakeXcode(named: "Xcode-15.app", build: "15A2")
        let xcodes = xcodes
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            shell: .installedXcodes([beta, release]),
            prompt: FakePrompt(agree: true),
            applicationsDirectory: applications.url
        )

        try await core.uninstall("15.0 beta 2", updateVersionList: true)

        #expect(!FileManager.default.fileExists(atPath: beta.path))
        #expect(FileManager.default.fileExists(atPath: release.path))
    }

    @Test
    func `uninstall fails when nothing matches`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let app = try applications.fakeXcode(named: "Xcode-16.app", build: "16A1")
        let xcodes = xcodes
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            shell: .installedXcodes([app]),
            applicationsDirectory: applications.url
        )

        await #expect {
            try await core.uninstall("13", updateVersionList: true)
        } throws: { error in
            isCoreError(error) { if case let .uninstallationFailed(message) = $0 { message == "No matching Xcode version found." } else { false } }
        }
    }

    @Test
    func `uninstall fails without known releases`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let core = Core.test(logs: LogRecorder(), cachesDirectory: caches.url, listXcodes: { [] }, applicationsDirectory: applications.url)

        await #expect {
            try await core.uninstall(nil, updateVersionList: true)
        } throws: { error in
            isCoreError(error) { if case let .uninstallationFailed(message) = $0 { message == "No Xcode releases found." } else { false } }
        }
    }
}

struct CoreCleanupTests {
    @Test
    func `cleanup removes credentials, sessions and cookies`() throws {
        let directory = try TemporaryDirectory()
        let logs = LogRecorder()
        let calls = Recorder<String>()
        let core = Core.test(
            logs: logs,
            cachesDirectory: directory.url,
            removeCookies: { calls.append("cookies") },
            cleanupCredentials: { calls.append("credentials") },
            cleanupAuthentication: { calls.append("authentication") },
            applicationsDirectory: directory.url
        )

        core.cleanup()

        #expect(calls.values == ["credentials", "authentication", "cookies"])
        #expect(logs.messages == ["\nCleanup", "", "Removed stored cookies."])
    }
}

struct CoreErrorTests {
    @Test
    func `errors describe what went wrong`() {
        let url = URL(fileURLWithPath: "/tmp/Xcode.app")

        #expect(CoreError.authenticationFailed.errorDescription == "Authentication with Apple failed.")
        #expect(CoreError.downloadFailed("broken").errorDescription == "broken")
        #expect(CoreError.uninstallationFailed("nope").errorDescription == "nope")
        #expect(CoreError.versionNotFound(.version("1.0")).errorDescription == "No Xcode found for given version '1.0'.")
        #expect(CoreError.invalidDownloadURL.errorDescription == "Invalid download url")
        #expect(CoreError.unsupportedFile("dmg").errorDescription == "'dmg' is not supported.")
        #expect(CoreError.installationFailed.errorDescription == "Xcode could not be installed.")
        #expect(CoreError.gatekeeperVerificationFailed(url).errorDescription == "Gatekeeper could not verify Xcode at /tmp/Xcode.app")
        #expect(CoreError.codesignVerificationFailed(url).errorDescription == "Code sign could not verify Xcode at /tmp/Xcode.app")
        #expect(CoreError.incorrectSuperUserPassword.errorDescription == "")
        #expect(CoreError.invalidExtractionOutputURL(url).errorDescription == "Failed to access output directory at /tmp/Xcode.app.")
        #expect(CoreError.extractionFailed(Extractor.ExtractionError("inner")).errorDescription == "inner")
    }

    @Test
    func `api errors describe what went wrong`() {
        let source = URL(fileURLWithPath: "/tmp/a.xip")
        let destination = URL(fileURLWithPath: "/tmp/b.xip")
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedFailureReasonErrorKey: "Disk full"])

        #expect(XCAPIError.invalidResponse.description == "Invalid response")
        #expect(XCAPIError.invalidCache.description == "Invalid cache file")
        #expect(XCAPIError.versionNotFound.description == "Version not found")
        #expect(XCAPIError.downloadInterrupted.description == "Download was interrupted")
        #expect(XCAPIError.recoverableDownloadError(url: source, resumeData: Data()).description == "Download failed")
        #expect(XCAPIError.couldNotMoveToTemporaryFile.description == "Could not move downloaded file into temporary directory")
        #expect(XCAPIError.couldNotMoveToDestinationFolder(source, destination, error).description == "Could not move downloaded file from /tmp/a.xip to /tmp/b.xip. Disk full)")
        #expect(XCAPIError.timeout.description == "The request timed out")
    }
}
