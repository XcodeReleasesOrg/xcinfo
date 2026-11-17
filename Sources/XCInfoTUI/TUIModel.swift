//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
import xcinfoCore
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.

public struct TUIEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case installed(URL)
        case available
        case notInstallable
    }

    public var kind: Kind
    public var xcode: Xcode
}

public struct TUISection: Sendable, Equatable {
    public var title: String
    public var entries: [TUIEntry]
}

public enum TUICommand: Sendable, Equatable {
    case quit
    case refresh
    case install(Xcode)
    case download(Xcode)
    case uninstall(XcodeApplication)
}

public struct TUIModel: Sendable, Equatable {
    public var sections: [TUISection]
    public var selection = 0
    public var status: String?

    public init(sections: [TUISection], status: String? = nil) {
        self.sections = sections
        self.status = status
    }

    public init(list: XcodeList, installed: [XcodeApplication], status: String? = nil) {
        let installedBuilds = Set(installed.map(\.xcode.version.build))
        let notInstallableBuilds = Set(list.notInstallable.map(\.version.build))
        let available = list.listed.filter {
            !installedBuilds.contains($0.version.build) && !notInstallableBuilds.contains($0.version.build)
        }
        self.init(
            sections: [
                TUISection(title: "Installed", entries: installed.map { TUIEntry(kind: .installed($0.url), xcode: $0.xcode) }),
                TUISection(title: "Available", entries: available.map { TUIEntry(kind: .available, xcode: $0) }),
                TUISection(title: "Not installable", entries: list.notInstallable.map { TUIEntry(kind: .notInstallable, xcode: $0) }),
            ].filter { !$0.entries.isEmpty },
            status: status
        )
    }

    public var entries: [TUIEntry] {
        sections.flatMap(\.entries)
    }

    public var selectedEntry: TUIEntry? {
        let entries = entries
        return entries.indices.contains(selection) ? entries[selection] : nil
    }

    public mutating func handle(_ key: Key, pageSize: Int = 10) -> TUICommand? {
        let count = entries.count
        switch key {
        case .up, .character("k"):
            selection = max(0, selection - 1)
        case .down, .character("j"):
            selection = min(max(0, count - 1), selection + 1)
        case .pageUp:
            selection = max(0, selection - pageSize)
        case .pageDown:
            selection = min(max(0, count - 1), selection + pageSize)
        case .home, .character("g"):
            selection = 0
        case .end, .character("G"):
            selection = max(0, count - 1)
        case .character("q"), .escape, .interrupt:
            return .quit
        case .character("r"):
            return .refresh
        case .character("i"):
            return command(for: .install)
        case .character("d"):
            return command(for: .download)
        case .character("u"):
            return command(for: .uninstall)
        default:
            break
        }
        status = nil
        return nil
    }

    private enum Action {
        case install
        case download
        case uninstall
    }

    private mutating func command(for action: Action) -> TUICommand? {
        guard let entry = selectedEntry else { return nil }
        switch (action, entry.kind) {
        case (.install, .available):
            return .install(entry.xcode)
        case (.download, .available), (.download, .installed):
            return .download(entry.xcode)
        case let (.uninstall, .installed(url)):
            return .uninstall(XcodeApplication(url: url, xcode: entry.xcode))
        case (.install, .installed):
            status = "\(entry.xcode.displayName) is already installed."
        case (.uninstall, _):
            status = "Only installed versions can be uninstalled."
        case (_, .notInstallable):
            status = "\(entry.xcode.displayName) cannot be installed on this Mac."
        }
        return nil
    }
}
