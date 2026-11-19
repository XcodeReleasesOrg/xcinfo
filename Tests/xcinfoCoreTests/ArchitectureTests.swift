import Foundation
import Testing
import XCIFoundation
@testable import xcinfo
@testable import xcinfoCore
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has immutable value types without Sendable annotations.

struct ArchitectureTests {
    private static let base = "https://download.developer.apple.com/Developer_Tools/Xcode_26.6/"
    private let appleSilicon = Xcode.fixture(
        "26.6",
        name: "Xcode (Apple Silicon)",
        build: "17F113",
        download: base + "Xcode_26.6_Apple_silicon.xip"
    )
    private let universal = Xcode.fixture("26.6", build: "17F113", download: base + "Xcode_26.6_Universal.xip")

    @Test(arguments: [
        ("Xcode (Apple Silicon)", "Xcode_26.6_Apple_silicon.xip", XcodeArchitecture?.some(.appleSilicon)),
        ("Xcode", "Xcode_26.6_Apple_silicon.xip", .appleSilicon),
        ("Xcode (Universal)", "Xcode_26.6.xip", .universal),
        ("Xcode", "Xcode_26.6_Universal.xip", .universal),
        ("Xcode", "Xcode_16.4.xip", nil)
    ])
    func `the architecture comes from the name or the download file`(name: String, file: String, architecture: XcodeArchitecture?) {
        let xcode = Xcode.fixture("26.6", name: name, build: "17F113", download: Self.base + file)
        #expect(xcode.architecture == architecture)
    }

    @Test
    func `variants are labelled and plain versions keep their name`() {
        #expect(appleSilicon.labeledName == "26.6 (17F113) · Apple silicon")
        #expect(universal.labeledName == "26.6 (17F113) · Universal")
        #expect(Xcode.fixture("16.4", build: "16F6").labeledName == "16.4 (16F6)")
        let list = XcodeList(listed: [appleSilicon, universal], installed: [], notInstallable: [])
        #expect(list.lines(terminalColumns: nil).map(\.strippingANSI) == ["26.6 (17F113) · Apple silicon", "26.6 (17F113) · Universal"])
    }

    @Test
    func `json adds the architecture next to the existing keys`() throws {
        let json = try TerminalRenderer.json(ListPayload(XcodeList(
            listed: [appleSilicon, Xcode.fixture("16.4", build: "16F6")],
            installed: [],
            notInstallable: []
        )))
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let listed = try #require(object["listed"] as? [[String: Any]])

        #expect(listed[0]["architecture"] as? String == "appleSilicon")
        #expect(listed[0]["name"] as? String == "Xcode (Apple Silicon)")
        #expect(listed[0]["version"] != nil)
        #expect(listed[1]["architecture"] == nil)
    }

    @Test
    func `the choice between variants names them`() async throws {
        let caches = try TemporaryDirectory()
        let applications = try TemporaryDirectory()
        let prompt = FakePrompt(choices: [1])
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { [appleSilicon, universal] },
            prompt: prompt,
            applicationsDirectory: applications.url
        )

        let found = try await core.info(version: .version("26.6"), shouldUpdate: true)

