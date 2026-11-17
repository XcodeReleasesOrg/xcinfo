//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
import Rainbow
import XCIFoundation
import xcinfoCore
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.

extension Error {
    var exitCode: Int32 {
        switch self {
        case let error as CoreError:
            switch error {
            case .versionNotFound, .invalidDownloadURL:
                3
            case .authenticationFailed, .signInFailed:
                4
            case .downloadFailed, .checksumMismatch:
                5
            case .extractionFailed, .unsupportedFile, .invalidExtractionOutputURL:
                6
            case .installationFailed, .gatekeeperVerificationFailed, .codesignVerificationFailed, .incorrectSuperUserPassword:
                7
            case .uninstallationFailed:
                8
            }
        case is XCAPIError, is DecodingError, is URLError, is CocoaError:
            9
        case let error as Interrupted:
            128 + error.signal
        default:
            1
        }
    }

    var message: String {
        switch self {
        case let error as XCAPIError:
            error.description
        case let error as Interrupted where error.signal == SIGINT:
            "Stopped with Ctrl-C."
        case let error as Interrupted:
            "Stopped by signal \(error.signal)."
        case is DecodingError:
            "The list of Xcode versions could not be read."
        case let error as CocoaError where error.code == .fileReadNoSuchFile:
            "No cached list of Xcode versions. Run the command again without --no-update-list."
        default:
            localizedDescription
        }
    }
}

private struct ErrorPayload: Encodable {
    var error: String
    var code: Int32
}

extension TerminalRenderer {
    func report(_ error: any Error) {
        if options.isJSON, let json = try? Self.json(ErrorPayload(error: error.message, code: error.exitCode)) {
            render(.message(json, .error))
        } else {
            render(.message(error.message, .error))
        }
    }

    func printJSON(_ value: some Encodable) throws {
        print(try Self.json(value))
    }

    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

extension Xcode {
    var attributedDisplayName: String {
        "\(displayVersion.cyan) (\(version.build ?? ""))"
    }

    var infoLines: [String] {
        let locale = Locale(identifier: "en_US_POSIX")
        var lines = [
            "",
            "Version info".cyan.bold,
            description,
            "Release date: \(releaseDate.formatted(Date.FormatStyle().year().month(.wide).day().locale(locale)))"
                + " (\(releaseDate.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(locale))))",
            "Requires macOS \(requires)",
        ]

        if let sdks = sdks?.keyed(), !sdks.isEmpty {
            let names = sdks.keys.sorted()
            let width = names.map { "\($0) SDK:".count }.max() ?? 0
            lines += ["", "SDKs".bold]
            lines += names.map { name in
                "\("\(name) SDK:".paddedWithSpaces(to: width)) \(sdks[name]?.first?.build ?? "")"
            }
        }
        if let compilers = compilers?.keyed(), !compilers.isEmpty {
            let names = compilers.keys.sorted()
            let labels = names.map { "\($0) \(compilers[$0]?.first?.number ?? ""):" }
            let width = labels.map(\.count).max() ?? 0
            lines += ["", "Compilers".bold]
            lines += zip(names, labels).map { name, label in
                "\(label.paddedWithSpaces(to: width)) \(compilers[name]?.first?.build ?? "")"
            }
        }

        let downloadLink = links?.download?.url.absoluteString
        let notesLink = links?.notes?.url.absoluteString
        if downloadLink != nil || notesLink != nil {
            lines += ["", "Links".bold]
            downloadLink.map { lines.append("Download:      " + $0) }
            notesLink.map { lines.append("Release Notes: " + $0) }
        }
        return lines
    }
}

extension XcodeList {
    func lines(terminalColumns: Int?) -> [String] {
        guard !isEmpty else {
            return ["No matching Xcode versions found.".yellow]
        }

        let columnWidth = (listed + installed + notInstallable).map(\.description.count).max()! + 12
        var lines = columns(listed.map(\.attributedDisplayName), width: columnWidth, terminalColumns: terminalColumns)
        if !installed.isEmpty {
            lines += ["", "Already installed:"]
            lines += columns(installed.map(\.attributedDisplayName), width: columnWidth, terminalColumns: terminalColumns)
        }
        if !notInstallable.isEmpty {
            lines += ["", "Not installable:"]
            lines += columns(notInstallable.map(\.description), width: columnWidth, terminalColumns: terminalColumns)
        }
        return lines
    }

    private func columns(_ entries: [String], width: Int, terminalColumns: Int?) -> [String] {
        guard entries.count > 10, let terminalColumns, terminalColumns >= width else {
            return entries
        }
        let columnCount = terminalColumns / width
        let rowCount = Int((Double(entries.count) / Double(columnCount)).rounded(.up))
        return (0 ..< rowCount).map { row in
            stride(from: row, to: entries.count, by: rowCount).map { index in
                let entry = entries[index]
                return entry.paddedWithSpaces(to: width + entry.count - entry.raw.count)
            }
            .joined()
        }
    }
}

extension Array where Element == XcodeApplication {
    var lines: [String] {
        let width = map(\.xcode.description.count).max() ?? 0
        return map { application in
            let name = application.xcode.attributedDisplayName
            return "\(name.paddedWithSpaces(to: width + name.count - name.raw.count)) – \(application.url.path.cyan)"
        }
    }
}

struct ApplicationPayload: Encodable {
    var path: String
    var version: String
    var build: String?
    var xcode: Xcode

    init(_ application: XcodeApplication) {
        path = application.url.path
        version = application.xcode.displayVersion
        build = application.xcode.version.build
        xcode = application.xcode
    }
}

struct ListPayload: Encodable {
    var listed: [Xcode]
    var installed: [Xcode]
    var notInstallable: [Xcode]

    init(_ list: XcodeList) {
        listed = list.listed
        installed = list.installed
        notInstallable = list.notInstallable
    }
}

struct DownloadPayload: Encodable {
    var path: String
    var xcode: Xcode
}

struct PathPayload: Encodable {
    var path: String?
}
