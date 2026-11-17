//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Dependencies
import OlympUs
import Foundation
import XCIFoundation
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.

public enum CoreError: LocalizedError, Sendable {
    case authenticationFailed
    case signInFailed(String)
    case downloadFailed(String)
    case versionNotFound(XcodeVersion)
    case invalidDownloadURL
    case extractionFailed(Error)
    case unsupportedFile(String)
    case installationFailed
    case gatekeeperVerificationFailed(URL)
    case codesignVerificationFailed(URL)
    case incorrectSuperUserPassword
    case uninstallationFailed(String)
    case invalidExtractionOutputURL(URL)
    case checksumMismatch(file: URL, expected: String, actual: String)
    case versionRequired
    case destinationExists(URL, reason: String)
    case archiveFormatNotOffered(ArchiveFormat, offered: [String])
    case unknownArchiveVersion(String?)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Authentication with Apple failed."
        case let .signInFailed(reason):
            return reason
        case let .downloadFailed(description), let .uninstallationFailed(description):
            return description
        case .invalidDownloadURL:
            return "Invalid download url"
        case let .versionNotFound(version):
            return "No Xcode found for given version '\(version)'."
        case let .extractionFailed(error):
            return error.localizedDescription
        case let .unsupportedFile(name):
            return "\(name) is not a .xip or .aea archive."
        case .installationFailed:
            return "Xcode could not be installed."
        case let .gatekeeperVerificationFailed(url):
            return "Gatekeeper could not verify Xcode at \(url.path)"
        case let .codesignVerificationFailed(url):
            return "Code sign could not verify Xcode at \(url.path)"
        case .incorrectSuperUserPassword:
            return "The administrator password was rejected three times."
        case .invalidExtractionOutputURL(let output):
            return "Failed to access output directory at \(output.path)."
        case let .archiveFormatNotOffered(format, offered):
            return "Apple does not offer this version as .\(format.rawValue)\(offered.isEmpty ? "." : ", only as \(offered.joined(separator: ", ")).") Run the command without --archive-format to take what is offered."
        case let .destinationExists(url, reason):
            return "\(url.path) already exists, and \(reason). Move or delete it, or run the command again with --overwrite to move it to the Trash and download anew."
        case .versionRequired:
            return "Give an Xcode version, or an archive with --archive-path."
        case let .unknownArchiveVersion(build):
            return "The archive contains \(build.map { "Xcode build \($0)" } ?? "no readable Xcode version"), which xcodereleases.com does not list. Run install again with the version."
        case let .checksumMismatch(file, expected, actual):
            return """
            The archive at \(file.path) is corrupt: its SHA-1 is \(actual), but xcodereleases.com lists \(expected).
            The file was kept. Delete it and run the command again to download it anew, or pass --no-verify to skip the check.
            """
        }
    }
}

public struct Core: Sendable {
    public enum ListFilter: CaseIterable, Sendable {
        case onlyGM
        case onlyReleases
    }

    public struct VersionOptions: Sendable {
        public init(version: XcodeVersion) {
            self.version = version
        }

        public var version: XcodeVersion
    }

    public struct DownloadOptions: Sendable {
        public init(
            destination: URL,
            disableSleep: Bool,
            verifiesChecksum: Bool = true,
            archiveFormat: ArchiveFormat? = nil,
            overwritesExistingFile: Bool = false
        ) {
            self.overwritesExistingFile = overwritesExistingFile
            self.destination = destination
            self.disableSleep = disableSleep
            self.verifiesChecksum = verifiesChecksum
            self.archiveFormat = archiveFormat
        }

        public var archiveFormat: ArchiveFormat?
        public var overwritesExistingFile: Bool

        public var destination: URL
        public var disableSleep: Bool
        public var verifiesChecksum: Bool
    }

    public struct ExtractionOptions: Sendable {
        public init(destination: URL) {
            self.destination = destination
        }

        public var destination: URL
    }

