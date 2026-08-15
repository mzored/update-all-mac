#!/usr/bin/env bash
set -euo pipefail

# A long-running command must stream its output into the canonical log before
# it exits. Otherwise an interrupted run loses the evidence needed to diagnose
# where it stopped, as happened during the Docker Desktop cask upgrade.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
updater_pid=""
trap '[ -n "$updater_pid" ] && kill "$updater_pid" 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/state"
run_log="$tmp_dir/run.log"
stdout_file="$tmp_dir/stdout.log"
marker='STREAMED_BEFORE_EXIT_7f91'

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
        touch "$STATE_DIR/marker-written"
        sleep 4
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
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$run_log" \
    --lock-dir "$tmp_dir/lock" \
    --only npm >"$stdout_file" 2>&1 &
updater_pid=$!

for _ in {1..40}; do
    [ -f "$tmp_dir/state/marker-written" ] && break
    sleep 0.1
done

if [ ! -f "$tmp_dir/state/marker-written" ]; then
    printf 'The npm stub never reached its long-running update.\n' >&2
    exit 1
fi

if ! grep -Fq "$marker" "$run_log"; then
    printf 'Expected command output in the canonical log before command exit.\n' >&2
    printf '%s\n' '--- canonical log ---' >&2
    cat "$run_log" >&2
    exit 1
fi

wait "$updater_pid"
updater_pid=""
