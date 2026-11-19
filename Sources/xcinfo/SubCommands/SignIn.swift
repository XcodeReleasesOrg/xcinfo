//
//  Copyright © 2026 xcodereleases.com
//  LGPL-3.0 license - see COPYING.LESSER
//

import ArgumentParser
import XCIFoundation
import xcinfoCore

extension XCInfo {
    struct SignIn: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "signin",
            abstract: "Sign in to Apple and store the Apple ID and session",
            discussion: """
            Signs in to the Apple Developer Portal, with two-factor authentication when Apple asks for it, and \
            stores the Apple ID and the Apple session in the Keychain item 'xcinfo'. Later download and install \
            runs reuse the session without asking for the password until Apple ends it, so a build machine can be \
            signed in once by hand and then run unattended. The password itself is never stored. If the stored \
            session is still valid, nothing is asked. Without an Apple ID argument, xcinfo takes the stored one, \
            XCINFO_APPLE_ID, or asks.
            """,
            aliases: ["login"]
        )

        @Argument(help: "The Apple ID (email) to sign in with.")
        var appleID: String?

        @OptionGroup
        var globals: DefaultOptions

        mutating func validate() throws {
            appleID = appleID?.trimmingCharacters(in: .whitespaces)
            if appleID?.isEmpty == true {
                throw ValidationError("The Apple ID is empty.")
            }
        }

        func run() async throws {
            try await globals.run { core, output in
                let accountName = try await core.signIn(appleID: appleID)
                if output.options.isJSON {
                    try output.printJSON(["appleID": accountName])
                }
            }
        }
    }
}
