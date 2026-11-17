import Foundation
import Testing
@testable import xcinfo
@testable import xcinfoCore
import XCIFoundation
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.

struct ArchitectureTests {
    private static let base = "https://download.developer.apple.com/Developer_Tools/Xcode_26.6/"
    private let appleSilicon = Xcode.fixture("26.6", name: "Xcode (Apple Silicon)", build: "17F113", download: base + "Xcode_26.6_Apple_silicon.xip")
    private let universal = Xcode.fixture("26.6", build: "17F113", download: base + "Xcode_26.6_Universal.xip")

    @Test(arguments: [
        ("Xcode (Apple Silicon)", "Xcode_26.6_Apple_silicon.xip", XcodeArchitecture?.some(.appleSilicon)),
        ("Xcode", "Xcode_26.6_Apple_silicon.xip", .appleSilicon),
        ("Xcode (Universal)", "Xcode_26.6.xip", .universal),
        ("Xcode", "Xcode_26.6_Universal.xip", .universal),
        ("Xcode", "Xcode_16.4.xip", nil),
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
        let json = try TerminalRenderer.json(ListPayload(XcodeList(listed: [appleSilicon, Xcode.fixture("16.4", build: "16F6")], installed: [], notInstallable: [])))
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
}
