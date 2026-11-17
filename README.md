# xcinfo

With `xcinfo` you can access all information available at xcodereleases.com and download and install Xcode from Apple's Developer Portal. It also finds the Xcode applications installed on this Mac, switches between them and removes them safely.

```
USAGE: xcinfo <subcommand>

SUBCOMMANDS:
  cleanup                 Remove the stored Apple ID and Apple session
  download                Downloads an Xcode version
  extract                 Extract an Xcode archive (.xip or .aea)
  info                    Xcode version info
  install                 Install an Xcode version
  installed               Show installed Xcode versions
  list                    List all available Xcode versions
  switch                  Switch to another installed Xcode
  tui                     Browse, install and uninstall Xcode versions in a
                          full-screen terminal UI
  uninstall               Uninstall an Xcode version
```

`xcinfo help <subcommand>` shows every option of a subcommand. Plain `xcinfo` opens the terminal UI in an interactive terminal and prints the help otherwise.

## Requirements

- macOS 13 (Ventura) or later
- Swift 6.4 to build from source
- `.aea` archives that are not signed-only need macOS 15 (see [Archives](#archives))

## Installation

### From source

```
$ git clone https://github.com/xcodereleases/xcinfo.git
$ cd xcinfo
$ make
$ sudo make install
```

- `make` builds a universal (`arm64` and `x86_64`) release binary and signs it ad hoc. `make CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"` signs it with your identity instead, so macOS remembers the Keychain approval across builds (see [Signing in to Apple](#signing-in-to-apple)).
- `sudo make install` copies the binary to `/usr/local/bin`; `sudo make install prefix=/opt/local` to another prefix. It installs what `make` built and does not build or sign itself.
- `make clean` cleans the build; `make cleanup` also removes `.build`.

To run without installing, use `swift run -c release xcinfo …`. Plain `swift run xcinfo …` is a debug build: it works, but extracting an Xcode takes noticeably longer.

### Homebrew and Mint

`brew install xcinfo` and `mint install xcodereleases/xcinfo` install the 1.x releases. Use the source build for the version described here until 2.0 is released.

## Usage

### list

Lists the Xcode versions from xcodereleases.com: by default the versions released in the last year that can be installed on this Mac, then the installed ones and the ones this Mac cannot run.

- `-a`, `--all` lists every version ever released
- `--only-releases` lists only versions marked as final releases; `--only-gm` only versions marked GM, which xcodereleases.com no longer uses for new releases, so it finds only older versions
- `--no-update-list` uses the cached list (`~/Library/Caches/xcinfo/xcinfo.json`) instead of loading it again from xcodereleases.com (`--update-list`, the default); every command that looks up versions accepts it

### info

`xcinfo info 26.6` shows the release date, the required macOS, the SDKs, the compilers and the links of a version.

### installed

Lists the Xcode applications Spotlight finds on this Mac, with their paths.

### download

`xcinfo download 26.6` downloads the archive to `~/Downloads` (`-d`, `--download-directory` for another folder). It signs in to Apple first (see [Signing in to Apple](#signing-in-to-apple)).

### install

`xcinfo install 26.6` downloads, verifies and extracts Xcode, then sets it up:

1. Checks the archive's SHA-1 (see [Archives](#archives))
2. Extracts it into `/Applications` (`-i`, `--installation-directory` for another folder), on the same volume as that folder, as `Xcode_26.6.app` (`Xcode_26.6-2.app` when the name is taken)
3. Checks the app with Gatekeeper (`spctl`) and `codesign`
4. With administrator rights (`sudo`): enables developer mode, accepts the license, installs the additional components
5. Points `/Applications/Xcode.app` to the new Xcode (`--no-symlink` skips this) and selects it with `xcode-select` (`--no-xcode-select` skips this)
6. Shows the new Xcode in the Finder

A downloaded archive is deleted after the extraction; `--preserve-archive` keeps it. An archive given with `--archive-path` is always kept. `--archive-path <file>` installs from an archive you already have, with or without a version.

If the setup after the extraction does not finish, xcinfo says where the extracted Xcode is, so you can move it to the Trash or open it once to finish the setup.

### extract

`xcinfo extract <archive>` only extracts a `.xip` or `.aea` into `/Applications` (`-i` for another folder), without download, checks or setup.

### switch

`xcinfo switch 16.0` points `/Applications/Xcode.app` to another installed Xcode and selects it with `xcode-select`, which asks for the Mac administrator password. It takes a version, a build number (`xcinfo switch 16A242d`) or `latest`; without one, or with several matching copies, it asks. It runs `xcode-select` first and changes the link only after that worked, so a refused or cancelled password changes nothing. `--no-symlink` and `--no-xcode-select` skip either change.

### uninstall

`xcinfo uninstall 26.6` asks with the full path of the Xcode it is about to remove and moves it to the Trash. `--delete-permanently` deletes it right away; if the Trash can't be used, `uninstall` stops and suggests that flag. Without a version it asks which installed Xcode to remove.

### cleanup

Deletes the Keychain item `xcinfo` (the stored Apple ID and the Apple session) and the Apple cookies left by older versions; the next download signs in again, with two-factor authentication. Downloaded archives, saved download progress and the cached list of Xcode versions are kept.

### tui

`xcinfo tui`, or plain `xcinfo` in an interactive terminal, opens a full-screen view of all Xcode versions, grouped into installed, available and not installable, with the release date, SDKs, compilers and links of the selected version next to the list.

| Key | Action |
|---|---|
| ↑ ↓, j k | Move |
| Page Up, Page Down | Move a page |
| Home, End, g, G | First or last version |
| i | Install the selected version |
| d | Download the selected version |
| u | Uninstall the selected installed version |
| s | Switch to the selected installed version |
| r | Reload the list |
| q, Esc, Ctrl-C | Quit |

- `i` first asks for the folder (default `/Applications`) and whether to point `/Applications/Xcode.app` to the new Xcode and select it with `xcode-select`. Tab moves between the fields, Space toggles, Return starts, Esc cancels.
- Install, download, uninstall and switch run inside the full-screen view. A panel next to the list shows each step, the progress and the latest output lines. Esc or Ctrl-C stops the running action; a stopped download resumes next time. Return goes back to the list afterwards.
- Questions open as dialogs over the view: the Apple ID, the Apple ID password, two-factor codes, the Mac administrator password, choices and confirmations. Password fields show only dots and are not kept after Return.
- Text fields edit like a shell prompt: ← → move, Option-← → or Option-B/F move by word, Home/End or Ctrl-A/E jump to the start or end, Option-Backspace or Ctrl-W delete a word (a `/` ends a word), Ctrl-U deletes to the start, Ctrl-K to the end, Delete or Ctrl-D the next character. Pasting works, and line breaks in pasted text are dropped.
- macOS does not show its Keychain dialog while the view owns the terminal, so xcinfo reads its Keychain item when an action first needs it and gives the terminal back for that moment.

## Choosing a version

Commands take a version number, a build number or `latest`:

- `26.6` is the final release 26.6, not 26.6 RC 2. xcinfo says which version it took and how to ask for the others: `Using Xcode 26.6 (17F113), the final release. Use '26.6 RC 2' for a release candidate.`
- `26` is the newest final release of Xcode 26.
- Release candidates and betas are chosen by name (`26.6 RC 2`, `26.6 rc2`, `27.0 beta 3`) or by build number (`17F109`). A version without a final release yet means its newest pre-release.
- `latest` is the newest entry on xcodereleases.com, betas included.
- If a request still matches several versions (`27 beta`), xcinfo asks.

Some versions come as two downloads, one for Apple silicon only and one Universal (Apple silicon and Intel). `list`, `info` and the terminal UI label them `· Apple silicon` and `· Universal`. `download` and `install` take the Apple silicon one on an Apple silicon Mac and the Universal one on an Intel Mac, and say so; `--apple-silicon` or `--universal` chooses. `info` asks which one to show.

## Archives

Xcode comes as `.xip` and, from Xcode 27.3, also as Apple Encrypted Archive (`.aea`). xcinfo recognizes the format by the file's contents, not its name; `download`, `install`, `install --archive-path` and `extract` accept both.

- A signed `.aea` is opened with the AppleArchive framework, after its embedded certificate chain is checked against Apple Root CA - G3 and the "Apple Platform Signing ECC CA 1 - G1" intermediate. A chain or signature that does not check out stops the extraction; nothing is extracted.
- Other `.aea` profiles are extracted with Apple's `archiveutil extractXcodeAEA`, available from macOS 15. On older macOS they stop with exit code 6.
- `.xip` archives are extracted with the built-in unxip.
- Downloads take the format from Apple's download list: the `.xip` when Apple offers both, the `.aea` when that is all there is. `--archive-format xip|aea` forces one; if Apple does not offer it, the command stops and says what is offered. Without a list, a missing `.xip` (HTTP 404) is retried as the `.aea` at the same path, and the output says that this address was derived. `-v` lists which archives Apple offers.
- After a download, and before installing from `--archive-path`, xcinfo checks the archive's SHA-1 against xcodereleases.com when the list has one. A mismatch after a download fails with exit code 5 and keeps the file; for an `--archive-path` archive it warns and asks whether to install anyway. `--no-verify` skips the check. xcodereleases.com lists SHA-1 checksums for `.xip` archives only; an `.aea` is checked by its signature instead.
- If the archive is already in the download folder, xcinfo checks it first (SHA-1 for a `.xip`, Apple signature for an `.aea`) and uses it instead of downloading again. A file it cannot confirm is never replaced silently: on a terminal xcinfo asks, otherwise it stops; `--overwrite` moves the old file to the Trash and downloads anew.
- `install --archive-path <file>` needs no version: xcinfo reads the build from the extracted app and looks it up on xcodereleases.com. A version given as well is used, with a warning if the archive contains another build.

Stopping a download with Ctrl-C saves its progress in `~/Library/Caches/xcinfo/<file>.resume`. The next `download` or `install` of the same version signs in again and resumes where it stopped; if the saved progress can't be used, it starts over. Press Ctrl-C a second time to quit immediately without saving.

## Signing in to Apple

`download` and `install` sign in to the Apple Developer Portal with SRP, like Xcode does, so the password never leaves the Mac. Two-factor codes come from a trusted Apple device, or by text message after typing `sms`.

- xcinfo keeps one Keychain item named `xcinfo` with your Apple ID account name and the Apple session. It never stores your password: it asks for it only when Apple needs a new sign-in.
- The item is read at most once per run and written only when the session changed. macOS asks you to allow access when the item was created by a differently signed build of xcinfo. Builds signed with the same identity keep that approval: `make CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"`, then `sudo make install`.
- `swift run` builds an ad-hoc signed binary with a new code identity on every build, so macOS asks again before it reads the Keychain item. During development, sign the binary with a stable identity and run it directly: `swift build && codesign -f -s "Apple Development: Your Name (TEAMID)" .build/debug/xcinfo && .build/debug/xcinfo …`.
- The prompts name the password they want: `Apple ID password for <account> (not your Mac password):` for the sign-in, `Mac administrator password for <user> (sudo):` when `install` or `switch` need administrator rights.
- Passwords are read from the terminal without echo. Ctrl-C at a password prompt restores the terminal and stops xcinfo; Return or Ctrl-D on an empty line gives an empty password, which is not accepted.
- If Apple rejects the password, xcinfo stops and does not retry. Repeated failed sign-ins can lock your Apple ID.
- Of Apple's cookies, the session keeps only those needed to reuse it, authorize downloads and skip two-factor authentication on this Mac (`myacinfo`, `DES…`, `DSESSIONID`, `dqsid`, `itctx`, `itcdq`, `acn01`, `aasp`) and drops expired ones. `ADCDownloadAuth` is requested fresh before every download and kept only in memory. Apple's cookies are held in memory during a run and saved only in the Keychain item.
- `xcinfo download <version> -v` logs each sign-in request with its HTTP status and Apple's error codes, without secrets, and which cookies were kept and why.
- `xcinfo cleanup` removes everything xcinfo stored.

## Unattended use

- Set `XCINFO_APPLE_ID` and `XCINFO_APPLE_PASSWORD` for the sign-in. The password is only used when Apple needs a new sign-in.
- `--non-interactive` never asks. Where xcinfo would ask a question, it fails with exit code 10 and prints the question and its choices, so you can give the answer up front: an exact version or build number, `--apple-silicon` or `--universal`, `--overwrite`, `--no-verify`.
- Without a terminal on standard input, a choice between versions and a missing Apple ID or password fail with exit code 10; yes/no questions read their answer from standard input and fail with exit code 10 when it ends. With `--json`, choices fail the same way, so the output stays valid JSON.
- Running as root, the administrator steps of `install` and `switch` run directly, without `sudo` and without asking for a password.
- `--prevent-sleep` keeps the Mac awake during a download. `--no-sleep` still works but is deprecated, and `--sleep` lets the Mac sleep.

## Output

- Progress and status go to standard output; questions, warnings and errors to standard error.
- Colors are used only when the output is a terminal. They are off when `NO_COLOR` is set, when `TERM` is `dumb`, or with `--no-ansi` (`--ansi` is the default).
- Progress updates a single line on a terminal. When the output is piped, it prints a plain line every 10 %.
- `-q`, `--quiet` shows only results, warnings and errors. `-v`, `--verbose` shows more details.
- `--json` prints the result as JSON on standard output, without progress or status. Errors are printed as JSON on standard error:

```
$ xcinfo installed --json
[
  {
    "build" : "27C5035i",
    "path" : "/Applications/Xcode_27.3_beta_2.app",
    "version" : "27.3 Beta 2",
    "xcode" : { … the entry from xcodereleases.com … }
  }
]
$ xcinfo info 99 --json
{
  "code" : 3,
  "error" : "No Xcode found for given version '99'."
}
```

Versions with two downloads have an extra `"architecture"` field (`"appleSilicon"` or `"universal"`) next to the entry's keys.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Unexpected error |
| 3 | Version not found |
| 4 | Sign-in failed |
| 5 | Download failed, or the archive's checksum does not match |
| 6 | Extraction failed |
| 7 | Installation failed |
| 8 | Uninstallation failed |
| 9 | xcodereleases.com or the cached list is unavailable |
| 10 | An answer was needed but could not be asked: with `--non-interactive`, without a terminal, after the input ended, or a choice with `--json` |
| 64 | Invalid arguments |
| 130 | Stopped with Ctrl-C (143 for `SIGTERM`); a paused download resumes on the next run |

## Migrating from 1.x

- `--xip-path` and `--preserve-xip` are now `--archive-path` and `--preserve-archive`; the old names still work.
- `--use-system-unxip` is still accepted but does nothing: `.xip` archives are always extracted with the built-in unxip.
- `--no-sleep` is now `--prevent-sleep`; the old flag still works.
- The Keychain items `xcinfo.appleid`, `xcinfo.session` and `xcinfo.cookies` are moved into the single item `xcinfo` on the first run and deleted, the stored password included. Apple cookies in `~/Library/HTTPStorages/xcinfo.binarycookies` are removed on the next sign-in or `cleanup`.
- `uninstall` moves Xcode to the Trash instead of deleting it; `--delete-permanently` deletes it.
- A version without a qualifier means the final release, and `download` and `install` choose the Apple silicon or Universal download themselves. 1.x asked in both cases.
- Failures have their own exit codes instead of 1.
- New: `download`, `extract`, `switch`, `tui`, `.aea` archives, SHA-1 checks, `--json`, `--quiet`, `--non-interactive`.

## Known limits

- Signing in has been checked by hand against Apple's service with SRP (`s2k`), two-factor codes from a trusted device and session reuse. Not yet checked live: the `s2k_fo` password protocol, two-factor codes by text message, and accounts without two-factor authentication.
- The `archiveutil` fallback for `.aea` archives that are not signed-only, and `install --archive-path` with an `.aea`, have not been checked with real archives yet.
- `installed` and the terminal UI can't tell whether an installed Xcode came from the Apple silicon or the Universal download, so installed versions are not labelled.

## License

xcinfo is licensed under the GNU Lesser General Public License 3.0 ([COPYING.LESSER](COPYING.LESSER)), which builds on the GNU General Public License 3.0 ([COPYING](COPYING)).

## Changelog

### Version 2.0.0

- Terminal UI with install, download, uninstall and switch inside the full-screen view
- `download`, `extract` and `switch` commands
- `.aea` archives, SHA-1 checks, reuse of existing downloads, resume after Ctrl-C
- Sign-in with SRP; one Keychain item without the password
- `--json`, `--quiet`, `--non-interactive`, exit codes
- Final releases preferred over release candidates and betas; Apple silicon and Universal downloads labelled and chosen for this Mac
- `uninstall` moves to the Trash

### Version 0.6.0
Adds:
- resuming of aborted downloads (Thanks @chippo)

### Version 0.5.1
Fixes:
-  version string 

### Version 0.5.0

Initial public release
