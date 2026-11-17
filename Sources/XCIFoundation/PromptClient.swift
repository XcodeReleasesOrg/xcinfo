//
//  Copyright © 2026 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Darwin
import Prompt

public struct PromptClient {
    public var ask: (_ message: String, _ invalidMessage: String, _ isInvalid: @escaping (String) -> Bool) -> String
    public var choose: (_ message: String, _ choices: [String]) -> Int
    public var agree: (_ message: String) -> Bool
    public var readSecret: (_ prompt: String) -> String

    public init(
        ask: @escaping (String, String, @escaping (String) -> Bool) -> String,
        choose: @escaping (String, [String]) -> Int,
        agree: @escaping (String) -> Bool,
        readSecret: @escaping (String) -> String
    ) {
        self.ask = ask
        self.choose = choose
        self.agree = agree
        self.readSecret = readSecret
    }
}

public extension PromptClient {
    static let live = PromptClient(
        ask: { message, invalidMessage, isInvalid in
            Prompt.ask(message, type: String.self) { settings in
                settings.addInvalidCase(invalidMessage, invalidIfTrue: isInvalid)
            }
        },
        choose: { message, choices in
            Prompt.choose(message, type: Int.self) { settings in
                for (index, choice) in choices.enumerated() {
                    settings.addChoice(choice) { index }
                }
            }
        },
        agree: { message in
            Prompt.agree(message)
        },
        readSecret: { prompt in
            String(cString: getpass("\(prompt) "))
        }
    )
}
