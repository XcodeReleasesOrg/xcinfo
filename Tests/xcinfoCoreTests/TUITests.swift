import Foundation
import Testing
@testable import XCInfoTUI
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.
@testable import xcinfoCore

private let keyExamples: [([UInt8], [Key])] = [
    ([0x1B, 0x5B, 0x41], [.up]),
    ([0x1B, 0x5B, 0x42], [.down]),
    ([0x1B, 0x4F, 0x43], [.right]),
    ([0x1B, 0x5B, 0x44], [.left]),
    ([0x1B, 0x5B, 0x35, 0x7E], [.pageUp]),
    ([0x1B, 0x5B, 0x36, 0x7E], [.pageDown]),
    ([0x1B, 0x5B, 0x48], [.home]),
    ([0x1B, 0x5B, 0x34, 0x7E], [.end]),
    ([0x1B], [.escape]),
    ([0x03], [.interrupt]),
    ([0x0D], [.enter]),
    ([0x09], [.tab]),
    (Array("jq".utf8), [.character("j"), .character("q")]),
    ([0x1B, 0x5B, 0x41, 0x6A, 0x1B, 0x5B, 0x42], [.up, .character("j"), .down]),
    ([0x7F, 0x00], [.backspace]),
    ([0x08], [.backspace]),
    (Array("Grüße🎉".utf8), Array("Grüße🎉").map { .character($0) }),
    ([0x80, 0x61], [.character("a")]),
]

struct KeyTests {
    @Test
    func `bytes are parsed into keys`() {
        for (bytes, keys) in keyExamples {
            #expect(Key.parse(bytes) == keys, "\(bytes)")
        }
    }
}

struct TUIModelTests {
    private let installed = XcodeApplication(url: URL(fileURLWithPath: "/Applications/Xcode.app"), xcode: .fixture("16.0", build: "16A1"))
    private let available = Xcode.fixture("17.0", build: "17A1", release: .beta(1))
    private let older = Xcode.fixture("15.0", build: "15A1")
    private let notInstallable = Xcode.fixture("18.0", build: "18A1", requires: "99.0")

    private var model: TUIModel {
        TUIModel(
            list: XcodeList(listed: [notInstallable, available, installed.xcode, older], installed: [installed.xcode], notInstallable: [notInstallable]),
            installed: [installed]
        )
    }

    @Test
    func `versions are grouped into installed, available and not installable`() {
        #expect(model.sections.map(\.title) == ["Installed", "Available", "Not installable"])
        #expect(model.sections.map { $0.entries.map(\.xcode.version.build) } == [["16A1"], ["17A1", "15A1"], ["18A1"]])
        #expect(model.entries.first?.kind == .installed(installed.url))
    }

    @Test
    func `empty groups are left out`() {
        let model = TUIModel(list: XcodeList(listed: [older], installed: [], notInstallable: []), installed: [])

        #expect(model.sections.map(\.title) == ["Available"])
    }

    @Test
    func `navigation stays within the list`() {
        var model = model

        _ = model.handle(.up)
        #expect(model.selection == 0)
        _ = model.handle(.down)
        _ = model.handle(.character("j"))
        #expect(model.selection == 2)
        _ = model.handle(.end)
        #expect(model.selection == 3)
        _ = model.handle(.down)
        #expect(model.selection == 3)
        _ = model.handle(.pageUp, pageSize: 2)
        #expect(model.selection == 1)
        _ = model.handle(.home)
        #expect(model.selection == 0)
        _ = model.handle(.pageDown, pageSize: 10)
        #expect(model.selection == 3)
    }

    @Test(arguments: [Key.character("q"), .escape, .interrupt])
    func `quitting keys quit`(key: Key) {
        var model = model

        #expect(model.handle(key) == .quit)
    }

    @Test
    func `actions depend on the selected version`() {
        var model = model

        #expect(model.handle(.character("u")) == .uninstall(installed))
        #expect(model.handle(.character("d")) == .download(installed.xcode))
        #expect(model.handle(.character("i")) == nil)
        #expect(model.status == "16.0 (16A1) is already installed.")

        _ = model.handle(.down)
        #expect(model.status == nil)
        #expect(model.handle(.character("i")) == .install(available))
        #expect(model.handle(.character("u")) == nil)
        #expect(model.status == "Only installed versions can be uninstalled.")

        _ = model.handle(.end)
        #expect(model.handle(.character("i")) == nil)
        #expect(model.status == "18.0 (18A1) cannot be installed on this Mac.")
        #expect(model.handle(.character("r")) == .refresh)
    }

