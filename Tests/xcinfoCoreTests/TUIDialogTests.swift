import Foundation
import Testing
@testable import XCInfoTUI

struct TUIDialogTests {
    private func type(_ text: String, into dialog: inout TUIDialog) {
        for character in text {
            _ = dialog.handle(.character(character))
        }
    }

    @Test
    func `a text field collects characters, supports backspace and returns the text`() {
        var dialog = TUIDialog(.text(prompt: "Apple ID (email):", isSecret: false, invalidMessage: nil, isInvalid: { _ in false }))
        type("user@examplx", into: &dialog)
        _ = dialog.handle(.backspace)
        type("e.invalid", into: &dialog)

        #expect(dialog.input == "user@example.invalid")
        #expect(dialog.handle(.enter) == .text("user@example.invalid"))
        #expect(dialog.input.isEmpty)
    }

    @Test
    func `an invalid entry shows the message and keeps the dialog open`() {
        var dialog = TUIDialog(.text(prompt: "Code:", isSecret: false, invalidMessage: "Enter 6 digits", isInvalid: { $0.count != 6 }))
        type("123", into: &dialog)

        #expect(dialog.handle(.enter) == nil)
        #expect(dialog.error == "Enter 6 digits")
        type("456", into: &dialog)
        #expect(dialog.error == nil)
        #expect(dialog.handle(.enter) == .text("123456"))
    }

    @Test
    func `a secret is never shown and not kept after confirming`() {
        var dialog = TUIDialog(.text(
            prompt: "Apple ID password for user (not your Mac password):",
            isSecret: true,
            invalidMessage: nil,
            isInvalid: { _ in false }
        ))
        type("Grüße 🎉", into: &dialog)

        let rendered = TUIRenderer(usesColors: false).box(dialog, width: 80).joined(separator: "\n")
        #expect(!rendered.contains("Grüße"))
        #expect(rendered.contains("> •••••••▏"))
        #expect(rendered.contains("Apple ID password for user (not your Mac password):"))
        #expect(dialog.handle(.enter) == .text("Grüße 🎉"))
        #expect(dialog.input.isEmpty)
    }

    @Test(arguments: [Key.escape, .interrupt])
    func `escape and ctrl-c cancel any dialog`(key: Key) {
        var text = TUIDialog(.text(prompt: "x", isSecret: true, invalidMessage: nil, isInvalid: { _ in false }))
        var choice = TUIDialog(.choice(prompt: "x", choices: ["a"]))
        var confirm = TUIDialog(.confirm(prompt: "x"))

        #expect(text.handle(key) == .cancelled)
        #expect(choice.handle(key) == .cancelled)
        #expect(confirm.handle(key) == .cancelled)
    }

    @Test
    func `a choice moves with the arrows and accepts a number`() {
        var dialog = TUIDialog(.choice(prompt: "Choose:", choices: ["one", "two", "three"]))
        _ = dialog.handle(.down)
        _ = dialog.handle(.down)
        _ = dialog.handle(.down)
        #expect(dialog.selection == 2)
        _ = dialog.handle(.up)
        #expect(dialog.handle(.enter) == .choice(1))

        var numbered = TUIDialog(.choice(prompt: "Choose:", choices: ["one", "two"]))
        #expect(numbered.handle(.character("2")) == .choice(1))
        #expect(numbered.handle(.character("9")) == nil)
    }

    @Test
    func `a question is answered with y, n or the selected button`() {
        var dialog = TUIDialog(.confirm(prompt: "Move it to the Trash?"))
        #expect(dialog.handle(.character("y")) == .confirm(true))
        #expect(dialog.handle(.character("N")) == .confirm(false))
        #expect(dialog.handle(.enter) == .confirm(true))
        _ = dialog.handle(.right)
        #expect(dialog.handle(.enter) == .confirm(false))
    }

    @Test
    func `the dialog is drawn as a centered box without changing the screen size`() {
        var model = TUIModel(sections: [])
        model.dialog = TUIDialog(.confirm(prompt: "Move Xcode 16.0 at /Applications/Xcode.app to the Trash?"))

        let lines = TUIRenderer(usesColors: false).render(model, width: 80, height: 20)

        #expect(lines.count == 20)
        #expect(lines.allSatisfy { $0.count == 80 })
        #expect(lines.contains { $0.contains("Move Xcode 16.0 at /Applications/Xcode.app to the Trash?") })
        #expect(lines.contains { $0.contains("[ Yes ]   No") })
        #expect(lines.contains { $0.contains("┌") } && lines.contains { $0.contains("┘") })
    }
}
