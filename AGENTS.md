# xcinfo — Agent Instructions

`xcinfo` is a command line tool for macOS that lists Xcode releases from xcodereleases.com, shows details about a version, downloads and installs Xcode from Apple's Developer Portal, and lists or removes installed Xcode applications.

## Architecture

- SwiftPM package only, no Xcode project. Swift 6 language mode with full strict concurrency, deployment target **macOS 13**
- Targets:
  - `xcinfo`: the executable. `ArgumentParser` commands in `Sources/xcinfo/SubCommands`, one file per subcommand. Commands parse options, set the logger with `withDependencies` and call `Core`. No logic beyond that
  - `xcinfoCore`: all behaviour. `Core` is the entry point; every side effect goes through a client in `Dependencies.swift`, read with `@Dependency`
  - `OlympUs`: Apple ID sign-in and developer portal session (an `actor`)
  - `XCIFoundation`: `Logger`, Keychain access and small extensions
  - `XCUnxip`: Objective-C header for the private `PKSignedContainer` (legacy extraction via `--use-system-unxip`)
- Dependency injection uses swift-dependencies (no TCA). One client per concern (`xcodeReleases`, `credentials`, `authentication`, `downloads`, `extraction`, `processes`, `fileSystem`, `keychain`, `workspace`, `logger`, `prompt`), declared with `@DependencyClient` and `DependencyKey` (`liveValue` and an unimplemented `testValue`). Use the built-in `\.continuousClock` and `\.date` for time
- Dependencies come through SPM only. In `Package.swift`, list `dependencies` alphabetically by URL and give every Swift target `swiftSettings` (warnings are errors)
- `XCModel` (`xcodereleases/data`) is pinned to a revision because the model moved to another repository; updating it is a separate change, not a drive-by bump

## Concurrency

- Async work is `async`/`await`. No Combine, no completion-handler chains, no `DispatchQueue`, locks, semaphores or `Timer`s in our code. Progress from callback APIs (URL session delegates, `PKSignedContainer`) is bridged with `AsyncStream` and consumed in a `for await` loop; mutable progress state lives in that loop, never in a captured `var`
- Shared mutable state lives in an `actor`. Everything else is a value type or a `final class` with only `let` properties
- Values that cross actors are `Sendable`, and closures stored in clients are `@Sendable`
- No global or static `var`s. Use `static let` or put the state in an actor
- `@preconcurrency import`, `@unchecked Sendable` and `nonisolated(unsafe)` only where a dependency truly forces it, with a one-line comment at that place saying why. Current sites: `Rainbow` (global color switch, wrapped once in `Logger.isANSIEnabled`) and `XCModel` (unannotated value types)
- Don't fix a diagnostic with `-strict-concurrency=minimal`, `swiftLanguageModes: [.v5]` or by wrapping work in an unstructured `Task` to hop isolation

## Terminal I/O

