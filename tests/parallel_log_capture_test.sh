#!/usr/bin/env bash
set -euo pipefail

# Parallel workers use captured stdout as their replay transport. Compact mode
# must not discard raw command details before the worker can append them to the
# canonical log.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/state"
run_log="$tmp_dir/run.log"
marker='PARALLEL_COMMAND_DETAIL_81be'
stdout_file="$tmp_dir/stdout.log"

cat >"$tmp_dir/bin/npm" <<'NPM_STUB'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    outdated)
        if [ -f "$STATE_DIR/upgraded" ]; then
            exit 0
        fi
        printf 'demo 1.0.0 2.0.0\n'
        exit 1
        ;;
    update)
        printf '%s\n' "$MARKER"
        sleep 2
        touch "$STATE_DIR/upgraded"
        exit 0
        ;;
esac
exit 0
NPM_STUB

chmod +x "$tmp_dir/bin/npm"

MARKER="$marker" \
    STATE_DIR="$tmp_dir/state" \
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_HEARTBEAT_SECONDS=1 \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --parallel \
    --no-color \
    --log-file "$run_log" \
    --lock-dir "$tmp_dir/lock" \
    --only npm >"$stdout_file" 2>&1

if ! grep -Fq "$marker" "$run_log"; then
    printf 'Parallel compact mode lost command output from the log.\n' >&2
    cat "$run_log" >&2
    exit 1
fi

if grep -Fq "$marker" "$stdout_file"; then
    printf 'Parallel compact mode leaked raw command output to the terminal.\n' >&2
    cat "$stdout_file" >&2
    exit 1
fi

if ! grep -Fq 'Still working' "$stdout_file"; then
    printf 'Parallel waiting needs a visible heartbeat.\n' >&2
    cat "$stdout_file" >&2
    exit 1
fi
if ! grep -Fq 'Parallel package managers' "$stdout_file"; then
    printf 'Parallel waiting must name the work still running.\n' >&2
    cat "$stdout_file" >&2
    exit 1
fi
