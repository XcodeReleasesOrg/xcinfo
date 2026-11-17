//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
@preconcurrency import Rainbow // Rainbow (Swift 4 mode) keeps its color switch in an unannotated global; it is written once at startup before any concurrent work.

public enum OutputStyle: String, Sendable, Equatable {
    case plain
    case emphasized
    case success
    case warning
    case error
}

public enum CheckState: String, Sendable, Equatable {
    case running
    case passed
    case failed
}

public struct OutputProgress: Sendable, Equatable {
    public var title: String
    public var fraction: Double
    public var detail: String?
    public var isMilestone: Bool

    public init(title: String, fraction: Double, detail: String? = nil, isMilestone: Bool = false) {
        self.title = title
        self.fraction = fraction
        self.detail = detail
        self.isMilestone = isMilestone
    }

    public var isFinished: Bool {
        fraction >= 1
    }
}

public enum OutputEvent: Sendable, Equatable {
    case section(String)
    case paragraph(String)
    case message(String, OutputStyle)
    case verbose(String)
    case check(String, CheckState)
    case progress(OutputProgress)
}

public struct Logger: Sendable {
    private let emit: @Sendable (OutputEvent) -> Void

    public init(emit: @escaping @Sendable (OutputEvent) -> Void) {
        self.emit = emit
    }

    public func emit(_ event: OutputEvent) {
        emit(event)
    }

    public func beginSection(_ message: String) {
        emit(.section(message))
    }

    public func beginParagraph(_ message: String) {
        emit(.paragraph(message))
    }

    public func log(_ message: String) {
        emit(.message(message, .plain))
    }

    public func emphasized(_ message: String) {
        emit(.message(message, .emphasized))
    }

    public func verbose(_ message: String) {
        emit(.verbose(message))
    }

    public func success(_ message: String) {
        emit(.message(message, .success))
    }

    public func error(_ message: String) {
        emit(.message(message, .error))
    }

    public func warn(_ message: String) {
        emit(.message(message, .warning))
    }

    public func check(_ title: String, _ state: CheckState) {
        emit(.check(title, state))
    }

    public func progress(_ progress: OutputProgress) {
        emit(.progress(progress))
    }
}

public extension Logger {
    static var isANSIEnabled: Bool {
        get { Rainbow.enabled }
        set { Rainbow.enabled = newValue }
    }
}
