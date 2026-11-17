import Foundation
import Testing
import XCIFoundation
@testable import xcinfo
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.
@testable import xcinfoCore

struct PresentationTests {
    private let xcode = Xcode(
        version: Version("15A240d", "15.0", .release),
        date: (2023, 9, 18),
        requires: "13.5",
        sdks: SDKs(macOS: Version("23A334"), iOS: Version("21A325")),
        compilers: Compilers(swift: Version("5.9.0.128.108", "5.9")),
        links: Links(
            download: Link("https://download.example.invalid/Xcode_15.xip"),
            notes: Link("https://notes.example.invalid/15")
        )
    )

    @Test
    func `info shows the version details`() {
        let lines = xcode.infoLines.map(\.strippingANSI)

        #expect(Array(lines.prefix(3)) == ["", "Version info", "15.0 (15A240d)"])
        #expect(lines[3].hasPrefix("Release date: September 18, 2023 ("))
        #expect(Array(lines.dropFirst(4)) == [
            "Requires macOS 13.5",
            "",
            "SDKs",
            "iOS SDK:   21A325",
            "macOS SDK: 23A334",
            "",
            "Compilers",
            "swift 5.9: 5.9.0.128.108",
            "",
            "Links",
            "Download:      https://download.example.invalid/Xcode_15.xip",
            "Release Notes: https://notes.example.invalid/15",
        ])
    }

    @Test
    func `info without sdks, compilers and links ends with the requirement`() {
        let bare = Xcode(version: Version("15A240d", "15.0", .release), date: (2023, 9, 18), requires: "13.5")

        #expect(bare.infoLines.last?.strippingANSI == "Requires macOS 13.5")
    }

    @Test
    func `list shows the listed, installed and not installable versions`() {
        let list = XcodeList(
            listed: [.fixture("16.0", build: "16A1"), .fixture("15.0", build: "15A1")],
            installed: [.fixture("15.0", build: "15A1")],
            notInstallable: [.fixture("17.0", build: "17A1", release: .beta(1)), .fixture("13.0", build: "13A1")]
        )

        #expect(list.lines(terminalColumns: nil).map(\.strippingANSI) == [
            "16.0 (16A1)",
            "15.0 (15A1)",
            "",
            "Already installed:",
            "15.0 (15A1)",
            "",
            "Not installable:",
            "17.0 Beta 1 (17A1)",
            "13.0 (13A1)",
        ])
    }

    @Test
    func `long lists use columns on a wide terminal`() {
        let xcodes = (1 ... 12).map { Xcode.fixture("\($0).0", build: "\($0)A1") }
        let list = XcodeList(listed: xcodes, installed: [], notInstallable: [])

        let lines = list.lines(terminalColumns: 46).map(\.strippingANSI)

        #expect(lines.count == 6)
        #expect(lines[0].hasPrefix("1.0 (1A1)"))
        #expect(lines[0].contains("7.0 (7A1)"))
        #expect(list.lines(terminalColumns: nil).count == 12)
    }

    @Test
    func `an empty list says so`() {
        let list = XcodeList(listed: [], installed: [], notInstallable: [])

        #expect(list.lines(terminalColumns: 80).map(\.strippingANSI) == ["No matching Xcode versions found."])
    }

    @Test
    func `installed applications are padded to the longest name`() {
        let applications = [
            XcodeApplication(url: URL(fileURLWithPath: "/Applications/Xcode-beta.app"), xcode: .fixture("17.0", build: "17A1", release: .beta(1))),
            XcodeApplication(url: URL(fileURLWithPath: "/Applications/Xcode.app"), xcode: .fixture("16.0", build: "16A1")),
        ]

        #expect(applications.lines.map(\.strippingANSI) == [
            "17.0 Beta 1 (17A1) – /Applications/Xcode-beta.app",
            "16.0 (16A1)        – /Applications/Xcode.app",
        ])
        #expect([XcodeApplication]().lines.isEmpty)
    }

    @Test
    func `errors map to exit codes`() {
        let expectations: [(any Error, Int32)] = [
            (CoreError.versionNotFound(.latest), 3),
            (CoreError.invalidDownloadURL, 3),
            (CoreError.authenticationFailed, 4),
            (CoreError.downloadFailed("x"), 5),
            (CoreError.unsupportedFile("dmg"), 6),
            (CoreError.extractionFailed(CocoaError(.fileNoSuchFile)), 6),
            (CoreError.incorrectSuperUserPassword, 7),
            (Interrupted(signal: SIGINT), 130),
            (Interrupted(signal: SIGTERM), 143),
            (CoreError.installationFailed, 7),
            (CoreError.uninstallationFailed("x"), 8),
            (XCAPIError.invalidResponse, 9),
            (URLError(.notConnectedToInternet), 9),
            (CocoaError(.fileReadNoSuchFile), 9),
            (CancellationError(), 1),
        ]

        for (error, code) in expectations {
            #expect(error.exitCode == code, "\(error)")
        }
    }

    @Test
    func `errors have specific messages`() {
        #expect(CoreError.incorrectSuperUserPassword.message == "The administrator password was rejected three times.")
        #expect(XCAPIError.invalidResponse.message == "Invalid response")
        #expect(Interrupted(signal: SIGINT).message == "Stopped with Ctrl-C.")
        #expect(Interrupted(signal: SIGTERM).message == "Stopped by signal 15.")
        #expect(CocoaError(.fileReadNoSuchFile).message == "No cached list of Xcode versions. Run the command again without --no-update-list.")
    }

    @Test
    func `errors are reported as json in json mode`() throws {
        let captured = CapturedOutput()

        captured.renderer(.init(isJSON: true)).report(CoreError.authenticationFailed)

        let payload = try JSONSerialization.jsonObject(with: Data(captured.error.utf8)) as? [String: Any]
        #expect(payload?["error"] as? String == "Authentication with Apple failed.")
        #expect(payload?["code"] as? Int == 4)
        #expect(captured.output.isEmpty)
    }

    @Test
    func `results are printed as json`() throws {
        let captured = CapturedOutput()
        let application = XcodeApplication(url: URL(fileURLWithPath: "/Applications/Xcode.app"), xcode: .fixture("16.0", build: "16A1"))

        try captured.renderer(.init(isJSON: true)).printJSON(ApplicationPayload(application))

        let payload = try JSONSerialization.jsonObject(with: Data(captured.output.utf8)) as? [String: Any]
        #expect(payload?["path"] as? String == "/Applications/Xcode.app")
        #expect(payload?["version"] as? String == "16.0")
        #expect(payload?["build"] as? String == "16A1")
    }
}
