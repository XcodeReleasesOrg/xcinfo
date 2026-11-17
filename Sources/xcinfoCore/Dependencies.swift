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
    public var credentials: @Sendable () throws -> Credentials
    public var removeAll: @Sendable () -> Void
}

@DependencyClient
public struct AuthenticationClient: Sendable {
    public var authenticate: @Sendable (_ credentials: Credentials) async throws -> Void
    public var cleanup: @Sendable () -> Void
}

@DependencyClient
public struct DownloadClient: Sendable {
    public var download: @Sendable (_ url: URL, _ destination: URL, _ disableSleep: Bool) async throws -> URL
}

@DependencyClient
public struct ExtractionClient: Sendable {
    public var extract: @Sendable (_ source: URL, _ destination: URL, _ appFilename: String?, _ useLegacyUnxip: Bool) async throws -> URL
}

@DependencyClient
public struct ProcessClient: Sendable {
    public var run: @Sendable (_ command: String, _ arguments: [String]) async throws -> ProcessResult
    public var runPrivileged: @Sendable (_ command: String, _ password: String, _ arguments: [String]) async throws -> ProcessResult
}

@DependencyClient
public struct FileSystemClient: Sendable {
    public var cachesDirectory: @Sendable () -> URL = { URL(fileURLWithPath: NSTemporaryDirectory()) }
    public var applicationsDirectory: @Sendable () -> URL = { URL(fileURLWithPath: NSTemporaryDirectory()) }
    public var temporaryDirectory: @Sendable () -> URL = { URL(fileURLWithPath: NSTemporaryDirectory()) }
}

@DependencyClient
public struct KeychainClient: Sendable {
    public var accounts: @Sendable (_ service: String) throws -> [String]
    public var readPassword: @Sendable (_ service: String, _ account: String) throws -> String
    public var savePassword: @Sendable (_ password: String, _ service: String, _ account: String) throws -> Void
    public var deleteAll: @Sendable (_ service: String) throws -> Int
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
        credentials: { try CredentialService().appleIDCredentials() },
        removeAll: { CredentialService().cleanup() }
    )

    public static let testValue = CredentialsClient()
}

extension AuthenticationClient: DependencyKey {
    public static let liveValue = AuthenticationClient(
        authenticate: { credentials in
            @Dependency(\.logger) var logger
            @Dependency(\.prompt) var prompt
            let olymp = OlympUs(logger: logger, session: .xcinfo, prompt: prompt)
            try await AppleAuthenticator(olymp: olymp, logger: logger).authenticate(credentials: credentials)
        },
        cleanup: {
            @Dependency(\.logger) var logger
            OlympUs(logger: logger, session: .xcinfo).cleanup()
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
            return try await downloader.download(url: url, destination: destination, disableSleep: disableSleep)
        }
    )

    public static let testValue = DownloadClient()
}

extension ExtractionClient: DependencyKey {
    public static let liveValue = ExtractionClient(
        extract: { source, destination, appFilename, useLegacyUnxip in
            @Dependency(\.logger) var logger
            @Dependency(\.fileSystem) var fileSystem
            let extractor = Extractor(
                forReadingFromContainerAt: source,
                destination: destination,
                appFilename: appFilename,
                temporaryDirectory: fileSystem.temporaryDirectory(),
                logger: logger
            )
            if useLegacyUnxip {
                return try await extractor.extract()
            } else {
                return try await extractor.extractExperimental()
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
            try await ProcessRunner.runPrivileged(command, password: password, arguments: arguments)
        }
    )

    public static let testValue = ProcessClient()
}

extension FileSystemClient: DependencyKey {
    public static let liveValue = FileSystemClient(
        cachesDirectory: { FileManager.default.cachesDirectory },
        applicationsDirectory: { URL(fileURLWithPath: "/Applications") },
        temporaryDirectory: { FileManager.default.temporaryDirectory }
    )

    public static let testValue = FileSystemClient()
}

extension KeychainClient: DependencyKey {
    public static let liveValue = KeychainClient(
        accounts: { service in
            try KeychainPasswordItem.passwordItems(forService: service).map(\.account)
        },
        readPassword: { service, account in
            try KeychainPasswordItem(service: service, account: account).readPassword()
        },
        savePassword: { password, service, account in
            try KeychainPasswordItem(service: service, account: account).savePassword(password, overwriteExisting: true)
        },
        deleteAll: { service in
            let items = try KeychainPasswordItem.passwordItems(forService: service)
            for item in items {
                try item.deleteItem()
            }
            return items.count
        }
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

extension URLSession {
    static let xcinfo: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = .shared
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()

    static let xcinfoDownloads: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = .shared
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: configuration)
    }()
}

extension FileManager {
    var cachesDirectory: URL {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var directory = cachesDirectory.appendingPathComponent("xcinfo")
        do {
            try FileManager.default.ensureFolderExists(directory)
        } catch {
            directory = URL(filePath: "~/.xcinfo")
            if let _ = try? FileManager.default.ensureFolderExists(directory) {
                return directory
            } else {
                fail(statusCode: 1, errorMessage: "Could create caches directory.")
            }
        }
        return directory
    }

    func ensureFolderExists(_ folder: URL) throws {
        if !fileExists(atPath: folder.path) {
            try createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}
