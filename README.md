# update-all-mac

Update macOS apps and developer tools with one command. The script uses the package
managers already installed on your Mac and skips missing tools.

## Install and run

Requires macOS and its built-in Bash. Install with Homebrew:

```bash
brew tap mzored/update-all-mac https://github.com/mzored/update-all-mac
brew install update-all-mac
update-all-mac
```

Updates can close or relaunch apps. Save your work first. Homebrew may ask for an
administrator password.

## Usage

Pass options to `update-all-mac`:

- `--dry-run` previews updates without changing packages.
- `--only homebrew,mas` updates only Homebrew packages and App Store apps.
- `--doctor` shows detected tools and their versions.
- `--help` lists all options and step IDs.

Full output goes to `~/Library/Logs/update-all-mac.log`. Add `--verbose` to see it
in the terminal.

## Supported tools

- Homebrew formulae and casks, except pinned packages.
- Mac App Store apps through [mas](https://github.com/mas-cli/mas).
- Global npm packages, pipx packages and uv tools.
- Oh My Zsh, Rust toolchains and crates, mise tools, asdf plugins and Google Cloud CLI.

The script also cleans unused package caches. `--macos` checks for system updates
without installing them.

## Documentation

- [Reference](docs/reference.md) for all options, automation and logs.
- [Troubleshooting](docs/troubleshooting.md) for installation and update problems.
- [Development](docs/development.md) to run from source and check changes.

Report problems in [GitHub issues](https://github.com/mzored/update-all-mac/issues).
Include the failed step and relevant log output. Remove private information first.

[MIT license](LICENSE).
