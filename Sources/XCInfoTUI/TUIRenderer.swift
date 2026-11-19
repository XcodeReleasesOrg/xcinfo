//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import Foundation
import XCIFoundation
import xcinfoCore
@preconcurrency import XCModel // XCModel (Swift 5 mode, pinned) has immutable value types without Sendable annotations.

// annotations.

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
            return [message.padded(to: width)] + Array(
                repeating: String(repeating: " ", count: max(0, width)),
                count: max(0, height - 1)
            )
        }

        let bodyHeight = height - 3
        if let activity = model.activity {
            var lines = [style(" xcinfo — Xcode versions".padded(to: width), .title)]
            let listWidth = width >= 90 ? max(28, width / 3) : 0
            let panelWidth = listWidth > 0 ? width - listWidth - 1 : width
            let panel = activityPanel(activity, width: panelWidth, height: bodyHeight)
            if listWidth > 0 {
                let rows = listRows(model)
                let selectedRow = rows.firstIndex { $0.entryIndex == model.selection } ?? 0
                let offset = min(max(0, selectedRow - bodyHeight / 2), max(0, rows.count - bodyHeight))
                let visibleRows = Array(rows.dropFirst(offset).prefix(bodyHeight))
                for index in 0 ..< bodyHeight {
                    let row = visibleRows.indices.contains(index) ? visibleRows[index] : nil
                    let marker = row?.entryIndex == model.selection && row?.entryIndex != nil ? "› " : "  "
                    let text = row.map { $0.entryIndex == nil ? $0.text : marker + $0.text } ?? ""
                    lines.append(style(text.truncated(to: listWidth).padded(to: listWidth), .dim) + " " + panel[index])
                }
            } else {
                lines += panel
            }
            lines.append((model.status ?? "").truncated(to: width).padded(to: width))
            lines.append(style(activityHelp(activity).truncated(to: width).padded(to: width), .dim))
            if let dialog = model.dialog {
                overlay(box(dialog, width: width), on: &lines, height: height)
            }
            return lines
        }
        let listWidth = width >= 90 ? max(32, width * 2 / 5) : width
        let detailWidth = width - listWidth - 3

        let rows = listRows(model)
        let selectedRow = rows.firstIndex { $0.entryIndex == model.selection } ?? 0
        let offset = min(max(0, selectedRow - bodyHeight / 2), max(0, rows.count - bodyHeight))
        let visibleRows = Array(rows.dropFirst(offset).prefix(bodyHeight))

        let details = detailWidth > 0 ? detailLines(model.selectedEntry, width: detailWidth) : []

        var lines = [style(" xcinfo — Xcode versions".padded(to: width), .title)]
        for index in 0 ..< bodyHeight {
            let row = visibleRows.indices.contains(index) ? visibleRows[index] : nil
            var line = row.map { render($0, selected: $0.entryIndex == model.selection, width: listWidth) } ?? String(
                repeating: " ",
                count: listWidth
            )
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
        } else if let setup = model.installSetup {
            overlay(
                box(setup.lines(fieldWidth: max(10, min(56, width - 18))), width: width),
                on: &lines,
                height: height
            )
        }
        return lines
    }

    func activityPanel(_ activity: TUIActivity, width: Int, height: Int) -> [String] {
        let inner = max(10, width - 4)
        var progressContent: [(String, Style)] = []
        if let progress = activity.progress {
            let barWidth = max(6, min(40, inner - 22))
            let display = ProgressDisplay(ratio: progress.fraction, width: barWidth)
            progressContent = [("", .plain), ("\(progress.title) \(display.representation.unstyled)", .plain)]
            if let detail = progress.detail {
                progressContent.append((detail, .dim))
            }
        }
        var content: [(String, Style)] = if activity.steps.count + progressContent.count <= max(0, height - 2) {
            activity.steps.map { step in
                let (symbol, style): (String, Style) = switch step.state {
                case .pending: ("·", .dim)
                case .running: ("▸", .plain)
                case .done: ("✓", .success)
                case .failed: ("✗", .error)
                }
                return ("\(symbol) \(step.name)", style)
            }
        } else if let current = activity.steps.firstIndex(where: { $0.state == .running || $0.state == .failed }) {
            [("▸ \(activity.steps[current].name) (\(current + 1) of \(activity.steps.count))", .plain)]
        } else {
            []
        }
        content += progressContent
        let fixed = content.count + 1
        let logHeight = max(0, height - 2 - fixed)
        let log = Array(activity.lines.flatMap { line -> [(String, Style)] in
            let text = prefix(for: line.kind) + line.text
            guard line.kind != .detail else { return [(text, style(for: line.kind))] }
            return text.wrapped(to: inner, indent: prefix(for: line.kind).count).map { ($0, style(for: line.kind)) }
        }.suffix(logHeight))
        if !log.isEmpty {
            content.append(("", .plain))
            content += log
        }
        let title = " \(activity.title) "
        let top = "┌" + title.truncated(to: inner + 2) + String(
            repeating: "─",
            count: max(0, inner + 2 - title.truncated(to: inner + 2).count)
        ) + "┐"
        var lines = [top]
        for index in 0 ..< max(0, height - 2) {
            let (text, textStyle) = content.indices.contains(index) ? content[index] : ("", .plain)
            lines.append("│ " + style(text.truncated(to: inner).padded(to: inner), textStyle) + " │")
        }
        lines.append("└" + String(repeating: "─", count: inner + 2) + "┘")
        return lines.map { line in
            line.unstyledWidth < width ? line + String(repeating: " ", count: width - line.unstyledWidth) : line
        }
    }

    func activityHelp(_ activity: TUIActivity) -> String {
        switch activity.state {
        case .running:
            " Esc or Ctrl-C to stop"
        case .stopping:
            " Stopping…"
        case .finished:
            " Return to go back to the list"
        }
    }

    private func prefix(for kind: TUIActivity.Line.Kind) -> String {
        switch kind {
        case .section: ""
        case .plain, .detail: "  "
        case .success: "  "
        case .warning: "  ⚠ "
        case .error: "  ✗ "
        case .check(.running): "  … "
        case .check(.passed): "  ✓ "
        case .check(.failed): "  ✗ "
        }
    }

    private func style(for kind: TUIActivity.Line.Kind) -> Style {
        switch kind {
        case .section: .heading
        case .plain, .check(.running), .check(.passed): .plain
        case .detail: .dim
        case .success: .success
        case .warning: .warning
        case .error, .check(.failed): .error
        }
    }

    func box(_ dialog: TUIDialog, width: Int) -> [String] {
        box([dialog.prompt, ""] + dialog.lines(fieldWidth: max(10, min(56, width - 10))), width: width)
    }

    func box(_ content: [String], width: Int) -> [String] {
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
            let base = lines[top + offset]
            lines[top + offset] = base.columns(before: left) + style(row, .dialog) + base.columns(from: left + boxWidth)
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
                rows.append(Row(text: entry.title, entryIndex: entryIndex))
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

    func detailLines(_ entry: TUIEntry?, width: Int = .max) -> [String] {
        guard let entry else { return [] }
        let xcode = entry.xcode
        var lines = [entry.title, ""]
        let releaseDate = xcode.releaseDate
            .formatted(Date.FormatStyle().year().month(.wide).day().locale(Locale(identifier: "en_US_POSIX")))
        lines.append("Released:  \(releaseDate)")
        lines.append("Requires:  macOS \(xcode.requires)")
        switch entry.kind {
        case let .installed(url):
            lines += "Installed: \(url.path)".pathWrapped(to: width, indent: 11)
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
            lines += compilers.keys.sorted()
                .map { "  \($0) \(compilers[$0]?.first?.number ?? ""): \(compilers[$0]?.first?.build ?? "")" }
        }
        let links = [("Download", xcode.links?.download?.url), ("Release notes", xcode.links?.notes?.url)]
            .compactMap { label, url in
                url.map { url in
                    let inline = "  \(label): \(url.absoluteString)"
                    return inline.count <= width ? [inline] : ["  \(label):"] + "    \(url.absoluteString)".pathWrapped(
                        to: width,
                        indent: 4
                    )
                }
            }
            .flatMap(\.self)
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
            actions += ["s switch", "d download", "u uninstall"]
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
        case plain
        case success
        case warning
        case error
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
        case .plain:
            "0"
        case .success:
            "32"
        case .warning:
            "33"
        case .error:
            "31"
        }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }
}

