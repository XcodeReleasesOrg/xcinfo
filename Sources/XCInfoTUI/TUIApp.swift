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

    public init(
        load: @escaping @Sendable () async throws -> (XcodeList, [XcodeApplication]),
        perform: @escaping @Sendable (TUICommand, TUISession) async -> TUIOutcome
    ) {
        self.load = load
        self.perform = perform
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

    static let frameInterval = Duration.milliseconds(100)

    public static var isAvailable: Bool {
        TerminalSession.isInteractive
    }

    public func run() async throws {
        try await InterruptSignals([SIGTERM, SIGHUP]).run { _ in } operation: {
            await runInTerminal()
        }
    }

    private func runInTerminal() async {
        let terminal = TerminalSession()
        terminal.enter()
        defer { terminal.leave() }

        let (inputs, input) = AsyncStream.makeStream(of: TUIInput.self)
        let gate = KeyReaderGate()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let reader = TerminalInput()
                while !Task.isCancelled {
                    if await gate.isPaused {
                        try? await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    let keys = reader.readKeys(timeout: .milliseconds(100))
                    input.yield(keys.isEmpty ? .tick : .keys(keys))
                }
            }
            await loop(terminal: terminal, gate: gate, inputs: inputs, input: input, group: &group)
            group.cancelAll()
        }
    }

    private func loop(
        terminal: TerminalSession,
        gate: KeyReaderGate,
        inputs: AsyncStream<TUIInput>,
        input: AsyncStream<TUIInput>.Continuation,
        group: inout TaskGroup<Void>
    ) async {
        var model = TUIModel(sections: [], status: "Loading Xcode versions…")
        var lastSize: TerminalSize?
        var questions: TUIQuestionBox?
        var cancelAction: AsyncStream<Void>.Continuation?

        var lastDraw = ContinuousClock.now
        var isDirty = false

        func draw(force: Bool = false) {
            let size = terminal.size
            guard force || isDirty || size != lastSize else { return }
            terminal.draw(renderer.render(model, width: size.width, height: size.height))
            terminal.isPasteBracketed = model.isEditingText
            lastSize = size
            lastDraw = .now
            isDirty = false
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
                isDirty = true
                if lastDraw.duration(to: .now) >= TUIApp.frameInterval {
                    draw()
                }
                continue
            case let .question(question):
                model.dialog = TUIDialog(question)
            case let .releaseTerminal(release):
                model.activity?.apply(.message(release.message, .plain))
                draw(force: true)
                await terminal.handOver(release, gate: gate)
                continue
            case let .reacquireTerminal(release):
                await terminal.takeBack(release, gate: gate)
                lastSize = nil
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
                    case .install, .download, .uninstall, .switchTo:
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
        case .switchTo:
            ["Switch"]
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
        case let .switchTo(application):
            "Switching to Xcode \(application.xcode.displayName)"
        case .quit, .refresh:
            ""
        }
    }
}

extension TerminalControl {
    func handOver(_ release: TerminalRelease, gate: KeyReaderGate) async {
        await gate.pause()
        if release.leavesFullScreen {
            leave()
        } else {
            leaveRawMode()
        }
        release.done.resume(returning: modeDescription)
    }

    func takeBack(_ release: TerminalRelease, gate: KeyReaderGate) async {
        if release.leavesFullScreen {
            enter()
        } else {
            enterRawMode()
        }
        discardInput()
        await gate.resume()
        release.done.resume(returning: modeDescription)
    }
}
