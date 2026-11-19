import Testing
@testable import xcinfoCore

struct VersionPartsTests {
    @Test(arguments: [
        ("14", VersionParts(major: 14)),
        ("14.3", VersionParts(major: 14, minor: 3)),
        ("14.3 RC 2", VersionParts(major: 14, minor: 3, type: .rc("2"))),
        ("14.0.1", VersionParts(major: 14, minor: 0, patch: 1)),
        ("11.6 GM", VersionParts(major: 11, minor: 6, type: .gm(""))),
        ("11.3.1 GM", VersionParts(major: 11, minor: 3, patch: 1, type: .gm(""))),
        ("11.2.1 GM Seed 1", VersionParts(major: 11, minor: 2, patch: 1, type: .gm("Seed 1"))),
        ("8.3 Beta 3", VersionParts(major: 8, minor: 3, type: .beta("3"))),
        ("5.1 DP 2", VersionParts(major: 5, minor: 1, type: .dp("2"))),
        ("15 beta", VersionParts(major: 15, type: .beta(""))),
        ("15.0 BETA 7", VersionParts(major: 15, minor: 0, type: .beta("7"))),
        ("15.0  rc   1", VersionParts(major: 15, minor: 0, type: .rc("1"))),
        ("15.0 beta2", VersionParts(major: 15, minor: 0, type: .beta("2")))
    ])
    func `version parts are parsed from a version string`(versionString: String, expected: VersionParts) {
        #expect(VersionParts(rawValue: versionString) == expected)
    }

    @Test(arguments: ["Xcode", "14.3 alpha 1", "v14", "14,3", "14.3-beta"])
    func `strings that are not versions are rejected`(versionString: String) {
        #expect(VersionParts(rawValue: versionString) == nil)
    }

    @Test(arguments: [
        ("beta", "1", VersionParts.VersionType.beta("1")),
        ("BETA", "1", .beta("1")),
        ("gm", "", .gm("")),
        ("rc", "3", .rc("3")),
        ("dp", "4", .dp("4")),
    ])
    func `version types are created from their name`(type: String, content: String, expected: VersionParts.VersionType) {
        #expect(VersionParts.VersionType(type: type, content: content) == expected)
    }

    @Test
    func `version types need a known name and content`() {
        #expect(VersionParts.VersionType(type: "alpha", content: "1") == nil)
        #expect(VersionParts.VersionType(type: nil, content: "1") == nil)
        #expect(VersionParts.VersionType(type: "beta", content: nil) == nil)
    }
}
