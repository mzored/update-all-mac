#!/usr/bin/env bash
set -euo pipefail

# Startup cleanup may remove only updater-owned temp artifacts older than the
# configured threshold. Recent artifacts survive, and the current run's private
# scratch directory must be removed on normal exit.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/system-tmp"
calls_file="$tmp_dir/calls.log"

cat >"$tmp_dir/bin/npm" <<'NPM_STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    "cache --help") printf 'verify\n' ;;
    "cache verify") exit 0 ;;
esac
exit 0
NPM_STUB
chmod +x "$tmp_dir/bin/npm"

old_file="$tmp_dir/system-tmp/update-all-mac.old-file"
recent_file="$tmp_dir/system-tmp/update-all-mac.recent-file"
old_dir="$tmp_dir/system-tmp/update-all-mac-parallel.old-dir"
recent_dir="$tmp_dir/system-tmp/update-all-mac-parallel.recent-dir"
recent_empty_run_dir="$tmp_dir/system-tmp/update-all-mac-run.recent-empty"
protected_log="$tmp_dir/system-tmp/update-all-mac.log"
protected_rotated_log="$protected_log.1"
: >"$old_file"
: >"$recent_file"
: >"$protected_log"
: >"$protected_rotated_log"
mkdir -p "$old_dir" "$recent_dir" "$recent_empty_run_dir"
touch -t 202001010000 "$old_file" "$old_dir" "$protected_log" "$protected_rotated_log"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$recent_empty_run_dir"

CALLS_FILE="$calls_file" \
    TMPDIR="$tmp_dir/system-tmp" \
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_TEMP_MAX_AGE_MINUTES=60 \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$protected_log" \
    --lock-dir "$tmp_dir/lock" \
    --only npm >/dev/null 2>&1

if [ -e "$old_file" ] || [ -e "$old_dir" ]; then
    printf 'Old updater-owned temp artifacts were not removed.\n' >&2
    find "$tmp_dir/system-tmp" -maxdepth 1 -print >&2
    exit 1
fi

if [ ! -e "$protected_log" ] || [ ! -e "$protected_rotated_log" ]; then
    printf 'Stale-temp cleanup must never remove the active or rotated log.\n' >&2
    exit 1
fi

if [ ! -e "$recent_file" ] || [ ! -e "$recent_dir" ]; then
    printf 'Recent updater-owned temp artifacts must be preserved.\n' >&2
    exit 1
fi

if [ -e "$recent_empty_run_dir" ]; then
    printf 'Empty updater runtime directories are safe garbage after lock acquisition.\n' >&2
    exit 1
fi

if find "$tmp_dir/system-tmp" -maxdepth 1 -type d -name 'update-all-mac-run.*' | grep -q .; then
    printf 'The current run scratch directory leaked after exit.\n' >&2
    find "$tmp_dir/system-tmp" -maxdepth 1 -print >&2
    exit 1
fi

dry_run_file="$tmp_dir/system-tmp/update-all-mac.dry-run-survivor"
: >"$dry_run_file"
touch -t 202001010000 "$dry_run_file"

TMPDIR="$tmp_dir/system-tmp" \
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_TEMP_MAX_AGE_MINUTES=60 \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --dry-run \
    --no-color \
    --log-file "$tmp_dir/dry-run.log" \
    --lock-dir "$tmp_dir/dry-run-lock" \
    --only npm >/dev/null 2>&1

if [ ! -e "$dry_run_file" ]; then
    printf 'Dry-run must not remove stale temp artifacts.\n' >&2
    exit 1
fi
