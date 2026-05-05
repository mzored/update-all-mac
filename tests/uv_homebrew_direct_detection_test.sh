#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home"
calls_file="$tmp_dir/calls.log"

cat >"$tmp_dir/bin/brew" <<'BREW_STUB'
#!/usr/bin/env bash
set -euo pipefail

printf 'brew %s\n' "$*" >>"$CALLS_FILE"

case "$*" in
    "help update-if-needed")
        exit 0
        ;;
    "update-if-needed")
        exit 0
        ;;
    "list --formula")
        # Simulate a broad list response that is insufficient for uv detection.
        printf 'mas\n'
        exit 0
        ;;
    "list --formula uv")
        printf '/opt/homebrew/Cellar/uv/0.11.8/bin/uv\n'
        exit 0
        ;;
    "outdated --formula --quiet uv")
        exit 0
        ;;
esac

printf 'unexpected brew call: %s\n' "$*" >&2
exit 64
BREW_STUB

cat >"$tmp_dir/bin/uv" <<'UV_STUB'
#!/usr/bin/env bash
set -euo pipefail

printf 'uv %s\n' "$*" >>"$CALLS_FILE"

case "$*" in
    "self update")
        printf 'uv was installed through an external package manager\n'
        exit 0
        ;;
    "tool upgrade --help")
        printf 'Usage: uv tool upgrade --all\n'
        exit 0
        ;;
    "tool upgrade --all")
        exit 0
        ;;
esac

printf 'unexpected uv call: %s\n' "$*" >&2
exit 64
UV_STUB

chmod +x "$tmp_dir/bin/brew" "$tmp_dir/bin/uv"

CALLS_FILE="$calls_file" \
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$tmp_dir/run.log" \
    --lock-dir "$tmp_dir/lock" \
    --only uv >/dev/null

if ! grep -Fxq 'brew list --formula uv' "$calls_file"; then
    printf 'Expected uv detection to use a direct Homebrew formula check.\n' >&2
    printf 'Observed calls:\n' >&2
    cat "$calls_file" >&2
    exit 1
fi

if grep -Fxq 'uv self update' "$calls_file"; then
    printf 'Did not expect uv self update for directly detected Homebrew-managed uv.\n' >&2
    cat "$calls_file" >&2
    exit 1
fi
