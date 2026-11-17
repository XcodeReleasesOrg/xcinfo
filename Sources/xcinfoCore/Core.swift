//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Dependencies
import Foundation
import XCIFoundation
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.

public enum CoreError: LocalizedError, Sendable {
    case authenticationFailed
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

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Authentication with Apple failed."
        case let .downloadFailed(description), let .uninstallationFailed(description):
            return description
        case .invalidDownloadURL:
            return "Invalid download url"
        case let .versionNotFound(version):
            return "No Xcode found for given version '\(version)'."
        case let .extractionFailed(error):
            return error.localizedDescription
        case let .unsupportedFile(fileExtension):
            return "'\(fileExtension)' is not supported."
        case .installationFailed:
            return "Xcode could not be installed."
        case let .gatekeeperVerificationFailed(url):
            return "Gatekeeper could not verify Xcode at \(url.path)"
        case let .codesignVerificationFailed(url):
            return "Code sign could not verify Xcode at \(url.path)"
        case .incorrectSuperUserPassword:
            return ""
        case .invalidExtractionOutputURL(let output):
            return "Failed to access output directory at \(output.path)."
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
        public init(destination: URL, disableSleep: Bool) {
            self.destination = destination
            self.disableSleep = disableSleep
        }

        public var destination: URL
        public var disableSleep: Bool
    }

    public struct ExtractionOptions: Sendable {
        public init(destination: URL, useLegacyUnxip: Bool = false) {
            self.destination = destination
            self.useLegacyUnxip = useLegacyUnxip
        }

        public var destination: URL
        public var useLegacyUnxip: Bool
    }

    public struct InstallationOptions: Sendable {
        public init(
            version: XcodeVersion,
            xipFile: URL?,
            downloadOptions: Core.DownloadOptions,
            extractionOptions: Core.ExtractionOptions,
            skipSymlinkCreation: Bool = false,
            skipXcodeSelection: Bool = false,
            shouldPreserveXIP: Bool = false
        ) {
            self.version = version
            self.xipFile = xipFile
            self.downloadOptions = downloadOptions
            self.extractionOptions = extractionOptions
            self.skipSymlinkCreation = skipSymlinkCreation
            self.skipXcodeSelection = skipXcodeSelection
            self.shouldPreserveXIP = shouldPreserveXIP
        }

        public var version: XcodeVersion
        public var xipFile: URL?
        public var downloadOptions: DownloadOptions
        public var extractionOptions: ExtractionOptions
        public var skipSymlinkCreation = false
        public var skipXcodeSelection = false
        public var shouldPreserveXIP = true
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

    public init() {}

    public func info(version: XcodeVersion, shouldUpdate: Bool) async throws {
        let xcode = try await identifyVersion(version, updateVersionList: shouldUpdate)

        logger.beginSection("Version info")
        logger.log(xcode.description)

        let locale = Locale(identifier: "en_US_POSIX")

        var releaseDateString = "Release date: \(xcode.releaseDate.formatted(Date.FormatStyle().year().month(.wide).day().locale(locale)))"
        releaseDateString += " (\(xcode.releaseDate.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(locale))))"

        logger.log(releaseDateString)
        logger.log("Requires macOS \(xcode.requires)")

        if let sdks = xcode.sdks?.keyed() {
            logger.beginParagraph("SDKs")
            let longestSDKName = sdks.map { "\($0.key) SDK:" }.max(by: { $1.count > $0.count })!.count
            for (name, versions) in sdks {
                let sdkName = "\(name) SDK:"
                let version = versions[0]
                logger.log("\(sdkName.paddedWithSpaces(to: longestSDKName)) \(version.build ?? "")")
            }
        }
        if let compilers = xcode.compilers?.keyed() {
            logger.beginParagraph("Compilers")
            let longestName = compilers.map { "\($0.key) \($0.value[0].number ?? ""):" }
                .max(by: { $1.count > $0.count })!.count
            for (name, versions) in compilers {
                let version = versions[0]
                let compilerName = "\(name) \(version.number ?? ""):"
                logger.log("\(compilerName.paddedWithSpaces(to: longestName)) \(version.build ?? "")")
            }
        }

        let downloadLink = xcode.links?.download?.url.absoluteString
        let notesLink = xcode.links?.notes?.url.absoluteString
        guard ![downloadLink, notesLink].compactMap({ $0 }).isEmpty else { return }

        logger.beginParagraph("Links")
        downloadLink.map {
            logger.log("Download:      " + $0)
        }
        notesLink.map {
            logger.log("Release Notes: " + $0)
        }
    }

    public func installedXcodes(shouldUpdate: Bool) async throws {
        let knownXcodes: [Xcode] = try await list(shouldUpdate: shouldUpdate)
        let xcodes = try await installedXcodes(knownVersions: knownXcodes)
        guard let longestXcodeNameLength = xcodes.map(\.xcode.description.count).max() else {
            return
        }
        xcodes.forEach {
            let displayVersion = $0.xcode.displayVersion
            let attributedDisplayName = "\(displayVersion) (\($0.xcode.version.build ?? ""))"

            let attributedName = attributedDisplayName.cyan
            let width = longestXcodeNameLength + attributedName.count - attributedName.raw.count
            logger.log("\(attributedName.paddedWithSpaces(to: width)) – \($0.url.path.cyan)")
        }
    }

    public func list(shouldUpdate: Bool, showAllVersions: Bool, filter: ListFilter?) async throws {
        let xcodes: [Xcode] = try await list(shouldUpdate: shouldUpdate)
        try await printXcodeList(xcodes, showAllVersions, filter)
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
        let appleID = try credentials.credentials()
        do {
            try await authentication.authenticate(appleID)
        } catch {
            throw CoreError.authenticationFailed
        }

        logger.beginSection("Downloading")
        do {
            let downloadURL = try await downloads.download(
                url,
                options.destination,
                options.disableSleep
            )
            logger.log("Download to \(options.destination.path) complete.")
            return (xcode, downloadURL)
        } catch let error as XCAPIError {
            throw CoreError.downloadFailed(error.description)
        }
    }

    public func install(options: InstallationOptions, updateVersionList: Bool) async throws {
        typealias DownloadResult = (xcode: Xcode, url: URL)

        let downloadResult: DownloadResult

        if let url = options.xipFile {
            let xcode = try await identifyVersion(options.version, updateVersionList: updateVersionList)
            downloadResult = (xcode, url)
        } else {
            downloadResult = try await download(
                version: options.version,
                options: options.downloadOptions,
                updateVersionList: updateVersionList
            )
        }

        let app = try await extractXIP(
            source: downloadResult.url,
            options: options.extractionOptions,
            xcode: downloadResult.xcode
        )

        if !options.shouldPreserveXIP, options.xipFile == nil {
            try deleteDownload(at: downloadResult.url)
        }

        guard let app = app else {
            throw CoreError.installationFailed
        }

        try await installXcode(app, options: options)
    }

    public func uninstall(_ version: String?, updateVersionList: Bool) async throws {
        let knownVersions: [Xcode] = try await list(shouldUpdate: updateVersionList)
        guard !knownVersions.isEmpty else {
            throw CoreError.uninstallationFailed("No Xcode releases found.")
        }

        let xcodes: [XcodeApplication] = try await findInstalledXcodes(for: version, knownVersions: knownVersions).sorted(by: >)

        if xcodes.isEmpty {
            throw CoreError.uninstallationFailed("No matching Xcode version found.")
        } else {
            let selected: XcodeApplication
            if xcodes.count > 1 {
                let listFormatter = ListFormatter()
                listFormatter.locale = Locale(identifier: "en_US")
                logger.verbose("Found: \(listFormatter.string(from: xcodes.map { $0.xcode.description })!)")

                let longestXcodeNameLength = xcodes.map { $0.xcode.attributedDisplayName }
                    .max(by: { $1.count > $0.count })!.count
                let choices = xcodes.map { xcodeApp in
                    let attributedName = xcodeApp.xcode.attributedDisplayName
                    let width = longestXcodeNameLength + attributedName.count - attributedName.raw.count
                    return "\(attributedName.paddedWithSpaces(to: width)) – \(xcodeApp.url.path.cyan)"
                }
                selected = xcodes[prompt.choose("Please choose the version you want to uninstall: ", choices)]
            } else {
                selected = xcodes[0]
            }

            let displayName = selected.xcode.attributedDisplayName
            if prompt.agree("Are you sure you want to uninstall Xcode \(displayName)?") {
                do {
                    logger
                        .verbose("Uninstalling Xcode \(selected.xcode.description) from \(selected.url.path) ...")
                    try FileManager.default.removeItem(at: selected.url)
                    logger.success("\(selected.xcode.description) uninstalled!")
                } catch {
                    throw CoreError.uninstallationFailed("Uninstallation failed. Error: \(error.localizedDescription)")
                }
            } else {
                logger.log("kthxbye")
            }
        }
    }

    @discardableResult
    public func extractXIP(
        source: URL,
        options: ExtractionOptions,
        xcode: Xcode? = nil
    ) async throws -> XcodeApplication? {
        logger.beginSection("Extracting")

        guard source.pathExtension.lowercased() == "xip" else {
            throw CoreError.unsupportedFile(source.pathExtension)
        }

        let start = Date()
        defer {
            let end = Date()
            logger
                .verbose(
                    "Extraction time: \(Int((end.timeIntervalSinceReferenceDate - start.timeIntervalSinceReferenceDate).rounded(.up))) seconds."
                )
        }

        do {
            let destinationURL = try await extraction.extract(
                source,
                options.destination,
                xcode?.filename(in: fileSystem.applicationsDirectory()),
                options.useLegacyUnxip
            )
            logger.log("XIP successfully extracted to \(destinationURL.path)")
            guard let xcode = xcode else { return nil }
            return .init(url: destinationURL, xcode: xcode)
        } catch {
            throw CoreError.extractionFailed(error)
        }
    }

    public func cleanup() {
        logger.beginSection("Cleanup")
        logger.log("")
        credentials.removeAll()
        authentication.cleanup()
        xcodeReleases.removeCookies()

        logger.log("Removed stored cookies.")
    }
}

