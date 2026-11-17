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

    public enum StepState: Sendable, Equatable {
        case pending
        case running
        case done
        case failed
    }

    public struct Step: Sendable, Equatable {
        public var name: String
        public var state = StepState.pending

        public init(name: String) {
            self.name = name
        }
    }

    static let maximumLines = 200

    public var title: String
    public private(set) var steps: [Step]
    public var state = State.running
    public var progress: OutputProgress?
    public private(set) var lines: [Line] = []
    public var showsVerbose: Bool

    public init(title: String, steps: [String] = [], showsVerbose: Bool = false) {
        self.title = title
        self.steps = steps.map(Step.init)
        self.showsVerbose = showsVerbose
        if !self.steps.isEmpty {
            self.steps[0].state = .running
        }
    }

    static let stepNames = [
        "Identifying": "Identify",
        "Sign in to Apple Developer": "Sign in",
        "Downloading": "Download",
        "Verifying": "Verify",
        "Extracting": "Extract",
        "Installing": "Set up",
    ]

    mutating func begin(_ section: String) {
        guard let name = Self.stepNames[section] ?? steps.first(where: { section.hasPrefix($0.name) })?.name,
              let index = steps.firstIndex(where: { $0.name == name }),
              steps[index].state == .pending
        else { return }
        for earlier in steps.indices where earlier < index && steps[earlier].state != .failed {
            steps[earlier].state = .done
        }
        steps[index].state = .running
    }

    public mutating func apply(_ event: OutputEvent) {
        switch event {
        case let .section(title), let .paragraph(title):
            progress = nil
            begin(title)
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
            begin(value.title)
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
        for index in steps.indices where steps[index].state == .running {
            steps[index].state = succeeded ? .done : .failed
        }
        if succeeded {
            for index in steps.indices where steps[index].state == .pending {
                steps[index].state = .done
            }
        }
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
