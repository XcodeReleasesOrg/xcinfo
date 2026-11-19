//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import Darwin
import Foundation

struct TerminalSize: Sendable, Equatable {
    var width: Int
    var height: Int
}

protocol TerminalControl: AnyObject {
    func enter()
    func leave()
    func enterRawMode()
    func leaveRawMode()
    func discardInput()
    var modeDescription: String { get }
}

final class TerminalSession: TerminalControl {
    private var originalAttributes = termios()
    private var isActive = false
    private var isRaw = false

    var isPasteBracketed = false {
        didSet {
            guard isPasteBracketed != oldValue else { return }
            write(isPasteBracketed ? "\u{1B}[?2004h" : "\u{1B}[?2004l")
        }
    }

    static var isInteractive: Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }

    func enter() {
        guard !isActive else { return }
        tcgetattr(STDIN_FILENO, &originalAttributes)
        enterRawMode()
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[H\u{1B}[2J")
        isActive = true
    }

    func leave() {
        guard isActive else { return }
        isPasteBracketed = false
        write("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
        leaveRawMode()
        isActive = false
    }

    func enterRawMode() {
        var raw = originalAttributes
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true
    }

    func leaveRawMode() {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalAttributes)
        isRaw = false
    }

    func discardInput() {
        tcflush(STDIN_FILENO, TCIFLUSH)
    }

    var modeDescription: String {
        var mask = sigset_t()
        pthread_sigmask(SIG_SETMASK, nil, &mask)
        let blocked = (1 ..< 32).filter { sigismember(&mask, Int32($0)) == 1 }
        return "terminal \(isRaw ? "raw" : "cooked"), \(isActive ? "alternate screen" : "normal screen"), "
            + "main thread \(Thread.isMainThread ? "yes" : "no"), blocked signals \(blocked.isEmpty ? "none" : blocked.map(String.init).joined(separator: ","))"
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

    private func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}

struct TerminalInput: Sendable {
    func readKeys(timeout: Duration) -> [Key] {
        guard waitForInput(timeout: timeout) else { return [] }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var bytes: [UInt8] = []
        repeat {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            guard count > 0 else { break }
            bytes += buffer[0 ..< count]
        } while Key.isIncomplete(bytes) && waitForInput(timeout: .milliseconds(30))
        return Key.parse(bytes)
    }

    private func waitForInput(timeout: Duration) -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(timeout.components.seconds * 1_000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        return poll(&descriptor, 1, milliseconds) > 0
    }
}
