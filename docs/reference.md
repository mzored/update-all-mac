# Reference

[Back to README](../README.md)

## Options

| Option | Effect |
| --- | --- |
| `--only <id1,id2>` | Run selected steps. |
| `--skip <id1,id2>` | Skip selected steps. |
| `--dry-run` | Run detection and preview changes without updating packages or refreshing the Homebrew catalog. |
| `--doctor` | Report detected tools and versions, then exit. |
| `--list-steps` | Print step IDs, then exit. |
| `--verbose` | Stream full command output to the terminal. |
| `--parallel` | Run npm, pipx and App Store steps alongside the sequential steps. |
| `--fail-fast` | Stop sequential steps after the first failure. |
| `--strict` | Exit nonzero for warnings as well as failures. |
| `--exit-zero` | Exit zero even when steps warn or fail. The summary still reports problems. |
| `--no-color` | Disable terminal colors. |
| `--macos` | Add a macOS update check with `softwareupdate -l`. |
| `--greedy-casks` | Include Homebrew casks marked `auto_updates` or `latest`. |
| `--force-cask-repair` | Allow forced cask uninstall and reinstall if normal recovery fails. |
| `--mas-accurate` | Use slower, more accurate App Store update detection. |
| `--install-homebrew` | Install Homebrew non-interactively if it is missing. |
| `--deep-clean` | Purge reinstall caches during cleanup. |
| `--log-file <path>` | Set the log path. |
| `--lock-dir <path>` | Set the lock directory. |
| `-h`, `--help` | Show help, then exit. |

Homebrew, pip and uv stay sequential because they share state. With `--parallel`,
background steps keep separate temporary output and print their results after the
sequential steps. `--fail-fast` does not stop those background steps.

## Step IDs

| ID | Action |
| --- | --- |
| `homebrew` | Update unpinned formulae and casks. |
| `npm` | Update global packages. |
| `mas` | Update Mac App Store apps. |
| `ohmyzsh` | Update Oh My Zsh. |
| `pip` | Report the installed pip version. |
| `pipx` | Upgrade packages and shared libraries. Include injected packages when supported. |
| `uv` | Upgrade tools and, when supported by its installation method, uv itself. |
| `rust` | Update toolchains through rustup and crates through `cargo install-update`. |
| `mise` | Run `mise upgrade`. |
| `asdf` | Update plugins with `asdf plugin update --all`. |
| `gcloud` | Update Google Cloud CLI components when its installation supports it. |
| `cleanup` | Clean package caches. |
| `macos` | Check system updates. Requires `--macos`. |

Cleanup is a separate step. `--only homebrew` updates packages without cleaning
caches. Use `--only homebrew,cleanup` to do both.

## Cleanup

Default cleanup runs `brew cleanup --scrub`, `npm cache verify` and `uv cache prune`
when available. It keeps Rust, mise and asdf versions selected by projects.

`--deep-clean` also purges Homebrew, npm, pip, pipx and uv reinstall caches. Future
installs may need to download those files again. Preview it with
`update-all-mac --dry-run --deep-clean`.

## Automation

To run without the final interactive pause or terminal colors:

```bash
UPDATE_ALL_NO_PAUSE=1 update-all-mac --no-color
```

Set boolean variables to `1` to enable them or `0` to disable them.

| Variable | Equivalent option or default |
| --- | --- |
| `UPDATE_ALL_ONLY` | `--only` |
| `UPDATE_ALL_SKIP` | `--skip` |
| `UPDATE_ALL_EXIT_ZERO` | `--exit-zero` |
| `UPDATE_ALL_STRICT` | `--strict` |
| `UPDATE_ALL_FAIL_FAST` | `--fail-fast` |
| `UPDATE_ALL_NO_COLOR` | `--no-color` |
| `UPDATE_ALL_MACOS` | `--macos` |
| `UPDATE_ALL_HOMEBREW_GREEDY_CASKS` | `--greedy-casks` |
| `UPDATE_ALL_FORCE_CASK_REPAIR` | `--force-cask-repair` |
| `UPDATE_ALL_MAS_ACCURATE` | `--mas-accurate` |
| `UPDATE_ALL_PARALLEL` | `--parallel` |
| `UPDATE_ALL_DRY_RUN` | `--dry-run` |
| `UPDATE_ALL_INSTALL_HOMEBREW` | `--install-homebrew` |
| `UPDATE_ALL_VERBOSE` | `--verbose` |
| `UPDATE_ALL_DEEP_CLEAN` | `--deep-clean` |
| `UPDATE_ALL_LOG_FILE` | `--log-file` |
| `UPDATE_ALL_LOCK_DIR` | `--lock-dir` |
| `UPDATE_ALL_PIPX_INCLUDE_INJECTED` | Include injected pipx packages. Default `1`. |
| `UPDATE_ALL_NO_PAUSE` | Skip the final pause. Default `0`. |
| `UPDATE_ALL_LOG_MAX_BYTES` | Rotate logs above this size. Default `1048576` bytes. |
| `UPDATE_ALL_NET_TIMEOUT` | npm update timeout. Default `600` seconds. Requires `gtimeout` or `timeout`. |
| `UPDATE_ALL_HEARTBEAT_SECONDS` | Progress reminder interval. Default `30` seconds. |
| `UPDATE_ALL_TEMP_MAX_AGE_MINUTES` | Minimum age for stale run-directory cleanup. Default `1440` minutes. |

## Logs and interruption

The default log is `~/Library/Logs/update-all-mac.log`. Sequential commands write
their full output to the log in real time. Parallel steps append their captured
output when they finish. The terminal shows progress events and reminders with the
current operation, elapsed time and time since its last output.

Before the next run, logs larger than the configured limit rotate to
`update-all-mac.log.1`. The updater acquires `/tmp/update-all-mac.lock` before
opening or rotating the log, so another run cannot alter it.

Closing the terminal or sending HUP, INT or TERM stops active commands before
removing the lock and private temporary files. The next non-dry run removes old
private run directories only if their recorded owner process is gone. Other
temporary files are left alone.

## Homebrew recovery and passwords

An app directory ending in `.upgrading` marks an interrupted cask update. The
updater includes it in the normal cask batch. If recovery fails, it retries the
affected apps together with `brew reinstall --cask`. That extra batch may ask for
another password. Forced uninstall requires `--force-cask-repair`.

Interactive runs create a temporary `SUDO_ASKPASS` helper for the macOS password
dialog. The password goes to `sudo` and the updater does not store it. Existing
`SUDO_ASKPASS` configuration is preserved. Homebrew confirmation prompts are disabled.

Failed package discovery or verification stops the affected operation. Recovered
cask errors produce a warning. Unresolved errors fail the step. Pinned packages
are skipped and recorded in the log.