    public struct InstallationOptions: Sendable {
        public init(
            version: XcodeVersion?,
            archiveFile: URL?,
            downloadOptions: Core.DownloadOptions,
            extractionOptions: Core.ExtractionOptions,
            skipSymlinkCreation: Bool = false,
            skipXcodeSelection: Bool = false,
            shouldPreserveArchive: Bool = false
        ) {
            self.version = version
            self.archiveFile = archiveFile
            self.downloadOptions = downloadOptions
            self.extractionOptions = extractionOptions
            self.skipSymlinkCreation = skipSymlinkCreation
            self.skipXcodeSelection = skipXcodeSelection
            self.shouldPreserveArchive = shouldPreserveArchive
        }

        public var version: XcodeVersion?
        public var archiveFile: URL?
        public var downloadOptions: DownloadOptions
        public var extractionOptions: ExtractionOptions
        public var skipSymlinkCreation = false
        public var skipXcodeSelection = false
        public var shouldPreserveArchive = true
    }

    @Dependency(\.logger) private var logger
    @Dependency(\.xcodeReleases) private var xcodeReleases
    @Dependency(\.credentials) private var credentials
    @Dependency(\.authentication) private var authentication
    @Dependency(\.downloads) private var downloads
    @Dependency(\.extraction) private var extraction
    @Dependency(\.processes) private var processes
    @Dependency(\.prompt) private var prompt
    @Dependency(\.fileSystem) private var fileSystem
    @Dependency(\.workspace) private var workspace

    var signingTrust: AEASigningTrust = .apple

    public init() {}

    public func info(version: XcodeVersion, shouldUpdate: Bool) async throws -> Xcode {
        try await identifyVersion(version, updateVersionList: shouldUpdate)
    }

    public func installedXcodes(shouldUpdate: Bool) async throws -> [XcodeApplication] {
        let knownXcodes: [Xcode] = try await list(shouldUpdate: shouldUpdate)
        return try await installedXcodes(knownVersions: knownXcodes)
    }

    public func list(shouldUpdate: Bool, showAllVersions: Bool, filter: ListFilter?) async throws -> XcodeList {
        let xcodes: [Xcode] = try await list(shouldUpdate: shouldUpdate)
        return try await xcodeList(xcodes, showAllVersions: showAllVersions, filter: filter)
    }

    @discardableResult
    public func download(
        version: XcodeVersion,
        options: DownloadOptions,
        updateVersionList: Bool
    ) async throws -> (Xcode, URL) {
        let xcode = try await identifyVersion(version, updateVersionList: updateVersionList)

        guard let url = xcode.links?.download?.url else {
            throw CoreError.invalidDownloadURL
        }

        logger.beginSection("Sign in to Apple Developer")
        let accountName = try await credentials.accountName()
        let listing: DownloadListing?
        do {
            listing = try await authentication.authenticate(accountName) { [credentials] in
                try await credentials.password(accountName)
            }
        } catch let error as CredentialsError {
            throw error
        } catch let error as OlympUsError {
            throw CoreError.signInFailed(error.description)
        } catch {
            throw CoreError.authenticationFailed
        }

        logger.beginSection("Downloading")
        let source = try DownloadSource(
            listed: url,
            offered: listing?.archiveURLs(inFolderOf: url, named: "Xcode \(xcode.displayVersion)"),
            format: options.archiveFormat
        )
        if let note = source.note {
            logger.log(note)
        }
        if let existing = try await reusableDownload(at: options.destination.appendingPathComponent(source.url.lastPathComponent), xcode: xcode, options: options) {
            return (xcode, existing)
        }
        do {
            let downloadURL: URL
            do {
                downloadURL = try await downloads.download(source.url, options.destination, options.disableSleep)
            } catch XCAPIError.unexpectedStatusCode(404) where source.derivedFallback != nil {
                let fallback = source.derivedFallback!
                logger.warn("Apple has no file at \(source.url.lastPathComponent). Trying the .aea at the same path, a derived address: \(fallback)")
                downloadURL = try await downloads.download(fallback, options.destination, options.disableSleep)
            }
            logger.success("Downloaded to \(downloadURL.path)")
            if options.verifiesChecksum, let mismatch = try await checksumMismatch(of: downloadURL, xcode: xcode) {
                throw mismatch
            }
            return (xcode, downloadURL)
        } catch let error as XCAPIError {
            throw CoreError.downloadFailed(error.description)
        }
    }

