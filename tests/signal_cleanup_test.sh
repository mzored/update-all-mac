#!/usr/bin/env bash
set -euo pipefail

# TERM must release both the single-run lock and the private runtime directory,
# even while a package-manager command is still running.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
updater_pid=""
heartbeat_pid=""
trap '[ -n "$updater_pid" ] && kill -KILL "$updater_pid" 2>/dev/null || true; [ -n "$heartbeat_pid" ] && kill -KILL "$heartbeat_pid" 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/system-tmp" "$tmp_dir/state"

cat >"$tmp_dir/bin/npm" <<'NPM_STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    outdated)
        printf 'demo 1.0.0 2.0.0\n'
        exit 1
        ;;
    update)
        printf '%s\n' "$$" >"$STATE_DIR/command-pid"
        touch "$STATE_DIR/started"
        sleep 30
        ;;
esac
exit 0
NPM_STUB
chmod +x "$tmp_dir/bin/npm"

TMPDIR="$tmp_dir/system-tmp" \
    STATE_DIR="$tmp_dir/state" \
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_HEARTBEAT_SECONDS=1 \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$tmp_dir/run.log" \
    --lock-dir "$tmp_dir/lock" \
    --only npm >"$tmp_dir/stdout.log" 2>&1 &
updater_pid=$!

for _ in {1..50}; do
    [ -f "$tmp_dir/state/started" ] && [ -d "$tmp_dir/lock" ] && break
    sleep 0.1
done

if [ ! -f "$tmp_dir/state/started" ]; then
    printf 'Updater did not reach the long-running command.\n' >&2
    exit 1
fi

for child_pid in $(pgrep -P "$updater_pid" 2>/dev/null || true); do
    if ps -p "$child_pid" -o command= | grep -Fq "$repo_root/update-all-mac.command"; then
        heartbeat_pid="$child_pid"
        break
    fi
done

if [ -z "$heartbeat_pid" ]; then
    printf 'Could not identify the active heartbeat child.\n' >&2
    exit 1
fi

kill -TERM "$updater_pid"
# Bash defers a trapped TERM while waiting for the foreground child. Ending the
# test stub models the same process-group signal a terminal sends on Ctrl-C.
command_pid=$(cat "$tmp_dir/state/command-pid")
pkill -TERM -P "$command_pid" 2>/dev/null || true
kill -TERM "$command_pid" 2>/dev/null || true
wait "$updater_pid" 2>/dev/null || true
updater_pid=""

if kill -0 "$heartbeat_pid" 2>/dev/null; then
    printf 'TERM left the heartbeat child running.\n' >&2
    exit 1
fi
heartbeat_pid=""

if [ -e "$tmp_dir/lock" ]; then
    printf 'TERM left the updater lock behind.\n' >&2
    exit 1
fi

if find "$tmp_dir/system-tmp" -maxdepth 1 -type d -name 'update-all-mac-run.*' | grep -q .; then
    printf 'TERM left a private runtime directory behind.\n' >&2
    find "$tmp_dir/system-tmp" -maxdepth 1 -print >&2
    exit 1
fi
