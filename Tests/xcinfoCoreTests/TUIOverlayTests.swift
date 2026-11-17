import Foundation
import Testing
@testable import XCInfoTUI
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.
@testable import xcinfoCore

struct TUIOverlayTests {
    private var model: TUIModel {
        let entries = (0 ..< 60).map { TUIEntry(kind: .available, xcode: .fixture("26.\($0)", build: "17F\($0)")) }
        return TUIModel(sections: [TUISection(title: "Available", entries: entries)])
    }

    private func assertOverlayKeepsSurroundings(_ overlaid: TUIModel, width: Int, height: Int, usesColors: Bool) throws {
        let renderer = TUIRenderer(usesColors: usesColors)
        let base = renderer.render(model, width: width, height: height).map(\.strippingANSI)
        let lines = renderer.render(overlaid, width: width, height: height).map(\.strippingANSI)
        let top = try #require(lines.firstIndex { $0.contains("┌") })
        let bottom = try #require(lines.firstIndex { $0.contains("└") })
        let left = try #require(lines[top].firstIndex(of: "┌")).utf16Offset(in: lines[top])
        let right = try #require(lines[top].firstIndex(of: "┐")).utf16Offset(in: lines[top]) + 1

        #expect(lines.count == height)
        for (index, line) in lines.enumerated() {
            #expect(line.count == width, "row \(index)")
            if (top ... bottom).contains(index) {
                #expect(String(line.prefix(left)) == String(base[index].prefix(left)), "row \(index)")
                #expect(String(line.dropFirst(right)) == String(base[index].dropFirst(right)), "row \(index)")
            } else {
                #expect(line == base[index], "row \(index)")
            }
        }
        if width >= 120 {
            #expect(lines[top].prefix(left).contains("26."))
        }
    }

    @Test(arguments: [(80, 24), (120, 40), (180, 50)], [false, true])
    func `the install setup covers only its box`(size: (Int, Int), usesColors: Bool) throws {
        var overlaid = model
        _ = overlaid.handle(.character("i"))
        try assertOverlayKeepsSurroundings(overlaid, width: size.0, height: size.1, usesColors: usesColors)
    }

    @Test(arguments: [(80, 24), (120, 40), (180, 50)])
    func `a dialog covers only its box`(size: (Int, Int)) throws {
        var overlaid = model
        overlaid.dialog = TUIDialog(.confirm(prompt: "Move Xcode 16.0 to the Trash?"))
        try assertOverlayKeepsSurroundings(overlaid, width: size.0, height: size.1, usesColors: true)
    }

    @Test(arguments: [
        ("abcdef", 2, "ab", "cdef"),
        ("a界b", 2, "a ", " b"),
        ("\u{1B}[7mabcd\u{1B}[0m", 2, "\u{1B}[7mab\u{1B}[0m\u{1B}[0m", "\u{1B}[7mcd\u{1B}[0m"),
    ])
    func `styled text is split by terminal columns`(text: String, column: Int, before: String, from: String) {
        #expect(text.columns(before: column) == before)
        #expect(text.columns(from: column) == from)
    }
}

struct TUIDetailTests {
    @Test(arguments: [40, 60, 100])
    func `long links wrap after a slash and keep the file name visible`(width: Int) throws {
        let url = "https://download.developer.apple.com/Developer_Tools/Xcode_27.3_beta/Xcode_27.3_beta_Apple_silicon.xip"
        let xcode = Xcode.fixture("27.3", build: "27C5020n", download: url)
        let lines = TUIRenderer(usesColors: false).detailLines(TUIEntry(kind: .available, xcode: xcode), width: width)
        let start = try #require(lines.firstIndex(of: "  Download:"))
        let wrapped = lines[(start + 1)...].prefix { $0.hasPrefix("    ") }

        #expect(wrapped.allSatisfy { $0.count <= width })
        #expect(wrapped.map { $0.trimmingCharacters(in: .whitespaces) }.joined() == url)
        #expect(wrapped.last?.hasSuffix("Xcode_27.3_beta_Apple_silicon.xip") == true)
    }
}