    private enum ExistingDownload {
        case valid(String)
        case unusable(String)
    }

    private func reusableDownload(at file: URL, xcode: Xcode, options: DownloadOptions) async throws -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        logger.log("\(file.lastPathComponent) is already in \(file.deletingLastPathComponent().path). Checking it before downloading again.")
        switch try await check(existing: file, xcode: xcode) {
        case let .valid(reason):
            logger.success("Using the existing \(file.path) (\(reason)).")
            return file
        case let .unusable(reason):
            var replaces = options.overwritesExistingFile
            if !replaces, isatty(STDIN_FILENO) != 0 {
                replaces = await prompt.agree("\(file.path) exists, but \(reason). Move it to the Trash and download it anew?")
            }
            guard replaces else { throw CoreError.destinationExists(file, reason: reason) }
            let trashed = try fileSystem.trashItem(file)
            logger.log("Moved the existing file to the Trash\(trashed.map { ": \($0.path)" } ?? ".")")
            return nil
        }
    }

    private func check(existing file: URL, xcode: Xcode) async throws -> ExistingDownload {
        switch ArchiveFormat(contentsOf: file) {
        case nil:
            return .unusable("it is not a .xip or .aea archive")
        case .xip:
            guard let expected = xcode.checksums?.sha1?.lowercased(), !expected.isEmpty else {
                return .unusable("xcodereleases.com has no checksum to check it against")
            }
            let actual = try await ArchiveChecksum(url: file).sha1(logger: logger)
            return actual == expected ? .valid("SHA-1 matches xcodereleases.com") : .unusable("its SHA-1 does not match xcodereleases.com")
        case .aea:
            do {
                try await verifySignature(of: file)
                return .valid("Apple signature checked")
            } catch let error as AEAError {
                return .unusable("its signature could not be checked: \(error.localizedDescription)")
            }
        }
    }

    private func verifySignature(of file: URL) async throws {
        let (progressUpdates, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let trust = signingTrust
        async let check: Void = {
            defer { continuation.finish() }
            try AEASignatureCheck(source: file, trust: trust).run { continuation.yield($0) }
        }()
        var milestones = ProgressMilestones()
        for await progress in progressUpdates {
            logger.progress(OutputProgress(title: "Verifying", fraction: min(progress, 0.999), isMilestone: milestones.reached(progress)))
        }
        try await check
        logger.progress(OutputProgress(title: "Verifying", fraction: 1, detail: "signature checked", isFinished: true))
    }

    private func checksumMismatch(of archive: URL, xcode: Xcode) async throws -> CoreError? {
        if ArchiveFormat(contentsOf: archive) == .aea {
            logger.log("xcodereleases.com lists no SHA-1 for the .aea archive. Its Apple signature is checked during extraction instead.")
            return nil
        }
        guard let expected = xcode.checksums?.sha1?.lowercased(), !expected.isEmpty else {
            logger.verbose("xcodereleases.com has no checksum for Xcode \(xcode.displayVersion); skipping the SHA-1 check.")
            return nil
        }
        let actual = try await ArchiveChecksum(url: archive).sha1(logger: logger)
        guard actual != expected else {
            logger.verbose("SHA-1 \(actual) matches xcodereleases.com.")
            return nil
        }
        return CoreError.checksumMismatch(file: archive, expected: expected, actual: actual)
    }

    @discardableResult
    public func install(options: InstallationOptions, updateVersionList: Bool) async throws -> XcodeApplication {
        typealias DownloadResult = (xcode: Xcode, url: URL)

        let downloadResult: DownloadResult

        guard let version = options.version else {
            guard let archive = options.archiveFile else { throw CoreError.versionRequired }
            return try await installIdentifyingArchive(archive, options: options, updateVersionList: updateVersionList)
        }

        if let url = options.archiveFile {
            let xcode = try await identifyVersion(version, updateVersionList: updateVersionList)
            if options.downloadOptions.verifiesChecksum, let mismatch = try await checksumMismatch(of: url, xcode: xcode) {
                logger.warn(mismatch.localizedDescription)
                guard await prompt.agree("Install from this archive anyway?") else {
                    throw mismatch
                }
            }
            downloadResult = (xcode, url)
        } else {
            downloadResult = try await download(
                version: version,
                options: options.downloadOptions,
                updateVersionList: updateVersionList
            )
        }

        let applicationURL = try await extractArchive(
            source: downloadResult.url,
            options: options.extractionOptions,
            xcode: downloadResult.xcode
        )

        if !options.shouldPreserveArchive, options.archiveFile == nil {
            try deleteDownload(at: downloadResult.url)
        }

        if let build = applicationURL.xcodeBuild, let expected = downloadResult.xcode.version.build, build != expected {
            logger.warn("The archive contains Xcode build \(build), not \(expected) as requested. xcinfo continues with Xcode \(downloadResult.xcode.displayName).")
        }

        let app = XcodeApplication(url: applicationURL, xcode: downloadResult.xcode)
        try await installXcode(app, options: options)
        return app
    }

    private func installIdentifyingArchive(_ archive: URL, options: InstallationOptions, updateVersionList: Bool) async throws -> XcodeApplication {
        let knownVersions = try await list(shouldUpdate: updateVersionList)
        let destination = options.extractionOptions.destination
        let extracted = try await extractArchive(
            source: archive,
            options: options.extractionOptions,
            appFilename: ".xcinfo-\(UUID().uuidString).app"
        )
        let build = extracted.xcodeBuild
        guard let xcode = knownVersions.first(where: { $0.version.build == build }) else {
            try? FileManager.default.removeItem(at: extracted)
            throw CoreError.unknownArchiveVersion(build)
        }
        logger.log("The archive contains Xcode \(xcode.displayName).")
        if options.downloadOptions.verifiesChecksum, let mismatch = try await checksumMismatch(of: archive, xcode: xcode) {
            logger.warn(mismatch.localizedDescription)
            guard await prompt.agree("Install from this archive anyway?") else {
                try? FileManager.default.removeItem(at: extracted)
                throw mismatch
            }
        }
        let applicationURL = destination.appendingPathComponent(xcode.filename(in: destination))
        do {
            try FileManager.default.moveItem(at: extracted, to: applicationURL)
        } catch {
            throw CoreError.extractionFailed(error)
        }
        logger.log("Renamed the extracted app to \(applicationURL.lastPathComponent).")

        let app = XcodeApplication(url: applicationURL, xcode: xcode)
        try await installXcode(app, options: options)
        return app
    }

    @discardableResult
    public func uninstall(_ version: String?, updateVersionList: Bool, deletePermanently: Bool = false) async throws -> XcodeApplication? {
        let knownVersions: [Xcode] = try await list(shouldUpdate: updateVersionList)
        guard !knownVersions.isEmpty else {
            throw CoreError.uninstallationFailed("No Xcode releases found.")
        }

        let xcodes: [XcodeApplication] = try await findInstalledXcodes(for: version, knownVersions: knownVersions).sorted(by: >)

        guard !xcodes.isEmpty else {
            throw CoreError.uninstallationFailed("No matching Xcode version found.")
        }

        let selected: XcodeApplication
        if xcodes.count > 1 {
            let listFormatter = ListFormatter()
            listFormatter.locale = Locale(identifier: "en_US")
            logger.verbose("Found: \(listFormatter.string(from: xcodes.map { $0.xcode.description })!)")

            let longestXcodeNameLength = xcodes.map(\.xcode.displayName.count).max() ?? 0
            let choices = xcodes.map { xcodeApp in
                "\(xcodeApp.xcode.displayName.paddedWithSpaces(to: longestXcodeNameLength)) – \(xcodeApp.url.path)"
            }
            selected = xcodes[await prompt.choose("Please choose the version you want to uninstall: ", choices)]
        } else {
            selected = xcodes[0]
        }

        let question = deletePermanently
            ? "Permanently delete Xcode \(selected.xcode.displayName) at \(selected.url.path)? This cannot be undone."
            : "Move Xcode \(selected.xcode.displayName) at \(selected.url.path) to the Trash?"
        guard await prompt.agree(question) else {
            logger.log("Nothing was uninstalled.")
            return nil
        }
        if deletePermanently {
            do {
                try fileSystem.removeItem(selected.url)
            } catch {
                throw CoreError.uninstallationFailed("Could not delete \(selected.url.path): \(error.localizedDescription)")
            }
            logger.success("Deleted Xcode \(selected.xcode.description) at \(selected.url.path).")
            return selected
        }
        let trashedURL: URL?
        do {
            trashedURL = try fileSystem.trashItem(selected.url)
        } catch {
            throw CoreError.uninstallationFailed("""
            Could not move \(selected.url.path) to the Trash: \(error.localizedDescription)
            Nothing was deleted. Run the command again with --delete-permanently to delete it without the Trash.
            """)
        }
        logger.success("Moved Xcode \(selected.xcode.description) to the Trash\(trashedURL.map { ": \($0.path)" } ?? ".")")
        return selected
    }

    @discardableResult
    public func extractArchive(
        source: URL,
        options: ExtractionOptions,
        xcode: Xcode? = nil
    ) async throws -> URL {
        try await extractArchive(source: source, options: options, appFilename: xcode?.filename(in: options.destination))
    }

    private func extractArchive(source: URL, options: ExtractionOptions, appFilename: String?) async throws -> URL {
        logger.beginSection("Extracting")

        guard let format = ArchiveFormat(contentsOf: source) else {
            throw CoreError.unsupportedFile(source.lastPathComponent)
        }
        logger.verbose("\(source.lastPathComponent) is a .\(format.rawValue) archive.")

        let start = ContinuousClock.now
        defer {
            logger.verbose("Extraction time: \(start.duration(to: .now).englishDescription)")
        }

        do {
            let destinationURL = try await extraction.extract(
                source,
                options.destination,
                appFilename
            )
            logger.success("Extracted to \(destinationURL.path)")
            return destinationURL
        } catch {
            throw CoreError.extractionFailed(error)
        }
    }

    public func cleanup() async {
        logger.beginSection("Cleanup")
        await credentials.removeAll()
        await authentication.cleanup()
        xcodeReleases.removeCookies()

        logger.success("Removed stored cookies.")
    }
}

