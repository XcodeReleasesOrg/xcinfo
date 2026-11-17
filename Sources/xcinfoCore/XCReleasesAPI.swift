//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import Foundation
import XCIFoundation
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable

// annotations.

public struct XcodeApplication: Sendable {
    public init(url: URL, xcode: Xcode) {
        self.url = url
        self.xcode = xcode
    }

    public var url: URL
    public var xcode: Xcode
}

extension XcodeApplication: Comparable {
    public static func < (lhs: XcodeApplication, rhs: XcodeApplication) -> Bool {
        lhs.xcode < rhs.xcode
    }
}

public extension Xcode {
    var releaseDate: Date {
        Calendar.current.date(from: DateComponents(
            year: date.year,
            month: date.month,
            day: date.day
        )) ?? Date(timeIntervalSinceReferenceDate: 0)
    }
}

extension Xcode: @retroactive CustomStringConvertible, @retroactive CustomDebugStringConvertible {
    public var displayVersion: String {
        var components: [String] = []
        if let number = version.number {
            components.append(number)
        }

        switch version.release {
        case .gm:
            components.append("GM")
        case let .gmSeed(version):
            components.append("GM Seed \(version)")
        case let .beta(version):
            components.append("Beta \(version)")
        case let .dp(version):
            components.append("DP \(version)")
        case let .rc(version):
            components.append("RC \(version)")
        case .release:
            break
        }

        return components.joined(separator: " ")
    }

    private var namedVersion: String {
        var components: [String] = []
        if let number = version.number {
            components.append(number)
        }

        switch version.release {
        case .gm:
            components.append("gm")
        case let .gmSeed(version):
            components.append("gmseed_\(version)")
        case let .beta(version):
            components.append("beta_\(version)")
        case let .dp(version):
            components.append("dp_\(version)")
        case let .rc(version):
            components.append("rc_\(version)")
        case .release:
            break
        }
        return components.joined(separator: "_")
    }

    public var displayName: String {
        "\(displayVersion) (\(version.build ?? ""))"
    }

    public var architecture: XcodeArchitecture? {
        let download = links?.download?.url.lastPathComponent ?? ""
        if name.localizedCaseInsensitiveContains("Apple Silicon") || download.hasSuffix("_Apple_silicon.xip") {
            return .appleSilicon
        }
        if name.localizedCaseInsensitiveContains("Universal") || download.hasSuffix("_Universal.xip") {
            return .universal
        }
        return nil
    }

    var isFinalRelease: Bool {
        switch version.release {
        case .release, .gm: true
        case .beta, .dp, .rc, .gmSeed: false
        }
    }

    func hasVersionNumber(of versionParts: VersionParts) -> Bool {
        let parts = (version.number ?? "").split(separator: ".").map { Int($0) ?? 0 }
        let requested = [versionParts.major, versionParts.minor ?? 0, versionParts.patch ?? 0]
        return (0 ..< 3).allSatisfy { (parts.indices.contains($0) ? parts[$0] : 0) == requested[$0] }
    }

    func isVariant(of other: Xcode) -> Bool {
        displayName == other.displayName && links?.download?.url != other.links?.download?.url
    }

    public var labeledName: String {
        architecture.map { "\(displayName) · \($0.label)" } ?? displayName
    }

    func filename(in applicationsDirectory: URL) -> String {
        let fileManager = FileManager.default
        var filename = "Xcode_\(namedVersion).app"
        var counter = 1
        while fileManager.fileExists(atPath: applicationsDirectory.appendingPathComponent(filename).path) {
            counter += 1
            filename = "Xcode_\(namedVersion)-\(counter).app"
        }
        return filename
    }

    public var description: String {
        displayName
    }

    public var debugDescription: String {
        displayName
    }
}

extension Xcode {
    var isBeta: Bool {
        version.isBeta
    }
}

extension Version {
    var isGM: Bool {
        release.isGM
    }

    var isGMSeed: Bool {
        guard case .gmSeed = release else { return false }
        return true
    }

    var isBeta: Bool {
        guard case .beta = release else { return false }
        return true
    }

    var isDP: Bool {
        guard case .dp = release else { return false }
        return true
    }

    var isRC: Bool {
        guard case .rc = release else { return false }
        return true
    }

    var isRelease: Bool {
        guard case .release = release else { return false }
        return true
    }
}

extension Xcode: @retroactive Equatable, @retroactive Comparable, @retroactive Hashable {
    public static func == (lhs: Xcode, rhs: Xcode) -> Bool {
        lhs.version == rhs.version
    }

    public static func < (lhs: Xcode, rhs: Xcode) -> Bool {
        lhs.version < rhs.version
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(version)
    }
}

