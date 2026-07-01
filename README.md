# update-all-mac

One-command macOS updater for Homebrew formulae and casks, Mac App Store apps, global npm packages, Oh My Zsh, pipx packages, uv tools, Rust/cargo, mise, asdf, gcloud components, and optional macOS update checks.

The recommended installation path is Homebrew. It avoids the common macOS Gatekeeper friction that happens when unsigned `.command` files are downloaded through a browser and opened from Finder.

## What It Updates

- Homebrew formulae and casks
- Global npm packages
- Mac App Store apps through [`mas`](https://github.com/mas-cli/mas)
- Oh My Zsh
- pipx packages and shared pipx libraries
- uv tools and, when possible, uv itself
- Rust toolchains (`rustup`) and globally installed crates (`cargo install-update`)
- mise-managed tools (`mise upgrade`)
- asdf plugins (`asdf plugin update --all`)
- Google Cloud CLI components (`gcloud components update`)
- Optional macOS update check through `softwareupdate -l`

Every step self-detects its tool and is skipped when the tool is absent, so the same
command works on any Mac. The script does not install package managers for you, except
that `--install-homebrew` will bootstrap Homebrew on a fresh Mac when you opt in.

## Requirements

- macOS
- Bash available at `/bin/bash` (included with macOS)
- Optional tools depending on what you want to update: `brew`, `npm`, `mas`, `git`, `python3`/`pip3`, `pipx`, `uv`, `rustup`/`cargo`, `mise`, `asdf`, and `gcloud`

## Install

Recommended Homebrew install:

```bash
brew tap mzored/update-all-mac https://github.com/mzored/update-all-mac
brew install update-all-mac
```

Then run:

```bash
update-all-mac
```

Alternative install from Git:

```bash
git clone https://github.com/mzored/update-all-mac.git
cd update-all-mac
chmod +x update-all-mac.command
./update-all-mac.command
```

Alternative direct script download:

```bash
curl -fsSL -o update-all-mac.command https://raw.githubusercontent.com/mzored/update-all-mac/main/update-all-mac.command
chmod +x update-all-mac.command
./update-all-mac.command
```

Avoid piping the network directly into a shell. Download the file first, review it, then run it.

## Migrating From the Old Tap

Earlier versions used a separate Homebrew tap repository. If you installed with the old tap, move to the single-repository tap:

```bash
brew uninstall update-all-mac
brew untap mzored/tap
brew tap mzored/update-all-mac https://github.com/mzored/update-all-mac
brew install update-all-mac
```

The source code and Homebrew formula now live in this repository.

## macOS Gatekeeper and Browser Downloads

If you use GitHub's **Download ZIP** button or download `update-all-mac.command` through a browser, macOS may attach a quarantine marker. Because this project ships a shell script rather than a signed and notarized macOS app, double-clicking the downloaded `.command` file in Finder can show a Gatekeeper warning.

Use Homebrew, `git clone`, or the Terminal `curl -o` flow above when possible. If you intentionally downloaded the script through a browser, review it first and then remove the quarantine marker:

```bash
xattr -d com.apple.quarantine update-all-mac.command
```

After that, run it from Terminal:

```bash
./update-all-mac.command
```

## Usage

Run all default update steps:

```bash
update-all-mac
```

If you installed from Git or downloaded the script directly, use:

```bash
./update-all-mac.command
```

Show help:

```bash
update-all-mac --help
```

List step IDs:

```bash
update-all-mac --list-steps
```

Report which tools are detected on this Mac (and their versions):

```bash
update-all-mac --doctor
```

Preview what would be updated without changing anything:

```bash
update-all-mac --dry-run
```

Bootstrap a fresh Mac by installing Homebrew if it is missing:

```bash
update-all-mac --install-homebrew
```

Run only selected steps:

```bash
update-all-mac --only homebrew,mas
```

Skip selected steps:

```bash
update-all-mac --skip npm,pip
```

Check macOS updates too:

```bash
update-all-mac --macos
```

Useful non-interactive run:

```bash
UPDATE_ALL_NO_PAUSE=1 update-all-mac --no-color
```

## Options

```text
--only <id1,id2>       Run only selected steps
--skip <id1,id2>       Skip selected steps
--fail-fast            Stop after first failure
--strict               Exit non-zero on warnings as well as failures
--exit-zero            Always exit 0
--no-color             Disable ANSI colors in stdout
--macos                Add macOS updates check step (softwareupdate -l)
--greedy-casks         Include Homebrew casks marked auto_updates/latest
--force-cask-repair    Allow forced cask uninstall+install fallback
--mas-accurate         Use slower, more accurate mas outdated detection
--parallel             Run npm, pipx, and Mac App Store steps concurrently
--dry-run              Show what would be updated without changing anything
--install-homebrew     Install Homebrew if it is missing (bootstrap a Mac)
--log-file <path>      Override log file path
--lock-dir <path>      Override lock directory path
--list-steps           Print available step IDs and exit
--doctor               Report detected tools/versions and exit
-h, --help             Show help and exit
```

The `--parallel` flag runs the independent npm, pipx, and Mac App Store steps at the
same time as the heavier Homebrew step, which can shorten total run time. Homebrew, pip,
and uv always run sequentially because they share state. With `--parallel`, the npm, pipx,
and Mac App Store blocks are printed together after the sequential steps so the log stays
readable, and `--fail-fast` only stops the sequential steps.

Step IDs:

```text
homebrew   Homebrew
npm        npm
mas        Mac App Store
ohmyzsh    Oh My Zsh
pip        pip
pipx       pipx
uv         uv
rust       Rust (rustup + cargo)
mise       mise
asdf       asdf
gcloud     gcloud
macos      macOS (only when --macos is used)
```

`--dry-run` runs each step's read-only detection and prints what it *would* update,
without refreshing the Homebrew catalog or changing anything. `--doctor` prints the
tools detected on the current Mac and their versions, then exits. `--install-homebrew`
installs Homebrew non-interactively when it is missing (opt-in bootstrap for a new Mac).

## Environment Variables

Every CLI option has an environment-friendly path for automation:

```text
UPDATE_ALL_ONLY=homebrew,mas
UPDATE_ALL_SKIP=npm,pip
UPDATE_ALL_EXIT_ZERO=1
UPDATE_ALL_STRICT=1
UPDATE_ALL_FAIL_FAST=1
UPDATE_ALL_NO_COLOR=1
UPDATE_ALL_MACOS=1
UPDATE_ALL_HOMEBREW_GREEDY_CASKS=1
UPDATE_ALL_FORCE_CASK_REPAIR=1
UPDATE_ALL_PIPX_INCLUDE_INJECTED=0
UPDATE_ALL_MAS_ACCURATE=1
UPDATE_ALL_PARALLEL=1
UPDATE_ALL_DRY_RUN=1
UPDATE_ALL_INSTALL_HOMEBREW=1
UPDATE_ALL_LOG_FILE=/path/to/update-all-mac.log
UPDATE_ALL_LOG_MAX_BYTES=1048576
UPDATE_ALL_NET_TIMEOUT=600
UPDATE_ALL_LOCK_DIR=/tmp/update-all-mac.lock
UPDATE_ALL_NO_PAUSE=1
```

`UPDATE_ALL_NET_TIMEOUT` caps how long the npm step may run (in seconds) when `gtimeout`
or `timeout` is available, so a stuck download cannot hang the whole run.

## Logs and Locking

By default, logs are written to:

```text
~/Library/Logs/update-all-mac.log
```

Each step's full command output is captured in the log, so a failed upgrade can be
diagnosed after the fact. When the log grows past `UPDATE_ALL_LOG_MAX_BYTES` (1 MiB by
default), it is rotated once to `update-all-mac.log.1` before the next run starts.

A lock directory prevents concurrent runs:

```text
/tmp/update-all-mac.lock
```

If a previous run crashed, the script detects stale locks and removes them when safe.

## Safety Notes

- Review scripts before running them from the internet.
- Some updates can close, replace, or relaunch apps. The script warns when Homebrew cask apps appear to be running.
- `--force-cask-repair` can uninstall and reinstall a cask as a recovery fallback. Use it only when you understand the risk.
- The macOS step checks for system updates but does not install them.
- A signed and notarized `.app` or `.pkg` would be required for the cleanest double-click Finder experience. This repository currently distributes a CLI script.

## Troubleshooting

If double-clicking does nothing, run from Terminal to see output:

```bash
./update-all-mac.command --no-color
```

If macOS blocks a browser-downloaded script, review the file and remove quarantine:

```bash
xattr -d com.apple.quarantine update-all-mac.command
```

If `mas` cannot see updates, make sure App Store apps are indexed by Spotlight and that you are signed in to the App Store.

## License

MIT. See [LICENSE](LICENSE).
