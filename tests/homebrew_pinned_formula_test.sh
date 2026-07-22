#!/usr/bin/env bash
set -euo pipefail

# Pinned formulae, like pinned casks, are expected state and must not make an
# otherwise successful Homebrew update fail.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home"
calls_file="$tmp_dir/calls.log"
run_log="$tmp_dir/run.log"

cat >"$tmp_dir/bin/brew" <<'BREW_STUB'
#!/usr/bin/env bash
set -euo pipefail

printf 'brew %s\n' "$*" >>"$CALLS_FILE"

case "$*" in
    "help update-if-needed" | "update-if-needed" | "cleanup" | \
        "outdated --cask --quiet")
        exit 0
        ;;
    "outdated --formula --quiet")
        printf 'pinned-tool\nregular-tool\n'
        exit 0
        ;;
    "list --pinned")
        printf 'pinned-tool\n'
        exit 0
        ;;
    "upgrade --formula regular-tool")
        exit 0
        ;;
    "upgrade --formula pinned-tool regular-tool")
        printf 'Error: pinned-tool is pinned. You must unpin it to upgrade.\n' >&2
        exit 1
        ;;
esac

printf 'unexpected brew call: %s\n' "$*" >&2
exit 64
BREW_STUB

chmod +x "$tmp_dir/bin/brew"

if ! CALLS_FILE="$calls_file" \
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$run_log" \
    --lock-dir "$tmp_dir/lock" \
    --only homebrew >/dev/null 2>&1; then
    printf 'Expected a pinned outdated formula not to fail the Homebrew step.\n' >&2
    cat "$run_log" >&2
    exit 1
fi

if ! grep -Fxq 'brew upgrade --formula regular-tool' "$calls_file"; then
    printf 'Expected the unpinned formula to be upgraded.\n' >&2
    cat "$calls_file" >&2
    exit 1
fi

if grep -Eq '^brew upgrade --formula .*pinned-tool' "$calls_file"; then
    printf 'Pinned formula must not be upgraded.\n' >&2
    cat "$calls_file" >&2
    exit 1
fi

if ! grep -Fq 'Skipping pinned formula: pinned-tool' "$run_log"; then
    printf 'Expected the log to explain that the pinned formula was skipped.\n' >&2
    cat "$run_log" >&2
    exit 1
fi
