# Troubleshooting

[Back to README](../README.md)

Start with `update-all-mac --doctor` to check detected tools. Use `--verbose` to
see full output, or read `~/Library/Logs/update-all-mac.log`.

## Migrate from the old tap

If you installed from `mzored/tap`, switch to the tap in this repository:

```bash
brew uninstall update-all-mac
brew untap mzored/tap
brew tap mzored/update-all-mac https://github.com/mzored/update-all-mac
brew install update-all-mac
```

## macOS Gatekeeper blocks the script

Browser downloads, including GitHub's Download ZIP button, may add a quarantine
marker. The script is not a signed or notarized macOS app. Install through
Homebrew or clone with Git to avoid this download warning.

If you chose a browser download, review the script before removing its marker:

```bash
xattr -d com.apple.quarantine update-all-mac.command
chmod +x update-all-mac.command
./update-all-mac.command --no-color
```

Running from Terminal also shows errors hidden when double-clicking in Finder.

## macOS shows an App Management notice

This notice appears when Terminal or another host app replaces software in
`/Applications`. It is separate from the administrator password dialog. macOS
names the app that launched the updater.

## App Store updates are missing

Make sure you are signed in to the App Store and Spotlight indexes your App Store
apps. Try `update-all-mac --only mas --mas-accurate` for more accurate detection.

## Homebrew reports a link conflict

An upgrade can install a new version while another installation still owns its
command names. The updater keeps the step failed. Choose one installation method
for the conflicting tool. It does not overwrite another manager's files.

For example, Homebrew or global npm installations of pnpm can conflict with
Corepack's `pnpm` and `pnpx` shims. If you use Corepack, remove duplicate pnpm
installations through their original package managers, then run
`corepack enable pnpm`. Check installed dependents before removing a formula.

Warnings from a third-party tap stay in the log. Address them in that tap. They
do not by themselves mean an installed app failed to update.
