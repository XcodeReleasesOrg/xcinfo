//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import AppKit
import Foundation
import OlympUs
import XCIFoundation

public struct Environment {
    public var logger: Logger
    public var api: APIClient
    public var cachesDirectory: URL
    public var credentialProviding: CredentialProviding
    public var authenticationProviding: AuthenticationProviding
    public var downloadProviding: DownloadProviding
    public var extractionProviding: ExtractionProviding
    public var shell: ShellClient
    public var prompt: PromptClient
    public var applicationsDirectory: URL
    public var revealInFinder: (URL) -> Void
}

public struct ShellClient {
    var execute: (_ command: String, _ args: [String]) -> ProcessExecutionResult
    var executePrivileged: (_ command: String, _ password: String, _ args: [String]) -> ProcessExecutionResult
}

extension ShellClient {
    static let live = ShellClient(
        execute: { command, args in
            Shell.execute(command, args: args)
        },
        executePrivileged: { command, password, args in
            Shell.executePrivileged(command: command, password: password, args: args)
        }
    )
}

public struct ExtractionProviding {
    var extract: (_ source: URL, _ destination: URL, _ appFilename: String?, _ useLegacyUnxip: Bool, _ logger: Logger) async throws -> URL
}

extension ExtractionProviding {
    static let live = ExtractionProviding { source, destination, appFilename, useLegacyUnxip, logger in
        let extractor = Extractor(
            forReadingFromContainerAt: source,
            destination: destination,
            appFilename: appFilename,
            logger: logger
        )
        if useLegacyUnxip {
            return try await extractor.extract()
        } else {
            return try await extractor.extractExperimental()
        }
    }
}

public extension Environment {
    static func live(isVerboseLoggingEnabled: Bool = false) -> Self {
        let logger = Logger(isVerbose: isVerboseLoggingEnabled)
        let credentialsService = CredentialService(logger: logger)

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = .shared
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config, delegate: sessionDelegateProxy, delegateQueue: nil)
        let xcReleasesAPI = XCReleasesAPI(
            baseURL: URL(string: "https://xcodereleases.com/data.json")!,
            session: session
        )

        let olymp = OlympUs(logger: logger, session: session)
        let downloader = Downloader(logger: logger, olymp: olymp, sessionDelegateProxy: sessionDelegateProxy)
        let authenticator = AppleAuthenticator(olymp: olymp, logger: logger)

        return .init(
            logger: logger,
            api: xcReleasesAPI.apiClient,
            cachesDirectory: FileManager.default.cachesDirectory,
            credentialProviding: credentialsService.credentialProviding,
            authenticationProviding: authenticator.authenticationProviding,
            downloadProviding: downloader.downloadProviding,
            extractionProviding: .live,
            shell: .live,
            prompt: .live,
            applicationsDirectory: URL(fileURLWithPath: "/Applications"),
            revealInFinder: { url in
                NSWorkspace.shared.selectFile(
                    url.path,
                    inFileViewerRootedAtPath: url.deletingLastPathComponent().path
                )
            }
        )
    }
}

private let xcReleasesAPI: XCReleasesAPI = {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieAcceptPolicy = .always
    config.httpCookieStorage = .shared
    config.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: config, delegate: sessionDelegateProxy, delegateQueue: nil)
    return XCReleasesAPI(baseURL: URL(string: "https://xcodereleases.com/data.json")!, session: session)
}()

private let sessionDelegateProxy = URLSessionDelegateProxy()

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
