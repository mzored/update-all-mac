#!/usr/bin/env bash
set -euo pipefail

# When the log grows past UPDATE_ALL_LOG_MAX_BYTES, the next run rotates it once
# to "<log>.1" before appending, keeping the active log from growing forever.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/home"
run_log="$tmp_dir/run.log"
marker='OLD_LOG_MARKER_zzz'

# Seed an over-sized existing log.
{
    printf '%s\n' "$marker"
    head -c 4096 /dev/zero | tr '\0' 'x'
    printf '\n'
} >"$run_log"

# --only ohmyzsh is a clean no-op here (no ~/.oh-my-zsh in the temp HOME).
PATH="/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_NO_PAUSE=1 \
    UPDATE_ALL_LOG_MAX_BYTES=100 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$run_log" \
    --lock-dir "$tmp_dir/lock" \
    --only ohmyzsh >/dev/null 2>&1

if [ ! -f "$run_log.1" ]; then
    printf 'Expected a rotated log file at %s.1\n' "$run_log" >&2
    exit 1
fi

if ! grep -Fq "$marker" "$run_log.1"; then
    printf 'Rotated log should contain the previous run content.\n' >&2
    exit 1
fi

if grep -Fq "$marker" "$run_log"; then
    printf 'Active log should not contain the rotated-out content.\n' >&2
    exit 1
fi
