import Foundation
import Testing
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.
@testable import xcinfoCore

struct VersionOrderingTests {
    @Test
    func `newer betas sort above older betas and older releases`() {
        let first = Version("8A218a", "8.0")
        let second = Version("11M392q", "11.0", .beta(6))
        let third = Version("11M374r", "11.0", .beta(4))

        let sorted = [second, third, first].sorted { $0 > $1 }
        #expect(sorted.map(\.build) == [second, third, first].map(\.build))
    }

    @Test
    func `two releases sort by version number`() {
        let first = Version("10A255", "10.0")
        let second = Version("10B61", "10.1")

        let sorted = [first, second].sorted { $0 > $1 }
        #expect(sorted.map(\.build) == [second, first].map(\.build))
    }

    @Test(arguments: [
        ("9.0", "10.0"),
        ("10.0", "10.1"),
        ("10.1", "10.1.1"),
        ("14.3.1", "15.0"),
    ])
    func `version numbers compare numerically`(lower: String, higher: String) {
        #expect(Version("1", lower, .release) < Version("2", higher, .release))
        #expect(!(Version("2", higher, .release) < Version("1", lower, .release)))
    }

    @Test
    func `gm versions with the same number compare by build`() {
        let older = Version("10A254a", "10.0", .gm)
        let newer = Version("10A255", "10.0", .gm)

        #expect(older < newer)
        #expect(!(newer < older))
    }

    @Test(arguments: [
        (Release.beta(1), Release.beta(2)),
        (.rc(1), .rc(2)),
        (.dp(3), .dp(4)),
        (.gmSeed(1), .gmSeed(2)),
    ])
    func `prereleases with the same number compare by their counter`(lower: Release, higher: Release) {
        #expect(Version("1", "15.0", lower) < Version("2", "15.0", higher))
        #expect(!(Version("2", "15.0", higher) < Version("1", "15.0", lower)))
    }

    @Test(arguments: [
        (Release.dp(9), Release.beta(1)),
        (.beta(9), .rc(1)),
        (.rc(9), .gmSeed(1)),
        (.gmSeed(9), .gm),
        (.beta(1), .release),
    ])
    func `prereleases sort below later release kinds with the same number`(lower: Release, higher: Release) {
        #expect(Version("15A5160n", "15.0", lower) < Version("15A240d", "15.0", higher))
        #expect(!(Version("15A240d", "15.0", higher) < Version("15A5160n", "15.0", lower)))
    }

    @Test
    func `releases with the same number compare by build`() {
        #expect(Version("15A240d", "15.0", .release) < Version("15A240e", "15.0", .release))
        #expect(Version("15A240d", "15.0", .gm) < Version("15A240e", "15.0", .release))
    }

    @Test
    func `xcodes compare by version`() {
        let older = Xcode.fixture("14.3", build: "14E222b")
        let newer = Xcode.fixture("15.0", build: "15A240d")

        #expect(older < newer)
        #expect([older, newer].sorted(by: >).map(\.version.build) == ["15A240d", "14E222b"])
    }

    @Test
    func `xcode applications compare by their xcode`() {
        let older = XcodeApplication(url: URL(fileURLWithPath: "/tmp/a.app"), xcode: .fixture("14.3", build: "14E222b"))
        let newer = XcodeApplication(url: URL(fileURLWithPath: "/tmp/b.app"), xcode: .fixture("15.0", build: "15A240d"))

        #expect(older < newer)
    }

    @Test
    func `versions with the same number and release are equal and hash alike`() {
        let first = Version("15A240d", "15.0", .release)
        let second = Version("15A240d", "15.0", .release)

        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
        #expect(Xcode.fixture("15.0", build: "15A240d") == Xcode.fixture("15.0", build: "15A240d"))
    }

    @Test
    func `different releases with the same number are not equal`() {
        let beta4 = Version("11M374r", "11.0", .beta(4))
        let beta6 = Version("11M392q", "11.0", .beta(6))

        #expect(beta4 != beta6)
        #expect(Set([beta4, beta6]).count == 2)
        #expect(Set([Xcode.fixture("11.0", build: "11M374r", release: .beta(4)), .fixture("11.0", build: "11M392q", release: .beta(6))]).count == 2)
    }
}

struct XcodeMatchingTests {
    @Test(arguments: [
        ("14.3", "14", true),
        ("14.3", "15", false),
        ("14.3", "14.3", true),
        ("14.3", "14.2", false),
        ("14.3.1", "14.3", true),
        ("14.3.1", "14.3.1", true),
        ("14.3.1", "14.3.2", false),
    ])
    func `xcodes match version parts by number`(number: String, query: String, matches: Bool) throws {
        let parts = try #require(VersionParts(rawValue: query))

        #expect(Xcode.fixture(number, build: "1").matching(parts) == matches)
    }

    @Test
    func `release types are compared when both have a patch number`() throws {
        let rc = Xcode.fixture("14.3.1", build: "1", release: .rc(1))

        #expect(rc.matching(try #require(VersionParts(rawValue: "14.3.1 RC 1"))))
        #expect(!rc.matching(try #require(VersionParts(rawValue: "14.3.1 beta 1"))))
    }

    @Test
    func `release types are compared without a patch number`() throws {
        let rc = Xcode.fixture("14.3", build: "1", release: .rc(2))
        let betaQuery = try #require(VersionParts(rawValue: "14.3 beta 1"))

        #expect(!rc.matching(betaQuery))
        #expect(rc.matching(try #require(VersionParts(rawValue: "14.3 RC 2"))))
        #expect(rc.matching(try #require(VersionParts(rawValue: "14.3 rc"))))
        #expect(!Xcode.fixture("14.3", build: "1").matching(try #require(VersionParts(rawValue: "14.3 rc"))))
    }

    @Test
    func `xcodes without a number never match`() throws {
        let xcode = Xcode(version: Version("15A240d"), date: (2023, 9, 18), requires: "13.5")

        #expect(!xcode.matching(try #require(VersionParts(rawValue: "15"))))
    }

    @Test(arguments: [
        ("15.0", 2, "15.0 beta 2", true),
        ("15.0", 3, "15.0 beta 3", false),
        ("15", 2, "15 beta 2", true),
        ("14.0", 2, "14.0 beta 2", false),
    ])
    func `beta queries match the number prefix and the beta counter`(fullVersion: String, betaVersion: Int, query: String, matches: Bool) {
        let xcode = Xcode.fixture("15.0", build: "15A5195k", release: .beta(2))

        #expect(xcode.matching(fullVersion: fullVersion, betaVersion: betaVersion, version: query) == matches)
    }

    @Test
    func `queries match the build number case insensitively`() {
        let xcode = Xcode.fixture("15.0", build: "15A240d")

        #expect(xcode.matching(fullVersion: nil, betaVersion: nil, version: "15a240d"))
        #expect(xcode.matching(fullVersion: nil, betaVersion: 1, version: "15a240d"))
        #expect(!xcode.matching(fullVersion: nil, betaVersion: nil, version: "15a241"))
    }

    @Test(arguments: [
        ("15", true),
        ("15.0", true),
        ("14", false),
        ("1", true),
    ])
    func `release queries match the number prefix`(query: String, matches: Bool) {
        let xcode = Xcode.fixture("15.0", build: "15A240d")

        #expect(xcode.matching(fullVersion: nil, betaVersion: nil, version: query) == matches)
    }
}
