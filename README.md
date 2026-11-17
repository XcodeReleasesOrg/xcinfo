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
- if something goes wrong this removes all entries stored in the keychain, all cookies, and user defaults

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

After a download, and before installing from `--xip-path`, xcinfo checks the archive's SHA-1 against xcodereleases.com when the list has one ("Verifying"). A mismatch after a download fails with exit code 5 and keeps the file; for a `--xip-path` archive it warns and asks whether to install anyway. `--no-verify` skips the check.

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
