//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation
import XCIFoundation
import xcinfoCore
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has only immutable value types but no Sendable annotations.

public struct TUIRenderer: Sendable {
    public var usesColors: Bool

    public init(usesColors: Bool) {
        self.usesColors = usesColors
    }

    public static let minimumWidth = 40
    public static let minimumHeight = 8

    public func render(_ model: TUIModel, width: Int, height: Int) -> [String] {
        guard width >= Self.minimumWidth, height >= Self.minimumHeight else {
            let message = String("Terminal too small. Enlarge the window or press q to quit.".prefix(max(0, width)))
            return [message.padded(to: width)] + Array(repeating: String(repeating: " ", count: max(0, width)), count: max(0, height - 1))
        }

        let bodyHeight = height - 3
        let listWidth = width >= 90 ? max(32, width * 2 / 5) : width
        let detailWidth = width - listWidth - 3

        let rows = listRows(model)
        let selectedRow = rows.firstIndex { $0.entryIndex == model.selection } ?? 0
        let offset = min(max(0, selectedRow - bodyHeight / 2), max(0, rows.count - bodyHeight))
        let visibleRows = Array(rows.dropFirst(offset).prefix(bodyHeight))

        let details = detailWidth > 0 ? detailLines(model.selectedEntry) : []

        var lines = [style(" xcinfo — Xcode versions".padded(to: width), .title)]
        for index in 0 ..< bodyHeight {
            let row = visibleRows.indices.contains(index) ? visibleRows[index] : nil
            var line = row.map { render($0, selected: $0.entryIndex == model.selection, width: listWidth) } ?? String(repeating: " ", count: listWidth)
            if detailWidth > 0 {
                let detail = details.indices.contains(index) ? details[index] : ""
                line += " │ " + detail.truncated(to: detailWidth).padded(to: detailWidth)
            }
            lines.append(line)
        }
        lines.append((model.status ?? "").truncated(to: width).padded(to: width))
        lines.append(style(help(for: model.selectedEntry).truncated(to: width).padded(to: width), .dim))
        if let dialog = model.dialog {
            overlay(box(dialog, width: width), on: &lines, height: height)
        }
        return lines
    }

    func box(_ dialog: TUIDialog, width: Int) -> [String] {
        let content = [dialog.prompt, ""] + dialog.lines
        let innerWidth = max(20, min(width - 6, (content.map(\.count).max() ?? 0) + 2))
        let border = String(repeating: "─", count: innerWidth)
        return ["┌" + border + "┐"]
            + content.map { "│ " + $0.truncated(to: innerWidth - 2).padded(to: innerWidth - 2) + " │" }
            + ["└" + border + "┘"]
    }

    private func overlay(_ box: [String], on lines: inout [String], height: Int) {
        guard let boxWidth = box.first?.count, let width = lines.first.map({ $0.unstyledWidth }) else { return }
        let top = max(1, (height - box.count) / 2)
        let left = max(0, (width - boxWidth) / 2)
        for (offset, row) in box.enumerated() where lines.indices.contains(top + offset) {
            let text = String(repeating: " ", count: left) + row
            lines[top + offset] = style(text.padded(to: width), .dialog)
        }
    }

    struct Row: Equatable {
        var text: String
        var entryIndex: Int?
    }

    func listRows(_ model: TUIModel) -> [Row] {
        var rows: [Row] = []
        var entryIndex = 0
        for section in model.sections {
            rows.append(Row(text: "\(section.title) (\(section.entries.count))", entryIndex: nil))
            for entry in section.entries {
                rows.append(Row(text: entry.xcode.displayName, entryIndex: entryIndex))
                entryIndex += 1
            }
        }
        if rows.isEmpty {
            rows.append(Row(text: "No Xcode versions found.", entryIndex: nil))
        }
        return rows
    }

    private func render(_ row: Row, selected: Bool, width: Int) -> String {
        guard row.entryIndex != nil else {
            return style(row.text.truncated(to: width).padded(to: width), .heading)
        }
        let text = ((selected ? "› " : "  ") + row.text).truncated(to: width).padded(to: width)
        return selected ? style(text, .selected) : text
    }

    func detailLines(_ entry: TUIEntry?) -> [String] {
        guard let entry else { return [] }
        let xcode = entry.xcode
        var lines = [xcode.displayName, ""]
        let releaseDate = xcode.releaseDate.formatted(Date.FormatStyle().year().month(.wide).day().locale(Locale(identifier: "en_US_POSIX")))
        lines.append("Released:  \(releaseDate)")
        lines.append("Requires:  macOS \(xcode.requires)")
        switch entry.kind {
        case let .installed(url):
            lines.append("Installed: \(url.path)")
        case .available:
            lines.append("Status:    available")
        case .notInstallable:
            lines.append("Status:    not installable on this Mac")
        }
        if let sdks = xcode.sdks?.keyed(), !sdks.isEmpty {
            lines += ["", "SDKs"]
            lines += sdks.keys.sorted().map { "  \($0): \(sdks[$0]?.first?.build ?? "")" }
        }
        if let compilers = xcode.compilers?.keyed(), !compilers.isEmpty {
            lines += ["", "Compilers"]
            lines += compilers.keys.sorted().map { "  \($0) \(compilers[$0]?.first?.number ?? ""): \(compilers[$0]?.first?.build ?? "")" }
        }
        let links = [("Download", xcode.links?.download?.url), ("Release notes", xcode.links?.notes?.url)]
            .compactMap { label, url in url.map { "  \(label): \($0.absoluteString)" } }
        if !links.isEmpty {
            lines += ["", "Links"] + links
        }
        return lines
    }

    func help(for entry: TUIEntry?) -> String {
        var actions = ["↑↓ move"]
        switch entry?.kind {
        case .available:
            actions += ["i install", "d download"]
        case .installed:
            actions += ["d download", "u uninstall"]
        case .notInstallable, .none:
            break
        }
        actions += ["r refresh", "q quit"]
        return " " + actions.joined(separator: "   ")
    }

    private enum Style {
        case title
        case heading
        case selected
        case dim
        case dialog
    }

    private func style(_ text: String, _ style: Style) -> String {
        guard usesColors else { return text }
        let code = switch style {
        case .title:
            "1;36"
        case .heading:
            "1"
        case .selected:
            "7"
        case .dim:
            "2"
        case .dialog:
            "1"
        }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }
}

extension String {
    var unstyledWidth: Int {
        replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count
    }

    func truncated(to width: Int) -> String {
        guard count > width else { return self }
        guard width > 1 else { return String(prefix(max(0, width))) }
        return String(prefix(width - 1)) + "…"
    }

    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