public struct XcodeList: Sendable {
    public var listed: [Xcode]
    public var installed: [Xcode]
    public var notInstallable: [Xcode]

    public var isEmpty: Bool {
        listed.isEmpty && installed.isEmpty && notInstallable.isEmpty
    }
}

extension Core {
    private func identifyVersion(_ version: XcodeVersion, updateVersionList: Bool) async throws -> Xcode {
        logger.beginSection("Identifying")
        let availableXcodes = try await findXcodes(for: version, shouldUpdate: updateVersionList)

        guard
            let xcode = await chooseXcode(
                version: version,
                from: availableXcodes,
                prompt: "Please choose the version you want to install: "
            )
        else {
            throw CoreError.versionNotFound(version)
        }
        return xcode
    }

    private func installXcode(_ xcode: XcodeApplication, options: InstallationOptions) async throws {
        logger.beginSection("Installing")

        try await verify(xcode)

        let password = try await getPassword()

        try await enableDeveloperMode(password: password)
        try await approveLicense(password: password, url: xcode.url)
        try await installComponents(password: password, url: xcode.url)

        if !options.skipSymlinkCreation {
            try await createSymbolicLink(to: xcode.url)
        }

        if !options.skipXcodeSelection {
            try await selectXcode(at: xcode.url, password: password)
        }

        logger.success("Installed Xcode to \(xcode.url.path)")
        await workspace.revealInFinder(xcode.url)
    }