    @Test
    func `an empty model has no selection and no actions`() {
        var model = TUIModel(sections: [])

        #expect(model.selectedEntry == nil)
        #expect(model.handle(.character("i")) == nil)
        #expect(model.handle(.down) == nil)
        #expect(model.selection == 0)
    }
}

struct TUIRendererTests {
    private let renderer = TUIRenderer(usesColors: false)

    private var model: TUIModel {
        let xcodes = (1 ... 30).map { Xcode.fixture("\($0).0", build: "\($0)A1") }
        return TUIModel(sections: [
            TUISection(title: "Installed", entries: [TUIEntry(kind: .installed(URL(fileURLWithPath: "/Applications/Xcode.app")), xcode: .fixture(
                "16.0",
                build: "16A1",
                sdks: SDKs(macOS: Version("25A1")),
                compilers: Compilers(swift: Version("6.0.0.1", "6.0"))
            ))]),
            TUISection(title: "Available", entries: xcodes.map { TUIEntry(kind: .available, xcode: $0) }),
        ])
    }

    @Test
    func `every line fills the terminal exactly`() {
        for (width, height) in [(80, 24), (120, 40), (40, 8)] {
            let lines = renderer.render(model, width: width, height: height)

            #expect(lines.count == height)
            #expect(lines.allSatisfy { $0.count == width }, "\(width)x\(height)")
        }
    }

    @Test
    func `the list shows groups, the selection and the help`() {
        let lines = renderer.render(model, width: 80, height: 12)

        #expect(lines[0].hasPrefix(" xcinfo — Xcode versions"))
        #expect(lines[1].hasPrefix("Installed (1)"))
        #expect(lines[2].hasPrefix("› 16.0 (16A1)"))
        #expect(lines[3].hasPrefix("Available (30)"))
        #expect(lines[4].hasPrefix("  1.0 (1A1)"))
        #expect(lines.last?.hasPrefix(" ↑↓ move   d download   u uninstall   r refresh   q quit") == true)
    }

    @Test
    func `the list scrolls to keep the selection visible`() {
        var model = model
        model.selection = 25

        let lines = renderer.render(model, width: 80, height: 12)

        #expect(lines.contains { $0.hasPrefix("› 25.0 (25A1)") })
        #expect(!lines.contains { $0.hasPrefix("Installed") })
    }

    @Test
    func `wide terminals show the details next to the list`() {
        let lines = renderer.render(model, width: 120, height: 20)

        #expect(lines[1].contains("│ 16.0 (16A1)"))
        #expect(lines.contains { $0.contains("│ Installed: /Applications/Xcode.app") })
        #expect(lines.contains { $0.contains("│   macOS: 25A1") })
        #expect(lines.contains { $0.contains("│   swift 6.0: 6.0.0.1") })
        #expect(lines.contains { $0.contains("│   Download: https://download.example.invalid/Xcode.xip") })
    }

    @Test
    func `narrow terminals show only the list`() {
        let lines = renderer.render(model, width: 80, height: 20)

        #expect(!lines.contains { $0.contains("│") })
    }

    @Test
    func `long names are shortened with an ellipsis`() {
        let model = TUIModel(sections: [TUISection(title: "Available", entries: [
            TUIEntry(kind: .available, xcode: .fixture("15.0", build: String(repeating: "B", count: 60))),
        ])])

        let lines = renderer.render(model, width: 40, height: 8)

        #expect(lines[2].hasSuffix("…"))
        #expect(lines[2].count == 40)
    }

    @Test
    func `a tiny terminal asks for more space`() {
        let lines = renderer.render(model, width: 30, height: 5)

        #expect(lines.count == 5)
        #expect(lines[0].hasPrefix("Terminal too small"))
        #expect(lines.allSatisfy { $0.count == 30 })
    }

    @Test
    func `the status line shows messages`() {
        var model = model
        model.status = "Done."

        #expect(renderer.render(model, width: 80, height: 10)[8].hasPrefix("Done."))
    }

    @Test
    func `colors mark the selection`() {
        let lines = TUIRenderer(usesColors: true).render(model, width: 80, height: 10)

        #expect(lines[2].hasPrefix("\u{1B}[7m› 16.0 (16A1)"))
        #expect(lines[0].hasPrefix("\u{1B}[1;36m"))
    }

    @Test
    func `the help offers only the possible actions`() {
        let entry = TUIEntry(kind: .notInstallable, xcode: .fixture("18.0", build: "18A1"))

        #expect(renderer.help(for: entry) == " ↑↓ move   r refresh   q quit")
        #expect(renderer.help(for: TUIEntry(kind: .available, xcode: entry.xcode)) == " ↑↓ move   i install   d download   r refresh   q quit")
    }
}
