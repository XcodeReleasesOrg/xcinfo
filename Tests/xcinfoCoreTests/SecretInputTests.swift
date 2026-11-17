import Testing
import XCIFoundation

struct SecretInputTests {
    private func outcome(of bytes: [UInt8]) -> SecretInput.Outcome? {
        var input = SecretInput()
        for byte in bytes {
            if let outcome = input.handle(byte) {
                return outcome
            }
        }
        return nil
    }

    @Test(arguments: [
        (Array("secret\r".utf8), SecretInput.Outcome?.some(.entered("secret"))),
        (Array("secret\n".utf8), .entered("secret")),
        (Array("se".utf8) + [0x03], .interrupted),
        ([0x03], .interrupted),
        ([0x04], .ended),
        (Array("ab".utf8) + [0x04] + Array("c\r".utf8), .entered("abc")),
        (Array("secrex".utf8) + [0x7F] + Array("t\r".utf8), .entered("secret")),
        (Array("Grüß".utf8) + [0x7F, 0x7F] + Array("ün\r".utf8), .entered("Grün")),
        (Array("wrong".utf8) + [0x15] + Array("right\r".utf8), .entered("right")),
        (Array("pa".utf8) + Array("\u{1B}[D\u{1B}OA\u{1B}[3~".utf8) + Array("ss\r".utf8), .entered("pass")),
        (Array("pass".utf8), nil),
    ] as [([UInt8], SecretInput.Outcome?)])
    func `ctrl-c interrupts and editing keys change the secret`(bytes: [UInt8], expected: SecretInput.Outcome?) {
        #expect(outcome(of: bytes) == expected)
    }
}
