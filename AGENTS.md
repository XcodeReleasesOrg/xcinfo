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
- `@preconcurrency import`, `@unchecked Sendable` and `nonisolated(unsafe)` only where a dependency truly forces it, with a one-line comment at that place saying why. Current sites: `Rainbow` (global color switch, wrapped once in `Logger.isANSIEnabled`), `XCModel` (unannotated value types) and `UserDefaults` in `OlympUs` (thread-safe, not annotated)
- Don't fix a diagnostic with `-strict-concurrency=minimal`, `swiftLanguageModes: [.v5]` or by wrapping work in an unstructured `Task` to hop isolation

## Terminal I/O

- `xcinfoCore` never prints. It reports typed `OutputEvent`s (section, message with a style, verbose, check, progress) through the `logger` dependency and asks through the `prompt` dependency (`PromptClient`, backed by the in-house `ConsolePrompt`). No `print`, `readLine`, `getpass` or ANSI styling in `Core`, `OlympUs` or the clients
- Queries (`list`, `installed`, `info`) return data; the CLI renders it as text (`Presentation.swift`) or JSON
- `TerminalRenderer` (XCIFoundation) owns the terminal: stdout for status and results, stderr for warnings and errors, colors only on a terminal without `NO_COLOR`, one updating progress line on a terminal and 10 % milestones when piped, `--quiet` and `--json`
- Every failure maps to an exit code in `Error.exitCode`; keep the table in the README and in `xcinfo --help` in sync

## Behaviour that must not change

- CLI subcommands, flags and their defaults (deprecated flags stay as aliases)
- The text output of `list` and `installed` when piped
- Keychain service names `xcinfo.appleid` and `xcinfo.session`, the `cookies` user defaults key, and the cache file `~/Library/Caches/xcinfo/xcinfo.json`
- The Apple sign-in sequence in `OlympUs`

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