    private func check(_ title: String, failure: CoreError = .installationFailed, _ step: () async throws -> Bool) async throws {
        logger.check(title, .running)
        guard try await step() else {
            logger.check(title, .failed)
            throw failure
        }
        logger.check(title, .passed)
    }

    private func enableDeveloperMode(password: String) async throws {
        try await check("Enabling Developer Mode") {
            let devToolsSecurity = try await processes.runPrivileged("/usr/sbin/DevToolsSecurity", password, ["-enable"])
            guard devToolsSecurity.exitStatus == EXIT_SUCCESS else { return false }
            let groups = try await processes.runPrivileged(
                "/usr/sbin/dseditgroup",
                password,
                ["-o", "edit", "-t", "group", "-a", "staff", "_developer"]
            )
            return groups.exitStatus == EXIT_SUCCESS
        }
    }

    private func approveLicense(password: String, url: URL) async throws {
        try await check("Approving License") {
            try await processes.runPrivileged("\(url.path)/Contents/Developer/usr/bin/xcodebuild", password, ["-license", "accept"]).exitStatus == EXIT_SUCCESS
        }
    }

    private func installComponents(password: String, url: URL) async throws {
        try await check("Installing additional components") {
            try await processes.runPrivileged("\(url.path)/Contents/Developer/usr/bin/xcodebuild", password, ["-runFirstLaunch"]).exitStatus == EXIT_SUCCESS
        }
    }

