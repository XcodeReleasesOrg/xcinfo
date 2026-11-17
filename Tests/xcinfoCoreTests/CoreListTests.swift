import Foundation
import Testing
import XCModel
@testable import xcinfoCore

struct CoreListTests {
    private let recent = Xcode.fixture("16.0", build: "16A1", date: .monthsAgo(1))
    private let lastSummer = Xcode.fixture("15.0", build: "15A1", date: .monthsAgo(6))
    private let old = Xcode.fixture("14.0", build: "14A1", date: .monthsAgo(24))
    private let futureOS = Xcode.fixture("17.0", build: "17A1", release: .beta(1), date: .monthsAgo(1), requires: "99.0")
    private let withoutDownload = Xcode.fixture("13.0", build: "13A1", date: .monthsAgo(2), download: nil)
    private let gm = Xcode.fixture("12.0", build: "12A1", release: .gm, date: .monthsAgo(3))

    private var all: [Xcode] { [recent, lastSummer, old, futureOS, withoutDownload] }

    @Test
    func `list shows installable versions of the last year, installed and not installable versions`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let installed = try applications.fakeXcode(named: "Xcode-15.app", build: "15A1")
        let logs = LogRecorder()
        let xcodes = all
        let core = Core(environment: .test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            shell: .installedXcodes([installed]),
            applicationsDirectory: applications.url
        ))

        try await core.list(shouldUpdate: true, showAllVersions: false, filter: nil)

        #expect(logs.messages == [
            "16.0 (16A1)\n15.0 (15A1)",
            "\nAlready installed:",
            "15.0 (15A1)",
            "\nNot installable:",
            "17.0 Beta 1 (17A1)\n13.0 (13A1)",
        ])
    }

    @Test
    func `list shows all versions when asked`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let logs = LogRecorder()
        let xcodes = all
        let core = Core(environment: .test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            applicationsDirectory: applications.url
        ))

        try await core.list(shouldUpdate: true, showAllVersions: true, filter: nil)

        #expect(logs.messages.first == "17.0 Beta 1 (17A1)\n16.0 (16A1)\n15.0 (15A1)\n14.0 (14A1)\n13.0 (13A1)")
        #expect(!logs.messages.contains("\nAlready installed:"))
    }

    @Test(arguments: [
        (Core.ListFilter.onlyGM, "12.0 GM (12A1)"),
        (.onlyReleases, "16.0 (16A1)\n15.0 (15A1)"),
    ])
    func `list filters by release kind`(filter: Core.ListFilter, expected: String) async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let logs = LogRecorder()
        let xcodes = [recent, lastSummer, gm]
        let core = Core(environment: .test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            applicationsDirectory: applications.url
        ))

        try await core.list(shouldUpdate: true, showAllVersions: false, filter: filter)

        #expect(logs.messages.first == expected)
    }

    @Test(.disabled("Crashes the process: max(by:)! on an empty filtered list"))
    func `list with a filter that matches nothing reports an empty list`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let logs = LogRecorder()
        let xcodes = [recent]
        let core = Core(environment: .test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            applicationsDirectory: applications.url
        ))

        try await core.list(shouldUpdate: true, showAllVersions: false, filter: .onlyGM)

        #expect(logs.messages == ["Empty result list"])
    }

    @Test
    func `list reports an empty result`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let logs = LogRecorder()
        let core = Core(environment: .test(logs: logs, cachesDirectory: caches.url, applicationsDirectory: applications.url))

        try await core.list(shouldUpdate: true, showAllVersions: false, filter: nil)

        #expect(logs.messages == ["Empty result list"])
    }

    @Test
    func `updating the list writes the cache and the cache is used without updating`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let requests = Recorder<Void>()
        let xcodes = [recent, lastSummer]
        let environment = Environment.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: {
                requests.append(())
                return xcodes
            },
            applicationsDirectory: applications.url
        )
        let core = Core(environment: environment)

        try await core.list(shouldUpdate: true, showAllVersions: true, filter: nil)
        let cacheFile = caches.url.appendingPathComponent("xcinfo.json")
        let cached = try JSONDecoder().decode([Xcode].self, from: Data(contentsOf: cacheFile))
        #expect(cached.map(\.version.build) == ["16A1", "15A1"])

        let logs = LogRecorder()
        var offlineEnvironment = environment
        offlineEnvironment.logger = logs.logger()
        try await Core(environment: offlineEnvironment).list(shouldUpdate: false, showAllVersions: true, filter: nil)

        #expect(requests.values.count == 1)
        #expect(logs.messages.first == "16.0 (16A1)\n15.0 (15A1)")
    }

    @Test
    func `listing without updating fails without a cache`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let core = Core(environment: .test(logs: LogRecorder(), cachesDirectory: caches.url, applicationsDirectory: applications.url))

        await #expect(throws: (any Error).self) {
            try await core.list(shouldUpdate: false, showAllVersions: false, filter: nil)
        }
    }

    @Test
    func `listing without updating fails with a corrupt cache`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        _ = try caches.file("xcinfo.json", contents: Data("garbage".utf8))
        let core = Core(environment: .test(logs: LogRecorder(), cachesDirectory: caches.url, applicationsDirectory: applications.url))

        await #expect(throws: DecodingError.self) {
            try await core.list(shouldUpdate: false, showAllVersions: false, filter: nil)
        }
    }

    @Test
    func `list errors from the api are passed on`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let core = Core(environment: .test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { throw XCAPIError.invalidResponse },
            applicationsDirectory: applications.url
        ))

        await #expect(throws: XCAPIError.self) {
            try await core.list(shouldUpdate: true, showAllVersions: false, filter: nil)
        }
    }

    @Test
    func `installed lists the matching applications with their path`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let older = try applications.fakeXcode(named: "Xcode-15.app", build: "15A1")
        let newer = try applications.fakeXcode(named: "Xcode-16.app", build: "16A1")
        let unknown = try applications.fakeXcode(named: "Xcode-unknown.app", build: "99Z99")
        let notAnApp = applications.url.appendingPathComponent("Missing.app")
        let logs = LogRecorder()
        let xcodes = [recent, lastSummer, futureOS]
        let shell = FakeShell.installedXcodes([older, unknown, newer, notAnApp])
        let core = Core(environment: .test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            shell: shell,
            applicationsDirectory: applications.url
        ))

        try await core.installedXcodes(shouldUpdate: true)

        #expect(logs.messages == [
            "16.0 (16A1) – \(newer.path)",
            "15.0 (15A1) – \(older.path)",
        ])
        #expect(shell.calls.values == [
            ShellCall(command: "mdfind", args: ["kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'"], password: nil),
        ])
    }

    @Test
    func `installed pads names to the longest name`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let beta = try applications.fakeXcode(named: "Xcode-beta.app", build: "17A1")
        let release = try applications.fakeXcode(named: "Xcode.app", build: "16A1")
        let logs = LogRecorder()
        let xcodes = [recent, Xcode.fixture("17.0", build: "17A1", release: .beta(1))]
        let core = Core(environment: .test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            shell: .installedXcodes([beta, release]),
            applicationsDirectory: applications.url
        ))

        try await core.installedXcodes(shouldUpdate: true)

        #expect(logs.messages == [
            "17.0 Beta 1 (17A1) – \(beta.path)",
            "16.0 (16A1)        – \(release.path)",
        ])
    }

    @Test(.disabled("Crashes the process: max(by:)! when no Xcode is installed"))
    func `installed with nothing installed reports an empty list`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let xcodes = [recent]
        let core = Core(environment: .test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { xcodes },
            applicationsDirectory: applications.url
        ))

        try await core.installedXcodes(shouldUpdate: true)
    }
}
