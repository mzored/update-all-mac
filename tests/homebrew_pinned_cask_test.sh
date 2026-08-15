#!/usr/bin/env bash
set -euo pipefail

# An outdated cask intentionally pinned by the user is expected state. It must
# be excluded from upgrade and repair attempts without failing the Homebrew
# step, while unpinned outdated casks still upgrade normally.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/state" "$tmp_dir/caskroom/alt-tab/1.0.upgrading"
calls_file="$tmp_dir/calls.log"
outdated_count_file="$tmp_dir/state/outdated-count"
run_log="$tmp_dir/run.log"

cat >"$tmp_dir/bin/brew" <<'BREW_STUB'
#!/usr/bin/env bash
set -euo pipefail

printf 'brew %s\n' "$*" >>"$CALLS_FILE"

case "$*" in
    "help update-if-needed" | "update-if-needed" | "cleanup")
        exit 0
        ;;
    "outdated --formula --quiet")
        exit 0
        ;;
    "--caskroom")
        printf '%s\n' "$CASKROOM"
        exit 0
        ;;
    "outdated --cask --quiet")
        count=0
        if [ -f "$OUTDATED_COUNT_FILE" ]; then
            count=$(cat "$OUTDATED_COUNT_FILE")
        fi
        count=$((count + 1))
        printf '%s\n' "$count" >"$OUTDATED_COUNT_FILE"

        printf 'alt-tab\n'
        if [ "$count" -eq 1 ]; then
            printf 'regular-app\n'
        fi
        exit 0
        ;;
    "list --pinned")
        printf 'alt-tab\n'
        exit 0
        ;;
    "info --cask alt-tab" | "info --cask regular-app")
        exit 0
        ;;
    "upgrade --cask regular-app")
        exit 0
        ;;
    "upgrade --cask alt-tab regular-app")
        printf 'Error: alt-tab is pinned. You must unpin it to upgrade.\n' >&2
        exit 1
        ;;
    "reinstall --cask alt-tab")
        printf 'Error: alt-tab is pinned. You must unpin it to reinstall.\n' >&2
        exit 1
        ;;
esac

printf 'unexpected brew call: %s\n' "$*" >&2
exit 64
BREW_STUB

chmod +x "$tmp_dir/bin/brew"

if ! CALLS_FILE="$calls_file" \
    OUTDATED_COUNT_FILE="$outdated_count_file" \
    CASKROOM="$tmp_dir/caskroom" \
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$run_log" \
    --lock-dir "$tmp_dir/lock" \
    --only homebrew >/dev/null 2>&1; then
    printf 'Expected a pinned outdated cask not to fail the Homebrew step.\n' >&2
    cat "$run_log" >&2
    exit 1
fi

if ! grep -Fxq 'brew upgrade --cask regular-app' "$calls_file"; then
    printf 'Expected the unpinned cask to be upgraded.\n' >&2
    cat "$calls_file" >&2
    exit 1
fi

if grep -Eq '^brew (upgrade|reinstall) --cask .*alt-tab' "$calls_file"; then
    printf 'Pinned cask must not be upgraded or repaired.\n' >&2
    cat "$calls_file" >&2
    exit 1
fi

if ! grep -Fq 'Skipping pinned cask: alt-tab' "$run_log"; then
    printf 'Expected the log to explain that the pinned cask was skipped.\n' >&2
    cat "$run_log" >&2
    exit 1
fi

if ! grep -Fq 'Skipping pinned interrupted cask: alt-tab' "$run_log"; then
    printf 'Expected a pinned interrupted cask to remain pinned and skipped.\n' >&2
    cat "$run_log" >&2
    exit 1
fi
