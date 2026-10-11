#!/usr/bin/env bash
set -euo pipefail
set -m

# Capture queries must stream both channels while running, then clean the
# command tree, stdout relay, lock, and private storage after each signal.
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=${UPDATER_TEST_SCRIPT:-$repo_root/update-all-mac.command}
tmp_dir=$(mktemp -d)
updater_pid=""
owned_pids=""
cleanup() {
    local pid=""
    [ -z "$updater_pid" ] || collect_descendants "$updater_pid"
    for pid in $owned_pids; do kill -KILL "$pid" 2>/dev/null || true; done
    [ -z "$updater_pid" ] || kill -KILL "$updater_pid" 2>/dev/null || true
    [ -z "$updater_pid" ] || wait "$updater_pid" 2>/dev/null || true
    rm -rf "$tmp_dir"
}
trap cleanup EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/system-tmp"
cat >"$tmp_dir/bin/npm" <<'STUB'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$STATE/calls"
[ "${1:-}" = outdated ] || exit 64
printf '%s\n' "$$" >"$STATE/command-pid"
printf 'capture stdout marker\n'
printf 'capture stderr marker\n' >&2
sleep 30 &
child=$!
printf '%s\n' "$child" >"$STATE/child-pid"
touch "$STATE/started"
wait "$child"
STUB
cat >"$tmp_dir/bin/brew" <<'STUB'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$STATE/calls"
case "$*" in
    'help update-if-needed'|'update-if-needed') exit 0 ;;
    '--caskroom')
        printf '%s\n' "$$" >"$STATE/command-pid"
        printf 'capture stdout marker\n'
        printf 'capture stderr marker\n' >&2
        sleep 30 &
        child=$!
        printf '%s\n' "$child" >"$STATE/child-pid"
        touch "$STATE/started"
        wait "$child" ;;
    *) exit 64 ;;
esac
STUB
chmod +x "$tmp_dir/bin/npm" "$tmp_dir/bin/brew"
export PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin"
[ "$(command -v npm)" = "$tmp_dir/bin/npm" ] || exit 1
[ "$(command -v brew)" = "$tmp_dir/bin/brew" ] || exit 1
process_alive() {
    local state=""
    state=$(ps -p "$1" -o state= 2>/dev/null | tr -d '[:space:]')
    [ -n "$state" ] && [[ "$state" != Z* ]]
}
collect_descendants() {
    local child=""
    for child in $(pgrep -P "$1" 2>/dev/null || true); do
        owned_pids="$owned_pids $child"
        collect_descendants "$child"
    done
}
fail() {
    printf '%s: %s\n' "$name" "$1" >&2
    [ ! -f "$state/processes" ] || cat "$state/processes" >&2
    [ ! -f "$state/remaining" ] || cat "$state/remaining" >&2
    cat "$state/stdout" >&2
    [ ! -f "$state/run.log" ] || cat "$state/run.log" >&2
    exit 1
}
for manager in npm homebrew; do
    for signal in HUP INT TERM; do
        name="$manager-$signal"; state="$tmp_dir/$name"; mkdir -p "$state"
        case "$signal" in HUP) expected_rc=129 ;; INT) expected_rc=130 ;; TERM) expected_rc=143 ;; esac
        TMPDIR="$tmp_dir/system-tmp" STATE="$state" HOME="$tmp_dir/home" UPDATE_ALL_NO_PAUSE=1 \
            /bin/bash "$script" --only "$manager" --no-color --verbose --log-file "$state/run.log" \
            --lock-dir "$state/lock" >"$state/stdout" 2>&1 &
        updater_pid=$!
        ready=0
        for ((attempt=0; attempt<80; attempt++)); do
            if [ -f "$state/started" ] && grep -Fq 'capture stdout marker' "$state/run.log" \
                && grep -Fq 'capture stderr marker' "$state/run.log"; then ready=1; break; fi
            sleep 0.05
        done
        [ "$ready" -eq 1 ] || fail 'query did not stream both channels before completion'
        [ -s "$state/calls" ] || fail 'fixture manager was not invoked'
        process_alive "$(cat "$state/command-pid")" || fail 'query exited before streaming assertions'
        grep -Fq 'capture stdout marker' "$state/stdout" || fail 'verbose terminal lost stdout while query runs'
        grep -Fq 'capture stderr marker' "$state/stdout" || fail 'verbose terminal lost stderr while query runs'
        owned_pids=""
        collect_descendants "$updater_pid"
        ps -p "$(printf '%s' "$owned_pids" | xargs | tr ' ' ',')" -o pid,ppid,pgid,state,command >"$state/processes"
        relay_found=0
        for pid in $owned_pids; do
            if [ "$(ps -p "$pid" -o comm= 2>/dev/null | xargs)" = tee ]; then relay_found=1; fi
        done
        [ "$relay_found" -eq 1 ] || fail 'did not observe an active stdout capture relay'
        kill -"$signal" "$updater_pid"
        actual_rc=0
        wait "$updater_pid" 2>/dev/null || actual_rc=$?
        updater_pid=""
        [ "$actual_rc" -eq "$expected_rc" ] || fail "updater exited $actual_rc, expected $expected_rc"
        for pid in $owned_pids; do
            if process_alive "$pid"; then
                ps -p "$pid" -o pid,ppid,pgid,state,command >"$state/remaining" || true
                fail "active captured descendant remains: $pid"
            fi
        done
        owned_pids=""
        [ ! -e "$state/lock" ] || fail 'signal left updater lock'
        if find "$tmp_dir/system-tmp" -maxdepth 1 -name 'update-all-mac-run.*' | grep -q .; then fail 'signal left private runtime storage'; fi
        grep -Fq "Run interrupted by $signal" "$state/run.log" || fail 'canonical log lost signal exit evidence'
    done
done
