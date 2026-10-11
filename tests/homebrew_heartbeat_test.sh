#!/usr/bin/env bash
set -euo pipefail

# The native macOS Bash 3.2 must measure silence since the latest command
# output, including output hidden by compact mode.
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=${UPDATER_TEST_SCRIPT:-$repo_root/update-all-mac.command}
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/caskroom"
cat >"$tmp_dir/bin/brew" <<'STUB'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$STATE/calls"
case "$*" in
    'help update-if-needed') exit 0 ;;
    'update-if-needed')
        if [ "$ACTIVITY" = active ]; then
            i=0
            while [ "$i" -lt 20 ]; do
                printf 'heartbeat fixture detail %s\n' "$i"
                sleep 0.2
                i=$((i + 1))
            done
        else
            sleep 4
        fi ;;
    '--caskroom') printf '%s\n' "$CASKROOM" ;;
    'list --pinned'|'list --cask'|'list --formula'|'outdated --cask --quiet'|'outdated --formula --quiet') exit 0 ;;
    *) exit 64 ;;
esac
STUB
chmod +x "$tmp_dir/bin/brew"
# Include every setup_path directory so fixtures retain precedence.
export PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin"
[ "$(command -v brew)" = "$tmp_dir/bin/brew" ] || exit 1
failures=0
fail() { printf '%s: %s\n' "$name" "$1" >&2; failures=$((failures + 1)); }
for activity in active silent; do
    for mode in compact verbose; do
        name="$activity-$mode"; state="$tmp_dir/$name"; mkdir -p "$state"
        args=(); [ "$mode" != verbose ] || args=(--verbose)
        rc=0
        ACTIVITY="$activity" STATE="$state" CASKROOM="$tmp_dir/caskroom" HOME="$tmp_dir/home" \
            UPDATE_ALL_NO_PAUSE=1 UPDATE_ALL_HEARTBEAT_SECONDS=1 \
            /bin/bash "$script" --only homebrew --no-color --log-file "$state/run.log" \
            --lock-dir "$state/lock" ${args[@]+"${args[@]}"} >"$state/stdout" 2>&1 || rc=$?
        [ -s "$state/calls" ] || { printf 'Fixture brew was not invoked.\n' >&2; exit 1; }
        [ "$rc" -eq 0 ] || fail 'fixture update must succeed'
        sed -nE 's/.*Still working on Homebrew metadata: ([0-9]+)s elapsed, no new output for ([0-9]+)s.*/\1 \2/p' \
            "$state/stdout" >"$state/beats"
        if ! awk '$1 >= 3 {found=1} END {exit !found}' "$state/beats"; then fail 'long operation must emit a late heartbeat'; fi
        if [ "$activity" = active ]; then
            if ! awk '$1 >= 3 && $2 > 1 {bad=1} END {exit bad}' "$state/beats"; then fail 'repeated output must reset silence in Bash 3.2'; fi
            grep -Fq 'heartbeat fixture detail 19' "$state/run.log" || fail 'canonical log must retain final output'
            if [ "$mode" = compact ]; then
                if grep -Fq 'heartbeat fixture detail' "$state/stdout"; then fail 'compact mode must keep detail in log'; fi
            else
                grep -Fq 'heartbeat fixture detail 19' "$state/stdout" || fail 'verbose mode must stream detail'
            fi
        else
            if ! awk '$1 >= 3 && $2 >= 2 {found=1} END {exit !found}' "$state/beats"; then fail 'genuinely silent command must report increasing silence'; fi
        fi
    done
done
[ "$failures" -eq 0 ]
