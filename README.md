# xcinfo

With `xcinfo` you can access all information available at xcodereleases.com and install available Xcode versions from Apple's Developer Portal. It also finds and lists installed Xcode applications on hard drive and you can remove them safely.

![Screenhot of the install progress](https://github.com/xcodereleases/xcinfo/blob/master/Assets/install.png?raw=true)

```
USAGE: xcinfo <subcommand>

OPTIONS:
  --version               Show the version.
  -h, --help              Show help information.

SUBCOMMANDS:
  info                    Xcode version info
  list                    List all available Xcode versions
  install                 Install an Xcode version
  installed               Show installed Xcode versions
  uninstall               Uninstall an Xcode version
  cleanup                 Remove stored credentials
```

## Requirements
- macOS 13 (Ventura)
- Swift 6.4 (to build from source)

## Installation

### Manually
```
$ git clone https://github.com/xcodereleases/xcinfo.git
$ cd xcinfo
$ make
$ sudo make install
```

### Make
- Build a universal (`arm64` and `x86_64`) xcinfo: `make`
- Install xcinfo (default to `/usr/local/bin`): `sudo make install` or to other local: `sudo make install prefix=/opt/local`
- Clean build caches: `make clean`
- Cleanup all caches: `make cleanup`

### Mint
```
$ mint install xcodereleases/xcinfo
```

### homebrew
```
$ brew install xcinfo
```

## Usage

### info (default)
- show detailed information about a version of Xcode

### list
- list all available Xcode versions ever released by Apple

### install
- download and install a version of Xcode

### installed
- list Xcode versions installed in /Applications

### uninstall
- removes an installed version of Xcode from /Applications

### cleanup
- Deletes the Keychain item `xcinfo` (the stored Apple ID and the Apple session) and the Apple cookies left by older versions; the next download signs in again, with two-factor authentication
- Keeps downloaded archives, saved download progress and the cached list of Xcode versions

### tui

`xcinfo tui`, or plain `xcinfo` in an interactive terminal, opens a full-screen view of all Xcode versions, grouped into installed, available and not installable, with the SDKs, compilers and links of the selected version.

| Key | Action |
|---|---|
| ↑ ↓, j k, Page Up/Down, Home/End | Move |
| i | Install the selected version: first asks for the folder (default /Applications) and whether to point /Applications/Xcode.app to it and select it with xcode-select |
| d | Download the selected version |
| u | Uninstall the selected version |
| r | Refresh the list |
| q, Esc, Ctrl-C | Quit |

Install, download and uninstall run inside the full-screen view. Questions open as dialogs: the Apple ID, the Apple ID password, two-factor codes, the Mac administrator password for sudo, and confirmations. Password fields show only dots. The activity view shows each step, progress bars and warnings; Esc or Ctrl-C stops the running action (a download keeps its progress and resumes next time). Press Return afterwards to go back to the list.

### Signing in to Apple

`download` and `install` sign in to the Apple Developer Portal with SRP, like Xcode does, so the password is never sent.

- xcinfo keeps one Keychain item named `xcinfo` with your Apple ID account name and the Apple session. It never stores your password: it asks for it only when Apple needs a new sign-in.
- Of Apple's cookies, the session keeps only those needed to reuse it, authorize downloads and skip two-factor authentication on this Mac (`myacinfo`, `DES…`, `DSESSIONID`, `dqsid`, `itctx`, `itcdq`, `acn01`, `aasp`) and drops expired ones. `ADCDownloadAuth` is requested fresh before every download and kept only in memory, so an unchanged session is not written to the Keychain again. `-v` lists which cookies were kept and dropped, and why.
- Apple's cookies are held in memory during a run and saved only in that Keychain item. Older versions also left them in `~/Library/HTTPStorages/xcinfo.binarycookies`; xcinfo removes the Apple cookies from that file on its next sign-in or `cleanup`.
- The prompts name the password they want: `Apple ID password for <account> (not your Mac password):` for the sign-in, `Mac administrator password for <user> (sudo):` when `install` needs administrator rights. Two-factor codes come from a trusted Apple device, or by text message after typing `sms`.
- If Apple rejects the password, xcinfo stops and does not retry. Repeated failed sign-ins can lock your Apple ID.
- The item is read once per run. macOS asks you to allow access when the item was created by a different build of xcinfo. Builds signed with the same identity keep that approval: `make CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" install`.
- `swift run` builds an ad-hoc signed binary with a new code identity on every build, so macOS asks again before it reads the Keychain item. During development, sign the binary with a stable identity and run it directly (`swift build && codesign -f -s "Apple Development: Your Name (TEAMID)" .build/debug/xcinfo && .build/debug/xcinfo …`), or install it with `make CODESIGN_IDENTITY=… install`.
- For unattended use, set `XCINFO_APPLE_ID` and `XCINFO_APPLE_PASSWORD`. Without a terminal and without these variables, xcinfo fails with exit code 4 instead of waiting for input.
- Older versions kept the password in the Keychain items `xcinfo.appleid`, `xcinfo.session` and `xcinfo.cookies`. The first run moves the account name and session into the new item and deletes the old ones, the password included.
- `xcinfo cleanup` removes everything xcinfo stored.

### Output

- Progress and status go to standard output, warnings and errors to standard error.
- Colors are used only when the output is a terminal. They are off when `NO_COLOR` is set, when `TERM` is `dumb`, or with `--no-ansi`.
- Progress updates a single line on a terminal. When the output is piped, it prints a plain line every 10 %.
- `-q`, `--quiet` shows only results, warnings and errors.
- `--json` prints the result of the command as JSON on standard output, without progress or status. Errors are printed as `{"error": "...", "code": n}` on standard error.
- `download` and `install` keep the Mac awake with `--prevent-sleep`. `--no-sleep` still works but is deprecated.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Unexpected error |
| 3 | Version not found |
| 4 | Sign-in failed |
| 5 | Download failed |
| 6 | Extraction failed |
| 7 | Installation failed |
| 8 | Uninstallation failed |
| 9 | xcodereleases.com or the cached list is unavailable |
| 64 | Invalid arguments |
| 130 | Stopped with Ctrl-C (143 for `SIGTERM`) |

### Archive formats

Xcode comes as `.xip` and, from Xcode 27.3, also as Apple Encrypted Archive (`.aea`). xcinfo recognizes the format by the file's contents, not its name; `extract`, `install --archive-path` and downloads accept both.

- A signed `.aea` is opened with the AppleArchive framework, after its embedded certificate chain is checked against Apple Root CA - G3 and the "Apple Platform Signing ECC CA 1 - G1" intermediate. A chain or signature that does not check out stops the extraction; nothing is extracted.
- Other `.aea` profiles are extracted with Apple's `archiveutil extractXcodeAEA`, available from macOS 15.
- xcodereleases.com lists SHA-1 checksums for `.xip` archives only. An `.aea` is not compared with them; its signature is checked instead.
- `install --archive-path <file>` needs no version: xcinfo reads the build from the extracted app and looks it up on xcodereleases.com. A version given as well is used, with a warning if the archive contains another build.
- Downloads take the format from Apple's download list: the `.xip` when Apple offers both, the `.aea` when that is all there is. `--archive-format xip|aea` forces one; if Apple does not offer it, the command stops and says what is offered. Without a list, a missing `.xip` (HTTP 404) is retried as the `.aea` at the same path, and the output says that this address was derived.
- If the archive is already in the download folder, xcinfo checks it first (SHA-1 for a `.xip`, Apple signature for an `.aea`) and uses it instead of downloading again. A file it cannot confirm is never replaced silently: on a terminal xcinfo asks, otherwise it stops; `--overwrite` moves the old file to the Trash and downloads anew.
- `.xip` archives are always extracted with the built-in unxip. `--use-system-unxip` is still accepted but only prints that it is no longer needed.
- `--archive-path` and `--preserve-archive` replace `--xip-path` and `--preserve-xip`, which still work.
- `-v` during a download lists which Xcode archives Apple offers and which of them as `.aea`.

After a download, and before installing from `--archive-path`, xcinfo checks the archive's SHA-1 against xcodereleases.com when the list has one ("Verifying"). A mismatch after a download fails with exit code 5 and keeps the file; for an `--archive-path` archive it warns and asks whether to install anyway. `--no-verify` skips the check.

`uninstall` asks with the full path of the Xcode it is about to remove and moves it to the Trash. `--delete-permanently` deletes it right away; if the Trash can't be used, `uninstall` stops and suggests that flag.

`install` names the app after the version (`Xcode_27.3_beta_2.app`, or `…-2.app` when that name is taken in the installation folder) and extracts on the same volume as the installation folder.

Stopping a download with Ctrl-C saves its progress in `~/Library/Caches/xcinfo/<file>.resume`. The next `download` or `install` of the same version signs in, then resumes where it stopped; if the saved progress can't be used, it starts over. Press Ctrl-C a second time to quit immediately without saving.

## CI
- no-ansi flag to suppress colored output
- verbose flag

## Screenshots

![Show info for a specific Xcode version](https://github.com/xcodereleases/xcinfo/blob/master/Assets/inf.png?raw=true)

![Installed and available Xcode versions](https://github.com/xcodereleases/xcinfo/blob/master/Assets/list.png?raw=true)

## TODO
- sudo support without storing user password in memory
- man page
- tests
- include default data (when github is offline)

## Changelog

### Version 0.6.0
Adds:
- resuming of aborted downloads (Thanks @chippo)

### Version 0.5.1
Fixes:
-  version string 

### Version 0.5.0

Initial public release
