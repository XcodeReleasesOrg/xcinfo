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

    private func runningDownload() -> TUIActivity {
        var activity = TUIActivity(title: "Installing Xcode 16.0", steps: ["Identify", "Sign in", "Download", "Verify", "Extract", "Set up"])
        activity.apply(.section("Identifying"))
        activity.apply(.section("Sign in to Apple Developer"))
        activity.apply(.section("Downloading"))
        activity.apply(.message("Source: https://download.developer.apple.com/Developer_Tools/Xcode_16_with_a_really_long_name/Xcode_16_with_a_really_long_name.xip", .plain))
        for index in 0 ..< 30 {
            activity.apply(.message("message \(index)", .plain))
        }
        activity.apply(.message("watch out", .warning))
        activity.apply(.progress(OutputProgress(title: "Downloading", fraction: 0.25, detail: "1.5 GB of 2 GB remaining, 80 MB/s, about 19 sec left")))
        return activity
    }

    @Test
    func `steps follow the sections and the verification progress`() {
        var activity = runningDownload()
        #expect(activity.steps.map(\.state) == [.done, .done, .running, .pending, .pending, .pending])

        activity.apply(.progress(OutputProgress(title: "Verifying", fraction: 0.1)))
        #expect(activity.steps.map(\.state) == [.done, .done, .done, .running, .pending, .pending])

        activity.finish(succeeded: false, message: "Stopped.")
        #expect(activity.steps.map(\.state) == [.done, .done, .done, .failed, .pending, .pending])
    }

    @Test(arguments: [(80, 24), (120, 40), (40, 12), (200, 60)])
    func `the panel keeps the layout at every size`(width: Int, height: Int) {
        var model = TUIModel(sections: [TUISection(title: "Available", entries: [])])
        model.activity = runningDownload()

        let lines = TUIRenderer(usesColors: false).render(model, width: width, height: height)

        #expect(lines.count == height)
        #expect(lines.allSatisfy { $0.count == width }, "\(lines.map(\.count))")
        #expect(lines[0].hasPrefix(" xcinfo — Xcode versions"))
        #expect(lines.contains { $0.contains("┌ Installing Xcode 16.0") })
        if height >= 20 {
            #expect(lines.contains { $0.contains("✓ Identify") })
            #expect(lines.contains { $0.contains("▸ Download") })
            #expect(lines.contains { $0.contains("· Set up") })
        } else {
            #expect(lines.contains { $0.contains("▸ Download (3 of 6)") })
        }
        #expect(lines.contains { $0.contains("Downloading [") && $0.contains("25.0%") })
        #expect(lines.last?.hasPrefix(" Esc or Ctrl-C to stop") == true)
    }

    @Test
    func `wide terminals keep the list next to the panel`() {
        var model = TUIModel(sections: [TUISection(title: "Available", entries: [TUIEntry(kind: .available, xcode: .fixture("16.0", build: "16A1"))])])
        model.activity = runningDownload()

        let lines = TUIRenderer(usesColors: false).render(model, width: 120, height: 30)

        #expect(lines.contains { $0.hasPrefix("Available (1)") })
        #expect(lines.contains { $0.contains("about 19 sec left") })
        #expect(lines.contains { $0.contains("⚠ watch out") })
    }

    @Test
    func `a finished action shows its result and how to go back`() {
        var model = TUIModel(sections: [])
        var activity = runningDownload()
        activity.finish(succeeded: false, message: "The download failed.")
        model.activity = activity

        let lines = TUIRenderer(usesColors: false).render(model, width: 80, height: 24)

        #expect(lines.contains { $0.contains("✗ The download failed.") })
        #expect(lines.contains { $0.contains("✗ Download") })
        #expect(lines.last?.hasPrefix(" Return to go back to the list") == true)
    }

    @Test
    func `warnings and errors wrap inside the panel while detail lines are shortened`() {
        let warning = "The Keychain item 'xcinfo' could not be read: macOS refused access to the Keychain item: the password in the Keychain dialog was not accepted, or access was denied."
        var activity = TUIActivity(title: "Installing Xcode 16.0", steps: ["Identify"], showsVerbose: true)
        activity.apply(.message(warning, .warning))
        activity.apply(.verbose("Source: https://download.developer.apple.com/Developer_Tools/Xcode_16_with_a_really_long_name/Xcode_16.xip"))
        var model = TUIModel(sections: [])
        model.activity = activity

        let lines = TUIRenderer(usesColors: false).render(model, width: 80, height: 24)

        #expect(lines.allSatisfy { $0.count == 80 })
        let panelText = lines.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "│ ")) }.joined(separator: " ")
        let words = panelText.split(separator: " ").joined(separator: " ")
        #expect(words.contains("or access was denied."))
        #expect(!lines.contains { $0.contains("denied…") })
        #expect(lines.contains { $0.contains("Source: https://download.developer.apple.com/") && $0.contains("…") })
    }

    @Test
    func `a failed action still shows how to go back`() {
        var activity = TUIActivity(title: "Installing Xcode 16.0", steps: ["Identify", "Sign in"])
        activity.apply(.section("Sign in to Apple Developer"))
        activity.finish(succeeded: false, message: "Apple's sign-in configuration could not be loaded (configuration endpoint: HTTP 404).")
        var model = TUIModel(sections: [])
        model.activity = activity

        for (width, height) in [(80, 24), (60, 16)] {
            let lines = TUIRenderer(usesColors: false).render(model, width: width, height: height)
            #expect(lines.last?.hasPrefix(" Return to go back to the list") == true)
            #expect(lines.contains { $0.contains("✗ Sign in") })
        }
    }
}
