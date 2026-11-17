//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.

public struct TUIInstallOptions: Sendable, Equatable {
    public var folder: String
    public var createsSymlink: Bool
    public var selectsXcode: Bool

    public init(folder: String = "/Applications", createsSymlink: Bool = true, selectsXcode: Bool = true) {
        self.folder = folder
        self.createsSymlink = createsSymlink
        self.selectsXcode = selectsXcode
    }

    public var folderURL: URL {
        URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL
    }
}

public struct TUIInstallSetup: Sendable, Equatable {
    public enum Field: Sendable, Equatable, CaseIterable {
        case folder
        case symlink
        case selection
    }

    public enum Result: Sendable, Equatable {
        case start(TUIInstallOptions)
        case cancel
    }

    public let xcode: Xcode
    public private(set) var options: TUIInstallOptions
    public private(set) var focus = Field.folder

    public init(xcode: Xcode, options: TUIInstallOptions = TUIInstallOptions()) {
        self.xcode = xcode
        self.options = options
    }

    public mutating func handle(_ key: Key) -> Result? {
        switch key {
        case .escape, .interrupt:
            return .cancel
        case .enter:
            return options.folder.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .start(options)
        case .tab, .down:
            focus = Field.allCases[(Field.allCases.firstIndex(of: focus)! + 1) % Field.allCases.count]
        case .up:
            focus = Field.allCases[(Field.allCases.firstIndex(of: focus)! + Field.allCases.count - 1) % Field.allCases.count]
        case .backspace where focus == .folder:
            if !options.folder.isEmpty {
                options.folder.removeLast()
            }
        case let .character(character) where focus == .folder:
            options.folder.append(character)
        case .character(" "):
            toggle()
        default:
            break
        }
        return nil
    }

    private mutating func toggle() {
        switch focus {
        case .symlink:
            options.createsSymlink.toggle()
        case .selection:
            options.selectsXcode.toggle()
        case .folder:
            break
        }
    }

    var lines: [String] {
        func marker(_ field: Field) -> String {
            focus == field ? "›" : " "
        }
        return [
            "Install Xcode \(xcode.displayName)",
            "",
            "\(marker(.folder)) Folder: \(options.folder)\(focus == .folder ? "▏" : "")",
            "\(marker(.symlink)) [\(options.createsSymlink ? "x" : " ")] Point /Applications/Xcode.app to it",
            "\(marker(.selection)) [\(options.selectsXcode ? "x" : " ")] Select it with xcode-select",
            "",
            "Administrator rights (sudo) are needed for the license and components.",
            "Tab next · Space toggle · Return start · Esc cancel",
        ]
    }
}