    private func createSymbolicLink(to destination: URL) async throws {
        let applicationsDirectory = fileSystem.applicationsDirectory()
        let symlinkURL = applicationsDirectory.appendingPathComponent("Xcode.app")
        let fileManager = FileManager.default

        if fileManager.isSymbolicLink(atPath: symlinkURL.path) {
            logger.verbose("Symbolic link at \(symlinkURL.path) found. Removing it...")
            try? fileManager.removeItem(at: symlinkURL)
        } else if fileManager.fileExists(atPath: symlinkURL.path) {
            let knownXcodes = try await list(shouldUpdate: false)
            let installed = try await installedXcodes(knownVersions: knownXcodes)

            if let xcodeApp = installed.first(where: { $0.url == symlinkURL }) {
                let filename = xcodeApp.xcode.filename(in: applicationsDirectory)
                logger.verbose("\(symlinkURL.path) already exists. Moving it to \(applicationsDirectory.path)/\(filename).")
                let destination = applicationsDirectory.appendingPathComponent(filename)
                try? fileManager.moveItem(at: symlinkURL, to: destination)
            }
        }

        try await check("Creating symbolic link at \(symlinkURL.path)") {
            try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: destination)
            return true
        }
    }

    func selectXcode(at url: URL, password: String) async throws {
        try await check("Selecting Xcode") {
            try await processes.runPrivileged("xcode-select", password, ["-s", url.path]).exitStatus == EXIT_SUCCESS
        }
    }

    private func getPassword() async throws -> String {
        logger.log("Installing Xcode needs administrator rights (sudo) to accept the license, enable developer mode and select the new Xcode.")
        let passwordPrompt = "Mac administrator password for \(NSUserName()) (sudo):"

        for attempt in 1 ... 3 {
            let password = await prompt.readSecret(attempt == 1 ? passwordPrompt : "Sorry, try again. \(passwordPrompt)")
            try Task.checkCancellation()
            if try await processes.runPrivileged("ls", password, []).exitStatus == EXIT_SUCCESS {
                return password
            }
        }
        throw CoreError.incorrectSuperUserPassword
    }

    private func verify(_ app: XcodeApplication) async throws {
        try await check("Verifying Xcode with Gatekeeper", failure: .gatekeeperVerificationFailed(app.url)) {
            try await processes.run("/usr/sbin/spctl", ["--assess", "--verbose", "--type", "execute", app.url.path]).exitStatus == EXIT_SUCCESS
        }
        try await check("Verifying the code signature", failure: .codesignVerificationFailed(app.url)) {
            try await processes.run("/usr/bin/codesign", ["--verify", "--verbose", app.url.path]).exitStatus == EXIT_SUCCESS
        }
    }

    private func deleteDownload(at url: URL) throws {
        logger.log("Deleting downloaded Xcode archive...")
        try FileManager.default.removeItem(at: url)
    }

    private func findXcodes(for version: XcodeVersion, shouldUpdate: Bool) async throws -> [Xcode] {
        let knownXcodes: [Xcode] = try await list(shouldUpdate: shouldUpdate)

        guard !knownXcodes.isEmpty else { return [] }

        switch version {
        case let .version(version):
            if let versionParts = VersionParts(rawValue: version) {
                let result = knownXcodes.filter {
                    $0.matching(versionParts)
                }
                return result
            } else {
                return knownXcodes.filter { xcode in
                    xcode.version.build?.hasPrefix(version) ?? false
                }
            }
        case .latest:
            return [knownXcodes[0]]
        }
    }

    private func findInstalledXcodes(for version: String?, knownVersions: [Xcode]) async throws -> [XcodeApplication] {
        var xcodesApplications = try await installedXcodes(knownVersions: knownVersions)
        if let version = version {
            let (fullVersion, betaVersion) = extractVersionParts(from: version)
            xcodesApplications = xcodesApplications.filter {
                $0.xcode.matching(fullVersion: fullVersion, betaVersion: betaVersion, version: version)
            }
        }
        return xcodesApplications
    }

    private func extractVersionParts(from version: String) -> (String?, Int?) {
        let pattern = #"(\d*.?\d*.?\d*) [b|B]eta ?(\d*)"#
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        var betaVersion: Int?
        var fullVersion: String?
        if let match = regex?.firstMatch(in: version, options: [], range: NSRange(version.startIndex..., in: version)) {
            if let versionRange = Range(match.range(at: 1), in: version) {
                fullVersion = String(version[versionRange])
            }
            if let betaRange = Range(match.range(at: 2), in: version), let beta = Int(version[betaRange]) {
                betaVersion = beta
            }
        }
        return (fullVersion, betaVersion)
    }

    private func chooseXcode(version: XcodeVersion, from xcodes: [Xcode], prompt: String) async -> Xcode? {
        switch xcodes.count {
        case 0:
            return nil
        case 1:
            logger.log("Found matching Xcode \(xcodes[0].displayName).")
            return xcodes.first
        default:
            logger
                .log("Found multiple possibilities for the requested version '\(version.description)'.")

            let index = await self.prompt.choose(prompt, xcodes.map(\.displayName))
            return xcodes[index]
        }
    }

    private func list(shouldUpdate: Bool) async throws -> [Xcode] {
        let xcodes: [Xcode]

        if shouldUpdate {
            xcodes = try await xcodeReleases.listXcodes()
            try await cache(xcodes)
        } else {
            xcodes = try await cachedXcodes()
        }
        return xcodes
    }

    private func installedXcodes(knownVersions: [Xcode]) async throws -> [XcodeApplication] {
        guard !knownVersions.isEmpty else {
            return []
        }
        let result = try await processes.run("mdfind", ["kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'"])
        let paths = result.stdout.split(separator: "\n")

        return paths.compactMap { path -> XcodeApplication? in
            let url = URL(fileURLWithPath: String(path))
            let versionURL = url.appendingPathComponent("Contents/version.plist")
            if
                let plistBuild = NSDictionary(contentsOfFile: versionURL.path)?["ProductBuildVersion"] as? String,
                let release = knownVersions.first(where: { $0.version.build == plistBuild })
            {
                return XcodeApplication(url: url, xcode: release)
            } else {
                return nil
            }
        }.sorted(by: >)
    }

    private func xcodeList(_ xcodes: [Xcode], showAllVersions: Bool, filter: ListFilter?) async throws -> XcodeList {
        let versions: [Xcode] = switch filter {
        case .none:
            xcodes
        case .onlyGM:
            xcodes.filter { $0.version.isGM }
        case .onlyReleases:
            xcodes.filter { $0.version.isRelease }
        }

        guard !versions.isEmpty else {
            return XcodeList(listed: [], installed: [], notInstallable: [])
        }

        let installableVersions = versions.filter {
            guard let installableOsVersion = OperatingSystemVersion(string: $0.requires) else { return false }
            return $0.links?.download?.url != nil &&
                ProcessInfo.processInfo.isOperatingSystemAtLeast(installableOsVersion)
        }

        let referenceDate = Calendar.current.date(byAdding: DateComponents(year: -1), to: Date())!
        let listedVersions = showAllVersions
            ? versions
            : installableVersions.filter { $0.releaseDate > referenceDate }

        let installedVersions = try await installedXcodes(knownVersions: versions).map(\.xcode)
        let notInstallableVersions = Set(versions).subtracting(installableVersions)

        return XcodeList(
            listed: listedVersions.sorted(by: >),
            installed: installedVersions.sorted(by: >),
            notInstallable: notInstallableVersions.sorted(by: >)
        )
    }
}

