#!/usr/bin/env bash
set -euo pipefail
set -m

# A signal sent to the updater must stop the command tree before removing the
# lock and private scratch directory. Check both schedulers and a fresh rerun.

repo_root=$(pwd -P)
tmp_dir=$(mktemp -d)
updater_pid=""
trap '[ -z "$updater_pid" ] || kill -KILL "$updater_pid" 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/system-tmp"
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
        printf '%s\n' "$$" >"$STATE_DIR/command-pid"
        sleep 30 &
        child=$!
        printf '%s\n' "$child" >"$STATE_DIR/child-pid"
        touch "$STATE_DIR/started"
        [ "${DETACH:-0}" = 1 ] && exit 0
        wait "$child"
        ;;
esac
NPM_STUB
chmod +x "$tmp_dir/bin/npm"

process_alive() {
    local state=""
    state=$(ps -p "$1" -o state= 2>/dev/null | tr -d '[:space:]')
    [ -n "$state" ] && [[ "$state" != Z* ]]
}

run_case() {
    local signal="$1"
    local mode="$2"
    local expected_rc="$3"
    local detached="${4:-0}"
    local name="$signal-$mode-$detached"
    local state_dir="$tmp_dir/$name-state"
    local run_log="$tmp_dir/$name.log"
    local lock_dir="$tmp_dir/$name-lock"
    local command_pid="" child_pid="" actual_rc=0
    local -a extra_args=(--only npm)
    local attempt=0

    mkdir -p "$state_dir"
    [ "$mode" = parallel ] && extra_args+=(--parallel)
    TMPDIR="$tmp_dir/system-tmp" \
        STATE_DIR="$state_dir" DETACH="$detached" \
        PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin" \
        HOME="$tmp_dir/home" \
        UPDATE_ALL_NO_PAUSE=1 \
        /bin/bash "$repo_root/update-all-mac.command" \
        --no-color --log-file "$run_log" --lock-dir "$lock_dir" \
        "${extra_args[@]}" >"$tmp_dir/$name.stdout" 2>&1 &
    updater_pid=$!

    for ((attempt = 0; attempt < 80; attempt++)); do
        [ -f "$state_dir/started" ] && break
        sleep 0.1
    done
    if [ ! -f "$state_dir/started" ]; then
        printf 'Did not reach the command in %s.\n' "$name" >&2
        cat "$tmp_dir/$name.stdout" >&2
        exit 1
    fi
    command_pid=$(cat "$state_dir/command-pid")
    child_pid=$(cat "$state_dir/child-pid")
    [ "$detached" -eq 0 ] || sleep 0.2
    kill -"$signal" "$updater_pid"
    wait "$updater_pid" 2>/dev/null || actual_rc=$?
    updater_pid=""

    if [ "$actual_rc" -ne "$expected_rc" ]; then
        printf '%s exited %s, expected %s.\n' "$name" "$actual_rc" "$expected_rc" >&2
        cat "$tmp_dir/$name.stdout" >&2
        exit 1
    fi
    if process_alive "$command_pid" || process_alive "$child_pid"; then
        printf '%s left an active command or child.\n' "$name" >&2
        ps -p "$command_pid,$child_pid" -o pid,ppid,state,command >&2 || true
        exit 1
    fi
    if [ -e "$lock_dir" ] || find "$tmp_dir/system-tmp" -maxdepth 1 -type d -name 'update-all-mac-run.*' | grep -q .; then
        printf '%s left its lock or private scratch directory.\n' "$name" >&2
        exit 1
    fi
    if ! grep -Fq "Run interrupted by $signal" "$run_log"; then
        printf '%s did not record the signal in the log.\n' "$name" >&2
        exit 1
    fi

    TMPDIR="$tmp_dir/system-tmp" \
        STATE_DIR="$state_dir" FAST=1 \
        PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin" \
        HOME="$tmp_dir/home" UPDATE_ALL_NO_PAUSE=1 \
        /bin/bash "$repo_root/update-all-mac.command" \
        --no-color --log-file "$run_log" --lock-dir "$lock_dir" \
        "${extra_args[@]}" >/dev/null 2>&1
}

run_case HUP sequential 129
run_case INT sequential 130
run_case TERM sequential 143
run_case HUP parallel 129
run_case INT parallel 130
run_case TERM parallel 143
run_case HUP sequential 129 1
run_case TERM parallel 143 1
