import Foundation
import Testing
import XCIFoundation
@testable import XCInfoTUI

struct TUIActivityTests {
    @Test
    func `output events become lines, checks are updated in place and verbose lines are hidden`() {
        var activity = TUIActivity(title: "Installing Xcode 16.0")
        activity.apply(.section("Extracting"))
        activity.apply(.message("first\nsecond", .plain))
        activity.apply(.verbose("hidden"))
        activity.apply(.check("Verifying Xcode with Gatekeeper", .running))
        activity.apply(.check("Verifying Xcode with Gatekeeper", .passed))
        activity.apply(.message("careful", .warning))
        activity.apply(.message("broken", .error))

        #expect(activity.lines == [
            .init(text: "Extracting", kind: .section),
            .init(text: "first", kind: .plain),
            .init(text: "second", kind: .plain),
            .init(text: "Verifying Xcode with Gatekeeper", kind: .check(.passed)),
            .init(text: "careful", kind: .warning),
            .init(text: "broken", kind: .error),
        ])
    }

    @Test
    func `progress is shown until it finishes and then becomes a line`() {
        var activity = TUIActivity(title: "Downloading")
        activity.apply(.progress(OutputProgress(title: "Downloading", fraction: 0.5, detail: "1 GB remaining")))
        #expect(activity.progress?.fraction == 0.5)

        activity.apply(.progress(OutputProgress(title: "Downloading", fraction: 1, detail: "done in 10 sec", isFinished: true)))

        #expect(activity.progress == nil)
        #expect(activity.lines.last == .init(text: "Downloading: done in 10 sec", kind: .success))
    }

    @Test
    func `verbose lines are shown when asked for and the history is limited`() {
        var activity = TUIActivity(title: "x", showsVerbose: true)
        for index in 0 ..< 250 {
            activity.apply(.verbose("line \(index)"))
        }

        #expect(activity.lines.count == TUIActivity.maximumLines)
        #expect(activity.lines.last?.text == "line 249")
    }

    @Test
    func `the activity view fills the screen and shows progress, recent lines and the right help`() {
        var activity = TUIActivity(title: "Downloading Xcode 16.0")
        for index in 0 ..< 30 {
            activity.apply(.message("message \(index)", .plain))
        }
        activity.apply(.message("watch out", .warning))
        activity.apply(.progress(OutputProgress(title: "Downloading", fraction: 0.25, detail: "3 GB remaining")))
        var model = TUIModel(sections: [])
        model.activity = activity
        let renderer = TUIRenderer(usesColors: false)

        let lines = renderer.render(model, width: 80, height: 20)

        #expect(lines.count == 20)
        #expect(lines.allSatisfy { $0.count == 80 }, "\(lines.map(\.count))")
        #expect(lines[0].hasPrefix(" xcinfo — Downloading Xcode 16.0"))
        #expect(lines.contains { $0.contains("⚠ watch out") })
        #expect(lines.contains { $0.contains("Downloading: [") && $0.contains("25.0%") && $0.contains("3 GB remaining") })
        #expect(!lines.contains { $0.contains("message 0 ") })
        #expect(lines.last?.hasPrefix(" Esc or Ctrl-C to stop") == true)

        model.activity?.finish(succeeded: false, message: "The download failed.")
        let finished = renderer.render(model, width: 80, height: 20)
        #expect(finished.contains { $0.contains("✗ The download failed.") })
        #expect(finished.last?.hasPrefix(" Return to go back to the list") == true)
    }
}