extension Core {
    private var cacheFile: URL { fileSystem.cachesDirectory().appendingPathComponent(.xcodesCacheFile) }

    private func cache(_ xcodes: [Xcode]) async throws {
        let data = try JSONEncoder().encode(xcodes)
        try data.write(to: cacheFile, options: .atomic)
    }

    private func cachedXcodes() async throws -> [Xcode] {
        let data = try Data(contentsOf: cacheFile)
        return try JSONDecoder().decode([Xcode].self, from: data)
    }
}

private extension String {
    static let xcodesCacheFile = "xcinfo.json"
}

struct InstalledXcode {
    var path: String
    var version: Version

    init(path: String, version: Version) {
        self.path = path
        self.version = version
    }

    init?(path: String.SubSequence) {
        let path = String(path)
        let url = URL(fileURLWithPath: path)
        let infoPlistURL = url.appendingPathComponent("Contents/Info.plist")
        let versionURL = url.appendingPathComponent("Contents/version.plist")

        guard
            let shortBuildNumber = NSDictionary(contentsOf: infoPlistURL)?["CFBundleShortVersionString"] as? String,
            let plistBuild = NSDictionary(contentsOf: versionURL)?["ProductBuildVersion"] as? String
        else { return nil }

        self.init(path: path, version: .init(plistBuild, shortBuildNumber, .release))
    }
}

