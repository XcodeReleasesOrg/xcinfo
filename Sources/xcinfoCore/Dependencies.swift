//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import AppKit
import Dependencies
import DependenciesMacros
import Foundation
import IssueReporting
import OlympUs
import XCIFoundation
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.

@DependencyClient
public struct XcodeReleasesClient: Sendable {
    public var listXcodes: @Sendable () async throws -> [Xcode]
    public var removeCookies: @Sendable () -> Void
}

@DependencyClient
public struct CredentialsClient: Sendable {
    public var accountName: @Sendable () async throws -> String
    public var password: @Sendable (_ accountName: String) async throws -> String
    public var removeAll: @Sendable () async -> Bool = { false }
}

@DependencyClient
public struct AuthenticationClient: Sendable {
    public var authenticate: @Sendable (_ accountName: String, _ password: @escaping @Sendable () async throws -> String) async throws -> DownloadListing?
    public var cleanup: @Sendable () async -> Bool = { false }
}

@DependencyClient
public struct DownloadClient: Sendable {
    public var download: @Sendable (_ url: URL, _ destination: URL, _ disableSleep: Bool) async throws -> URL
}

@DependencyClient
public struct ExtractionClient: Sendable {
    public var extract: @Sendable (_ source: URL, _ destination: URL, _ appFilename: String?) async throws -> URL
}

@DependencyClient
public struct ProcessClient: Sendable {
    public var run: @Sendable (_ command: String, _ arguments: [String]) async throws -> ProcessResult
    public var runPrivileged: @Sendable (_ command: String, _ password: String, _ arguments: [String]) async throws -> ProcessResult
    public var isRunningAsRoot: @Sendable () -> Bool = { false }
    public var isAppleSilicon: @Sendable () -> Bool = { true }
}

@DependencyClient
public struct FileSystemClient: Sendable {
    public var cachesDirectory: @Sendable () -> URL = { URL(fileURLWithPath: NSTemporaryDirectory()) }
    public var applicationsDirectory: @Sendable () -> URL = { URL(fileURLWithPath: NSTemporaryDirectory()) }
    public var temporaryDirectory: @Sendable (_ onVolumeOf: URL) -> URL = { _ in URL(fileURLWithPath: NSTemporaryDirectory()) }
    public var trashItem: @Sendable (_ url: URL) throws -> URL? = { url in
        reportIssue("Unimplemented: fileSystem.trashItem(\(url.path))")
        return nil
    }
    public var removeItem: @Sendable (_ url: URL) throws -> Void = { url in
        reportIssue("Unimplemented: fileSystem.removeItem(\(url.path))")
    }
}

@DependencyClient
public struct KeychainClient: Sendable {
    public var load: @Sendable () async throws -> VaultContents
    public var reload: @Sendable () async throws -> VaultContents
    public var stage: @Sendable (_ change: @escaping @Sendable (inout VaultContents) -> Void) async throws -> Void
    public var commit: @Sendable (_ change: @escaping @Sendable (inout VaultContents) -> Void) async throws -> Void
}

@DependencyClient
public struct WorkspaceClient: Sendable {
    public var revealInFinder: @Sendable (_ url: URL) async -> Void
}

extension XcodeReleasesClient: DependencyKey {
    public static let liveValue: XcodeReleasesClient = {
        let api = XCReleasesAPI(
            baseURL: URL(string: "https://xcodereleases.com/data.json")!,
            session: .xcinfo
        )
        return XcodeReleasesClient(
            listXcodes: { try await api.listXcodes() },
            removeCookies: { api.removeCookies() }
        )
    }()

    public static let testValue = XcodeReleasesClient()
}

extension CredentialsClient: DependencyKey {
    public static let liveValue = CredentialsClient(
        accountName: { try await CredentialService().accountName() },
        password: { accountName in try await CredentialService().password(for: accountName) },
        removeAll: { await CredentialService().cleanup() }
    )

    public static let testValue = CredentialsClient()
}