extension Core {
    private func identifyVersion(_ version: XcodeVersion, updateVersionList: Bool) async throws -> Xcode {
        logger.beginSection("Identifying")
        let availableXcodes = try await findXcodes(for: version, shouldUpdate: updateVersionList)

        guard
            let xcode = chooseXcode(
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

        logger.log("Installed Xcode to \(xcode.url.path)")
        await workspace.revealInFinder(xcode.url)
    }

    private func enableDeveloperMode(password: String) async throws {
        logger.log("Enabling Developer Mode...")

        let result1 = try await processes.runPrivileged("/usr/sbin/DevToolsSecurity", password, ["-enable"]).exitStatus

        guard result1 == EXIT_SUCCESS else {
            logger.log("Enabling Developer Mode \("✗".red)", onSameLine: true)
            throw CoreError.installationFailed
        }

        let result2 = try await processes.runPrivileged("/usr/sbin/dseditgroup", password, "-o edit -t group -a staff _developer".components(separatedBy: " ")).exitStatus

        guard result2 == EXIT_SUCCESS else {
            logger.log("Enabling Developer Mode \("✗".red)", onSameLine: true)
            throw CoreError.installationFailed
        }

        logger.log("Enabling Developer Mode \("✓".cyan)", onSameLine: true)
    }

    private func approveLicense(password: String, url: URL) async throws {
        logger.log("Approving License...")
        let result = try await processes.runPrivileged("\(url.path)/Contents/Developer/usr/bin/xcodebuild", password, ["-license", "accept"]).exitStatus

        guard result == EXIT_SUCCESS else {
            logger.log("Approving License \("✗".red)", onSameLine: true)
            throw CoreError.installationFailed
        }

        logger.log("Approving License \("✓".cyan)", onSameLine: true)
    }

    private func installComponents(password: String, url: URL) async throws {
        logger.log("Install additional components...")
        let result = try await processes.runPrivileged("\(url.path)/Contents/Developer/usr/bin/xcodebuild", password, ["-runFirstLaunch"]).exitStatus

        guard result == EXIT_SUCCESS else {
            logger.log("Install additional components \("✗".red)", onSameLine: true)
            throw CoreError.installationFailed
        }

        logger.log("Install additional components \("✓".cyan)", onSameLine: true)
    }

    private func createSymbolicLink(to destination: URL) async throws {
        let symlinkURL = fileSystem.applicationsDirectory().appendingPathComponent("Xcode.app")
        let fileManager = FileManager.default

        if fileManager.isSymbolicLink(atPath: symlinkURL.path) {
            logger.verbose("Symbolic link at \(symlinkURL.path) found. Removing it...")
            try? fileManager.removeItem(at: symlinkURL)
        } else if fileManager.fileExists(atPath: symlinkURL.path) {
            logger.verbose("\(symlinkURL.path) already exists. Renaming it...")

            let knownXcodes = try await list(shouldUpdate: false)
            let installed = try await installedXcodes(knownVersions: knownXcodes)

            if let xcodeApp = installed.first(where: { $0.url == symlinkURL }) {
                let filename = xcodeApp.xcode.filename(in: fileSystem.applicationsDirectory())
                logger.verbose(
                    "\(symlinkURL.path) already exists. Moving it to \(fileSystem.applicationsDirectory().path)/\(filename).",
                    onSameLine: true
                )
                let destination = fileSystem.applicationsDirectory().appendingPathComponent(filename)
                try? fileManager.moveItem(at: symlinkURL, to: destination)
            }
        }

        logger.log("Creating symbolic link at \(symlinkURL.path).")
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: destination)
        logger.log("Creating symbolic link at \(symlinkURL.path). \("✓".cyan)", onSameLine: true)
    }

