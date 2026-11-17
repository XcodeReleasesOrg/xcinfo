//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
import xcinfoCore

public struct TUIActions: Sendable {
    public var load: @Sendable () async throws -> (XcodeList, [XcodeApplication])
    public var perform: @Sendable (TUICommand) async -> Bool

    public init(
        load: @escaping @Sendable () async throws -> (XcodeList, [XcodeApplication]),
        perform: @escaping @Sendable (TUICommand) async -> Bool
    ) {
        self.load = load
        self.perform = perform
    }
}

public struct TUIApp: Sendable {
    private let actions: TUIActions
    private let renderer: TUIRenderer

    public init(actions: TUIActions, usesColors: Bool) {
        self.actions = actions
        renderer = TUIRenderer(usesColors: usesColors)
    }

    public static var isAvailable: Bool {
        TerminalSession.isInteractive
    }

    public func run() async throws {
        let terminal = TerminalSession()
        terminal.enter()
        defer { terminal.leave() }

        terminal.draw(renderer.render(TUIModel(sections: [], status: "Loading Xcode versions…"), width: terminal.size.width, height: terminal.size.height))
        var model = await load(status: nil)
        var lastSize: TerminalSize?
        var needsDraw = true

        while true {
            let size = terminal.size
            if needsDraw || size != lastSize {
                terminal.draw(renderer.render(model, width: size.width, height: size.height))
                lastSize = size
                needsDraw = false
            }

            for key in terminal.readKeys(timeout: .milliseconds(200)) {
                needsDraw = true
                guard let command = model.handle(key, pageSize: max(1, size.height - 4)) else { continue }
                switch command {
                case .quit:
                    return
                case .refresh:
                    model = await load(status: "Refreshed.", keepingSelection: model.selection)
                case .install, .download, .uninstall:
                    let selection = model.selection
                    terminal.leave()
                    let succeeded = await actions.perform(command)
                    print("\nPress Return to go back to the list.", terminator: "")
                    fflush(nil)
                    _ = readLine()
                    terminal.enter()
                    model = await load(status: succeeded ? "Done." : "The action did not finish.", keepingSelection: selection)
                }
            }
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