        #expect(found.architecture == .universal)
        #expect(prompt.chosen.values == [["26.6 (17F113) · Apple silicon", "26.6 (17F113) · Universal"]])
    }

    @Test
    func `the terminal UI downloads exactly the selected entry`() async throws {
        let caches = try TemporaryDirectory()
        let downloaded = Recorder<String>()
        let candidate = Xcode.fixture(
            "26.6",
            build: "17F113",
            release: .rc(2),
            download: Self.base + "Xcode_26.6_Release_Candidate_2_Universal.xip"
        )
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { [appleSilicon, universal, candidate] },
            accountName: { "appleid@example.invalid" },
            password: { _ in "secret" },
            authenticate: { _, _ in },
            download: { url, destination, _, _ in
                downloaded.append(url.lastPathComponent)
                return destination.appendingPathComponent(url.lastPathComponent)
            },
            applicationsDirectory: caches.url
        )

        _ = try await core.download(
            version: .exactly(universal),
            options: .init(destination: caches.url, disableSleep: false),
            updateVersionList: true
        )

        #expect(downloaded.values == ["Xcode_26.6_Universal.xip"])
    }

    @Test(arguments: [
        (
            true,
            XcodeArchitecture?.none,
            XcodeArchitecture.appleSilicon,
            "Using the Apple silicon download because this Mac has Apple silicon; use --universal for the other one."
        ),
        (
            false,
            nil,
            .universal,
            "Using the Universal download because this Mac has an Intel processor; use --apple-silicon for the other one."
        ),
        (true, .universal, .universal, "Using the Universal download as requested with --universal."),
        (false, .appleSilicon, .appleSilicon, "Using the Apple silicon download as requested with --apple-silicon.")
    ])
    func `download picks the variant for this Mac without asking`(
        isAppleSilicon: Bool,
        requested: XcodeArchitecture?,
        expected: XcodeArchitecture,
        message: String
    ) async throws {
        let caches = try TemporaryDirectory()
        let downloads = try TemporaryDirectory()
        let logs = LogRecorder()
        let downloaded = Recorder<String>()
        let core = Core.test(
            logs: logs,
            cachesDirectory: caches.url,
            listXcodes: { [appleSilicon, universal, .fixture("26.5", build: "17F42")] },
            accountName: { "appleid@example.invalid" },
            password: { _ in "secret" },
            authenticate: { _, _ in },
            download: { url, destination, _, _ in
                downloaded.append(url.lastPathComponent)
                return destination.appendingPathComponent(url.lastPathComponent)
            },
            isAppleSilicon: isAppleSilicon,
            prompt: FakePrompt(),
            applicationsDirectory: caches.url
        )

        let (xcode, _) = try await core.download(
            version: .version("26.6"),
            options: .init(destination: downloads.url, disableSleep: false, architecture: requested),
            updateVersionList: true
        )

        #expect(xcode.architecture == expected)
        #expect(downloaded.values == [expected == .appleSilicon ? "Xcode_26.6_Apple_silicon.xip" : "Xcode_26.6_Universal.xip"])
        #expect(logs.messages.contains(message))
        #expect(logs.messages.contains("Found matching Xcode \(xcode.labeledName)."))
    }

    @Test
    func `info still asks between variants`() async throws {
        let caches = try TemporaryDirectory()
        let prompt = FakePrompt(choices: [0])
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { [appleSilicon, universal] },
            prompt: prompt,
            applicationsDirectory: caches.url
        )

        _ = try await core.info(version: .version("26.6"), shouldUpdate: true)

        #expect(prompt.chosen.values.count == 1)
    }

    @Test
    func `variant flags are parsed for download and install`() throws {
        #expect(try XCInfo.Download.parse(["26.6"]).downloadOptions.options.architecture == nil)
        #expect(try XCInfo.Download.parse(["26.6", "--universal"]).downloadOptions.options.architecture == .universal)
        #expect(try XCInfo.Install.parse(["26.6", "--apple-silicon"]).installationOptions.downloadOptions.options
            .architecture == .appleSilicon)
        #expect(throws: (any Error).self) {
            try XCInfo.Download.parse(["26.6", "--universal", "--apple-silicon"])
        }
    }

    @Test
    func `with non-interactive the variant is chosen without failing`() async throws {
        let caches = try TemporaryDirectory()
        let downloaded = Recorder<String>()
        let core = Core.test(
            logs: LogRecorder(),
            cachesDirectory: caches.url,
            listXcodes: { [appleSilicon, universal] },
            accountName: { "appleid@example.invalid" },
            password: { _ in "secret" },
            authenticate: { _, _ in },
            download: { url, destination, _, _ in
                downloaded.append(url.lastPathComponent)
                return destination.appendingPathComponent(url.lastPathComponent)
            },
            isAppleSilicon: true,
            promptClient: .unavailable,
            applicationsDirectory: caches.url
        )

        _ = try await core.download(
            version: .version("26.6"),
            options: .init(destination: caches.url, disableSleep: false),
            updateVersionList: true
        )

        #expect(downloaded.values == ["Xcode_26.6_Apple_silicon.xip"])
    }
}