    func selectXcode(at url: URL, password: String) async throws {
        logger.log("Selecting Xcode...")
        let result = try await processes.runPrivileged("xcode-select", password, ["-s", url.path])
            .exitStatus

        guard result == EXIT_SUCCESS else {
            logger.log("Selecting Xcode \("✗".red)", onSameLine: true)
            throw CoreError.installationFailed
        }

        logger.log("Selecting Xcode \("✓".cyan)", onSameLine: true)
    }

    private func getPassword() async throws -> String {
        logger.log("XCInfo needs super user privileges in order to proceed.")

        var passwordAttempts = 0
        let maxPasswordAttempts = 3
        var possiblePassword: String?
        repeat {
            passwordAttempts += 1
            let prompt: String = {
                if passwordAttempts == 1 {
                    return "Please enter your password:"
                } else {
                    return "Sorry, try again:"
                }
            }()

            func getPwd(prompt: String) async throws -> String? {
                let password = self.prompt.readSecret(prompt)
                let sudoExitStatus = try await processes.runPrivileged("ls", password, []).exitStatus
                return sudoExitStatus == EXIT_SUCCESS ? password : nil
            }
            possiblePassword = try await getPwd(prompt: prompt)
        } while
            possiblePassword == nil && passwordAttempts < maxPasswordAttempts

        guard let password = possiblePassword else {
            logger.verbose("3rd incorrect password attempt. Terminating...")
            throw CoreError.incorrectSuperUserPassword
        }
        return password
    }