extension AuthenticationClient: DependencyKey {
    public static let liveValue = AuthenticationClient(
        authenticate: { accountName, password in
            @Dependency(\.logger) var logger
            @Dependency(\.prompt) var prompt
            @Dependency(\.keychain) var keychain
            HTTPCookieStorage.shared.removeAppleCookies()
            let olymp = OlympUs(logger: logger, session: .xcinfo, sessionStore: .vault(keychain), prompt: prompt)
            return try await AppleAuthenticator(olymp: olymp, logger: logger).authenticate(username: accountName, password: password)
        },
        cleanup: {
            @Dependency(\.logger) var logger
            @Dependency(\.keychain) var keychain
            HTTPCookieStorage.shared.removeAppleCookies()
            return await OlympUs(logger: logger, session: .xcinfo, sessionStore: .vault(keychain)).cleanup()
        }
    )

    public static let testValue = AuthenticationClient()
}

extension DownloadClient: DependencyKey {
    public static let liveValue = DownloadClient(
        download: { url, destination, disableSleep in
            @Dependency(\.logger) var logger
            @Dependency(\.fileSystem) var fileSystem
            @Dependency(\.continuousClock) var clock
            let downloader = Downloader(
                logger: logger,
                session: .xcinfoDownloads,
                cachesDirectory: fileSystem.cachesDirectory(),
                clock: clock
            )
            return try await InterruptSignals().run { _ in
                logger.warn("Stopping the download and saving its progress. Press Ctrl-C again to quit immediately.")
            } operation: {
                try await downloader.download(url: url, destination: destination, disableSleep: disableSleep)
            }
        }
    )

    public static let testValue = DownloadClient()
}

extension ExtractionClient: DependencyKey {
    public static let liveValue = ExtractionClient(
        extract: { source, destination, appFilename in
            @Dependency(\.logger) var logger
            @Dependency(\.fileSystem) var fileSystem
            let extractor = Extractor(
                forReadingFromContainerAt: source,
                destination: destination,
                appFilename: appFilename,
                temporaryDirectory: fileSystem.temporaryDirectory(destination),
                logger: logger
            )
            switch ArchiveFormat(contentsOf: source) {
            case .aea:
                return try await extractor.extractAEA(trust: .apple, archiveUtility: ProcessRunner.archiveUtility)
            case .xip, nil:
                return try await extractor.extractXIP()
            }
        }
    )

    public static let testValue = ExtractionClient()
}

extension ProcessClient: DependencyKey {
    public static let liveValue = ProcessClient(
        run: { command, arguments in
            try await ProcessRunner.run(command, arguments: arguments)
        },
        runPrivileged: { command, password, arguments in
            if geteuid() == 0 {
                return try await ProcessRunner.run(command, arguments: arguments)
            }
            return try await ProcessRunner.runPrivileged(command, password: password, arguments: arguments)
        },
        isRunningAsRoot: { geteuid() == 0 },
        isAppleSilicon: {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        }
    )

    public static let testValue = ProcessClient()
}

extension FileSystemClient: DependencyKey {
    public static let liveValue = FileSystemClient(
        cachesDirectory: { FileManager.default.cachesDirectory },
        applicationsDirectory: { URL(fileURLWithPath: "/Applications") },
        temporaryDirectory: { destination in
            (try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true))
                ?? FileManager.default.temporaryDirectory
        },
        trashItem: { url in
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
            return trashedURL as URL?
        },
        removeItem: { url in
            try FileManager.default.removeItem(at: url)
        }
    )

    public static let testValue = FileSystemClient()
}

extension KeychainClient: DependencyKey {
    public static let liveValue = KeychainClient(
        load: { try await KeychainVault.shared.load() },
        reload: { try await KeychainVault.shared.reload() },
        stage: { change in try await KeychainVault.shared.stage(change) },
        commit: { change in try await KeychainVault.shared.commit(change) }
    )

    public static let testValue = KeychainClient()
}

