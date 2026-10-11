# update-all-mac

Update macOS apps and developer tools with one command. The script runs the package
managers already installed on your Mac and skips the rest.

Current version: 3.4.2

## Install

Requires macOS and its built-in Bash. Homebrew is the simplest way to install and
avoids Gatekeeper warnings for browser downloads.

```bash
brew tap mzored/update-all-mac https://github.com/mzored/update-all-mac
brew install update-all-mac
```

## Run

```bash
update-all-mac
```

| Command | What it does |
| --- | --- |
| `update-all-mac --dry-run` | Preview updates without changing packages. |
| `update-all-mac --only homebrew,mas` | Update Homebrew packages and App Store apps. |
| `update-all-mac --skip npm,pip` | Run all default steps except npm and pip. |
| `update-all-mac --doctor` | Show detected tools and their versions. |
| `update-all-mac --verbose` | Show full command output. |
| `update-all-mac --help` | List all options and step IDs. |

Progress appears in the terminal. Full output goes to
`~/Library/Logs/update-all-mac.log`.

## What it updates

- Homebrew formulae and casks, except pinned packages.
- Mac App Store apps through [mas](https://github.com/mas-cli/mas).
- Global npm packages, pipx packages and uv tools.
- Oh My Zsh, Rust toolchains and installed crates, mise tools, asdf plugins and
  Google Cloud CLI components.

The `pip` step reports the installed version. It does not upgrade Python packages.
Rust crate updates require `cargo install-update`.

The default cleanup removes old Homebrew versions and unused cache entries.
`--deep-clean` also purges reinstall caches. Use `--macos` to check for macOS
updates. The script does not install system updates.

## Before you run it

Updates can close or relaunch apps. Save your work first. Homebrew may request an
administrator password through a macOS dialog.

Package managers must already be installed. `--install-homebrew` is the opt-in
exception. Forced cask removal requires `--force-cask-repair`.

## Documentation

- [Reference](docs/reference.md) for options, step IDs, automation and logs.
- [Troubleshooting](docs/troubleshooting.md) for the old Homebrew tap, Gatekeeper
  and update failures.
- [Development](docs/development.md) for the repository layout and checks.

To run from source instead of Homebrew:

```bash
git clone https://github.com/mzored/update-all-mac.git
cd update-all-mac
./update-all-mac.command --help
```

Report problems in [GitHub issues](https://github.com/mzored/update-all-mac/issues).
Include the failed step and relevant log output. Remove private information first.

## License

[MIT](LICENSE).
