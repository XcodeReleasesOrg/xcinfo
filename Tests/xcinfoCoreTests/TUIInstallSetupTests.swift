import Foundation
import Testing
@testable import XCInfoTUI
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.
@testable import xcinfoCore

struct TUIInstallSetupTests {
    private let xcode = Xcode.fixture("27.3", build: "27C5035i", release: .beta(2))

    @Test
    func `the folder can be edited and both changes can be switched off`() {
        var setup = TUIInstallSetup(xcode: xcode)
        for _ in 0 ..< "/Applications".count {
            _ = setup.handle(.backspace)
        }
        for character in "~/xcinfo-test" {
            _ = setup.handle(.character(character))
        }
        _ = setup.handle(.tab)
        _ = setup.handle(.character(" "))
        _ = setup.handle(.tab)
        _ = setup.handle(.character(" "))

        let expected = TUIInstallOptions(folder: "~/xcinfo-test", createsSymlink: false, selectsXcode: false)
        #expect(setup.handle(.enter) == .start(expected))
    }

    @Test
    func `option-backspace and ctrl-u clear the folder without leaving the setup`() {
        var setup = TUIInstallSetup(xcode: xcode, options: TUIInstallOptions(folder: "/Volumes/External/Xcodes"))
        for key in Key.parse([0x1B, 0x7F]) {
            #expect(setup.handle(key) == nil)
        }
        #expect(setup.options.folder == "/Volumes/External/")
        #expect(setup.handle(.deleteToStart) == nil)
        #expect(setup.options.folder.isEmpty)
        #expect(setup.handle(.paste("/Applications")) == nil)
        #expect(setup.options.folder == "/Applications")
    }

    @Test
    func `a tilde folder is expanded`() {
        #expect(TUIInstallOptions(folder: "~/xcinfo-test").folderURL.path == "\(NSHomeDirectory())/xcinfo-test")
    }

    @Test(arguments: [Key.escape, .interrupt])
    func `the setup can be cancelled`(key: Key) {
        var setup = TUIInstallSetup(xcode: xcode)
        #expect(setup.handle(key) == .cancel)
    }

    @Test
    func `an empty folder cannot be started`() {
        var setup = TUIInstallSetup(xcode: xcode, options: TUIInstallOptions(folder: ""))
        #expect(setup.handle(.enter) == nil)
    }

    @Test
    func `the setup shows the folder and what will change before anything starts`() {
        var model = TUIModel(sections: [TUISection(title: "Available", entries: [TUIEntry(kind: .available, xcode: xcode)])])
        _ = model.handle(.character("i"))

        let lines = TUIRenderer(usesColors: false).render(model, width: 90, height: 24)

        #expect(lines.count == 24)
        #expect(lines.allSatisfy { $0.count == 90 })
        #expect(lines.contains { $0.contains("Folder: /Applications") })
        #expect(lines.contains { $0.contains("[x] Point /Applications/Xcode.app to it") })
        #expect(lines.contains { $0.contains("[x] Select it with xcode-select") })
        #expect(lines.contains { $0.contains("Return start · Esc cancel") })
    }
}
