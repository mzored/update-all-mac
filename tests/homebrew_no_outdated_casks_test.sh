#!/usr/bin/env bash
set -euo pipefail

# The pinned-cask filter must remain safe under macOS Bash 3.2 when Homebrew
# reports no outdated casks. Empty arrays fail under `set -u` if expanded.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home"

cat >"$tmp_dir/bin/brew" <<'BREW_STUB'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    "help update-if-needed" | "update-if-needed" | "cleanup" | \
        "outdated --formula --quiet" | "outdated --cask --quiet" | \
        "list --pinned")
        exit 0
        ;;
esac

printf 'unexpected brew call: %s\n' "$*" >&2
exit 64
BREW_STUB

chmod +x "$tmp_dir/bin/brew"

if ! PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$tmp_dir/run.log" \
    --lock-dir "$tmp_dir/lock" \
    --only homebrew >/dev/null 2>&1; then
    printf 'Expected an empty outdated-cask list to remain valid under macOS Bash.\n' >&2
    cat "$tmp_dir/run.log" >&2
    exit 1
fi