extension String {
    func pathWrapped(to width: Int, indent: Int) -> [String] {
        guard count > width, width > indent + 8 else { return [self] }
        var lines: [String] = []
        var rest = Substring(self)
        while rest.count > width {
            let limit = rest.index(rest.startIndex, offsetBy: width)
            let minimum = rest.index(rest.startIndex, offsetBy: indent + 1)
            let end = rest[minimum ..< limit].lastIndex(of: "/").map { rest.index(after: $0) } ?? limit
            lines.append(String(rest[..<end]))
            rest = Substring(String(repeating: " ", count: indent)) + rest[end...]
        }
        return lines + [String(rest)]
    }

    func wrapped(to width: Int, indent: Int) -> [String] {
        guard count > width, width > indent + 4 else { return [self] }
        var lines: [String] = []
        var current = ""
        for word in split(separator: " ", omittingEmptySubsequences: false) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count <= width {
                current = candidate
                continue
            }
            if !current.isEmpty {
                lines.append(current)
            }
            var rest = String(repeating: " ", count: indent) + word
            while rest.count > width {
                lines.append(String(rest.prefix(width)))
                rest = String(repeating: " ", count: indent) + rest.dropFirst(width)
            }
            current = rest
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    var unstyledWidth: Int {
        unstyled.count
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
