#!/usr/bin/env bash
set -euo pipefail

# A rejected concurrent run must not open or rotate the active run's log.

repo_root=$(pwd -P)
tmp_dir=$(mktemp -d)
updater_pid=""
trap '[ -z "$updater_pid" ] || kill -TERM "$updater_pid" 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/state"

cat >"$tmp_dir/bin/npm" <<'NPM_STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    outdated)
        [ "${FAST:-0}" = 1 ] && exit 0
        printf 'demo 1.0.0 2.0.0\n'
        exit 1
        ;;
    update)
        touch "$STATE_DIR/started"
        sleep 3
        ;;
esac
NPM_STUB
chmod +x "$tmp_dir/bin/npm"

run_update() {
    STATE_DIR="$tmp_dir/state" FAST="${FAST:-0}" \
        PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin" \
        HOME="$tmp_dir/home" UPDATE_ALL_NO_PAUSE=1 UPDATE_ALL_LOG_MAX_BYTES=100 \
        /bin/bash "$repo_root/update-all-mac.command" \
        --no-color --log-file "$tmp_dir/run.log" --lock-dir "$tmp_dir/lock" --only npm
}

run_update >"$tmp_dir/first.stdout" 2>&1 &
updater_pid=$!
for _ in {1..80}; do
    [ -f "$tmp_dir/state/started" ] && break
    sleep 0.1
done
if [ ! -f "$tmp_dir/state/started" ]; then
    printf 'First run did not reach the long-running command.\n' >&2
    exit 1
fi

size_before=$(stat -f '%z' "$tmp_dir/run.log")
rc=0
run_update >"$tmp_dir/second.stdout" 2>&1 || rc=$?
size_after=$(stat -f '%z' "$tmp_dir/run.log")
if [ "$rc" -ne 1 ] || [ "$size_before" -ne "$size_after" ] || [ -e "$tmp_dir/run.log.1" ]; then
    printf 'Concurrent run changed the active log or was not rejected.\n' >&2
    exit 1
fi

wait "$updater_pid"
updater_pid=""
if [ -e "$tmp_dir/lock" ]; then
    printf 'First run left its lock behind.\n' >&2
    exit 1
fi

mkdir "$tmp_dir/lock"
printf '99999999\n' >"$tmp_dir/lock/pid"
# shlock waits for a stable stale file before reclaiming it.
sleep 2
rc=0
FAST=1 run_update >"$tmp_dir/stale.stdout" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
    printf 'Run with a dead owner lock failed (exit %s).\n' "$rc" >&2
    cat "$tmp_dir/stale.stdout" >&2
    exit 1
fi
if [ -e "$tmp_dir/lock" ] || ! grep -Fq 'Found a stale lock' "$tmp_dir/stale.stdout"; then
    printf 'Dead owner lock was not recovered and cleaned.\n' >&2
    exit 1
fi
