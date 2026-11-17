import Foundation
import Testing
import XCIFoundation
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.
@testable import xcinfo
@testable import XCInfoTUI
@testable import xcinfoCore

struct SwitchTests {
    private let xcodes = [Xcode.fixture("16.0", build: "16A1"), .fixture("15.0", build: "15A1", release: .beta(2)), .fixture("15.0", build: "15A2")]

    private struct Fixture {
        let caches: TemporaryDirectory
        let applications: TemporaryDirectory
        let logs = LogRecorder()
        let shell: FakeShell
        let prompt: FakePrompt
        let core: Core

        init(xcodes: [Xcode], apps: (TemporaryDirectory) throws -> [URL], prompt: FakePrompt = FakePrompt(passwords: ["sudo-password"])) throws {
            caches = try TemporaryDirectory()
            applications = try TemporaryDirectory()
            shell = .installedXcodes(try apps(applications))
            self.prompt = prompt
            core = Core.test(logs: logs, cachesDirectory: caches.url, listXcodes: { xcodes }, shell: shell, prompt: prompt, applicationsDirectory: applications.url)
        }

        var symlink: URL {
            applications.url.appendingPathComponent("Xcode.app")
        }
    }

    @Test
    func `switch points the link to the chosen xcode and selects it`() async throws {
        let fixture = try Fixture(xcodes: xcodes) { [try $0.fakeXcode(named: "Xcode-16.app", build: "16A1")] }
        let app = fixture.applications.url.appendingPathComponent("Xcode-16.app")

        let switched = try await fixture.core.switchXcode(to: "16", options: .init(), updateVersionList: true)

        #expect(switched.url == app)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.symlink.path) == app.path)
        #expect(fixture.shell.privilegedCalls.map(\.command) == ["ls", "xcode-select"])
        #expect(fixture.shell.privilegedCalls.last?.args == ["-s", app.path])
        #expect(fixture.prompt.secrets.values == ["Mac administrator password for \(NSUserName()) (sudo):"])
        #expect(fixture.logs.messages.contains("Selecting Xcode needs administrator rights (sudo) to run xcode-select."))
        #expect(fixture.logs.messages.last == "Switched to Xcode 16.0 (16A1) at \(app.path).")
    }

    @Test
    func `several matches are offered with their paths`() async throws {
        let prompt = FakePrompt(choices: [1], passwords: ["sudo-password"])
        let fixture = try Fixture(xcodes: xcodes, apps: {
            [try $0.fakeXcode(named: "Xcode-15-copy.app", build: "15A2"), try $0.fakeXcode(named: "Xcode-15.app", build: "15A2")]
        }, prompt: prompt)

        let switched = try await fixture.core.switchXcode(to: "15", options: .init(skipXcodeSelection: true), updateVersionList: true)

        let choices = try #require(prompt.chosen.values.first)
        #expect(choices.count == 2)
        #expect(choices.allSatisfy { $0.contains(fixture.applications.url.path) })
        #expect(switched.url.lastPathComponent == (choices[1].contains("Xcode-15-copy.app") ? "Xcode-15-copy.app" : "Xcode-15.app"))
        #expect(fixture.shell.privilegedCalls.isEmpty)
    }

    @Test
    func `both changes can be skipped`() async throws {
        let fixture = try Fixture(xcodes: xcodes) { [try $0.fakeXcode(named: "Xcode-16.app", build: "16A1")] }

        try await fixture.core.switchXcode(to: "16a1", options: .init(skipSymlinkCreation: true, skipXcodeSelection: true), updateVersionList: true)

        #expect(!FileManager.default.fileExists(atPath: fixture.symlink.path))
        #expect(fixture.shell.privilegedCalls.isEmpty)
        #expect(fixture.prompt.secrets.values.isEmpty)
    }

