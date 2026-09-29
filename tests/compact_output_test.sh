#!/usr/bin/env bash
set -euo pipefail

# Default terminal output should stay compact but visibly alive during a long
# command. --verbose must restore the complete command stream without changing
# what is captured in the canonical log.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home"
marker='DETAIL_ONLY_IN_VERBOSE_f4c2'

cat >"$tmp_dir/bin/npm" <<'NPM_STUB'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    outdated)
        if [ "${SLOW_OUTDATED:-0}" = 1 ] && [ ! -f "$STATE_DIR/upgraded" ]; then
            sleep 2
        fi
        if [ -f "$STATE_DIR/upgraded" ]; then
            exit 0
        fi
        printf 'demo 1.0.0 2.0.0\n'
        exit 1
        ;;
    update)
        printf '%s\n' "$MARKER"
        sleep 3
        touch "$STATE_DIR/upgraded"
        exit 0
        ;;
esac
exit 0
NPM_STUB

chmod +x "$tmp_dir/bin/npm"

run_case() {
    local name="$1"
    shift
    local state_dir="$tmp_dir/$name-state"
    local run_log="$tmp_dir/$name-run.log"
    local stdout_file="$tmp_dir/$name-stdout.log"
    mkdir -p "$state_dir"

    MARKER="$marker" \
        SLOW_OUTDATED="${SLOW_OUTDATED:-0}" \
        STATE_DIR="$state_dir" \
        PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
        HOME="$tmp_dir/home" \
        UPDATE_ALL_HEARTBEAT_SECONDS=1 \
        UPDATE_ALL_NO_PAUSE=1 \
        /bin/bash "$repo_root/update-all-mac.command" \
        --no-color \
        --log-file "$run_log" \
        --lock-dir "$tmp_dir/$name-lock" \
        --only npm "$@" >"$stdout_file" 2>&1
}

run_case compact

if grep -Fq "$marker" "$tmp_dir/compact-stdout.log"; then
    printf 'Compact output must not print raw command details.\n' >&2
    cat "$tmp_dir/compact-stdout.log" >&2
    exit 1
fi

if grep -Fq 'demo 1.0.0 2.0.0' "$tmp_dir/compact-stdout.log"; then
    printf 'Compact output must keep package tables in the log only.\n' >&2
    cat "$tmp_dir/compact-stdout.log" >&2
    exit 1
fi

if ! grep -Fq 'Still working' "$tmp_dir/compact-stdout.log"; then
    printf 'Compact output needs a heartbeat during long commands.\n' >&2
    cat "$tmp_dir/compact-stdout.log" >&2
    exit 1
fi

if ! grep -Fq 'if input is expected' "$tmp_dir/compact-stdout.log"; then
    printf 'Compact output must explain how to uncover a hidden prompt.\n' >&2
    cat "$tmp_dir/compact-stdout.log" >&2
    exit 1
fi

if ! grep -Fq "$marker" "$tmp_dir/compact-run.log"; then
    printf 'Compact mode must retain command details in the log.\n' >&2
    cat "$tmp_dir/compact-run.log" >&2
    exit 1
fi

run_case verbose --verbose

if ! grep -Fq "$marker" "$tmp_dir/verbose-stdout.log"; then
    printf -- '--verbose must print raw command details.\n' >&2
    cat "$tmp_dir/verbose-stdout.log" >&2
    exit 1
fi

SLOW_OUTDATED=1 run_case slow-check
if ! grep -Fq 'Still working on Checking npm global packages' "$tmp_dir/slow-check-stdout.log"; then
    printf 'A slow read-only check did not show its operation and wait time.\n' >&2
    cat "$tmp_dir/slow-check-stdout.log" >&2
    exit 1
fi
