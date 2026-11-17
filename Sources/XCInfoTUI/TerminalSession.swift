//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Darwin
import Foundation

struct TerminalSize: Sendable, Equatable {
    var width: Int
    var height: Int
}

final class TerminalSession {
    private var originalAttributes = termios()
    private var isActive = false

    static var isInteractive: Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }

    func enter() {
        guard !isActive else { return }
        tcgetattr(STDIN_FILENO, &originalAttributes)
        var raw = originalAttributes
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[H\u{1B}[2J")
        isActive = true
    }

    func leave() {
        guard isActive else { return }
        write("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalAttributes)
        isActive = false
    }

    deinit {
        leave()
    }

    var size: TerminalSize {
        var window = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0, window.ws_col > 0, window.ws_row > 0 else {
            return TerminalSize(width: 80, height: 24)
        }
        return TerminalSize(width: Int(window.ws_col), height: Int(window.ws_row))
    }

    func draw(_ lines: [String]) {
        var frame = "\u{1B}[H"
        for (index, line) in lines.enumerated() {
            frame += line + "\u{1B}[0m\u{1B}[K"
            if index < lines.count - 1 {
                frame += "\r\n"
            }
        }
        write(frame)
    }

    func readKeys(timeout: Duration) -> [Key] {
        guard waitForInput(timeout: timeout) else { return [] }
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        guard count > 0 else { return [] }
        var bytes = Array(buffer[0 ..< count])
        if bytes == [0x1B], waitForInput(timeout: .milliseconds(30)) {
            let more = read(STDIN_FILENO, &buffer, buffer.count)
            if more > 0 {
                bytes += buffer[0 ..< more]
            }
        }
        return Key.parse(bytes)
    }

    private func waitForInput(timeout: Duration) -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        return poll(&descriptor, 1, milliseconds) > 0
    }

    private func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
