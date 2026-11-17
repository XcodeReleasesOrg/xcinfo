//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
import XCIFoundation

public struct TUIActivity: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running
        case stopping
        case finished(succeeded: Bool)
    }

    public struct Line: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case section
            case plain
            case success
            case warning
            case error
            case check(CheckState)
        }

        public var text: String
        public var kind: Kind
    }

    static let maximumLines = 200

    public var title: String
    public var state = State.running
    public var progress: OutputProgress?
    public private(set) var lines: [Line] = []
    public var showsVerbose: Bool

    public init(title: String, showsVerbose: Bool = false) {
        self.title = title
        self.showsVerbose = showsVerbose
    }

    public mutating func apply(_ event: OutputEvent) {
        switch event {
        case let .section(title), let .paragraph(title):
            progress = nil
            append(Line(text: title, kind: .section))
        case let .message(text, style):
            let kind: Line.Kind = switch style {
            case .plain, .emphasized: .plain
            case .success: .success
            case .warning: .warning
            case .error: .error
            }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                append(Line(text: String(line), kind: kind))
            }
        case let .verbose(text):
            if showsVerbose {
                append(Line(text: text, kind: .plain))
            }
        case let .check(title, state):
            if state != .running, let index = lines.lastIndex(where: { $0.text == title && $0.kind == .check(.running) }) {
                lines[index].kind = .check(state)
            } else {
                append(Line(text: title, kind: .check(state)))
            }
        case let .progress(value):
            progress = value
            if value.isFinished {
                append(Line(text: ([value.title + ":"] + [value.detail].compactMap { $0 }).joined(separator: " "), kind: .success))
                progress = nil
            }
        }
    }

    public mutating func finish(succeeded: Bool, message: String?) {
        state = .finished(succeeded: succeeded)
        progress = nil
        if let message {
            append(Line(text: message, kind: succeeded ? .success : .error))
        }
    }

    private mutating func append(_ line: Line) {
        lines.append(line)
        if lines.count > Self.maximumLines {
            lines.removeFirst(lines.count - Self.maximumLines)
        }
    }
}
