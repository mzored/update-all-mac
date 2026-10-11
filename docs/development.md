# Development

[Back to README](../README.md)

## Repository layout

| Path | Purpose |
| --- | --- |
| `update-all-mac.command` | Executable updater. Homebrew installs it as `update-all-mac`. |
| `Formula/` | Homebrew formula. |
| `tests/` | Shell regression tests with temporary fixtures and cleanup traps. |
| `docs/` | User reference, troubleshooting and development notes. |
| `.github/workflows/` | CI checks and tagged releases. |

## Checks

Run from the repository root. ShellCheck and shfmt must be installed.

```bash
bash -n update-all-mac.command
shellcheck -s bash update-all-mac.command
shfmt -i 4 -ci -bn -d update-all-mac.command
tests/release_docs_test.sh
ruby -c Formula/update-all-mac.rb
git diff --check
```

Run the affected behavior tests in `tests/` for script changes. The complete CI
sequence, including Homebrew installation checks, lives in
[ci.yml](../.github/workflows/ci.yml).

Pushes and pull requests run CI. Pushing a `v*` tag creates a GitHub release with
the script attached. Documentation changes do not need a version bump or a tag.