    @Test
    func `an xcode that is itself at Xcode.app keeps its place`() async throws {
        let fixture = try Fixture(xcodes: xcodes) { [try $0.fakeXcode(named: "Xcode.app", build: "16A1")] }

        try await fixture.core.switchXcode(to: "16", options: .init(skipXcodeSelection: true), updateVersionList: true)

        #expect(!FileManager.default.isSymbolicLink(atPath: fixture.symlink.path))
        #expect(FileManager.default.fileExists(atPath: fixture.symlink.appendingPathComponent("Contents/version.plist").path))
        #expect(fixture.logs.messages.contains("\(fixture.symlink.path) is this Xcode itself, so there is no link to change."))
    }

    @Test
    func `no installed match is a version not found error`() async throws {
        let fixture = try Fixture(xcodes: xcodes) { [try $0.fakeXcode(named: "Xcode-16.app", build: "16A1")] }

        await #expect {
            try await fixture.core.switchXcode(to: "13", options: .init(), updateVersionList: true)
        } throws: { error in
            guard case CoreError.noInstalledXcode("13") = error else { return false }
            return error.exitCode == 3
        }
    }

    @Test
    func `switch options are parsed`() throws {
        let command = try XCInfo.Switch.parse(["15.0 Beta 2", "--no-symlink", "--no-xcode-select", "--no-update-list"])

        #expect(command.xcodeVersion == "15.0 Beta 2")
        #expect(command.skipSymlinkCreation)
        #expect(command.skipXcodeSelection)
        #expect(!command.listOptions.updateList)
        #expect(try XCInfo.Switch.parse([]).xcodeVersion == nil)
    }

    @Test
    func `the terminal UI switches to an installed version with s`() {
        let app = XcodeApplication(url: URL(fileURLWithPath: "/Applications/Xcode-16.app"), xcode: xcodes[0])
        var model = TUIModel(sections: [
            TUISection(title: "Installed", entries: [TUIEntry(kind: .installed(app.url), xcode: app.xcode)]),
            TUISection(title: "Available", entries: [TUIEntry(kind: .available, xcode: xcodes[2])]),
        ])

        #expect(model.handle(.character("s")) == .switchTo(app))
        _ = model.handle(.down)
        #expect(model.handle(.character("s")) == nil)
        #expect(model.status == "Only installed versions can be switched to.")
    }

    @Test
    func `xcode-select runs before the link changes`() async throws {
        let order = Recorder<String>()
        let fixture = try Fixture(xcodes: xcodes) { [try $0.fakeXcode(named: "Xcode-16.app", build: "16A1")] }
        let shell = FakeShell { call in
            if call.command == "mdfind" { return (0, fixture.applications.url.appendingPathComponent("Xcode-16.app").path + "\n", "") }
            if call.command == "xcode-select" {
                order.append(FileManager.default.isSymbolicLink(atPath: fixture.symlink.path) ? "link first" : "select first")
            }
            return (0, "", "")
        }
        let core = Core.test(logs: fixture.logs, cachesDirectory: fixture.caches.url, listXcodes: { [xcodes] in xcodes }, shell: shell, prompt: fixture.prompt, applicationsDirectory: fixture.applications.url)

        try await core.switchXcode(to: "16", options: .init(), updateVersionList: true)

        #expect(order.values == ["select first"])
        #expect(FileManager.default.isSymbolicLink(atPath: fixture.symlink.path))
    }

    @Test
    func `a cancelled password question changes nothing`() async throws {
        let fixture = try Fixture(xcodes: xcodes, apps: { [try $0.fakeXcode(named: "Xcode-16.app", build: "16A1")] }, prompt: FakePrompt(cancelsOnSecret: true))

        await #expect(throws: CancellationError.self) {
            try await fixture.core.switchXcode(to: "16", options: .init(), updateVersionList: true)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.symlink.path))
        #expect(fixture.shell.privilegedCalls.isEmpty)
        #expect(fixture.logs.messages.contains("Nothing was changed."))
    }

    @Test
    func `a rejected password changes nothing`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let app = try applications.fakeXcode(named: "Xcode-16.app", build: "16A1")
        let logs = LogRecorder()
        let shell = FakeShell { call in
            call.command == "mdfind" ? (0, app.path + "\n", "") : call.command == "ls" ? (1, "", "") : (0, "", "")
        }
        let core = Core.test(logs: logs, cachesDirectory: caches.url, listXcodes: { [xcodes] in xcodes }, shell: shell, prompt: FakePrompt(passwords: ["a", "b", "c"]), applicationsDirectory: applications.url)

        await #expect(throws: CoreError.self) {
            try await core.switchXcode(to: "16", options: .init(), updateVersionList: true)
        }
        #expect(!FileManager.default.fileExists(atPath: applications.url.appendingPathComponent("Xcode.app").path))
        #expect(!shell.privilegedCalls.contains { $0.command == "xcode-select" })
        #expect(logs.messages.contains("Nothing was changed."))
    }

    @Test
    func `a failing xcode-select changes nothing`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let app = try applications.fakeXcode(named: "Xcode-16.app", build: "16A1")
        let logs = LogRecorder()
        let shell = FakeShell { call in
            call.command == "mdfind" ? (0, app.path + "\n", "") : call.command == "xcode-select" ? (1, "", "") : (0, "", "")
        }
        let core = Core.test(logs: logs, cachesDirectory: caches.url, listXcodes: { [xcodes] in xcodes }, shell: shell, prompt: FakePrompt(passwords: ["sudo-password"]), applicationsDirectory: applications.url)

        await #expect(throws: CoreError.self) {
            try await core.switchXcode(to: "16", options: .init(), updateVersionList: true)
        }
        #expect(!FileManager.default.fileExists(atPath: applications.url.appendingPathComponent("Xcode.app").path))
        #expect(logs.messages.contains("Nothing was changed."))
    }

    @Test
    func `without xcode-select only the link changes`() async throws {
        let fixture = try Fixture(xcodes: xcodes) { [try $0.fakeXcode(named: "Xcode-16.app", build: "16A1")] }

        try await fixture.core.switchXcode(to: "16", options: .init(skipXcodeSelection: true), updateVersionList: true)

        #expect(FileManager.default.isSymbolicLink(atPath: fixture.symlink.path))
        #expect(fixture.shell.privilegedCalls.isEmpty)
        #expect(fixture.prompt.secrets.values.isEmpty)
    }

    @Test
    func `without the link only xcode-select changes`() async throws {
        let fixture = try Fixture(xcodes: xcodes) { [try $0.fakeXcode(named: "Xcode-16.app", build: "16A1")] }

        try await fixture.core.switchXcode(to: "16", options: .init(skipSymlinkCreation: true), updateVersionList: true)

        #expect(!FileManager.default.fileExists(atPath: fixture.symlink.path))
        #expect(fixture.shell.privilegedCalls.map(\.command) == ["ls", "xcode-select"])
    }

    @Test
    func `a link that cannot be changed after xcode-select says what changed`() async throws {
        let fixture = try Fixture(xcodes: xcodes) { [try $0.fakeXcode(named: "Xcode-16.app", build: "16A1")] }
        try FileManager.default.createDirectory(at: fixture.symlink, withIntermediateDirectories: true)

        await #expect(throws: CoreError.self) {
            try await fixture.core.switchXcode(to: "16", options: .init(), updateVersionList: true)
        }
        let app = fixture.applications.url.appendingPathComponent("Xcode-16.app")
        #expect(fixture.shell.privilegedCalls.last?.args == ["-s", app.path])
        #expect(fixture.logs.messages.contains("xcode-select now uses \(app.path), but \(fixture.symlink.path) was not changed."))
    }

    @Test
    func `a version without a qualifier switches to the installed final release`() async throws {
        let fixture = try Fixture(xcodes: xcodes, apps: {
            [try $0.fakeXcode(named: "Xcode-beta.app", build: "15A1"), try $0.fakeXcode(named: "Xcode-15.app", build: "15A2")]
        })

        let switched = try await fixture.core.switchXcode(to: "15.0", options: .init(skipXcodeSelection: true), updateVersionList: true)

        #expect(switched.url.lastPathComponent == "Xcode-15.app")
        #expect(fixture.prompt.chosen.values.isEmpty)
        #expect(fixture.logs.messages.contains("Using Xcode 15.0 (15A2), the final release. Use '15.0 Beta 2' for a beta."))
    }
}
