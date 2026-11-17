//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
import Rainbow

public struct OutputOptions: Sendable, Equatable {
    public var isVerbose: Bool
    public var isQuiet: Bool
    public var isJSON: Bool
    public var usesColors: Bool
    public var isTerminal: Bool

    public init(isVerbose: Bool = false, isQuiet: Bool = false, isJSON: Bool = false, usesColors: Bool = false, isTerminal: Bool = false) {
        self.isVerbose = isVerbose
        self.isQuiet = isQuiet
        self.isJSON = isJSON
        self.usesColors = usesColors
        self.isTerminal = isTerminal
    }

    public static func detect(
        isVerbose: Bool,
        isQuiet: Bool,
        isJSON: Bool,
        allowsColors: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTerminal: Bool = isatty(STDOUT_FILENO) != 0
    ) -> OutputOptions {
        let colorsSupported = isTerminal && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb"
        return OutputOptions(
            isVerbose: isVerbose,
            isQuiet: isQuiet,
            isJSON: isJSON,
            usesColors: allowsColors && colorsSupported && !isJSON,
            isTerminal: isTerminal
        )
    }
}

public struct TerminalRenderer: Sendable {
    public let options: OutputOptions
    private let standardOutput: @Sendable (String) -> Void
    private let standardError: @Sendable (String) -> Void

    public init(
        options: OutputOptions,
        standardOutput: @escaping @Sendable (String) -> Void = TerminalRenderer.writeToStandardOutput,
        standardError: @escaping @Sendable (String) -> Void = TerminalRenderer.writeToStandardError
    ) {
        self.options = options
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public static let writeToStandardOutput: @Sendable (String) -> Void = { text in
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    public static let writeToStandardError: @Sendable (String) -> Void = { text in
        FileHandle.standardError.write(Data(text.utf8))
    }

    public var logger: Logger {
        Logger { render($0) }
    }

    private var lineStart: String {
        options.isTerminal ? "\r\u{1B}[K" : ""
    }

    public func render(_ event: OutputEvent) {
        switch event {
        case let .message(text, .error):
            standardError(lineStart + paint(text, .error) + "\n")
        case let .message(text, .warning):
            guard !options.isJSON else { return }
            standardError(lineStart + paint(text, .warning) + "\n")
        case let .check(title, .failed):
            guard !options.isJSON else { return }
            standardError(lineStart + "\(title) \(paint("✗", .error))\n")
        default:
            guard !options.isJSON, !options.isQuiet else { return }
            renderStatus(event)
        }
    }

    public func print(_ line: String) {
        standardOutput(lineStart + line + "\n")
    }

    private func renderStatus(_ event: OutputEvent) {
        switch event {
        case let .section(title):
            standardOutput(lineStart + "\n" + paintSection(title) + "\n")
        case let .paragraph(title):
            standardOutput(lineStart + "\n" + paint(title, .emphasized) + "\n")
        case let .message(text, style):
            standardOutput(lineStart + paint(text, style) + "\n")
        case let .verbose(text):
            guard options.isVerbose else { return }
            standardOutput(lineStart + text + "\n")
        case let .check(title, .running):
            guard options.isTerminal else { return }
            standardOutput(lineStart + "\(title)...")
        case let .check(title, _):
            standardOutput(lineStart + "\(title) \(paint("✓", .success))\n")
        case let .progress(progress):
            renderProgress(progress)
        }
    }

    private func renderProgress(_ progress: OutputProgress) {
        if options.isTerminal {
            let display = ProgressDisplay(ratio: progress.fraction, width: 20)
            let bar = options.usesColors ? display.representation : display.representation.unstyled
            let line = ([progress.title + ":", bar] + [progress.detail].compactMap { $0 }).joined(separator: " ")
            standardOutput(lineStart + line + (progress.isFinished ? "\n" : ""))
        } else if progress.isMilestone || progress.isFinished {
            let percent = Int((min(1, max(0, progress.fraction)) * 100).rounded(.down))
            let line = (["\(progress.title): \(percent) %"] + [progress.detail].compactMap { $0 }).joined(separator: ", ")
            standardOutput(line + "\n")
        }
    }

    private func paint(_ text: String, _ style: OutputStyle) -> String {
        guard options.usesColors else { return text }
        switch style {
        case .plain:
            return text
        case .emphasized:
            return text.bold
        case .success:
            return text.cyan
        case .warning:
            return text.yellow
        case .error:
            return text.red
        }
    }

    private func paintSection(_ text: String) -> String {
        options.usesColors ? text.cyan.bold : text
    }
}

private extension String {
    var unstyled: String {
        replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}