extension InstalledXcode {
    var displayVersion: String {
        var components: [String] = []
        if let number = version.number {
            components.append(number)
        }
        if case let .gmSeed(version) = version.release {
            components.append("GM Seed \(version)")
        } else if case let .beta(version) = version.release {
            components.append("Beta \(version)")
        } else if case let .dp(version) = version.release {
            components.append("DP \(version)")
        } else if case let .rc(version) = version.release {
            components.append("RC \(version)")
        }
        return components.joined(separator: " ")
    }
}

extension Xcode {
    func matching(_ versionParts: VersionParts) -> Bool {
        guard let parts = version.number?.split(separator: ".") else {
            return false
        }

        let majorStr = parts[safe: 0].map(String.init)
        guard let major = majorStr.flatMap(Int.init) else {
            return false
        }
        let minor = parts[safe: 1].flatMap { Int(String($0)) }
        let patch = parts[safe: 2].flatMap { Int(String($0)) }

        let p = VersionParts(major: major, minor: minor, patch: patch, type: version.release.versionType)
        if p.major != versionParts.major { return false }
        if let pMinor = p.minor, let vMinor = versionParts.minor {
            if pMinor != vMinor { return false }

            if let pPatch = p.patch, let vPatch = versionParts.patch {
                if pPatch != vPatch { return false }
            }
        }
        if let vType = versionParts.type {
            guard let pType = p.type, pType.matches(vType) else { return false }
        }
        return true
    }

    func matching(fullVersion: String?, betaVersion: Int?, version: String) -> Bool {
        if let betaVersion = betaVersion {
            let versionNumberHaveSamePrefix = self.version.number?.lowercased()
                .hasPrefix(fullVersion ?? version) == true
            let betaVersionsAreSame: Bool = {
                guard case let .beta(version) = self.version.release else { return false }
                return version == betaVersion
            }()
            let areSameVersions = self.version.build?.lowercased() == version

            return versionNumberHaveSamePrefix && betaVersionsAreSame || areSameVersions
        } else {
            return self.version.number?.lowercased().hasPrefix(fullVersion ?? version) == true ||
            self.version.build?.lowercased() == version
        }
    }
}

extension URL {
    var xcodeBuild: String? {
        NSDictionary(contentsOf: appendingPathComponent("Contents/version.plist"))?["ProductBuildVersion"] as? String
    }
}
