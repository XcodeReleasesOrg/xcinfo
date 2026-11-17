//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Darwin
import Foundation

public struct SecretInput: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case entered(String)
        case interrupted
        case ended
    }

    public private(set) var bytes: [UInt8] = []
    private var isInEscapeSequence = false

    public init() {}

    public mutating func handle(_ byte: UInt8) -> Outcome? {
        if isInEscapeSequence {
            isInEscapeSequence = !(0x40 ... 0x7e)
                .contains(byte) || byte == UInt8(ascii: "[") || byte == UInt8(ascii: "O")
            return nil
        }
        switch byte {
        case 0x03:
            return .interrupted
        case 0x04:
            return bytes.isEmpty ? .ended : nil
        case 0x0d, 0x0a:
            return .entered(String(decoding: bytes, as: UTF8.self))
        case 0x7f, 0x08:
            while let last = bytes.popLast(), last & 0xc0 == 0x80 {}
        case 0x15:
            bytes.removeAll()
        case 0x1b:
            isInEscapeSequence = true
        case 0x20...:
            bytes.append(byte)
        default:
            break
        }
        return nil
    }
}

extension SecretInput {
    static func readFromTerminal(prompt: String) -> String? {
        let terminal = open("/dev/tty", O_RDWR)
        guard terminal >= 0 else { return nil }
        defer { close(terminal) }
        write(terminal, prompt + " ")

        var original = termios()
        tcgetattr(terminal, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        tcsetattr(terminal, TCSAFLUSH, &raw)

        var input = SecretInput()
        var outcome: Outcome?
        var byte: UInt8 = 0
        while outcome == nil {
            guard read(terminal, &byte, 1) == 1 else {
                outcome = .ended
                break
            }
            outcome = input.handle(byte)
        }

        tcsetattr(terminal, TCSAFLUSH, &original)
        write(terminal, "\n")
        switch outcome {
        case let .entered(secret):
            return secret
        case .interrupted:
            raise(SIGINT)
            return nil
        case .ended, nil:
            return nil
        }
    }

    private static func write(_ terminal: Int32, _ text: String) {
        let data = Array(text.utf8)
        _ = data.withUnsafeBytes { Darwin.write(terminal, $0.baseAddress, $0.count) }
    }
}