- `xcinfoCore` never prints. It reports typed `OutputEvent`s (section, message with a style, verbose, check, progress) through the `logger` dependency and asks through the `prompt` dependency (`PromptClient`, backed by the in-house `ConsolePrompt`). No `print`, `readLine`, `getpass` or ANSI styling in `Core`, `OlympUs` or the clients
- Queries (`list`, `installed`, `info`) return data; the CLI renders it as text (`Presentation.swift`) or JSON
- `TerminalRenderer` (XCIFoundation) owns the terminal: stdout for status and results, stderr for warnings and errors, colors only on a terminal without `NO_COLOR`, one updating progress line on a terminal and 10 % milestones when piped, `--quiet` and `--json`
- Ctrl-C (or `SIGTERM`) during a download goes through `InterruptSignals` (XCIFoundation: `sigaction` plus a self-pipe read as an async sequence): it cancels the download task, the downloader saves the resume data, and the command exits with 128 + signal. After the first signal the default action is restored, so a second Ctrl-C quits at once. Cached resume data is checked (`ResumeData`) before URLSession sees it, because URLSession raises an exception for invalid data
- Archive formats are detected by content (`ArchiveFormat`: `xar!` for .xip, `AEA1` for .aea), never by extension. Signed-only .aea (profile `hkdf_sha256_hmac__none__ecdsa_p256`) is extracted with AppleArchive after `AEASigningTrust` validates the embedded chain with SecTrust: root pinned by SHA-256 (Apple Root CA - G3), intermediate "Apple Platform Signing ECC CA 1 - G1". A failed trust or signature check fails closed and never falls back to `archiveutil`; other profiles use `archiveutil extractXcodeAEA` (macOS 15+), otherwise exit 6. Test fixtures in `Tests/xcinfoCoreTests/Fixtures/AEA` come from `make-fixtures.sh` with a throwaway chain; never commit Apple's leaf certificate or real archives
- Not yet verified with a real Xcode .aea: extraction through AppleArchive (only checked read-only: the chain validates with SecTrust, and `aa list` with the leaf key lists `Xcode-beta.app`), progress over a 2 GB file, and the archiveutil fallback
- Archives are checked against `checksums.sha1` from xcodereleases.com with `ArchiveChecksum`, which streams the file in chunks. A mismatch after a download is `CoreError.checksumMismatch` (exit 5, file kept); for `--xip-path` it is a warning and a confirmation. `--no-verify` skips the check
- `uninstall` moves the app to the Trash through `fileSystem.trashItem` and asks with the full path; `--delete-permanently` uses `fileSystem.removeItem`. Never delete an Xcode without that confirmation
- Verified by hand on 2026-11-17: `install --xip-path … --installation-directory <folder> --no-symlink --no-xcode-select` (SHA-1 check, extraction, Gatekeeper, codesign, the sudo steps) and `uninstall` choosing that copy and moving it to the Trash
- Every failure maps to an exit code in `Error.exitCode`; keep the table in the README and in `xcinfo --help` in sync

## Behaviour that must not change

- CLI subcommands, flags and their defaults (deprecated flags stay as aliases)
- The text output of `list` and `installed` when piped
- The cache file `~/Library/Caches/xcinfo/xcinfo.json`
- One Keychain item, service and account `xcinfo`, holding a versioned `VaultContents` (account name, sessions per account). It is read at most once per run through `KeychainVault` and written at most once per run, after the download authorization succeeded. The old items `xcinfo.appleid`, `xcinfo.session`, `xcinfo.cookies` and the `cookies` user defaults key are migrated once and deleted
- The Apple ID password is never stored, logged or sent: it comes from `XCINFO_APPLE_PASSWORD` or a prompt, only when a new sign-in is needed, and goes only into the SRP computation

## Terminal UI

- `XCInfoTUI` is a small in-house full-screen UI (no third-party TUI library). `TUIModel` holds the groups and the selection and turns keys into `TUICommand`s; `TUIRenderer` draws a model into exactly `height` lines of `width` characters, so rendering is tested as plain strings; `TerminalSession` owns raw mode, the alternate screen and key polling
- Resizes are picked up by checking the size on every tick, not with a signal handler. Every exit path, Ctrl-C included, restores the terminal
- Actions that need typed input (sign-in, two-factor codes, the administrator password) leave the full-screen view and run the normal CLI flow, then return

## Apple sign-in