extension WorkspaceClient: DependencyKey {
    public static let liveValue = WorkspaceClient(
        revealInFinder: { url in
            await MainActor.run {
                _ = NSWorkspace.shared.selectFile(
                    url.path,
                    inFileViewerRootedAtPath: url.deletingLastPathComponent().path
                )
            }
        }
    )

    public static let testValue = WorkspaceClient()
}

extension Logger: DependencyKey {
    public static let liveValue = TerminalRenderer(options: .detect(isVerbose: false, isQuiet: false, isJSON: false, allowsColors: true)).logger

    public static let testValue = Logger { event in
        reportIssue("Unimplemented: logger was asked to emit \(event)")
    }
}

extension PromptClient: DependencyKey {
    public static let liveValue = PromptClient.live

    public static let testValue = PromptClient(
        ask: { message, _, _ in
            reportIssue("Unimplemented: prompt.ask(\"\(message)\")")
            return ""
        },
        choose: { message, _ in
            reportIssue("Unimplemented: prompt.choose(\"\(message)\")")
            return 0
        },
        agree: { message in
            reportIssue("Unimplemented: prompt.agree(\"\(message)\")")
            return false
        },
        readLine: { prompt in
            reportIssue("Unimplemented: prompt.readLine(\"\(prompt)\")")
            return ""
        },
        readSecret: { prompt in
            reportIssue("Unimplemented: prompt.readSecret(\"\(prompt)\")")
            return ""
        }
    )
}

public extension DependencyValues {
    var xcodeReleases: XcodeReleasesClient {
        get { self[XcodeReleasesClient.self] }
        set { self[XcodeReleasesClient.self] = newValue }
    }

    var credentials: CredentialsClient {
        get { self[CredentialsClient.self] }
        set { self[CredentialsClient.self] = newValue }
    }

    var authentication: AuthenticationClient {
        get { self[AuthenticationClient.self] }
        set { self[AuthenticationClient.self] = newValue }
    }

    var downloads: DownloadClient {
        get { self[DownloadClient.self] }
        set { self[DownloadClient.self] = newValue }
    }

    var extraction: ExtractionClient {
        get { self[ExtractionClient.self] }
        set { self[ExtractionClient.self] = newValue }
    }

    var processes: ProcessClient {
        get { self[ProcessClient.self] }
        set { self[ProcessClient.self] = newValue }
    }

    var fileSystem: FileSystemClient {
        get { self[FileSystemClient.self] }
        set { self[FileSystemClient.self] = newValue }
    }

    var keychain: KeychainClient {
        get { self[KeychainClient.self] }
        set { self[KeychainClient.self] = newValue }
    }

    var workspace: WorkspaceClient {
        get { self[WorkspaceClient.self] }
        set { self[WorkspaceClient.self] = newValue }
    }

    var logger: Logger {
        get { self[Logger.self] }
        set { self[Logger.self] = newValue }
    }

    var prompt: PromptClient {
        get { self[PromptClient.self] }
        set { self[PromptClient.self] = newValue }
    }
}

extension HTTPCookieStorage {
    static let xcinfo: HTTPCookieStorage = URLSessionConfiguration.ephemeral.httpCookieStorage ?? HTTPCookieStorage()

    func removeAppleCookies() {
        (cookies ?? []).filter { $0.domain == "apple.com" || $0.domain.hasSuffix(".apple.com") }.forEach(deleteCookie)
    }
}

extension URLSession {
    static let xcinfo: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = HTTPCookieStorage.xcinfo
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    static let xcinfoDownloads: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = HTTPCookieStorage.xcinfo
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: configuration)
    }()
}

extension FileManager {
    var cachesDirectory: URL {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = cachesDirectory.appendingPathComponent("xcinfo")
        if (try? FileManager.default.ensureFolderExists(directory)) != nil {
            return directory
        }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("xcinfo")
        try? FileManager.default.ensureFolderExists(fallback)
        return fallback
    }

    func ensureFolderExists(_ folder: URL) throws {
        if !fileExists(atPath: folder.path) {
            try createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}
