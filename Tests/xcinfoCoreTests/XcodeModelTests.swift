import Foundation
import Testing
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.
@testable import xcinfoCore

struct XcodeModelTests {
    @Test(arguments: [
        (Release.beta(5), "12.5", "Xcode_12.5_beta_5.app"),
        (.gm, "12.4.1", "Xcode_12.4.1_gm.app"),
        (.release, "12.4", "Xcode_12.4.app"),
        (.rc(1), "12.4", "Xcode_12.4_rc_1.app"),
        (.dp(6), "12.3", "Xcode_12.3_dp_6.app"),
        (.gmSeed(3), "12", "Xcode_12_gmseed_3.app"),
    ])
    func `filename is derived from the version`(release: Release, number: String, expected: String) throws {
        let applications = try TemporaryDirectory()
        let xcode = Xcode.fixture(number, build: "12345", release: release)

        #expect(xcode.filename(in: applications.url) == expected)
    }

    @Test
    func `filename gets a counter when the name is taken`() throws {
        let applications = try TemporaryDirectory()
        let xcode = Xcode.fixture("12.4", build: "12D4e")

        _ = try applications.directory("Xcode_12.4.app")
        #expect(xcode.filename(in: applications.url) == "Xcode_12.4-2.app")

        _ = try applications.directory("Xcode_12.4-2.app")
        #expect(xcode.filename(in: applications.url) == "Xcode_12.4-3.app")
    }

    @Test(arguments: [
        (Release.release, "15.0", "15.0"),
        (.gm, "15.0", "15.0 GM"),
        (.gmSeed(2), "15.0", "15.0 GM Seed 2"),
        (.beta(3), "15.0", "15.0 Beta 3"),
        (.dp(4), "15.0", "15.0 DP 4"),
        (.rc(1), "15.0", "15.0 RC 1"),
    ])
    func `display names describe the release`(release: Release, number: String, displayVersion: String) {
        let xcode = Xcode.fixture(number, build: "15A1", release: release)

        #expect(xcode.displayVersion == displayVersion)
        #expect(xcode.displayName == "\(displayVersion) (15A1)")
        #expect(xcode.description == xcode.displayName)
        #expect(xcode.debugDescription == xcode.displayName)
    }

    @Test
    func `display name without a build number has empty parentheses`() {
        let xcode = Xcode(version: Version(number: "15.0", nil, .release), date: (2023, 9, 18), requires: "13.5")

        #expect(xcode.displayName == "15.0 ()")
    }

    @Test
    func `release date is built from the year, month and day`() {
        let xcode = Xcode(version: Version("15A240d", "15.0", .release), date: (2023, 9, 18), requires: "13.5")
        let components = Calendar.current.dateComponents([.year, .month, .day], from: xcode.releaseDate)

        #expect(components.year == 2023)
        #expect(components.month == 9)
        #expect(components.day == 18)
    }

    @Test
    func `release kind flags reflect the release`() {
        #expect(Version("1", "1.0", .gm).isGM)
        #expect(Version("1", "1.0", .gmSeed(1)).isGMSeed)
        #expect(Version("1", "1.0", .beta(1)).isBeta)
        #expect(Version("1", "1.0", .dp(1)).isDP)
        #expect(Version("1", "1.0", .rc(1)).isRC)
        #expect(Version("1", "1.0", .release).isRelease)
        #expect(!Version("1", "1.0", .release).isBeta)
        #expect(Xcode.fixture("1.0", build: "1", release: .beta(2)).isBeta)
        #expect(!Xcode.fixture("1.0", build: "1", release: .gm).isBeta)
    }

    @Test(arguments: [
        (Release.gm, VersionParts.VersionType?.some(.gm(""))),
        (.gmSeed(2), .gm("Seed 2")),
        (.rc(3), .rc("3")),
        (.beta(4), .beta("4")),
        (.dp(5), .dp("5")),
        (.release, nil),
    ])
    func `releases map to version types`(release: Release, expected: VersionParts.VersionType?) {
        #expect(release.versionType == expected)
    }

    @Test
    func `sdk and compiler versions are keyed by name`() {
        let sdks = SDKs(macOS: Version("23A334"), iOS: Version("21A325"))
        let compilers = Compilers(clang: Version("1500.0.40.1", "15.0.0"), swift: Version("5.9.0.128.108", "5.9"))

        #expect(Set(sdks.keyed().keys) == ["macOS", "iOS"])
        #expect(sdks.keyed()["macOS"]?.first?.build == "23A334")
        #expect(Set(compilers.keyed().keys) == ["clang", "swift"])
        #expect(compilers.keyed()["swift"]?.first?.number == "5.9")
    }

    @Test(arguments: [
        ("13.0", OperatingSystemVersion?.some(OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0))),
        ("13.5", OperatingSystemVersion(majorVersion: 13, minorVersion: 5, patchVersion: 0)),
        ("14.2.1", OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 1)),
        ("13", nil),
        ("macOS", nil),
        ("", nil),
    ])
    func `operating system versions are parsed from requirement strings`(string: String, expected: OperatingSystemVersion?) {
        let version = OperatingSystemVersion(string: string)

        #expect(version?.versionString == expected?.versionString)
    }

    @Test
    func `xcode versions are parsed from arguments`() throws {
        #expect(try XcodeVersion("latest").description == "latest")
        #expect(try XcodeVersion("15.0.1").description == "15.0.1")
        guard case .latest = try XcodeVersion("latest") else {
            Issue.record("Expected latest")
            return
        }
        guard case let .version(string) = try XcodeVersion("15 beta 2") else {
            Issue.record("Expected a version")
            return
        }
        #expect(string == "15 beta 2")
    }

    @Test
    func `xcodes round trip through json`() throws {
        let xcode = Xcode.fixture(
            "15.0",
            build: "15A240d",
            release: .rc(2),
            notes: "https://notes.example.invalid",
            sdks: SDKs(macOS: Version("23A334")),
            compilers: Compilers(swift: Version("5.9.0.128.108", "5.9"))
        )

        let decoded = try JSONDecoder().decode(Xcode.self, from: JSONEncoder().encode(xcode))

        #expect(decoded.version.build == "15A240d")
        #expect(decoded.version.release.versionType == .rc("2"))
        #expect(decoded.links?.download?.url == xcode.links?.download?.url)
        #expect(decoded.links?.notes?.url == xcode.links?.notes?.url)
        #expect(decoded.sdks?.keyed()["macOS"]?.first?.build == "23A334")
    }
}