extension Version: @retroactive Equatable, @retroactive Comparable, @retroactive Hashable {
    public static func < (lhs: Version, rhs: Version) -> Bool {
        let numberComparision: ComparisonResult = {
            guard let lhsNumber = lhs.number, let rhsNumber = rhs.number else { return .orderedSame }
            return lhsNumber.compare(rhsNumber, options: .numeric)
        }()

        if lhs.isGM, rhs.isGM {
            if
                numberComparision == .orderedSame,
                let lhsBuild = lhs.build,
                let rhsBuild = rhs.build
            {
                return lhsBuild.compare(rhsBuild, options: .numeric) == .orderedAscending
            } else {
                return numberComparision == .orderedAscending
            }
        } else if numberComparision == .orderedSame {
            switch (lhs.release, rhs.release) {
            case let (.gmSeed(lhsVersion), .gmSeed(rhsVersion)):
                return lhsVersion < rhsVersion
            case let (.beta(lhsVersion), .beta(rhsVersion)):
                return lhsVersion < rhsVersion
            case let (.dp(lhsVersion), .dp(rhsVersion)):
                return lhsVersion < rhsVersion
            case let (.rc(lhsVersion), .rc(rhsVersion)):
                return lhsVersion < rhsVersion
            case (.gm, .release), (.release, .gm), (.release, .release):
                guard let lhsBuild = lhs.build, let rhsBuild = rhs.build else { return false }
                return lhsBuild.compare(rhsBuild, options: .numeric) == .orderedAscending
            default:
                return lhs.release.rank < rhs.release.rank
            }
        }
        return numberComparision == .orderedAscending
    }

    public static func == (lhs: Version, rhs: Version) -> Bool {
        lhs.number == rhs.number && lhs.build == rhs.build && lhs.release.versionType == rhs.release.versionType
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(number)
        hasher.combine(build)
    }
}

public protocol KeyedVersions {}
public extension KeyedVersions {
    func keyed() -> [String: [Version]] {
        let mirror = Mirror(reflecting: self)
        var dict: [String: [Version]] = [:]
        for child in mirror.children {
            guard let key = child.label, let versions = child.value as? [Version] else { continue }
            dict[key] = versions
        }
        return dict
    }
}

extension SDKs: KeyedVersions {}
extension Compilers: KeyedVersions {}

public enum XCAPIError: Error, CustomStringConvertible, Sendable {
    case invalidResponse
    case invalidCache
    case versionNotFound
    case downloadInterrupted
    case recoverableDownloadError(url: URL, resumeData: Data)
    case couldNotMoveToTemporaryFile
    case couldNotMoveToDestinationFolder(URL, URL, NSError)
    case timeout
    case unexpectedStatusCode(Int)
    case unauthorized

    public var description: String {
        switch self {
        case .invalidResponse:
            return "Invalid response"
        case .invalidCache:
            return "Invalid cache file"
        case .versionNotFound:
            return "Version not found"
        case .recoverableDownloadError:
            return "Download failed"
        case .downloadInterrupted:
            return "Download was interrupted"
        case .couldNotMoveToTemporaryFile:
            return "Could not move downloaded file into temporary directory"
        case let .couldNotMoveToDestinationFolder(source, destination, error):
            return "Could not move downloaded file from \(source.standardizedFileURL.path) to \(destination.standardizedFileURL.path). \(error.localizedFailureReason ?? error.localizedDescription))"
        case .timeout:
            return "The request timed out"
        case let .unexpectedStatusCode(statusCode):
            return "The server responded with HTTP status \(statusCode)"
        case .unauthorized:
            return "The Apple Developer Portal did not authorize the download"
        }
    }
}

public final class XCReleasesAPI: Sendable {
    public let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
    }

    public func listXcodes() async throws -> [Xcode] {
        let (data, urlResponse) = try await session.data(from: baseURL)
        guard
            let response = urlResponse as? HTTPURLResponse,
            (200 ... 299).contains(response.statusCode) else { throw XCAPIError.invalidResponse }

        return try JSONDecoder().decode([Xcode].self, from: data)
    }

    func removeCookies() {
        session.configuration.httpCookieStorage?.removeCookies(since: Date.distantPast)
    }
}

extension OperatingSystemVersion {
    init?(string: String) {
        var components = string.split(separator: ".").compactMap { Int($0) }
        guard components.count >= 2 else { return nil }
        if components.count == 2 {
            components.append(0)
        }
        self.init(majorVersion: components[0], minorVersion: components[1], patchVersion: components[2])
    }

    var versionString: String {
        "\(majorVersion).\(minorVersion).\(patchVersion)"
    }
}

extension Release {
    var kindDescription: String? {
        switch self {
        case .rc: "a release candidate"
        case .beta: "a beta"
        case .dp: "a developer preview"
        case .gmSeed: "the GM seed"
        case .release, .gm: nil
        }
    }

    var rank: Int {
        switch self {
        case .dp: 0
        case .beta: 1
        case .rc: 2
        case .gmSeed: 3
        case .gm, .release: 4
        }
    }

    var versionType: VersionParts.VersionType? {
        switch self {
        case .gm:
            return .gm("")
        case let .gmSeed(seed):
            return .gm("Seed \(seed)")
        case let .rc(rc):
            return .rc(String(rc))
        case let .beta(beta):
            return .beta(String(beta))
        case let .dp(dp):
            return .dp(String(dp))
        case .release:
            return nil
        }
    }
}

public enum XcodeArchitecture: String, Sendable, Codable, CaseIterable {
    case appleSilicon
    case universal

    public var label: String {
        switch self {
        case .appleSilicon: "Apple silicon"
        case .universal: "Universal"
        }
    }
}
