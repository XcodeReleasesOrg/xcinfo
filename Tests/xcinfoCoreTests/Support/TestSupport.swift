import Foundation
import os
import XCIFoundation
import Dependencies
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.
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
    private let recorder = Recorder<OutputEvent>()

    func logger(isVerbose _: Bool = false) -> XCIFoundation.Logger {
        XCIFoundation.Logger { [recorder] in recorder.append($0) }
    }

    var events: [OutputEvent] {
        recorder.values
    }

    var messages: [String] {
        events.compactMap { event in
            switch event {
            case let .section(title), let .paragraph(title):
                "\n" + title
            case let .message(text, _), let .verbose(text):
                text
            case let .check(title, .running):
                "\(title)..."
            case let .check(title, .passed):
                "\(title) ✓"
            case let .check(title, .failed):
                "\(title) ✗"
            case .progress:
                nil
            }
        }
    }

    var progress: [OutputProgress] {
        events.compactMap { event in
            guard case let .progress(progress) = event else { return nil }
            return progress
        }
    }

    var text: String {
        messages.joined(separator: "\n")
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
    typealias Handler = @Sendable (ShellCall) -> (exitStatus: Int32, stdout: String, stderr: String)

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

    var client: ProcessClient {
        ProcessClient(
            run: { [calls, handler] command, args in
                let call = ShellCall(command: command, args: args, password: nil)
                calls.append(call)
                let result = handler(call)
                return ProcessResult(exitStatus: result.exitStatus, stdout: result.stdout, stderr: result.stderr)
            },
            runPrivileged: { [calls, handler] command, password, args in
                let call = ShellCall(command: command, args: args, password: password)
                calls.append(call)
                let result = handler(call)
                return ProcessResult(exitStatus: result.exitStatus, stdout: result.stdout, stderr: result.stderr)
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
    let lines = Recorder<String>()
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
            readLine: { [lines, answers] prompt in
                lines.append(prompt)
                return answers.withLock { $0.isEmpty ? "" : $0.removeFirst() }
            },
            readSecret: { [secrets, passwords] prompt in
                secrets.append(prompt)
                return passwords.withLock { $0.isEmpty ? "" : $0.removeFirst() }
            }
        )
    }
}

extension Core {
    static func test(
        logs: LogRecorder,
        isVerbose: Bool = false,
        cachesDirectory: URL,
        listXcodes: (@Sendable () async throws -> [Xcode])? = nil,
        removeCookies: (@Sendable () -> Void)? = nil,
        accountName: (@Sendable () async throws -> String)? = nil,
        password: (@Sendable (String) async throws -> String)? = nil,
        cleanupCredentials: (@Sendable () async -> Void)? = nil,
        authenticate: (@Sendable (String, @escaping @Sendable () async throws -> String) async throws -> Void)? = nil,
        cleanupAuthentication: (@Sendable () async -> Void)? = nil,
        download: (@Sendable (URL, URL, Bool) async throws -> URL)? = nil,
        extract: (@Sendable (URL, URL, String?, Bool) async throws -> URL)? = nil,
        shell: FakeShell? = nil,
        prompt: FakePrompt? = nil,
        applicationsDirectory: URL,
        revealInFinder: (@Sendable (URL) -> Void)? = nil,
        trashItem: (@Sendable (URL) throws -> URL?)? = nil
    ) -> Core {
        withDependencies {
            $0.logger = logs.logger(isVerbose: isVerbose)
            $0.fileSystem = FileSystemClient(
                cachesDirectory: { cachesDirectory },
                applicationsDirectory: { applicationsDirectory },
                temporaryDirectory: { _ in cachesDirectory },
                trashItem: trashItem ?? { url in
                    let trash = cachesDirectory.appendingPathComponent("Trash")
                    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                    let trashed = trash.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.moveItem(at: url, to: trashed)
                    return trashed
                },
                removeItem: { try FileManager.default.removeItem(at: $0) }
            )
            if let listXcodes { $0.xcodeReleases.listXcodes = listXcodes }
            if let removeCookies { $0.xcodeReleases.removeCookies = removeCookies }
            if let accountName { $0.credentials.accountName = accountName }
            if let password { $0.credentials.password = password }
            if let cleanupCredentials { $0.credentials.removeAll = cleanupCredentials }
            if let authenticate { $0.authentication.authenticate = authenticate }
            if let cleanupAuthentication { $0.authentication.cleanup = cleanupAuthentication }
            if let download { $0.downloads.download = download }
            if let extract { $0.extraction.extract = extract }
            if let shell { $0.processes = shell.client }
            if let prompt { $0.prompt = prompt.client }
            if let revealInFinder { $0.workspace.revealInFinder = { revealInFinder($0) } }
        } operation: {
            Core()
        }
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
        compilers: Compilers? = nil,
        sha1: String? = nil
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
            links: links,
            checksums: sha1.map { Checksums(sha1: $0) }
        )
    }
}

extension Date {
    static func monthsAgo(_ months: Int) -> Date {
        Calendar.current.date(byAdding: .month, value: -months, to: Date())!
    }
}
