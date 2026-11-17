import Foundation
import os
import XCIFoundation
import XCModel
@testable import xcinfoCore

final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcinfo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String, contents: Data = Data()) throws -> URL {
        let fileURL = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL)
        return fileURL
    }

    func directory(_ name: String) throws -> URL {
        let directoryURL = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    func fakeXcode(named name: String, build: String, shortVersion: String = "1.0") throws -> URL {
        let appURL = try directory(name)
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let versionPlist = try PropertyListSerialization.data(
            fromPropertyList: ["ProductBuildVersion": build],
            format: .xml,
            options: 0
        )
        try versionPlist.write(to: contents.appendingPathComponent("version.plist"))
        let infoPlist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": shortVersion],
            format: .xml,
            options: 0
        )
        try infoPlist.write(to: contents.appendingPathComponent("Info.plist"))
        return appURL
    }
}

final class Recorder<Value: Sendable>: Sendable {
    private let storage: OSAllocatedUnfairLock<[Value]>

    init() {
        storage = OSAllocatedUnfairLock(initialState: [])
    }

    func append(_ value: Value) {
        storage.withLock { $0.append(value) }
    }

    var values: [Value] {
        storage.withLock { $0 }
    }
}

final class LogRecorder: Sendable {
    private let recorder = Recorder<String>()

    func logger(isVerbose: Bool = false) -> XCIFoundation.Logger {
        Logger(isVerbose: isVerbose, output: { [recorder] in recorder.append($0) })
    }

    var rawMessages: [String] {
        recorder.values
    }

    var messages: [String] {
        rawMessages.map(\.strippingANSI)
    }

    var text: String {
        messages.joined(separator: "\n")
    }

    var lines: [String] {
        text.components(separatedBy: "\n")
    }
}

extension String {
    var strippingANSI: String {
        replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}

struct ShellCall: Sendable, Equatable {
    var command: String
    var args: [String]
    var password: String?
}

final class FakeShell: Sendable {
    typealias Handler = @Sendable (ShellCall) -> (exitStatus: Int, stdout: String, stderr: String)

    let calls = Recorder<ShellCall>()
    private let handler: Handler

    init(handler: @escaping Handler = { _ in (0, "", "") }) {
        self.handler = handler
    }

    static func installedXcodes(_ urls: [URL], otherwise: @escaping Handler = { _ in (0, "", "") }) -> FakeShell {
        FakeShell { call in
            if call.command == "mdfind" {
                return (0, urls.map(\.path).joined(separator: "\n") + "\n", "")
            }
            return otherwise(call)
        }
    }

    var client: ShellClient {
        ShellClient(
            execute: { [calls, handler] command, args in
                let call = ShellCall(command: command, args: args, password: nil)
                calls.append(call)
                return handler(call)
            },
            executePrivileged: { [calls, handler] command, password, args in
                let call = ShellCall(command: command, args: args, password: password)
                calls.append(call)
                return handler(call)
            }
        )
    }

    var privilegedCalls: [ShellCall] {
        calls.values.filter { $0.password != nil }
    }
}

final class FakePrompt: Sendable {
    let asked = Recorder<String>()
    let chosen = Recorder<[String]>()
    let agreed = Recorder<String>()
    let secrets = Recorder<String>()

    private let answers: OSAllocatedUnfairLock<[String]>
    private let choiceIndices: OSAllocatedUnfairLock<[Int]>
    private let agreement: Bool
    private let passwords: OSAllocatedUnfairLock<[String]>

    init(answers: [String] = [], choices: [Int] = [], agree: Bool = true, passwords: [String] = []) {
        self.answers = OSAllocatedUnfairLock(initialState: answers)
        choiceIndices = OSAllocatedUnfairLock(initialState: choices)
        agreement = agree
        self.passwords = OSAllocatedUnfairLock(initialState: passwords)
    }

    var client: PromptClient {
        PromptClient(
            ask: { [asked, answers] message, _, _ in
                asked.append(message)
                return answers.withLock { $0.isEmpty ? "" : $0.removeFirst() }
            },
            choose: { [chosen, choiceIndices] _, choices in
                chosen.append(choices.map(\.strippingANSI))
                return choiceIndices.withLock { $0.isEmpty ? 0 : $0.removeFirst() }
            },
            agree: { [agreed, agreement] message in
                agreed.append(message.strippingANSI)
                return agreement
            },
            readSecret: { [secrets, passwords] prompt in
                secrets.append(prompt)
                return passwords.withLock { $0.isEmpty ? "" : $0.removeFirst() }
            }
        )
    }
}

extension Environment {
    static func test(
        logs: LogRecorder,
        isVerbose: Bool = false,
        cachesDirectory: URL,
        listXcodes: @escaping () async throws -> [Xcode] = { [] },
        removeCookies: @escaping () -> Void = {},
        getCredentials: @escaping () throws -> Credentials = { Credentials(username: "user", password: "secret") },
        cleanupCredentials: @escaping () -> Void = {},
        authenticate: @escaping (Credentials) async throws -> Void = { _ in },
        download: @escaping (URL, URL, Bool) async throws -> URL = { url, destination, _ in
            destination.appendingPathComponent(url.lastPathComponent)
        },
        cleanupDownloads: @escaping () -> Void = {},
        extract: @escaping (URL, URL, String?, Bool, XCIFoundation.Logger) async throws -> URL = { _, destination, filename, _, _ in
            destination.appendingPathComponent(filename ?? "Xcode.app")
        },
        shell: FakeShell = FakeShell(),
        prompt: FakePrompt = FakePrompt(),
        applicationsDirectory: URL,
        revealInFinder: @escaping (URL) -> Void = { _ in }
    ) -> Environment {
        Environment(
            logger: logs.logger(isVerbose: isVerbose),
            api: APIClient(listXcodes: listXcodes, removeCookies: removeCookies),
            cachesDirectory: cachesDirectory,
            credentialProviding: CredentialProviding(getCredentials: getCredentials, cleanup: cleanupCredentials),
            authenticationProviding: AuthenticationProviding(authenticate: authenticate),
            downloadProviding: DownloadProviding(download: download, cleanup: cleanupDownloads),
            extractionProviding: ExtractionProviding(extract: extract),
            shell: shell.client,
            prompt: prompt.client,
            applicationsDirectory: applicationsDirectory,
            revealInFinder: revealInFinder
        )
    }
}

extension Xcode {
    static func fixture(
        _ number: String,
        build: String,
        release: Release = .release,
        date: Date = Date(),
        requires: String = "13.0",
        download: String? = "https://download.example.invalid/Xcode.xip",
        notes: String? = nil,
        sdks: SDKs? = nil,
        compilers: Compilers? = nil
    ) -> Xcode {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let links = (download == nil && notes == nil)
            ? nil
            : Links(download: download.map { Link($0) }, notes: notes.map { Link($0) })
        return Xcode(
            version: Version(build, number, release),
            date: (components.year!, components.month!, components.day!),
            requires: requires,
            sdks: sdks,
            compilers: compilers,
            links: links
        )
    }
}

extension Date {
    static func monthsAgo(_ months: Int) -> Date {
        Calendar.current.date(byAdding: .month, value: -months, to: Date())!
    }
}