- `OlympUs` signs in with SRP-6a (`signin/init`, `signin/complete`, RFC 5054 2048-bit group, SHA-256, PBKDF2 for `s2k` / `s2k_fo`) and sends a hashcash stamp in `X-Apple-HC`. The password never leaves the machine
- The SRP and big-integer code is checked against the RFC 5054 test vectors and a fake server in the tests. Verified against Apple's live service on 2026-11-17: SRP with `s2k`, two-factor authentication with a trusted-device code, trust, session, download authorization, the start of a download, and reusing the session stored in the `xcinfo` Keychain item on the next run, also with the reduced cookie set and the in-memory cookie store, without a Keychain write when nothing changed, and pausing a download with Ctrl-C and resuming it on the next run. Not yet verified live: `s2k_fo`, SMS codes, and accounts without two-factor authentication. Treat every change to the protocol as unverified until someone signs in by hand
- Every password prompt names which password it wants: `Apple ID password for <account> (not your Mac password):` and `Mac administrator password for <user> (sudo):`, each after one line saying why it is needed. A rejected Apple ID password (`-20101`) ends the run without a retry
- Cookies live in the in-memory `HTTPCookieStorage.xcinfo`, shared by the sign-in and download sessions, never in `HTTPCookieStorage.shared` (persisted to a plain file). The session is written to the Keychain only when its headers or kept cookie values changed
- The stored session keeps only the cookies in `HTTPCookie.sessionCookieNames` plus the `DES…` trust cookie, on `apple.com` domains and not expired. `ADCDownloadAuth` is never stored: Apple renews it on every download authorization, which runs before every download and every resumed download. Removing a name from that list can break session reuse; check it with two runs of `xcinfo download <version> -v`, the second must log "Reusing valid session."
- `xcinfo download <version> -v` logs each sign-in request with its HTTP status and Apple's error codes, without secrets; use it when a sign-in fails
- Never sign in to Apple from tests or automation, and never read a developer's stored credentials: repeated attempts can lock the account

## Swift syntax

- Don't add explanatory comments; names and tests carry the meaning. The exception is the one-line justification at a concurrency escape hatch
- In `switch` statements, use `case let` pattern binding, not `let` inside the case
- In computed properties, use switch expressions (trailing expression, no `return`)
- No new namespaces of static functions (`enum` or `struct` that only groups static helpers). Put logic in extensions, initializers or computed properties on the type that owns the data
- Prefer `FormatStyle` over `Formatter` subclasses and `Duration` over `Double` seconds in new code. Existing formatters stay as they are unless the output is meant to change
- Format with SwiftFormat using the repository's `.swiftformat`

## Testing

- Use **Swift Testing**, not XCTest: `@Test` with backtick sentence-style names, `#expect` / `#require`, parameterized tests with `arguments:` for tables
- Override dependencies with `withDependencies`; every dependency a test does not set stays unimplemented and fails the test when it is called (`Core.test(...)` in the test support does this for `Core`)
- HTTP goes through `StubServer` / `StubURLProtocol`; files go into a `TemporaryDirectory`
- Tests never touch the network, the real Keychain, `sudo` or `/Applications`
- A known bug gets a test for the correct behaviour wrapped in `withKnownIssue` with a one-line reason; a test that would crash or hang the process is `.disabled` with the reason

## Build & verify

- `swift build` and `swift test` for the inner loop
- `make` builds the universal release binary (`swift build -c release --arch arm64 --arch x86_64`); `make install` copies it from `--show-bin-path`
- A change is finished when `swift build`, `make` and `swift test` pass with zero warnings in our targets
- Safe smoke tests: `swift run xcinfo list`, `swift run xcinfo installed`, `swift run xcinfo info latest`. They only read xcodereleases.com and Spotlight
- Never run `install`, `download`, `uninstall` or `cleanup`, and never sign in to Apple, as part of automated verification: they need credentials, `sudo`, or delete data
- Use `DEVELOPER_DIR` to pick another Xcode, never `sudo xcode-select`

## Git

- Never commit to `master` directly; work on a branch. Don't push or open a pull request unless asked
- Commit in small, focused steps, each with a passing build and test suite. Never commit with failing tests or new warnings
- No AI attribution in commit messages: no `Co-Authored-By` or similar trailers
- Don't name other projects in commit messages, code or file headers
- Commit messages: concise, single line when possible, **third person**, describing what the commit does (`Adds …`, `Updates …`, `Replaces …`), not what the developer did (`Add …`)
