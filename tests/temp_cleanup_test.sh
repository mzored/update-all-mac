#!/usr/bin/env bash
set -euo pipefail

# Startup cleanup removes only old private run directories with a dead owner.
# Other files, directories and active runs must survive.

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

recent_file="$tmp_dir/system-tmp/update-all-mac.recent-file"
old_dir="$tmp_dir/system-tmp/update-all-mac-run.old-dir"
recent_dir="$tmp_dir/system-tmp/update-all-mac-parallel.recent-dir"
foreign_file="$tmp_dir/system-tmp/update-all-mac.old-file"
foreign_dir="$tmp_dir/system-tmp/update-all-mac-parallel.old-dir"
unknown_dir="$tmp_dir/system-tmp/update-all-mac-run.no-owner"
active_dir="$tmp_dir/system-tmp/update-all-mac-run.active-dir"
protected_log="$tmp_dir/system-tmp/update-all-mac.log"
protected_rotated_log="$protected_log.1"
: >"$foreign_file"
: >"$recent_file"
: >"$protected_log"
: >"$protected_rotated_log"
mkdir -p "$old_dir" "$recent_dir" "$foreign_dir" "$unknown_dir" "$active_dir"
printf '99999999 1\n' >"$old_dir/owner"
printf '%s 1\n' "$$" >"$active_dir/owner"
touch -t 202001010000 "$foreign_file" "$old_dir" "$foreign_dir" "$unknown_dir" "$active_dir" "$protected_log" "$protected_rotated_log"

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

if [ -e "$old_dir" ]; then
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

if [ ! -e "$foreign_file" ] || [ ! -e "$foreign_dir" ] || [ ! -e "$unknown_dir" ] || [ ! -e "$active_dir" ]; then
    printf 'Cleanup removed another file or an active run.\n' >&2
    exit 1
fi

if find "$tmp_dir/system-tmp" -maxdepth 1 -type d -name 'update-all-mac-run.*' ! -name 'update-all-mac-run.active-dir' ! -name 'update-all-mac-run.no-owner' | grep -q .; then
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
