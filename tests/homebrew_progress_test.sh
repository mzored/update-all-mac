#!/usr/bin/env bash
set -euo pipefail

repo_root=$(pwd -P)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/home"

cat >"$tmp_dir/bin/brew" <<'BREW_STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    "help update-if-needed") exit 0 ;;
    "update-if-needed")
        printf '==> Auto-updating Homebrew...\n'
        [ "${BREW_SLEEP:-0}" = 0 ] || sleep "$BREW_SLEEP"
        printf '==> Fetching Homebrew repositories...\n'
        printf 'catalog detail kept in the log\n'
        exit "${BREW_EXIT:-0}"
        ;;
    "--caskroom") printf '%s\n' "$CASKROOM" ;;
    "outdated --formula --quiet" | "outdated --cask --quiet" | "list --pinned") exit 0 ;;
    "list --cask" | "list --formula") exit 0 ;;
    *) printf 'unexpected brew call: %s\n' "$*" >&2; exit 64 ;;
esac
BREW_STUB
chmod +x "$tmp_dir/bin/brew"

run_case() {
    local name="$1"
    local brew_exit="$2"
    local brew_sleep="$3"
    shift 3
    local rc=0
    BREW_EXIT="$brew_exit" BREW_SLEEP="$brew_sleep" CASKROOM="$tmp_dir/caskroom" \
        PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin" \
        HOME="$tmp_dir/home" UPDATE_ALL_NO_PAUSE=1 UPDATE_ALL_HEARTBEAT_SECONDS=1 \
        /bin/bash "$repo_root/update-all-mac.command" \
        --no-color --log-file "$tmp_dir/$name.log" --lock-dir "$tmp_dir/$name-lock" \
        --only homebrew "$@" >"$tmp_dir/$name.stdout" 2>&1 || rc=$?
    printf '%s\n' "$rc"
}

if [ "$(run_case compact 0 2)" -ne 0 ]; then
    printf 'Compact Homebrew update failed.\n' >&2
    exit 1
fi
for expected in 'Auto-updating Homebrew' 'Fetching Homebrew repositories' 'Still working on Homebrew metadata' 'no new output for'; do
    if ! grep -Fq "$expected" "$tmp_dir/compact.stdout"; then
        printf 'Missing compact progress event: %s\n' "$expected" >&2
        cat "$tmp_dir/compact.stdout" >&2
        exit 1
    fi
done
if grep -Fq 'catalog detail kept in the log' "$tmp_dir/compact.stdout"; then
    printf 'Compact output leaked unfiltered command detail.\n' >&2
    exit 1
fi
if ! grep -Fq 'catalog detail kept in the log' "$tmp_dir/compact.log"; then
    printf 'Full command output was not streamed to the log.\n' >&2
    exit 1
fi

if [ "$(run_case verbose 0 0 --verbose)" -ne 0 ] || ! grep -Fq 'catalog detail kept in the log' "$tmp_dir/verbose.stdout"; then
    printf 'Verbose mode did not show the complete command output.\n' >&2
    exit 1
fi

if [ "$(run_case failed 42 0)" -ne 1 ] || ! grep -Fq 'Homebrew failed' "$tmp_dir/failed.stdout"; then
    printf 'A failed Homebrew refresh did not reach the final status.\n' >&2
    cat "$tmp_dir/failed.stdout" >&2
    exit 1
fi