    private func verify(_ app: XcodeApplication) async throws {
        logger.log("Verifying Xcode...")
        var exitStatus = try await processes.run(
            "/usr/sbin/spctl",
            ["--assess", "--verbose", "--type", "execute", app.url.path]).exitStatus
        guard exitStatus == EXIT_SUCCESS else {
            throw CoreError.gatekeeperVerificationFailed(app.url)
        }

        exitStatus = try await processes.run("/usr/bin/codesign", ["--verify", "--verbose", app.url.path]).exitStatus

        guard exitStatus == EXIT_SUCCESS else {
            throw CoreError.codesignVerificationFailed(app.url)
        }

        logger.log("Verifying Xcode \("✓".cyan)", onSameLine: true)
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

    private func chooseXcode(version: XcodeVersion, from xcodes: [Xcode], prompt: String) -> Xcode? {
        switch xcodes.count {
        case 0:
            return nil
        case 1:
            logger.log("Found matching Xcode \(xcodes[0].attributedDisplayName).")
            return xcodes.first
        default:
            logger
                .log("Found multiple possibilities for the requested version '\(version.description.cyan)'.")

            let index = self.prompt.choose(prompt, xcodes.map(\.attributedDisplayName))
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

    private func printXcodeList(_ xcodes: [Xcode], _ showAllVersions: Bool, _ filter: ListFilter?) async throws {

        let versions: [Xcode] = {
            switch filter {
            case .none:
                return xcodes
            case .onlyGM:
                return xcodes.filter { $0.version.isGM }
            case .onlyReleases:
                return xcodes.filter { $0.version.isRelease }
            }
        }()

        guard let longestDescription = versions.map(\.description.count).max() else {
            logger.log("Empty result list".red)
            return
        }
        let columnWidth = longestDescription + 12
        let installableVersions = versions.filter {
            guard let installableOsVersion = OperatingSystemVersion(string: $0.requires) else { return false }
            return $0.links?.download?.url != nil &&
                ProcessInfo.processInfo.isOperatingSystemAtLeast(installableOsVersion)
        }

        let allVersions = Set(versions)

        let listedVersions = (
            showAllVersions
                ? versions
                : installableVersions.filter {
                    let components = DateComponents(year: -1)
                    let referenceDate = Calendar.current.date(byAdding: components, to: Date())!
                    return $0.releaseDate > referenceDate
                }
        )
        .sorted(by: >)

        printXcodeVersionList(xcodeVersions: listedVersions.map { $0.attributedDisplayName }, columnWidth: columnWidth)

        let installedVersions = try await installedXcodes(knownVersions: versions).map { $0.xcode }

        if !installedVersions.isEmpty {
            logger.log("\nAlready installed:")

            printXcodeVersionList(
                xcodeVersions: installedVersions.sorted(by: >).map { $0.attributedDisplayName },
                columnWidth: columnWidth
            )
        }

        let notInstallableVersions = allVersions.subtracting(installableVersions)
        if !notInstallableVersions.isEmpty {
            logger.log("\nNot installable:")

            printXcodeVersionList(
                xcodeVersions: notInstallableVersions.sorted(by: >).map { $0.description },
                columnWidth: columnWidth
            )
        }
    }

    private func printXcodeVersionList(xcodeVersions: [String], columnWidth: Int) {
        if
            xcodeVersions.count > 10,
            let windowSize = WindowSize.current
        {
            let cols = Int((Double(windowSize.columns) / Double(columnWidth)).rounded(.down))
            let rows = Int((Double(xcodeVersions.count) / Double(cols)).rounded(.up))

            for row in 0 ..< rows {
                var strings: [String] = []
                for col in 0 ..< cols {
                    guard row + rows * col < xcodeVersions.count else { break }
                    let xcversion = xcodeVersions[row + rows * col]
                    let width = columnWidth + xcversion.count - xcversion.raw.count
                    strings.append(xcversion.paddedWithSpaces(to: width))
                }

                logger.log(strings.joined())
            }
        } else {
            logger.log(xcodeVersions.joined(separator: "\n"))
        }
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
