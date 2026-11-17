import Testing
@testable import XCInfoTUI

struct TextFieldTests {
    private func field(_ text: String, cursor: Int? = nil) -> TextField {
        var field = TextField(text)
        for _ in 0 ..< (text.count - (cursor ?? text.count)) {
            field.handle(.left)
        }
        return field
    }

    private func applying(_ keys: [Key], to field: TextField) -> TextField {
        var field = field
        for key in keys {
            field.handle(key)
        }
        return field
    }

    @Test(arguments: [
        ("/Applications/Xcodes", [Key.deleteWord], "/Applications/", 14),
        ("/Applications/", [.deleteWord], "/", 1),
        ("/Applications/Xcodes", [.deleteToStart], "", 0),
        ("/Applications/Xcodes", [.home, .deleteToEnd], "", 0),
        ("/Applications", [.home, .character("~")], "~/Applications", 1),
        ("/Applications", [.home, .delete], "Applications", 0),
        ("/Applications", [.home, .right, .backspace], "Applications", 0),
        ("/Volumes/Ext", [.wordLeft, .deleteToEnd], "/Volumes/", 9),
        ("/Volumes/Ext", [.home, .wordRight, .paste("New "), .end], "/VolumesNew /Ext", 16),
        ("a b", [.left, .left, .left, .left, .backspace], "a b", 0),
        ("Grüße 🎉", [.backspace, .deleteWord], "", 0),
        ("Grüße 🎉", [.left, .backspace], "Grüße🎉", 5),
    ] as [(String, [Key], String, Int)])
    func `editing keys change the text and the cursor`(text: String, keys: [Key], expected: String, cursor: Int) {
        let edited = applying(keys, to: field(text))
        #expect(edited.text == expected)
        #expect(edited.cursor == cursor)
    }

    @Test
    func `keys that do not edit text are not handled`() {
        var field = TextField("x")
        let handled = [Key.enter, .escape, .tab, .up].map { field.handle($0) }
        #expect(handled == [false, false, false, false])
        #expect(field.text == "x")
    }

    @Test
    func `the display scrolls to keep the cursor visible`() {
        #expect(field("abcdef").display(width: 4) == "def▏")
        #expect(field("abcdef", cursor: 0).display(width: 4) == "▏abc")
        #expect(field("abcdef", cursor: 3).display(width: 10) == "abc▏def")
    }

    @Test
    func `a masked display shows only dots`() {
        #expect(TextField("Grüße").display(width: 20, masked: true) == "•••••▏")
    }
}
