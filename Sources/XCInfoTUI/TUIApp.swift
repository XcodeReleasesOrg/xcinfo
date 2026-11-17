//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
import XCIFoundation
import xcinfoCore

public struct TUIActions: Sendable {
    public var load: @Sendable () async throws -> (XcodeList, [XcodeApplication])
    public var perform: @Sendable (TUICommand, TUISession) async -> TUIOutcome
    public var prepare: @Sendable () async -> Void

    public init(
        load: @escaping @Sendable () async throws -> (XcodeList, [XcodeApplication]),
        perform: @escaping @Sendable (TUICommand, TUISession) async -> TUIOutcome,
        prepare: @escaping @Sendable () async -> Void = {}
    ) {
        self.load = load
        self.perform = perform
        self.prepare = prepare
    }
}

public struct TUIApp: Sendable {
    private let actions: TUIActions
    private let renderer: TUIRenderer
    private let showsVerbose: Bool

    public init(actions: TUIActions, usesColors: Bool, showsVerbose: Bool = false) {
        self.actions = actions
        renderer = TUIRenderer(usesColors: usesColors)
        self.showsVerbose = showsVerbose
    }

    public static var isAvailable: Bool {
        TerminalSession.isInteractive
    }

    public func run() async throws {
        try await InterruptSignals([SIGTERM, SIGHUP]).run { _ in } operation: {
            await runInTerminal()
        }
    }

    private func runInTerminal() async {
        await actions.prepare()
        let terminal = TerminalSession()
        terminal.enter()
        defer { terminal.leave() }

        let (inputs, input) = AsyncStream.makeStream(of: TUIInput.self)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let reader = TerminalInput()
                while !Task.isCancelled {
                    let keys = reader.readKeys(timeout: .milliseconds(100))
                    input.yield(keys.isEmpty ? .tick : .keys(keys))
                }
            }
            await loop(terminal: terminal, inputs: inputs, input: input, group: &group)
            group.cancelAll()
        }
    }

    private func loop(
        terminal: TerminalSession,
        inputs: AsyncStream<TUIInput>,
        input: AsyncStream<TUIInput>.Continuation,
        group: inout TaskGroup<Void>
    ) async {
        var model = TUIModel(sections: [], status: "Loading Xcode versions…")
        var lastSize: TerminalSize?
        var questions: TUIQuestionBox?
        var cancelAction: AsyncStream<Void>.Continuation?

        func draw(force: Bool = false) {
            let size = terminal.size
            guard force || size != lastSize else { return }
            terminal.draw(renderer.render(model, width: size.width, height: size.height))
            lastSize = size
        }

        draw(force: true)
        model = await load(status: nil)
        draw(force: true)

        for await event in inputs {
            switch event {
            case .tick:
                draw()
                continue
            case let .output(output):
                model.activity?.apply(output)
            case let .question(question):
                model.dialog = TUIDialog(question)
            case let .finished(outcome):
                model.activity?.finish(succeeded: outcome.succeeded, message: outcome.message)
                questions = nil
                cancelAction = nil
            case let .keys(keys):
                for key in keys {
                    if var dialog = model.dialog {
                        let answer = dialog.handle(key)
                        model.dialog = answer == nil ? dialog : nil
                        if answer == .cancelled {
                            await questions?.cancel()
                            cancelAction?.yield()
                            model.activity?.state = .stopping
                        } else if let answer {
                            await questions?.answer(answer)
                        }
                        continue
                    }
                    if let activity = model.activity {
                        switch (activity.state, key) {
                        case (.running, .escape), (.running, .interrupt):
                            await questions?.cancel()
                            cancelAction?.yield()
                            model.activity?.state = .stopping
                        case (.finished, .enter), (.finished, .escape), (.finished, .character("q")):
                            let status = model.activity?.lines.last?.text
                            model = await load(status: status, keepingSelection: model.selection)
                        default:
                            break
                        }
                        continue
                    }
                    let size = terminal.size
                    guard let command = model.handle(key, pageSize: max(1, size.height - 4)) else { continue }
                    switch command {
                    case .quit:
                        input.finish()
                        return
                    case .refresh:
                        model = await load(status: "Refreshed.", keepingSelection: model.selection)
                    case .install, .download, .uninstall:
                        let box = TUIQuestionBox(input: input)
                        let (cancelSignal, cancel) = AsyncStream.makeStream(of: Void.self)
                        questions = box
                        cancelAction = cancel
                        model.activity = TUIActivity(title: command.title, steps: command.steps, showsVerbose: showsVerbose)
                        let session = TUISession(input: input, questions: box)
                        group.addTask { [actions] in
                            let outcome = await withTaskGroup(of: TUIOutcome?.self) { action in
                                action.addTask { await actions.perform(command, session) }
                                action.addTask {
                                    for await _ in cancelSignal {
                                        return nil
                                    }
                                    return nil
                                }
                                var result: TUIOutcome?
                                for await finished in action {
                                    if let finished {
                                        result = finished
                                        action.cancelAll()
                                    } else if result == nil {
                                        action.cancelAll()
                                    }
                                }
                                return result ?? TUIOutcome(succeeded: false, message: "Stopped.")
                            }
                            input.yield(.finished(outcome))
                        }
                    }
                }
            }
            draw(force: true)
        }
    }

    private func load(status: String?, keepingSelection selection: Int = 0) async -> TUIModel {
        do {
            let (list, installed) = try await actions.load()
            var model = TUIModel(list: list, installed: installed, status: status)
            model.selection = min(selection, max(0, model.entries.count - 1))
            return model
        } catch {
            return TUIModel(sections: [], status: "Loading failed: \(error.localizedDescription)")
        }
    }
}

extension TUICommand {
    var steps: [String] {
        switch self {
        case .install:
            ["Identify", "Sign in", "Download", "Verify", "Extract", "Set up"]
        case .download:
            ["Identify", "Sign in", "Download", "Verify"]
        case .uninstall:
            ["Uninstall"]
        case .quit, .refresh:
            []
        }
    }

    var title: String {
        switch self {
        case let .install(xcode, _):
            "Installing Xcode \(xcode.displayName)"
        case let .download(xcode):
            "Downloading Xcode \(xcode.displayName)"
        case let .uninstall(application):
            "Uninstalling Xcode \(application.xcode.displayName)"
        case .quit, .refresh:
            ""
        }
    }
}
